import SwiftUI
import SwiftData
import RecipeKit

struct RecipeListView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \SavedRecipe.updatedAt, order: .reverse) private var recipes: [SavedRecipe]
    @State private var search = ""

    private var filtered: [SavedRecipe] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recipes }
        return recipes.filter { $0.title.localizedStandardContains(q) || ($0.recipe.cuisine ?? "").localizedStandardContains(q) }
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.recipePath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text(Greeting.now())
                        .serifTitle(Theme.Fonts.header)
                        .accessibilityAddTraits(.isHeader)
                    if recipes.isEmpty {
                        EmptyState(systemImage: "book.closed", title: "No recipes yet",
                                   message: "Import a recipe from a link, or share one from Safari.",
                                   buttonTitle: "Import a recipe") { router.startImport() }
                            .padding(.top, Theme.Spacing.xl)
                    } else if filtered.isEmpty {
                        Text("No recipes match “\(search)”.")
                            .foregroundStyle(Color.mise.inkSecondary)
                    } else {
                        ForEach(filtered) { saved in
                            NavigationLink(value: saved.id) {
                                let recipe = saved.recipe
                                RecipeCard(title: saved.title, imageURL: recipe.imageURL, metadata: RecipeFormat.metadata(recipe))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("recipe.card")
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.l)
            }
            .miseScreenBackground()
            .searchable(text: $search, prompt: "Search recipes")
            .navigationTitle("Recipes")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Import recipe", systemImage: "plus") { router.startImport() }
                        .accessibilityIdentifier("recipes.import")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let saved = recipes.first(where: { $0.id == id }) {
                    RecipeDetailView(saved: saved)
                } else {
                    EmptyState(systemImage: "questionmark.folder", title: "Recipe not found", message: "It may have been deleted.")
                }
            }
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

#Preview("Light") {
    RecipeListView()
        .modelContainer(PreviewData.container)
        .environment(AppRouter())
}

#Preview("Dark") {
    RecipeListView()
        .modelContainer(PreviewData.container)
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
