import Foundation

/// What an on-device model read from a "What can I cook?" question, before validation.
/// Plain values so RecipeKit stays free of FoundationModels.
public struct ProposedCookQuery: Hashable, Sendable {
    public var ingredients: [String]
    public var useUp: [String]
    public var avoid: [String]
    /// 0 when the question gives no limit.
    public var maxMinutes: Int
    /// Labels such as "Chinese"; unknown ones are dropped.
    public var cuisines: [String]
    /// `CookStyle` raw values; unknown ones are dropped.
    public var styles: [String]
    /// 0 when not given.
    public var servings: Int
    public var pantryOnly: Bool

    public init(ingredients: [String] = [], useUp: [String] = [], avoid: [String] = [], maxMinutes: Int = 0,
                cuisines: [String] = [], styles: [String] = [], servings: Int = 0, pantryOnly: Bool = false) {
        self.ingredients = ingredients
        self.useUp = useUp
        self.avoid = avoid
        self.maxMinutes = maxMinutes
        self.cuisines = cuisines
        self.styles = styles
        self.servings = servings
        self.pantryOnly = pantryOnly
    }
}

/// Validates a model's reading of the question and merges it into the rules' parse.
///
/// The rules' parse is the base and is never weakened: the model can only add.
/// - Ingredients and avoids must be grounded: the term's words appear in the question, or the term
///   maps to a catalog entry one of whose aliases appears in it. An avoid from the rules beats a
///   model "want" of the same thing, and a model avoid never removes a rules "want".
/// - Numbers (time limit, servings) must appear in the question as digits or words; the rules'
///   value wins when they found one.
/// - Cuisines must be named in the question (a vocabulary cuisine or one of the guesser's cuisine
///   words, e.g. "Sichuan" → Chinese). Styles are a closed list and only add soft score, so any
///   valid style is accepted ("nothing too heavy" → light).
/// - "With what I have" needs a pantry-ish word in the question (have, got, pantry, fridge, hand, shop, store).
public enum CookQueryMerge {
    public static func merge(_ proposal: ProposedCookQuery, rules: CookQuery, catalog: IngredientCatalog = .shared) -> CookQuery {
        var query = rules
        let tokens = CookQueryParser.tokenize(rules.text).filter { !$0.isBreak }
        let textNorm = " " + tokens.map(\.norm).joined(separator: " ") + " "
        let textWords = Set(tokens.map(\.word))

        func grounded(_ term: String) -> QueryIngredient? {
            let norm = IngredientCatalog.normalise(term)
            guard !norm.isEmpty, norm.count <= 40 else { return nil }
            let entry = catalog.match(term)
            if textNorm.contains(" \(norm) ") {
                return QueryIngredient(term: term.lowercased().trimmed, catalogID: entry?.id)
            }
            if let entry, let alias = entry.names.first(where: { textNorm.contains(" \(IngredientCatalog.normalise($0)) ") }) {
                return QueryIngredient(term: alias.lowercased(), catalogID: entry.id)
            }
            return nil
        }

        let ruleAvoid = Set(rules.avoid.map(\.key))
        let ruleWant = Set(rules.ingredients.map(\.key))
        let ruleMissing = Set(rules.missing.map(\.key))
        let useUpKeys = Set(proposal.useUp.compactMap { grounded($0)?.key })
        for term in proposal.ingredients + proposal.useUp {
            guard var ing = grounded(term), !ruleAvoid.contains(ing.key), !ruleMissing.contains(ing.key) else { continue }
            // "rice" is a style in the rules' parse.
            if ing.catalogID == "rice" {
                if !query.styles.contains(.rice) { query.styles.append(.rice) }
                continue
            }
            if let idx = query.ingredients.firstIndex(where: { $0.key == ing.key }) {
                if useUpKeys.contains(ing.key) { query.ingredients[idx].useUp = true }
                continue
            }
            ing.useUp = useUpKeys.contains(ing.key)
            query.ingredients.append(ing)
        }
        for term in proposal.avoid {
            guard let ing = grounded(term), !ruleWant.contains(ing.key), !query.avoid.contains(where: { $0.key == ing.key }) else { continue }
            query.avoid.append(ing)
            query.ingredients.removeAll { $0.key == ing.key }
        }

        if query.maxMinutes == nil, proposal.maxMinutes > 0, proposal.maxMinutes <= 24 * 60,
           appears(proposal.maxMinutes, in: tokens.map(\.word)) {
            query.maxMinutes = proposal.maxMinutes
        }
        if query.servings == nil, (1...24).contains(proposal.servings), appears(proposal.servings, in: tokens.map(\.word)) {
            query.servings = proposal.servings
        }

        let named = Set(CookQueryParser.cuisineWords.filter { phrase, _ in
            textNorm.contains(" \(phrase.joined(separator: " ")) ")
        }.flatMap(\.1))
        for raw in proposal.cuisines {
            guard let cuisine = CuisineGuesser.mapModelChoice(raw), named.contains(cuisine), !query.cuisines.contains(cuisine) else { continue }
            query.cuisines.append(cuisine)
        }
        for raw in proposal.styles {
            guard let style = CookStyle(rawValue: raw) ?? CookStyle.allCases.first(where: { $0.label == raw.lowercased() }),
                  !query.styles.contains(style), !query.avoidStyles.contains(style) else { continue }
            query.styles.append(style)
        }
        if proposal.pantryOnly, !textWords.isDisjoint(with: ["have", "got", "pantry", "fridge", "hand", "shop", "shopping", "store", "cupboard"]) {
            query.pantryOnly = true
        }
        // Keywords the model turned into ingredients aren't title keywords any more.
        let ingredientWords = Set(query.ingredients.flatMap { IngredientCatalog.normalise($0.term).split(separator: " ").map(String.init) })
        query.keywords.removeAll { ingredientWords.contains($0) }
        return query
    }

    /// The number is written in the question: "30", "thirty", "forty five", or 60 as "an hour",
    /// 30 as "half an hour", 90 as "an hour and a half".
    static func appears(_ n: Int, in words: [String]) -> Bool {
        for i in words.indices {
            if let (value, _) = CookQueryParser.number(words, at: i), words[i] != "a", words[i] != "an", Int(value) == n, Double(n) == value { return true }
            if let (minutes, _) = CookQueryParser.duration(words, at: i), minutes == n { return true }
        }
        return false
    }
}
