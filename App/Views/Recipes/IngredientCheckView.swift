import SwiftUI
import SwiftData
import RecipeKit

/// One card per flagged ingredient: conflicts, dislikes, missing items, "Do you have X?" and
/// heat. The user picks swaps (or keeps the original); Save applies them and records a revision.
struct IngredientCheckView: View {
    let recipe: Recipe
    /// Nil when importing; the saved recipe when re-checking from the detail screen.
    let existing: SavedRecipe?
    /// Importing a recipe a friend shared (`.mise`): the first revision says so, and their
    /// photo (if any) becomes the card image.
    var shared: SharedImport? = nil
    var onSaved: (SavedRecipe) -> Void

    struct SharedImport {
        var photo: ProcessedCookPhoto?
    }

    @Environment(\.modelContext) private var context
    @Environment(AssistantProvider.self) private var provider
    @State private var items: [ReviewItem] = []
    @State private var loaded = false
    /// Answers to "Do you have X?" (true = yes), by pantry key, so an ingredient listed twice
    /// is only asked about once.
    @State private var answers: [String: Bool] = [:]
    /// Accessibility identifier base per item: the pantry key, with "-2", "-3"… for repeats.
    @State private var idBases: [UUID: String] = [:]
    /// Chosen swap ID per ingredient; absent = keep original.
    @State private var choices: [UUID: String] = [:]
    /// Spicy ingredients the user agreed to halve.
    @State private var halved: Set<UUID> = []
    @State private var prefs = UserPreferences()
    @State private var checkingSteps = false
    @State private var rewriteReview: RewriteReview?

