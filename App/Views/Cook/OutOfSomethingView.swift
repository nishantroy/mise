import SwiftUI
import SwiftData
import RecipeKit

/// "Out of something?" in cook mode: pick the missing ingredient (this step's first, big rows,
/// or typed/dictated), then a swap, "Skip it", or a model's suggestion when the table has none.
/// Choosing changes this cooking session only.
struct OutOfSomethingView: View {
    /// The session's working recipe.
    let recipe: Recipe
    /// The step on screen (nil on the prep list).
    let stepIndex: Int?
    let links: StepIngredientLinker.Links
    let swaps: [CookSwap]
    var onChoose: (Ingredient, SwapSuggestion?, String?) -> Void
    var onUndo: (CookSwap) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path: [UUID] = []
    @FocusState private var searching: Bool

    /// Ingredients that came from a swap can only be undone, not swapped again.
    private var swappedIn: Set<UUID> { Set(swaps.flatMap { $0.replacements.map(\.id) }) }

    private var stepIngredients: [Ingredient] {
        guard let stepIndex else { return [] }
        return links.forStep(stepIndex).compactMap(recipe.ingredient(id:)).filter { !swappedIn.contains($0.id) }
    }

    private var otherIngredients: [Ingredient] {
        let shown = Set(stepIngredients.map(\.id))
        return recipe.ingredients.filter { !shown.contains($0.id) && !swappedIn.contains($0.id) }
    }

    private var matches: [Ingredient] {
        MissingIngredientMatcher.matches(query, in: recipe).filter { !swappedIn.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    searchField
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let found = matches
                        if found.isEmpty {
                            Text("Nothing in this recipe matches “\(MissingIngredientMatcher.query(query))”.")
                                .font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                        } else {
                            section("Matches", found)
                        }
                    } else {
                        if !swaps.isEmpty { swappedSection }
                        if !stepIngredients.isEmpty { section("In this step", stepIngredients) }
                        if !otherIngredients.isEmpty {
                            section(stepIngredients.isEmpty ? "Ingredients" : "Rest of the recipe", otherIngredients)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .miseScreenBackground()
            .navigationTitle("Out of something?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("outOf.close")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let ingredient = recipe.ingredient(id: id) {
                    SwapChoicesView(ingredient: ingredient, recipe: recipe) { suggestion, consequence in
                        onChoose(ingredient, suggestion, consequence)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.mise.inkSecondary).accessibilityHidden(true)
            TextField("Type or dictate: “out of Shaoxing wine”", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searching)
                .onSubmit {
                    // One clear match: go straight to its options.
                    if matches.count == 1 { path = [matches[0].id] }
                }
                .accessibilityIdentifier("outOf.search")
        }
        .font(.title3)
        .padding(Theme.Spacing.s)
        .frame(minHeight: Theme.Size.minTap)
        .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private func section(_ title: String, _ ingredients: [Ingredient]) -> some View {
        SectionCard(title: title) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ingredients.enumerated()), id: \.element.id) { index, ing in
                    if index > 0 { Divider().overlay(Color.mise.divider) }
                    NavigationLink(value: ing.id) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                            Text(RecipeFormat.capitalised(ing.name))
                                .font(.title3)
                                .foregroundStyle(Color.mise.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Theme.Spacing.xs)
                            if let amount = RecipeFormat.amount(ing) {
                                Text(amount).font(Theme.Fonts.meta).monospacedDigit().foregroundStyle(Color.mise.inkSecondary)
                            }
                            Image(systemName: "chevron.right").font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("outOf.ingredient")
                }
            }
        }
    }

    private var swappedSection: some View {
        SectionCard(title: "Changed while cooking") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(swaps) { swap in
                    HStack(spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(swap.label).foregroundStyle(Color.mise.ink)
                            if let line = swap.consequence {
                                Text(line).font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                            }
                        }
                        Spacer(minLength: Theme.Spacing.xs)
                        Button("Undo") { onUndo(swap) }
                            .buttonStyle(.miseSecondary)
                            .fixedSize()
                            .accessibilityLabel("Undo: \(swap.label)")
                            .accessibilityIdentifier("outOf.undo")
                    }
                }
            }
        }
    }
}

