import Foundation

/// Deterministic assistant: `FeedbackParser` for edits, `SwapEngine` for swaps.
public struct RuleBasedAssistant: RecipeAssistant {
    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    public var displayName: String { "Built-in rules" }

    public func proposeEdits(recipe: Recipe, feedback: String, prefs: UserPreferences) async throws -> [RecipeEdit] {
        FeedbackParser(catalog: catalog).edits(from: feedback, recipe: recipe)
    }

    public func suggestSwaps(for ingredient: Ingredient, in recipe: Recipe,
                             pantry: PantrySnapshot, prefs: UserPreferences) async throws -> [SwapSuggestion] {
        let id = ingredient.catalogID ?? catalog.match(ingredient.name)?.id
        return SwapEngine(catalog: catalog).suggestions(for: id, pantry: pantry, prefs: prefs, ensureLeaveOut: true)
    }

    public func guessCuisine(recipe: Recipe) async throws -> String? {
        CuisineGuesser(catalog: catalog).guess(recipe)
    }

    public func estimateTime(recipe: Recipe) async throws -> TimeEstimate {
        TimeEstimator(catalog: catalog).estimate(recipe)
    }
}