    /// The chosen swaps plus the model's step rewrites, waiting for the user to pick rewrites.
    struct RewriteReview: Identifiable {
        let id = UUID()
        let edits: [RecipeEdit]
        var rewrites: [EditProposal]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                header
                ForEach(items) { item in
                    card(for: item)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("review.\(idBase(item))")
                }
                Text("Flags are based on a limited ingredient list; check labels if you have allergies.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color.mise.inkSecondary)
                    .padding(.top, Theme.Spacing.xs)
                    .accessibilityIdentifier("review.disclaimer")
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .miseScreenBackground()
        .sheet(item: $rewriteReview) { review in
            NavigationStack {
                RewriteReviewView(review: review) { chosen in
                    rewriteReview = nil
                    finishSave(review.edits + chosen)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: save) {
                if checkingSteps {
                    HStack(spacing: Theme.Spacing.xs) { ProgressView().tint(Color.mise.onAccent); Text("Checking steps…") }
                } else {
                    Text(existing == nil ? "Save recipe" : "Save changes")
                }
            }
                .buttonStyle(.misePrimary)
                .disabled(checkingSteps)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.mise.background)
                .accessibilityIdentifier("review.save")
        }
        .navigationTitle("Ingredient check")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(recipe.title).serifTitle().accessibilityAddTraits(.isHeader)
            let meta = RecipeFormat.metadata(recipe)
            Text([meta, "\(recipe.ingredients.count) ingredients"].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(Color.mise.inkSecondary)
            if loaded {
                Text(items.isEmpty ? "Everything looks good for you." : "\(items.count) \(items.count == 1 ? "thing" : "things") to check before you save.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color.mise.ink)
                    .padding(.top, Theme.Spacing.xs)
                    .accessibilityIdentifier("review.summary")
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func card(for item: ReviewItem) -> some View {
        let name = RecipeFormat.capitalised(item.ingredient.name)
        switch item.kind {
        case .conflict(let reasons):
            ReviewCard(tone: .conflict, systemImage: "exclamationmark.triangle.fill", title: name, subtitle: reasons.joined(separator: " · ")) {
                swapList(item)
                halfOption(item)
            }
        case .dislike(let what):
            ReviewCard(tone: .caution, systemImage: "hand.thumbsdown", title: name, subtitle: "You said you don't like \(what)") {
                swapList(item)
            }
        case .missing:
            ReviewCard(tone: .caution, systemImage: "cart", title: name, subtitle: "Not in your pantry") {
                swapList(item)
                halfOption(item)
            }
        case .askHave:
            askCard(item, name: name)
        case .tooSpicy:
            ReviewCard(tone: .caution, systemImage: "flame", title: name, subtitle: "You prefer milder food") {
                halfOption(item)
            }
        }
    }

    @ViewBuilder
    private func askCard(_ item: ReviewItem, name: String) -> some View {
        switch answers[item.pantryKey] {
        case .some(true):
            ReviewCard(tone: .herb, systemImage: "checkmark.circle.fill", title: name, subtitle: "Saved to your pantry") {
                halfOption(item)
            }
        case .some(false):
            ReviewCard(tone: .caution, systemImage: "cart", title: name, subtitle: "Saved as missing. Pick a swap, or keep it and buy some.") {
                swapList(item)
                halfOption(item)
            }
        case .none:
            ReviewCard(tone: .caution, systemImage: "questionmark.circle", title: "Do you have \(item.ingredient.name)?",
                       subtitle: RecipeFormat.amount(item.ingredient).map { "Recipe uses \($0)" }) {
                HStack(spacing: Theme.Spacing.s) {
                    Button("Yes") { answer(item, have: true) }
                        .buttonStyle(.miseSecondaryWide)
                        .accessibilityIdentifier("review.\(idBase(item)).yes")
                    Button("No") { answer(item, have: false) }
                        .buttonStyle(.miseSecondaryWide)
                        .accessibilityIdentifier("review.\(idBase(item)).no")
                }
            }
        }
    }

    @ViewBuilder
    private func swapList(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(item.swaps) { swap in
                swapRow(item: item, title: swap.title, note: swap.note, fromPantry: swap.fromPantry,
                        selected: choices[item.id] == swap.id, identifier: "swap.\(idBase(item)).\(swap.id)") {
                    choices[item.id] = swap.id
                }
                Divider().overlay(Color.mise.divider)
            }
            swapRow(item: item, title: "Keep original", note: nil, fromPantry: false,
                    selected: choices[item.id] == nil, identifier: "swap.\(idBase(item)).keep") {
                choices[item.id] = nil
            }
        }
    }

    private func swapRow(item: ReviewItem, title: String, note: String?, fromPantry: Bool, selected: Bool,
                         identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.mise.accent : Color.mise.inkSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(Theme.Fonts.body).foregroundStyle(Color.mise.ink)
                    if let note, !note.isEmpty, note != title {
                        Text(note).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    }
                    if fromPantry { Badge(title: "From your pantry", systemImage: "checkmark") }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .frame(minHeight: Theme.Size.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func halfOption(_ item: ReviewItem) -> some View {
        if let scale = item.suggestedScale, item.ingredient.quantity != nil {
            Toggle(isOn: Binding(get: { halved.contains(item.id) },
                                 set: { on in if on { halved.insert(item.id) } else { halved.remove(item.id) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scale == 0.5 ? "Use half" : "Use less").foregroundStyle(Color.mise.ink)
                    if let before = RecipeFormat.amount(item.ingredient), let after = RecipeFormat.amount(item.ingredient.scaled(by: scale)) {
                        Text("\(before) → \(after)").font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary).monospacedDigit()
                    }
                }
            }
            .tint(Color.mise.accent)
            .accessibilityIdentifier("review.\(idBase(item)).half")
        }
    }

    private func idBase(_ item: ReviewItem) -> String { idBases[item.id] ?? item.pantryKey }

    // MARK: Actions

    private func load() async {
        guard !loaded else { return }
        prefs = context.profile().prefs
        let pantry = context.pantrySnapshot()
        var reviewed = SwapEngine().review(recipe: recipe, pantry: pantry, prefs: prefs)
        // Spicy-only cards default to "use half"; that's what they're for.
        for item in reviewed where item.kind == .tooSpicy && item.ingredient.quantity != nil { halved.insert(item.id) }
        var seen: [String: Int] = [:]
        for item in reviewed {
            seen[item.pantryKey, default: 0] += 1
            let n = seen[item.pantryKey]!
            idBases[item.id] = n == 1 ? item.pantryKey : "\(item.pantryKey)-\(n)"
        }
        items = reviewed
        loaded = true
        // Ask the assistant for swaps the bundled table doesn't have.
        let assistant = provider.assistant
        for index in reviewed.indices where reviewed[index].swaps.isEmpty && reviewed[index].kind != .tooSpicy {
            let ingredient = reviewed[index].ingredient
            if let swaps = try? await assistant.suggestSwaps(for: ingredient, in: recipe, pantry: pantry, prefs: prefs), !swaps.isEmpty {
                reviewed[index].swaps = swaps
                items = reviewed
            }
        }
    }

    private func answer(_ item: ReviewItem, have: Bool) {
        withAnimation { answers[item.pantryKey] = have }
        context.setPantry(key: item.pantryKey, displayName: item.ingredient.name.lowercased(), status: have ? .have : .missing)
        try? context.save()
    }

    private func edits() -> [RecipeEdit] {
        var edits: [RecipeEdit] = []
        for item in items {
            if let choice = choices[item.id], let swap = item.swaps.first(where: { $0.id == choice }) {
                edits.append(swap.edit(for: item.ingredient))
            } else if halved.contains(item.id), let scale = item.suggestedScale {
                edits.append(.scaleIngredient(id: item.ingredient.id, factor: scale))
            }
        }
        return edits
    }

    /// Save: with the model on, a swap that leaves a step awkward first gets a chance at a
    /// one-step rewrite, shown old → new and unticked. Otherwise saves straight away.
    private func save() {
        let edits = edits()
        guard provider.usesModel, !StepRewrites.requests(recipe: recipe, edits: edits).isEmpty else {
            finishSave(edits)
            return
        }
        let assistant = provider.assistant
        checkingSteps = true
        Task {
            let found = (try? await assistant.proposeStepRewrites(recipe: recipe, edits: edits, feedback: "")) ?? []
            checkingSteps = false
            if found.isEmpty {
                finishSave(edits)
            } else {
                rewriteReview = RewriteReview(edits: edits, rewrites: found.map {
                    EditProposal(edit: $0.edit, summary: "Reword step \($0.stepIndex + 1)", included: false, rewrite: $0)
                })
            }
        }
    }

    private func finishSave(_ edits: [RecipeEdit]) {
        if let existing {
            if !edits.isEmpty { existing.apply(edits) }
            try? context.save()
            onSaved(existing)
        } else {
            let current = recipe.applying(edits)
            let lead = shared == nil ? "Imported" : "Shared with you"
            let summary = edits.isEmpty ? lead : "\(lead): " + edits.summary(in: recipe)
            // The original is what was imported (for a shared recipe, the friend's version), so
            // "Reset to original" returns to it.
            let saved = SavedRecipe(original: recipe, current: current,
                                    revisions: [RecipeRevision(summary: summary, edits: edits)])
            // If the photo can't be written, the recipe is still saved, without it.
            if let photo = shared?.photo { _ = try? CookPhotoStore.shared.writeShared(photo, recipeID: saved.id) }
            context.insert(saved)
            try? context.save()
            onSaved(saved)
        }
    }
}

/// After a swap: the model's suggested rewrites of awkward steps, each unticked, then save.
private struct RewriteReviewView: View {
    @State var review: IngredientCheckView.RewriteReview
    let onSave: ([RecipeEdit]) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Tidy up the steps?").serifTitle().accessibilityAddTraits(.isHeader)
                Text("Your swap left these steps reading oddly. Tick a rewrite to use it.")
                    .font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                MiseCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(Array(review.rewrites.enumerated()), id: \.element.id) { index, proposal in
                            if let rewrite = proposal.rewrite {
                                RewriteToggle(rewrite: rewrite, isOn: $review.rewrites[index].included,
                                              identifier: "review.rewrite.\(rewrite.stepIndex)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .miseScreenBackground()
        .safeAreaInset(edge: .bottom) {
            Button("Save") { onSave(review.rewrites.filter(\.included).map(\.edit)) }
                .buttonStyle(.misePrimary)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.mise.background)
                .accessibilityIdentifier("review.rewriteSave")
        }
        .interactiveDismissDisabled()
    }
}

#Preview("Light") {
    NavigationStack {
        IngredientCheckView(recipe: PreviewData.recipe, existing: nil) { _ in }
    }
    .modelContainer(PreviewData.container)
    .environment(AssistantProvider())
}

#Preview("Dark, largest text") {
    NavigationStack {
        IngredientCheckView(recipe: PreviewData.recipe, existing: nil) { _ in }
    }
    .modelContainer(PreviewData.container)
    .environment(AssistantProvider())
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