/// The options for one missing ingredient, each with the amount to use.
struct SwapChoicesView: View {
    let ingredient: Ingredient
    let recipe: Recipe
    var onChoose: (SwapSuggestion?, String?) -> Void

    @Environment(\.modelContext) private var context
    @Environment(AssistantProvider.self) private var provider
    @State private var table: [SwapSuggestion]?
    @State private var modelOptions: [SwapSuggestion] = []
    @State private var asking = false

    private var swaps: [SwapSuggestion] { (table ?? []).filter { !$0.isLeaveOut } }

    private var skipLine: String? {
        if let line = SkipConsequence.text(for: ingredient) { return line }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Out of \(ingredient.name)").serifTitle(Theme.Fonts.title).accessibilityAddTraits(.isHeader)
                    if let amount = RecipeFormat.amount(ingredient) {
                        Text("The recipe uses \(amount).").font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                    }
                }
                if !swaps.isEmpty || !modelOptions.isEmpty || asking {
                    SectionCard(title: "Use instead") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            ForEach(swaps) { option in optionRow(option, fromModel: false) }
                            ForEach(modelOptions) { option in optionRow(option, fromModel: true) }
                            if asking {
                                HStack(spacing: Theme.Spacing.xs) {
                                    ProgressView()
                                    Text("Asking Apple Intelligence…")
                                }
                                .font(Theme.Fonts.meta)
                                .foregroundStyle(Color.mise.inkSecondary)
                            }
                        }
                    }
                } else if table != nil {
                    Text("No swaps known for \(ingredient.name).").font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                }
                Button { onChoose(nil, skipLine) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Skip it").font(.title3.weight(.semibold)).foregroundStyle(Color.mise.ink)
                            if let skipLine {
                                Text(skipLine).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Spacing.m)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Color.mise.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("outOf.skip")
                Text("Changes this cook only. You can keep it in the recipe when you finish.")
                    .font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .miseScreenBackground()
        .navigationTitle(RecipeFormat.capitalised(ingredient.name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func optionRow(_ option: SwapSuggestion, fromModel: Bool) -> some View {
        Button { onChoose(option, option.note.isEmpty ? nil : option.note) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(option.title).font(.title3.weight(.semibold)).foregroundStyle(Color.mise.ink)
                    Text("Use " + amountText(option)).font(.body.weight(.medium)).monospacedDigit().foregroundStyle(Color.mise.ink)
                    if !option.note.isEmpty, option.note != option.title {
                        Text(option.note).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: Theme.Spacing.xs) {
                        if option.fromPantry { Badge(title: "In your pantry", systemImage: "checkmark") }
                        if fromModel { Badge(title: "Apple Intelligence", systemImage: "sparkles", tone: Color.mise.inkSecondary) }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Theme.Fonts.caption).foregroundStyle(Color.mise.inkSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("outOf.option")
    }

    /// "1 tbsp mirin", "1 ½ tbsp soy sauce + sugar (½ tsp per tbsp)".
    private func amountText(_ option: SwapSuggestion) -> String {
        option.replacementIngredients(for: ingredient).map { ing in
            ing.quantity == nil && ing.note != nil ? "\(ing.name) (\(ing.note!))" : ing.displayText
        }.joined(separator: " + ")
    }

    /// The bundled table, pantry-aware (things you have rank first). When it has no real swap and
    /// the model is on, the model's suggestions (validated as on import) are added.
    private func load() async {
        guard table == nil else { return }
        let pantry = context.pantrySnapshot()
        let prefs = context.profile().prefs
        let id = ingredient.catalogID ?? IngredientCatalog.shared.match(ingredient.name)?.id
        table = SwapEngine().suggestions(for: id, pantry: pantry, prefs: prefs, ensureLeaveOut: true)
        guard swaps.isEmpty, provider.usesModel else { return }
        asking = true
        let assistant = provider.assistant
        let ingredient = ingredient, recipe = recipe
        let found = try? await FoundationModelsAssistant.withTimeout(FoundationModelsAssistant.insightTimeout) {
            try await assistant.suggestSwaps(for: ingredient, in: recipe, pantry: pantry, prefs: prefs)
        }
        modelOptions = (found ?? []).filter { !$0.isLeaveOut }
        asking = false
    }
}
