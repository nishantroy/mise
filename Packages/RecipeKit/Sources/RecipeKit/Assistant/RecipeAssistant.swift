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
    /// The whole recipe (ingredients, steps, notes, servings) from a pasted write-up whose
    /// amounts are only in its steps. `rules` is `StepStyleParser`'s parse of `text`. A model's
    /// answer must go through `RecipeAssembly.merge`; the rules return `rules` unchanged.
    func assembleRecipe(text: String, rules: Recipe) async throws -> Recipe
    /// The "Mise en place" list for cook mode. A model's plan must go through `PrepPlanner.map`.
    func planPrep(recipe: Recipe) async throws -> PrepPlan
    /// Rewrites of single steps after proposed `edits` (an added ingredient no step mentions, a
    /// swap that left a step awkward), validated by `StepRewrites`. Offered unticked. The rules
    /// have none.
    func proposeStepRewrites(recipe: Recipe, edits: [RecipeEdit], feedback: String) async throws -> [StepRewriteProposal]
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

    public func assembleRecipe(text: String, rules: Recipe) async throws -> Recipe {
        rules
    }

    public func planPrep(recipe: Recipe) async throws -> PrepPlan {
        PrepPlanner().plan(for: recipe)
    }

    public func proposeStepRewrites(recipe: Recipe, edits: [RecipeEdit], feedback: String) async throws -> [StepRewriteProposal] {
        []
    }
}
