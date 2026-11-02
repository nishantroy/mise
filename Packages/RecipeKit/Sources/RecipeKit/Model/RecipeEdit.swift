import Foundation

/// One change to a recipe. Stored in revisions as JSON (synthesised `Codable`), so cases may be
/// added but existing cases and their labels must never change: old revisions have to decode.
public enum RecipeEdit: Codable, Hashable, Sendable {
    case replaceIngredient(id: UUID, with: [Ingredient], reason: String?)
    case scaleIngredient(id: UUID, factor: Double)
    case removeIngredient(id: UUID)
    case addIngredient(Ingredient)
    case updateStep(index: Int, text: String)
    case addNote(String)
    /// Several ingredients replaced by one set ("fresh ginger" + "garlic" → "ginger garlic paste").
    /// Added after v1.
    case replaceIngredients(ids: [UUID], with: [Ingredient], reason: String?)
    /// The whole step list replaced by the user's own steps ("Paste my version"). Added after v1.
    case replaceSteps([String])

    /// `reason` on a `replaceIngredient` that only changes the amount (the user's version uses a
    /// different unit, so it can't be a scale). The summary reads "Change X: ¼ cup → 1 tbsp".
    public static let amountChangeReason = "Amount from your version"

    /// `reason` on a `replaceIngredient` where the user's line takes the same role in another form
    /// (2 tbsp black pepper → 1¾ tbsp black peppercorns). The summary reads
    /// "Change black pepper (2 tbsp) to 1 ¾ tbsp black peppercorns".
    public static let versionLineReason = "Line from your version"
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
