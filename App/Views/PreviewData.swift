import Foundation
import SwiftData
import RecipeKit

/// Sample data for SwiftUI previews.
@MainActor
enum PreviewData {
    static let recipe: Recipe = IngredientCatalog.shared.annotate(Recipe(
        title: "Red Braised Pork Belly",
        sourceURL: URL(string: "https://thewoksoflife.com/red-braised-pork-belly/"),
        servings: 4,
        totalMinutes: 105,
        cuisine: "Chinese",
        ingredients: [
            "2 pounds pork belly, cut into ¾-inch pieces",
            "6 slices ginger",
            "2 tablespoons oil",
            "3 tablespoons sugar",
            "½ cup Shaoxing wine",
            "3 tablespoons light soy sauce",
            "1½ tablespoons dark soy sauce",
            "2 star anise",
            "4 cups water",
        ].map(IngredientLineParser.parse),
        steps: [
            "Blanch the pork belly for 3 minutes, then drain.",
            "Caramelise the sugar in the oil, add the pork and ginger.",
            "Add the Shaoxing wine, soy sauces, star anise and water, and simmer for an hour.",
            "Reduce the sauce until glossy.",
        ]
    ))

    /// No stated time and no page cuisine: shows the estimate ("~") and a guessed cuisine.
    static let guessedRecipe: Recipe = {
        let base = IngredientCatalog.shared.annotate(Recipe(
            title: "Kung Pao Chicken",
            servings: 4,
            ingredients: ["1 lb chicken", "1 tbsp oyster sauce", "1 tbsp hoisin sauce", "½ cup peanuts"]
                .map(IngredientLineParser.parse),
            steps: ["Marinate the chicken for ½ hour.", "Stir fry for about 4 minutes.", "Add the sauce and cook for 1 minute."]
        ))
        return base.withInsights(cuisineGuess: CuisineGuesser().guess(base), estimate: TimeEstimator().estimate(base))
    }()

    static let container: ModelContainer = {
        let container = Persistence.inMemory()
        let context = container.mainContext
        let profile = UserProfile(prefs: UserPreferences(diet: .omnivore, avoid: [.peanuts], dislikes: ["olives"],
                                                         spiceLevel: 2, cuisines: ["Chinese", "Indian"]),
                                  onboardingDone: true)
        context.insert(profile)
        context.insert(PantryEntry(key: "soy-sauce", displayName: "soy sauce", status: .have))
        context.insert(PantryEntry(key: "shaoxing-wine", displayName: "shaoxing wine", status: .missing))
        let saved = SavedRecipe(original: recipe)
        saved.revisions = [RecipeRevision(summary: "Imported", edits: [])]
        context.insert(saved)
        context.insert(SavedRecipe(original: guessedRecipe))
        return container
    }()
}
