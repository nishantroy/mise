import SwiftUI
import SwiftData
import RecipeKit

/// The options for one ingredient, each with the amount to use: the bundled table (pantry-aware,
/// "In your pantry" first), the model's suggestions when the table has none, and leaving it out
/// with what that costs. Shared by cook mode's "Out of something?" and the recipe page's "Find a
/// substitute"; `purpose` only changes the wording.
struct SwapChoicesView: View {
    enum Purpose {
        /// Cook mode: changes this cook only.
        case cooking
        /// The recipe page: the next question is "Just this time" or "Update the recipe".
        case recipe

        var idPrefix: String { self == .cooking ? "outOf" : "substitute" }
    }

    /// As shown (scaled to the servings on screen), so the amounts match.
    let ingredient: Ingredient
    let recipe: Recipe
    var purpose: Purpose = .cooking
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
                    Text(purpose == .cooking ? "Out of \(ingredient.name)" : "Instead of \(ingredient.name)")
                        .serifTitle(Theme.Fonts.title).accessibilityAddTraits(.isHeader)
                    if let amount = RecipeFormat.amount(ingredient) {
                        Text(usesLine(amount)).font(Theme.Fonts.meta).foregroundStyle(Color.mise.inkSecondary)
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
                            Text(purpose == .cooking ? "Skip it" : "Leave it out").font(.title3.weight(.semibold)).foregroundStyle(Color.mise.ink)
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
                .accessibilityIdentifier("\(purpose.idPrefix).skip")
                Text(purpose == .cooking
                     ? "Changes this cook only. You can keep it in the recipe when you finish."
                     : "Next: just this time, or change the recipe.")
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
        .accessibilityIdentifier("\(purpose.idPrefix).option")
    }

    /// "The recipe uses 1 tbsp." On the recipe page also the servings it's for, since the amounts follow them.
    private func usesLine(_ amount: String) -> String {
        if purpose == .recipe, let servings = recipe.servings {
            return "The recipe uses \(amount) for \(servings) \(servings == 1 ? "serving" : "servings")."
        }
        return "The recipe uses \(amount)."
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
