import Foundation
import SwiftData

/// Frozen copies of the version 1 models: exactly the stored properties (names, types,
/// optionality, attributes) that the first release wrote. SwiftData matches an existing store
/// to a schema version by these, so never edit them. Behaviour lives on the current version.
extension SchemaV1 {
    @Model
    final class SavedRecipe {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var title: String
        var recipeData: Data
        var originalData: Data
        var revisionsData: Data
        var rating: Int?
        var timesCooked: Int

        init(id: UUID = UUID(), title: String, recipeData: Data, originalData: Data, revisionsData: Data,
             rating: Int? = nil, timesCooked: Int = 0, now: Date = Date()) {
            self.id = id
            createdAt = now
            updatedAt = now
            self.title = title
            self.recipeData = recipeData
            self.originalData = originalData
            self.revisionsData = revisionsData
            self.rating = rating
            self.timesCooked = timesCooked
        }
    }

    @Model
    final class PantryEntry {
        @Attribute(.unique) var key: String
        var displayName: String
        var status: String
        var updatedAt: Date

        init(key: String, displayName: String, status: String, updatedAt: Date = Date()) {
            self.key = key
            self.displayName = displayName
            self.status = status
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class UserProfile {
        var prefsData: Data
        var onboardingDone: Bool

        init(prefsData: Data, onboardingDone: Bool) {
            self.prefsData = prefsData
            self.onboardingDone = onboardingDone
        }
    }
}
