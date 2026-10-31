import Foundation

public enum RecipeEdit: Codable, Hashable, Sendable {
    case replaceIngredient(id: UUID, with: [Ingredient], reason: String?)
    case scaleIngredient(id: UUID, factor: Double)
    case removeIngredient(id: UUID)
    case addIngredient(Ingredient)
    case updateStep(index: Int, text: String)
    case addNote(String)
}

/// One saved change set: what the user accepted, when, and a human summary.
public struct RecipeRevision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var summary: String
    public var edits: [RecipeEdit]

    public init(id: UUID = UUID(), date: Date = Date(), summary: String, edits: [RecipeEdit]) {
        self.id = id
        self.date = date
        self.summary = summary
        self.edits = edits
    }
}
