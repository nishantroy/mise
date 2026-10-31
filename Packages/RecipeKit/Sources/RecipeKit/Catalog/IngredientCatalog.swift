import Foundation

public enum Commonness: String, Codable, Hashable, Sendable, CaseIterable {
    case staple, common, specialty, rare
}

public enum IngredientTag: String, Codable, Hashable, Sendable, CaseIterable {
    case meat, pork, beef, poultry, fish, shellfish, dairy, egg, honey, gluten, nuts, peanuts, soy, alcohol, spicy
}

public struct CatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var names: [String]
    public var commonness: Commonness
    public var category: String
    public var tags: Set<IngredientTag>
    /// Cuisines this ingredient points to (from `UserPreferences.cuisineChoices`). Only set on
    /// entries that say something about the cuisine; generic ones (garlic, onion) have none.
    public var cuisines: [String]? = nil
    /// Vote weight per listed cuisine. Defaults to 3 for a single cuisine, 1 when several share it.
    public var cuisineWeight: Int? = nil
    /// Catalog IDs this entry stands in for together ("ginger-garlic-paste" replaces ginger and
    /// garlic). Lets a diff pair several removed ingredients with one added one.
    public var replaces: [String]? = nil

    /// The first alias, used when an ingredient is written into a recipe.
    public var displayName: String { names.first ?? id }

    /// Weight this entry adds to each of its cuisines when guessing.
    public var cuisineVote: Int {
        guard let cuisines, !cuisines.isEmpty else { return 0 }
        return cuisineWeight ?? (cuisines.count == 1 ? 3 : 1)
    }
}

public enum SwapQuality: String, Codable, Hashable, Sendable, CaseIterable {
    case great, good, ok

    public var score: Int {
        switch self {
        case .great: 3
        case .good: 2
        case .ok: 1
        }
    }
}

/// One ingredient in a swap. Either `ratio` (quantity multiplier) or a free-text `amount`.
public struct SwapComponent: Codable, Hashable, Sendable {
    public var id: String
    public var ratio: Double?
    public var amount: String?

    public init(id: String, ratio: Double? = 1, amount: String? = nil) {
        self.id = id
        self.ratio = amount == nil ? ratio : nil
        self.amount = amount
    }
}

public struct SwapOption: Codable, Hashable, Sendable {
    public var use: [SwapComponent]
    public var quality: SwapQuality
    public var note: String

    public init(use: [SwapComponent], quality: SwapQuality, note: String) {
        self.use = use
        self.quality = quality
        self.note = note
    }
}

public struct SwapRule: Codable, Hashable, Sendable {
    public var `for`: String
    public var options: [SwapOption]
}

/// The bundled ingredient list and swap table, with alias matching.
public final class IngredientCatalog: Sendable {
    public let entries: [CatalogEntry]
    public let swapRules: [String: [SwapOption]]
    private let byID: [String: CatalogEntry]
    /// (normalised alias, entry id), longest alias first.
    let aliases: [(alias: String, id: String)]

    public init(entries: [CatalogEntry], swaps: [SwapRule]) {
        self.entries = entries
        var byID: [String: CatalogEntry] = [:]
        for e in entries { byID[e.id] = e }
        self.byID = byID
        var rules: [String: [SwapOption]] = [:]
        for r in swaps { rules[r.for, default: []] += r.options }
        self.swapRules = rules
        var aliases: [(String, String)] = []
        for e in entries {
            for n in e.names {
                let norm = Self.normalise(n)
                if !norm.isEmpty { aliases.append((norm, e.id)) }
            }
        }
        // Longest first; ties broken by word count so "dark soy sauce" beats "soy sauce".
        self.aliases = aliases.sorted { a, b in
            a.0.count != b.0.count ? a.0.count > b.0.count : a.0 < b.0
        }.map { (alias: $0.0, id: $0.1) }
    }

    public convenience init(ingredientsJSON: Data, swapsJSON: Data) throws {
        let decoder = JSONDecoder()
        try self.init(entries: decoder.decode([CatalogEntry].self, from: ingredientsJSON),
                      swaps: decoder.decode([SwapRule].self, from: swapsJSON))
    }

    /// Bundle holding `ingredients.json` and `swaps.json`.
    static var resourceBundle: Bundle { Bundle.module }

    /// The bundled catalog. Loading failures are programmer errors (the JSON ships with the package).
    public static let shared: IngredientCatalog = {
        guard let ing = Bundle.module.url(forResource: "ingredients", withExtension: "json"),
              let sw = Bundle.module.url(forResource: "swaps", withExtension: "json"),
              let catalog = try? IngredientCatalog(ingredientsJSON: Data(contentsOf: ing), swapsJSON: Data(contentsOf: sw))
        else { fatalError("RecipeKit: bundled ingredients.json / swaps.json missing or invalid") }
        return catalog
    }()

    public func entry(id: String) -> CatalogEntry? { byID[id] }

    public func swaps(for id: String) -> [SwapOption] { swapRules[id] ?? [] }

    // MARK: Matching

    /// Prep and size words dropped when building pantry keys for names the catalog doesn't know.
    static let prepWords: Set<String> = [
        "chopped", "minced", "diced", "sliced", "grated", "crushed", "peeled", "fresh", "freshly", "large",
        "small", "medium", "finely", "roughly", "thinly", "coarsely", "about", "approximately", "optional",
        "shredded", "julienned", "halved", "quartered", "trimmed", "rinsed", "drained", "softened", "melted",
        "beaten", "whole", "organic", "ripe", "cubed", "cut", "into", "pieces", "piece", "to", "taste", "of", "the", "a",
    ]

