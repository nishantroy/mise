import Foundation

/// The seam between the app and whatever produces edits and swaps: rules today, the
/// on-device model when available, a cloud model later.
public protocol RecipeAssistant: Sendable {
    var displayName: String { get }
    func proposeEdits(recipe: Recipe, feedback: String, prefs: UserPreferences) async throws -> [RecipeEdit]
    func suggestSwaps(for ingredient: Ingredient, in recipe: Recipe,
                      pantry: PantrySnapshot, prefs: UserPreferences) async throws -> [SwapSuggestion]
    /// A cuisine from `CuisineGuesser.vocabulary`, or nil when there's no clear answer.
    func guessCuisine(recipe: Recipe) async throws -> String?
    /// A realistic time estimate. The rules do the arithmetic; a model may only fill gaps.
    func estimateTime(recipe: Recipe) async throws -> TimeEstimate
    /// Ingredients for a recipe whose amounts are only written inside its steps. Never changes
    /// the steps. A model's answer must go through `ModelIngredientLines` before it's returned.
    func extractIngredients(steps: [String], title: String) async throws -> [Ingredient]
}

extension RecipeAssistant {
    /// Default: the rules, so every assistant can answer.
    public func guessCuisine(recipe: Recipe) async throws -> String? {
        CuisineGuesser().guess(recipe)
    }

    public func estimateTime(recipe: Recipe) async throws -> TimeEstimate {
        TimeEstimator().estimate(recipe)
    }

    public func extractIngredients(steps: [String], title: String) async throws -> [Ingredient] {
        IngredientCatalog.shared.annotate(Recipe(title: title, ingredients: StepIngredientExtractor.extract(from: steps))).ingredients
    }
}
