import Foundation

/// Runs the cuisine guess and time estimate through an assistant and writes them onto a recipe.
public enum RecipeInsights {
    /// Guesses the cuisine (only when the page or user gave none) and estimates the time.
    /// Any error from `assistant` falls back to the rules, so this never fails.
    public static func enrich(_ recipe: Recipe, using assistant: any RecipeAssistant,
                              catalog: IngredientCatalog = .shared) async -> Recipe {
        async let cuisine: String? = recipe.hasGivenCuisine ? nil : guessCuisine(recipe, using: assistant, catalog: catalog)
        async let estimate = estimateTime(recipe, using: assistant, catalog: catalog)
        return await recipe.withInsights(cuisineGuess: cuisine, estimate: estimate)
    }

    static func guessCuisine(_ recipe: Recipe, using assistant: any RecipeAssistant, catalog: IngredientCatalog) async -> String? {
        do {
            return try await assistant.guessCuisine(recipe: recipe)
        } catch {
            return CuisineGuesser(catalog: catalog).guess(recipe)
        }
    }

    static func estimateTime(_ recipe: Recipe, using assistant: any RecipeAssistant, catalog: IngredientCatalog) async -> TimeEstimate {
        do {
            return try await assistant.estimateTime(recipe: recipe)
        } catch {
            return TimeEstimator(catalog: catalog).estimate(recipe)
        }
    }
}
