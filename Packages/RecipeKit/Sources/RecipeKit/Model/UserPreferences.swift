import Foundation

public enum Diet: String, Codable, CaseIterable, Hashable, Sendable {
    case omnivore, pescatarian, vegetarian, vegan

    public var label: String { rawValue.capitalized }
}

public enum AvoidTag: String, Codable, CaseIterable, Hashable, Sendable {
    case gluten, dairy, egg, nuts, peanuts, shellfish, pork, beef, alcohol, soy

    public var label: String {
        switch self {
        case .egg: "Eggs"
        case .nuts: "Tree nuts"
        default: rawValue.capitalized
        }
    }
}

public struct UserPreferences: Codable, Hashable, Sendable {
    public var diet: Diet
    public var avoid: Set<AvoidTag>
    public var dislikes: [String]
    public var spiceLevel: Int
    public var cuisines: [String]
    public var weeknightMinutes: Int?
    public var servings: Int

    public init(diet: Diet = .omnivore, avoid: Set<AvoidTag> = [], dislikes: [String] = [],
                spiceLevel: Int = 2, cuisines: [String] = [], weeknightMinutes: Int? = 30, servings: Int = 2) {
        self.diet = diet
        self.avoid = avoid
        self.dislikes = dislikes
        self.spiceLevel = spiceLevel
        self.cuisines = cuisines
        self.weeknightMinutes = weeknightMinutes
        self.servings = servings
    }

    public static let spiceLabels = ["Mild", "Gentle", "Medium", "Hot", "Very hot"]
    public static let cuisineChoices = ["Indian", "Chinese", "Japanese", "Korean", "Thai", "Italian", "Mexican", "Middle Eastern", "French", "American"]
}
