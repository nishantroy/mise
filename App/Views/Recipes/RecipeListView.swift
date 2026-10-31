import SwiftUI
import SwiftData
import RecipeKit

struct RecipeListView: View {
    @Query(sort: \SavedRecipe.updatedAt, order: .reverse) private var recipes: [SavedRecipe]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text(Greeting.now()).serifTitle(Theme.Fonts.header).accessibilityAddTraits(.isHeader)
                    if recipes.isEmpty {
                        EmptyState(systemImage: "book.closed", title: "No recipes yet",
                                   message: "Import a recipe from a link, or share one from Safari.")
                    } else {
                        ForEach(recipes) { saved in
                            RecipeCard(title: saved.title, imageURL: saved.recipe.imageURL, metadata: "")
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
            }
            .miseScreenBackground()
            .navigationTitle("Recipes")
            .toolbarTitleDisplayMode(.inline)
        }
    }
}

enum Greeting {
    static func now(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }
}
