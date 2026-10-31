import Foundation
import SwiftData
import RecipeKit

extension SchemaV1 {
    @Model
    final class SavedRecipe {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        /// Denormalised for list sorting and search.
        var title: String
        /// JSON-encoded `Recipe` (current version).
        var recipeData: Data
        /// JSON-encoded `Recipe` as imported, for "Reset to original".
        var originalData: Data
        /// JSON-encoded `[RecipeRevision]`.
        var revisionsData: Data
        /// -1, 0 or 1.
        var rating: Int?
        var timesCooked: Int

        init(original: Recipe, current: Recipe? = nil, revisions: [RecipeRevision] = [], now: Date = Date()) {
            let current = current ?? original
            id = UUID()
            createdAt = now
            updatedAt = now
            title = current.title
            recipeData = ModelCoding.encode(current)
            originalData = ModelCoding.encode(original)
            revisionsData = ModelCoding.encode(revisions)
            rating = nil
            timesCooked = 0
        }

        var recipe: Recipe {
            get { ModelCoding.decode(Recipe.self, from: recipeData) ?? Recipe(title: title) }
            set {
                recipeData = ModelCoding.encode(newValue)
                title = newValue.title
            }
        }

        var original: Recipe {
            ModelCoding.decode(Recipe.self, from: originalData) ?? recipe
        }

        var revisions: [RecipeRevision] {
            get { ModelCoding.decode([RecipeRevision].self, from: revisionsData) ?? [] }
            set { revisionsData = ModelCoding.encode(newValue) }
        }

        /// Applies edits to the current recipe and records them as a revision.
        func apply(_ edits: [RecipeEdit], summary: String? = nil, now: Date = Date()) {
            let before = recipe
            recipe = before.applying(edits)
            revisions.append(RecipeRevision(date: now, summary: summary ?? edits.summary(in: before), edits: edits))
            updatedAt = now
        }

        /// "Paste my version": applies the ticked edits, plus the user's title and servings when
        /// they opted in, as one revision. `originalData` is untouched, so "Reset to original" works.
        func applyVersion(_ edits: [RecipeEdit], title: String?, servings: Int?, summary: String, now: Date = Date()) {
            var next = recipe.applying(edits)
            if let title { next.title = title }
            if let servings { next.servings = servings }
            recipe = next
            revisions.append(RecipeRevision(date: now, summary: summary, edits: edits))
            updatedAt = now
        }

        /// The user picked (or confirmed) a cuisine, or cleared a guessed one. A plain edit,
        /// recorded as a revision with no recipe edits (like "Reset to original").
        func setCuisine(_ cuisine: String?, now: Date = Date()) {
            var current = recipe
            let old = current.cuisine
            current.cuisine = cuisine
            current.cuisineIsGuess = false
            recipe = current
            let summary = cuisine.map { "Cuisine set to \($0)" } ?? "Cleared the cuisine\(old.map { " (\($0))" } ?? "")"
            revisions.append(RecipeRevision(date: now, summary: summary, edits: []))
            updatedAt = now
        }

        /// Writes a re-checked cuisine guess and time estimate onto the current and original
        /// versions (so "Reset to original" keeps them). A page or user cuisine is never replaced.
        /// Not a revision: it's metadata, not a change to the recipe.
        func updateInsights(cuisineGuess: String?, estimate: TimeEstimate?) {
            let base = original
            recipe = recipe.withInsights(cuisineGuess: cuisineGuess, estimate: estimate)
            originalData = ModelCoding.encode(base.withInsights(cuisineGuess: cuisineGuess, estimate: estimate))
        }

        /// Restores the imported version, recorded as a revision so history is kept.
        func resetToOriginal(now: Date = Date()) {
            recipe = original
            revisions.append(RecipeRevision(date: now, summary: "Reset to original", edits: []))
            updatedAt = now
        }
    }
}
