import SwiftUI
import SwiftData
import RecipeKit

/// One card per flagged ingredient: conflicts, dislikes, missing items, "Do you have X?" and
/// heat. The user picks swaps (or keeps the original); Save applies them and records a revision.
struct IngredientCheckView: View {
    let recipe: Recipe
    /// Nil when importing; the saved recipe when re-checking from the detail screen.
    let existing: SavedRecipe?
    var onSaved: (SavedRecipe) -> Void

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
        .safeAreaInset(edge: .bottom) {
            Button(existing == nil ? "Save recipe" : "Save changes", action: save)
                .buttonStyle(.misePrimary)
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

    private func save() {
        let edits = edits()
        if let existing {
            if !edits.isEmpty { existing.apply(edits) }
            try? context.save()
            onSaved(existing)
        } else {
            let current = recipe.applying(edits)
            let summary = edits.isEmpty ? "Imported" : "Imported: " + edits.summary(in: recipe)
            let saved = SavedRecipe(original: recipe, current: current,
                                    revisions: [RecipeRevision(summary: summary, edits: edits)])
            context.insert(saved)
            try? context.save()
            onSaved(saved)
        }
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
