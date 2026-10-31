import SwiftUI
import SwiftData
import RecipeKit

/// Recipe text shared from another app (e.g. a write-up from the claude.ai app). The user picks
/// what it is: their version of a saved recipe (best title match first) or a new recipe.
struct SharedTextView: View {
    let text: String
    /// Called with the recipe to open afterwards, or nil when cancelled.
    var onFinished: (SavedRecipe?) -> Void

    @Query(sort: \SavedRecipe.updatedAt, order: .reverse) private var recipes: [SavedRecipe]

    private var sharedTitle: String { TitleMatcher.title(ofPasted: text) }

    private var ranked: [SavedRecipe] {
        TitleMatcher.ranked(recipes, title: \.title, against: text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Shared text").serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                MiseCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(sharedTitle.isEmpty ? "Untitled" : sharedTitle)
                            .serifTitle()
                            .accessibilityIdentifier("share.textTitle")
                        Text(preview)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Color.mise.inkSecondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                NavigationLink {
                    ImportView(initialText: text) { saved in onFinished(saved) }
                } label: {
                    Label("Save as a new recipe", systemImage: "plus")
                }
                .buttonStyle(.misePrimary)
                .accessibilityIdentifier("share.newRecipe")

                if !recipes.isEmpty {
                    SectionCard(title: "Or use it as your version of…") {
                        VStack(alignment: .leading, spacing: 0) {
                            let list = ranked
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, recipe in
                                NavigationLink {
                                    PasteMyVersionView(saved: recipe, initialText: text) { onFinished(recipe) }
                                } label: {
                                    HStack(spacing: Theme.Spacing.s) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(recipe.title).foregroundStyle(Color.mise.ink)
                                                .multilineTextAlignment(.leading)
                                            if index == 0 && TitleMatcher.score(sharedTitle, recipe.title) > 0 {
                                                Badge(title: "Best match")
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(Theme.Fonts.caption)
                                            .foregroundStyle(Color.mise.inkSecondary)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(minHeight: Theme.Size.minTap)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("share.attach.\(index)")
                                if index < list.count - 1 { Divider().overlay(Color.mise.divider) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
        }
        .miseScreenBackground()
        .navigationTitle("Add to Mise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinished(nil) } }
        }
    }

    private var preview: String {
        let lines = HTMLText.lines(fromText: text).map(\.text)
        return lines.dropFirst().prefix(3).joined(separator: " ")
    }
}

#Preview("Light") {
    NavigationStack {
        SharedTextView(text: "Kung Pao Chicken (serves 2)\nFry 2 tbsp peanuts in 1 tbsp oil.\nAdd 300 g chicken.") { _ in }
    }
    .modelContainer(PreviewData.container)
    .environment(AssistantProvider())
}

#Preview("Dark") {
    NavigationStack {
        SharedTextView(text: "Kung Pao Chicken (serves 2)\nFry 2 tbsp peanuts in 1 tbsp oil.") { _ in }
    }
    .modelContainer(PreviewData.container)
    .environment(AssistantProvider())
    .preferredColorScheme(.dark)
}
