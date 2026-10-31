import Foundation

/// The seam between the app and whatever produces edits and swaps: rules today, the
/// on-device model when available, a cloud model later.
public protocol RecipeAssistant: Sendable {
    var displayName: String { get }
    func proposeEdits(recipe: Recipe, feedback: String, prefs: UserPreferences) async throws -> [RecipeEdit]
    func suggestSwaps(for ingredient: Ingredient, in recipe: Recipe,
                      pantry: PantrySnapshot, prefs: UserPreferences) async throws -> [SwapSuggestion]
}
