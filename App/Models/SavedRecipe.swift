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

        /// Restores the imported version, recorded as a revision so history is kept.
        func resetToOriginal(now: Date = Date()) {
            recipe = original
            revisions.append(RecipeRevision(date: now, summary: "Reset to original", edits: []))
            updatedAt = now
        }
    }
}
