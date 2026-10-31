import Foundation

public struct Recipe: Codable, Hashable, Sendable {
    public var title: String
    public var sourceURL: URL?
    public var imageURL: URL?
    public var servings: Int?
    public var totalMinutes: Int?
    public var cuisine: String?
    public var ingredients: [Ingredient]
    public var steps: [String]
    public var notes: [String]

    public init(title: String, sourceURL: URL? = nil, imageURL: URL? = nil, servings: Int? = nil,
                totalMinutes: Int? = nil, cuisine: String? = nil, ingredients: [Ingredient] = [],
                steps: [String] = [], notes: [String] = []) {
        self.title = title
        self.sourceURL = sourceURL
        self.imageURL = imageURL
        self.servings = servings
        self.totalMinutes = totalMinutes
        self.cuisine = cuisine
        self.ingredients = ingredients
        self.steps = steps
        self.notes = notes
    }

    public func ingredient(id: UUID) -> Ingredient? { ingredients.first { $0.id == id } }

    /// Display-only scaling: every ingredient quantity is multiplied by `servings / self.servings`.
    /// If the recipe has no servings count, it is returned unchanged.
    public func scaled(to newServings: Int) -> Recipe {
        guard let base = servings, base > 0, newServings > 0, newServings != base else { return self }
        let factor = Double(newServings) / Double(base)
        var copy = self
        copy.servings = newServings
        copy.ingredients = ingredients.map { $0.scaled(by: factor) }
        return copy
    }
}
