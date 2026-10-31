import SwiftUI
import SwiftData
import RecipeKit

struct RecipeListView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AssistantProvider.self) private var provider
    @Query(sort: \SavedRecipe.updatedAt, order: .reverse) private var recipes: [SavedRecipe]
    @Query private var pantryEntries: [PantryEntry]
    @Query private var profiles: [UserProfile]

    /// "What can I cook?" question and its results (nil until asked).
    @State private var question = ""
    @State private var result: CookSearchResult?
    @State private var submitted: String?
    @State private var refineTask: Task<Void, Never>?

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
                    } else {
                        CookAskCard(text: $question, isRefining: refineTask != nil, onSubmit: ask, onClear: clear)
                        if let result {
                            CookResultsView(result: result) { id in recipes.first { $0.id == id }?.recipe.imageURL }
                        } else {
                            ForEach(recipes) { saved in
                                NavigationLink(value: saved.id) {
                                    let recipe = saved.recipe
                                    RecipeCard(title: saved.title, imageURL: recipe.imageURL, metadata: RecipeFormat.metadata(recipe))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("recipe.card")
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .miseScreenBackground()
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
            .onChange(of: question) { _, new in
                // Editing the question after asking hides stale results once it's cleared.
                if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clear() }
            }
        }
    }

    // MARK: What can I cook?

    private var candidates: [CookCandidate] {
        recipes.map { CookCandidate(id: $0.id, recipe: $0.recipe, rating: $0.rating, timesCooked: $0.timesCooked) }
    }

    /// Rules first, shown at once; with the on-device model on, its validated reading of the
    /// question replaces them if it differs (and the question hasn't changed meanwhile).
    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let candidates = candidates
        let pantry = pantryEntries.snapshot
        let prefs = profiles.first?.prefs ?? UserPreferences()
        let matcher = RecipeMatcher()
        let rules = CookQueryParser().parse(text)
        result = matcher.search(rules, in: candidates, pantry: pantry, prefs: prefs)
        submitted = text
        refineTask?.cancel()
        refineTask = nil
        guard provider.usesModel else { return }
        let assistant = provider.assistant
        refineTask = Task {
            let refined = (try? await assistant.parseCookQuery(text: text)) ?? rules
            guard !Task.isCancelled, submitted == text else { return }
            if refined != rules {
                result = matcher.search(refined, in: candidates, pantry: pantry, prefs: prefs)
            }
            refineTask = nil
        }
    }

    private func clear() {
        refineTask?.cancel()
        refineTask = nil
        question = ""
        result = nil
        submitted = nil
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
        .environment(AssistantProvider())
}

#Preview("Dark") {
    RecipeListView()
        .modelContainer(PreviewData.container)
        .environment(AppRouter())
        .environment(AssistantProvider())
        .preferredColorScheme(.dark)
}
