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
                    SwapChoicesView(ingredient: ingredient, recipe: recipe, purpose: .cooking) { suggestion, consequence in
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
