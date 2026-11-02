import Foundation
import SwiftData
import RecipeKit

extension SchemaV2 {
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
        /// JSON-encoded `[CookLogEntry]` (`cookLog`); nil until the first logged cook. Added in V2.
        var cookLogData: Data?

        init(original: Recipe, current: Recipe? = nil, revisions: [RecipeRevision] = [], now: Date = Date()) {
            let current = current ?? original
            id = UUID()
            createdAt = now
            updatedAt = now
            title = current.title
            recipeData = ModelCoding.encode(current.refreshingStaleTimeEstimate())
            originalData = ModelCoding.encode(original.refreshingStaleTimeEstimate())
            revisionsData = ModelCoding.encode(revisions)
            rating = nil
            timesCooked = 0
            cookLogData = nil
        }

        /// Every write of the current version goes through here, so a time estimate computed from
        /// other steps (an edit, Paste my version, reset to original, cook-mode swaps…) is replaced
        /// by the rules' estimate for the new steps. `RecipeDetailView` then refines it with the
        /// model in the background.
        var recipe: Recipe {
            get { ModelCoding.decode(Recipe.self, from: recipeData) ?? Recipe(title: title) }
            set {
                recipeData = ModelCoding.encode(newValue.refreshingStaleTimeEstimate())
                title = newValue.title
            }
        }

        /// Replaces stale estimates (computed from other steps, or before estimates recorded what
        /// they were computed from) on the current and original versions with the rules'.
        /// True when anything changed. Not a revision and doesn't bump `updatedAt`.
        @discardableResult
        func refreshStaleEstimates() -> Bool {
            var changed = false
            let current = recipe
            if current.hasStaleTimeEstimate {
                recipe = current
                changed = true
            }
            if let base = ModelCoding.decode(Recipe.self, from: originalData), base.hasStaleTimeEstimate {
                originalData = ModelCoding.encode(base.refreshingStaleTimeEstimate())
                changed = true
            }
            return changed
        }

        /// Stores a model-refined estimate for the current version, if it still fits (the recipe
        /// may have been edited while the model was thinking).
        func refineEstimate(_ estimate: TimeEstimate) {
            var current = recipe
            guard estimate.fits(current), current.timeEstimate != estimate else { return }
            current.timeEstimate = estimate
            recipe = current
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
        /// Not a revision: it's metadata, not a change to the recipe. The estimate is computed
        /// from the current steps, so the original (when its steps differ) gets the rules' estimate
        /// for its own steps instead.
        func updateInsights(cuisineGuess: String?, estimate: TimeEstimate?) {
            let base = original
            recipe = recipe.withInsights(cuisineGuess: cuisineGuess, estimate: estimate)
            originalData = ModelCoding.encode(base.withInsights(cuisineGuess: cuisineGuess, estimate: estimate)
                .refreshingStaleTimeEstimate())
        }

        /// Restores the imported version, recorded as a revision so history is kept.
        func resetToOriginal(now: Date = Date()) {
            recipe = original
            revisions.append(RecipeRevision(date: now, summary: "Reset to original", edits: []))
            updatedAt = now
        }
    }
}