    /// Lowercase, punctuation to spaces, collapse whitespace, and a light singular form
    /// ("onions" → "onion") applied identically to aliases and input.
    public static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var scalars = String.UnicodeScalarView()
        for s in folded.unicodeScalars {
            scalars.append(CharacterSet.alphanumerics.contains(s) ? s : " ")
        }
        return String(scalars).split(separator: " ").map { singular(String($0)) }.joined(separator: " ")
    }

    static func singular(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") else { return word }
        return String(word.dropLast())
    }

    /// Longest catalog alias that appears in `name` as whole words.
    public func match(_ name: String) -> CatalogEntry? {
        matchWithAlias(name)?.entry
    }

    func matchWithAlias(_ name: String) -> (entry: CatalogEntry, alias: String)? {
        let norm = Self.normalise(name)
        guard !norm.isEmpty else { return nil }
        let padded = " \(norm) "
        for (alias, id) in aliases where padded.contains(" \(alias) ") {
            if let entry = byID[id] { return (entry, alias) }
        }
        return nil
    }

    /// A catalog entry only when the text names it and nothing more (prep words aside):
    /// "fresh ginger" → ginger, but "soy milk" never falls back to milk. For typed pantry items.
    public func exactMatch(_ text: String) -> CatalogEntry? {
        guard let (entry, alias) = matchWithAlias(text) else { return nil }
        let words = Set(Self.normalisedName(text).split(separator: " ").map(String.init))
        let aliasWords = Set(alias.split(separator: " ").map(String.init))
        return words.isSubset(of: aliasWords) ? entry : nil
    }

    // MARK: Qualifiers

    /// "gluten-free soy sauce", "vegan butter": qualifiers in the ingredient's own name that
    /// cancel catalog tags. Matched on the normalised name (hyphens become spaces).
    static let qualifiers: [(phrase: String, removes: Set<IngredientTag>)] = [
        ("gluten free", [.gluten]),
        ("dairy free", [.dairy]),
        ("non dairy", [.dairy]),
        ("lactose free", []),
        ("egg free", [.egg]),
        ("eggless", [.egg]),
        ("nut free", [.nuts]),
        ("alcohol free", [.alcohol]),
        ("non alcoholic", [.alcohol]),
        ("vegan", [.meat, .pork, .beef, .poultry, .fish, .shellfish, .dairy, .egg, .honey]),
        ("plant based", [.meat, .pork, .beef, .poultry, .fish, .shellfish, .dairy, .egg, .honey]),
        ("vegetarian", [.meat, .pork, .beef, .poultry, .fish, .shellfish]),
        ("meatless", [.meat, .pork, .beef, .poultry]),
    ]

    /// Catalog tags for an ingredient, minus any its name's qualifiers rule out.
    public func effectiveTags(for ingredient: Ingredient) -> Set<IngredientTag> {
        guard let entry = ingredient.catalogID.flatMap(entry(id:)) ?? match(ingredient.name) else { return [] }
        let padded = " \(Self.normalise(ingredient.name)) "
        var tags = entry.tags
        for (phrase, removes) in Self.qualifiers where padded.contains(" \(phrase) ") {
            tags.subtract(removes)
        }
        return tags
    }

    /// Catalog ID if matched, otherwise the normalised name without prep words.
    public func pantryKey(for ingredient: Ingredient) -> String {
        if let id = ingredient.catalogID ?? match(ingredient.name)?.id { return id }
        return Self.normalisedName(ingredient.name)
    }

    public static func normalisedName(_ name: String) -> String {
        let words = normalise(name).split(separator: " ").map(String.init).filter { !prepWords.contains($0) }
        return words.isEmpty ? normalise(name) : words.joined(separator: " ")
    }

    /// Sets `catalogID` on every ingredient in the recipe.
    public func annotate(_ recipe: Recipe) -> Recipe {
        var copy = recipe
        copy.ingredients = recipe.ingredients.map(annotate)
        return copy
    }

    public func annotate(_ ingredient: Ingredient) -> Ingredient {
        var copy = ingredient
        copy.catalogID = match(ingredient.name)?.id
        return copy
    }

    /// Names to look for when rewriting step text: catalog aliases plus the ingredient's own name.
    public func aliases(for ingredient: Ingredient) -> [String] {
        var names = [ingredient.name]
        if let id = ingredient.catalogID, let e = byID[id] { names += e.names }
        return names
    }

    public func displayName(for id: String) -> String { byID[id]?.displayName ?? id }

    // MARK: Onboarding

    /// ~30 items for the onboarding pantry grid: useful things people often don't have.
    public static let quickPickIDs: [String] = [
        "soy-sauce", "fish-sauce", "oyster-sauce", "sesame-oil", "rice-vinegar", "mirin", "shaoxing-wine", "dry-sherry",
        "gochujang", "miso", "hoisin", "coconut-milk", "garam-masala", "cumin", "turmeric", "smoked-paprika",
        "chili-flakes", "ghee", "yogurt", "cream", "parmesan", "tahini", "lemon", "lime", "ginger", "scallion",
        "cilantro", "chicken-stock", "vegetable-stock", "white-wine", "honey", "cornstarch",
    ]
}
