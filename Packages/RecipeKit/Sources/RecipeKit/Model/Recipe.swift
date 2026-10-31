import Foundation

public struct Recipe: Codable, Hashable, Sendable {
    public var title: String
    public var sourceURL: URL?
    public var imageURL: URL?
    public var servings: Int?
    public var totalMinutes: Int?
    /// Cuisine from the page, set by the user, or guessed (see `cuisineIsGuess`).
    public var cuisine: String?
    public var ingredients: [Ingredient]
    public var steps: [String]
    public var notes: [String]
    /// True when `cuisine` was guessed by Mise rather than given by the page or the user.
    /// Missing in recipes saved before guessing existed; decodes as false.
    public var cuisineIsGuess: Bool
    /// Mise's own estimate of how long the recipe really takes. `totalMinutes` (the source's
    /// stated time) is never overwritten by it. Missing in older saved recipes.
    public var timeEstimate: TimeEstimate?

    public init(title: String, sourceURL: URL? = nil, imageURL: URL? = nil, servings: Int? = nil,
                totalMinutes: Int? = nil, cuisine: String? = nil, ingredients: [Ingredient] = [],
                steps: [String] = [], notes: [String] = [], cuisineIsGuess: Bool = false,
                timeEstimate: TimeEstimate? = nil) {
        self.title = title
        self.sourceURL = sourceURL
        self.imageURL = imageURL
        self.servings = servings
        self.totalMinutes = totalMinutes
        self.cuisine = cuisine
        self.ingredients = ingredients
        self.steps = steps
        self.notes = notes
        self.cuisineIsGuess = cuisineIsGuess
        self.timeEstimate = timeEstimate
    }

    enum CodingKeys: String, CodingKey {
        case title, sourceURL, imageURL, servings, totalMinutes, cuisine, ingredients, steps, notes
        case cuisineIsGuess, timeEstimate
    }

    /// Tolerant decoding: fields added after v1 (`cuisineIsGuess`, `timeEstimate`) may be absent,
    /// and so may the list fields, so recipes saved by older builds still open.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        imageURL = try c.decodeIfPresent(URL.self, forKey: .imageURL)
        servings = try c.decodeIfPresent(Int.self, forKey: .servings)
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes)
        cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine)
        ingredients = try c.decodeIfPresent([Ingredient].self, forKey: .ingredients) ?? []
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        cuisineIsGuess = try c.decodeIfPresent(Bool.self, forKey: .cuisineIsGuess) ?? false
        // A malformed estimate shouldn't make the whole recipe unreadable.
        timeEstimate = try? c.decodeIfPresent(TimeEstimate.self, forKey: .timeEstimate)
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
