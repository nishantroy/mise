import Foundation

/// A saved recipe offered to the matcher, with the light signals the app stores beside it.
public struct CookCandidate: Sendable {
    public var id: UUID
    public var recipe: Recipe
    /// -1, 0 or 1 ("I made this" thumbs), or nil.
    public var rating: Int?
    public var timesCooked: Int

    public init(id: UUID, recipe: Recipe, rating: Int? = nil, timesCooked: Int = 0) {
        self.id = id
        self.recipe = recipe
        self.rating = rating
        self.timesCooked = timesCooked
    }
}

/// An ingredient the recipe needs that the pantry (or the question) says is missing.
public struct MissingIngredient: Hashable, Sendable {
    /// As the recipe names it, without "or …" alternatives ("Lao Gan Ma", "Chinese cooking wine").
    public var name: String
    public var catalogID: String?
    /// A known swap the cook can make from what they have or can easily get ("dry sherry").
    public var swap: String?
}

/// Why a recipe failed a hard filter.
public enum CookFilterFailure: Hashable, Sendable {
    /// Contains something the question ruled out ("pork").
    case contains(String)
    /// Takes longer than the limit.
    case tooLong(minutes: Int, limit: Int)
    /// "With what I have", but these aren't covered by the pantry or a swap.
    case needsShopping([String])

    /// What was relaxed to show this recipe: "no pork", "under 30 min", "with what you have".
    public var relaxedConstraint: String {
        switch self {
        case .contains(let what): "no \(what)"
        case .tooLong(_, let limit): "under \(CookFinderFormat.duration(limit))"
        case .needsShopping: "with what you have"
        }
    }
}

public struct CookMatch: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var score: Double
    /// Realistic minutes (the longer of stated and estimated), when known.
    public var minutes: Int?
    /// Query terms the recipe uses ("ground beef").
    public var usedIngredients: [String]
    public var matchedCuisine: String?
    public var matchedStyles: [CookStyle]
    public var matchedKeywords: [String]
    public var missing: [MissingIngredient]
    /// Non-staple ingredients the pantry covers, of `pantryTotal`.
    public var pantryCovered: Int
    public var pantryTotal: Int
    /// True when nothing is missing and every main protein is known to be at hand.
    public var hasEverything: Bool
    public var failures: [CookFilterFailure]
    /// The one-line reason shown on the card.
    public var why: String

    public var passesFilters: Bool { failures.isEmpty }
}

public struct CookSearchResult: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// `matches` has recipes that fit.
        case matched
        /// Nothing fit everything; `closeMatches` relax some of it.
        case closeOnly
        /// No recipes saved.
        case noRecipes
    }

    public var query: CookQuery
    public var status: Status
    public var matches: [CookMatch]
    public var closeMatches: [CookMatch]
    /// What `closeMatches` ignore, e.g. ["under 20 min", "Korean"].
    public var relaxed: [String]
    /// Ingredients asked for that no shown recipe uses ("broccoli").
    public var unmatchedIngredients: [String] = []
}

/// Deterministic ranking of saved recipes against a `CookQuery`.
///
/// Hard filters: avoided ingredients and tags, the time limit (realistic time, see
/// `realisticMinutes`), and "with what I have" (every missing item needs a known swap).
/// Score (all constants below): matched ingredients, cuisine, styles and title keywords; pantry
/// coverage; a small bonus for being well under the time limit; rating and times cooked as
/// tie-breakers. When the question asks for something (ingredients, cuisine, style, keyword), a
/// recipe must match at least one of them. If nothing passes, the best few failing recipes are
/// returned as close matches with what was relaxed.
public struct RecipeMatcher: Sendable {
    public static let ingredientWeight = 10.0
    public static let useUpWeight = 14.0
    public static let cuisineWeight = 8.0
    public static let styleWeight = 6.0
    public static let avoidStylePenalty = 6.0
    public static let keywordTitleWeight = 8.0
    public static let keywordIngredientWeight = 4.0
    public static let missingPenalty = 3.0
    public static let swappableMissingPenalty = 1.0
    public static let hasEverythingBonus = 2.0
    public static let underLimitBonus = 2.0
    public static let likedBonus = 1.0
    public static let dislikedPenalty = 2.0
    public static let cookedBonusPerTime = 0.2
    public static let maxCloseMatches = 3

    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    public func search(_ query: CookQuery, in candidates: [CookCandidate], pantry: PantrySnapshot,
                       prefs: UserPreferences = UserPreferences()) -> CookSearchResult {
        guard !candidates.isEmpty else {
            return CookSearchResult(query: query, status: .noRecipes, matches: [], closeMatches: [], relaxed: [])
        }
        let scored = candidates.map { evaluate($0, query: query, pantry: pantry, prefs: prefs) }
        let ordered = scored.sorted { a, b in
            a.match.score != b.match.score ? a.match.score > b.match.score
                : a.match.title.localizedCaseInsensitiveCompare(b.match.title) == .orderedAscending
        }
        let fits = ordered.filter { $0.match.passesFilters && (!query.hasPositiveCriteria || $0.relevance > 0) }
        if !fits.isEmpty {
            let unmatched = query.ingredients.map(\.term).filter { term in !fits.contains { $0.match.usedIngredients.contains(term) } }
            return CookSearchResult(query: query, status: .matched, matches: fits.map(\.match), closeMatches: [], relaxed: [],
                                    unmatchedIngredients: unmatched)
        }

        // Close matches: fewest failed filters, then anything relevant, then score.
        let close = scored.sorted { a, b in
            if a.match.failures.count != b.match.failures.count { return a.match.failures.count < b.match.failures.count }
            if (a.relevance > 0) != (b.relevance > 0) { return a.relevance > 0 }
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            return a.match.title.localizedCaseInsensitiveCompare(b.match.title) == .orderedAscending
        }.prefix(Self.maxCloseMatches)

        var relaxed: [String] = []
        func note(_ s: String) { if !relaxed.contains(s) { relaxed.append(s) } }
        for c in close { for f in c.match.failures { note(f.relaxedConstraint) } }
        // Asked-for things none of the close matches has.
        for ing in query.ingredients where !close.contains(where: { $0.match.usedIngredients.contains(ing.term) }) { note(ing.term) }
        for cuisine in query.cuisines where !close.contains(where: { $0.match.matchedCuisine == cuisine }) {
            if query.cuisines.count == 1 || !close.contains(where: { $0.match.matchedCuisine != nil }) { note(cuisine) }
        }
        for style in query.styles where !close.contains(where: { $0.match.matchedStyles.contains(style) }) { note(style.label) }
        for keyword in query.keywords where !close.contains(where: { $0.match.matchedKeywords.contains(keyword) }) { note("“\(keyword)”") }
        let unmatched = query.ingredients.map(\.term).filter { term in !close.contains { $0.match.usedIngredients.contains(term) } }
        return CookSearchResult(query: query, status: .closeOnly, matches: [], closeMatches: Array(close.map(\.match)), relaxed: relaxed,
                                unmatchedIngredients: unmatched)
    }

    // MARK: Scoring

    struct Evaluated {
        var match: CookMatch
        /// Score from the things the question asked for.
        var relevance: Double
    }

    func evaluate(_ candidate: CookCandidate, query: CookQuery, pantry basePantry: PantrySnapshot, prefs: UserPreferences) -> Evaluated {
        let recipe = candidate.recipe
        var pantry = basePantry
        // What the cook says they have counts as "have"; what they're out of as missing.
        for ing in query.ingredients { pantry.have.insert(ing.key); pantry.missing.remove(ing.key) }
        for ing in query.missing { pantry.missing.insert(ing.key); pantry.have.remove(ing.key) }

        let resolved: [(ingredient: Ingredient, entry: CatalogEntry?)] = recipe.ingredients.map {
            ($0, $0.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match($0.name))
        }
        var failures: [CookFilterFailure] = []
        var relevance = 0.0
        var score = 0.0

        // Avoid: ingredient (with its family) or tag.
        for avoid in query.avoid {
            if resolved.contains(where: { Self.matches(query: avoid, ingredient: $0.ingredient, entry: $0.entry, catalog: catalog, avoiding: true) }) {
                failures.append(.contains(avoid.term))
            }
        }
        if !query.avoidTags.isEmpty {
            let hit = recipe.ingredients.lazy.map { catalog.effectiveTags(for: $0).intersection(query.avoidTags) }.first { !$0.isEmpty }
            if let hit { failures.append(.contains(Self.tagName(hit, avoidTags: query.avoidTags))) }
        }

        // Ingredients asked for: in the list, or named in the title ("…Ground Beef" for "beef",
        // even when a bad parse dropped it from the list).
        let titleNorm = " \(IngredientCatalog.normalise(recipe.title)) "
        var used: [String] = []
        for want in query.ingredients
        where resolved.contains(where: { Self.matches(query: want, ingredient: $0.ingredient, entry: $0.entry, catalog: catalog, avoiding: false) })
            || titleNorm.contains(" \(IngredientCatalog.normalise(want.term)) ") {
            used.append(want.term)
            relevance += want.useUp ? Self.useUpWeight : Self.ingredientWeight
        }

        // Cuisine.
        let cuisine = query.cuisines.first { Self.recipe(recipe, hasCuisine: $0, catalog: catalog) }
        if cuisine != nil { relevance += Self.cuisineWeight }

        // Styles.
        let styles = query.styles.filter { RecipeStyleDetector(catalog: catalog).has($0, recipe) }
        relevance += Double(styles.count) * Self.styleWeight
        let avoidedStyles = query.avoidStyles.filter { RecipeStyleDetector(catalog: catalog).has($0, recipe) }
        score -= Double(avoidedStyles.count) * Self.avoidStylePenalty

        // Keywords: title words (whole or prefix of 4+ letters), then ingredient names.
        let titleWords = IngredientCatalog.normalise(recipe.title).split(separator: " ").map(String.init)
        let ingredientWords = Set(recipe.ingredients.flatMap { IngredientCatalog.normalise($0.name).split(separator: " ").map(String.init) })
        var keywords: [String] = []
        for k in query.keywords {
            if titleWords.contains(where: { $0 == k || (k.count >= 4 && $0.hasPrefix(k)) }) {
                keywords.append(k); relevance += Self.keywordTitleWeight
            } else if ingredientWords.contains(k) {
                keywords.append(k); relevance += Self.keywordIngredientWeight
            }
        }

        // Time.
        let minutes = realisticMinutes(recipe)
        if let limit = query.maxMinutes, let minutes {
            if minutes > limit {
                failures.append(.tooLong(minutes: minutes, limit: limit))
            } else {
                score += Self.underLimitBonus * (1 - Double(minutes) / Double(max(limit, 1)))
            }
        }

        // Pantry coverage.
        let coverage = pantryCoverage(resolved, pantry: pantry, prefs: prefs, query: query)
        for m in coverage.missing { score -= m.swap == nil ? Self.missingPenalty : Self.swappableMissingPenalty }
        if coverage.hasEverything { score += Self.hasEverythingBonus }
        if query.pantryOnly {
            let unswappable = coverage.missing.filter { $0.swap == nil }.map(\.name)
            if !unswappable.isEmpty { failures.append(.needsShopping(unswappable)) }
            // Double weight on coverage when they asked to use what they have.
            for m in coverage.missing { score -= m.swap == nil ? Self.missingPenalty : Self.swappableMissingPenalty }
        }

        // Tie-breakers.
        if let rating = candidate.rating { score += rating > 0 ? Self.likedBonus : (rating < 0 ? -Self.dislikedPenalty : 0) }
        score += Double(min(candidate.timesCooked, 5)) * Self.cookedBonusPerTime

        var match = CookMatch(id: candidate.id, title: recipe.title, score: relevance + score, minutes: minutes,
                              usedIngredients: used, matchedCuisine: cuisine, matchedStyles: styles, matchedKeywords: keywords,
                              missing: coverage.missing, pantryCovered: coverage.covered, pantryTotal: coverage.total,
                              hasEverything: coverage.hasEverything, failures: failures, why: "")
        match.why = CookWhy.line(for: match)
        return Evaluated(match: match, relevance: relevance)
    }

    /// The longer of the stated time and Mise's estimate (computed by the rules when the recipe
    /// has none stored). An overnight wait counts only when the recipe states no time: overnight
    /// is usually an optional make-ahead ("or refrigerate overnight").
    public func realisticMinutes(_ recipe: Recipe) -> Int? {
        let estimate = recipe.timeEstimate ?? (recipe.steps.isEmpty ? nil : TimeEstimator(catalog: catalog).estimate(recipe))
        let stated = recipe.totalMinutes.flatMap { $0 > 0 ? $0 : nil }
        guard let estimate else { return stated }
        if estimate.isOvernight, let stated { return max(stated, estimate.activeMinutes) }
        return max(stated ?? 0, estimate.totalMinutes)
    }

    // MARK: Pantry

    struct Coverage {
        var missing: [MissingIngredient]
        var covered: Int
        var total: Int
        var hasEverything: Bool
    }

    /// Non-staple ingredients only. Missing = the pantry or question says so, or a specialty/rare
    /// item the pantry doesn't list as "have". Common items are assumed (as in the ingredient
    /// check), but "you have everything" also needs every meat/fish/tofu at hand.
    func pantryCoverage(_ resolved: [(ingredient: Ingredient, entry: CatalogEntry?)], pantry: PantrySnapshot,
                        prefs: UserPreferences, query: CookQuery) -> Coverage {
        var seen: Set<String> = []
        var missing: [MissingIngredient] = []
        var total = 0
        var proteinsKnown = true
        let swaps = SwapEngine(catalog: catalog)
        for (ingredient, entry) in resolved {
            let key = entry?.id ?? IngredientCatalog.normalisedName(ingredient.name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if entry?.commonness == .staple { continue }
            total += 1
            let wanted = query.ingredients.contains { Self.matches(query: $0, ingredient: ingredient, entry: entry, catalog: catalog, avoiding: false) }
            // "sherry or rice wine": having any written alternative is enough.
            let alternativeInPantry = Self.alternatives(ingredient.name).contains { alt in
                catalog.match(alt).map { pantry.have.contains($0.id) } ?? false
            }
            let isMissing = !wanted && !alternativeInPantry && (pantry.missing.contains(key)
                || (entry.map { ($0.commonness == .specialty || $0.commonness == .rare) && !pantry.have.contains(key) } ?? false))
            if isMissing {
                let swap = entry.flatMap { entry in
                    swaps.suggestions(for: entry.id, pantry: pantry, prefs: prefs).first { s in
                        !s.isLeaveOut && s.quality != .ok && s.items.allSatisfy { item in
                            guard let id = item.catalogID, let e = catalog.entry(id: id) else { return false }
                            return pantry.have.contains(id) || (e.commonness == .staple || e.commonness == .common) && !pantry.missing.contains(id)
                        }
                    }
                }
                missing.append(MissingIngredient(name: Self.shortName(ingredient.name), catalogID: entry?.id,
                                                 swap: swap.map { $0.title.prefix(1).lowercased() + $0.title.dropFirst() }))
            } else if let entry, ["meat", "seafood", "protein"].contains(entry.category), !wanted, !pantry.have.contains(key) {
                proteinsKnown = false
            }
        }
        return Coverage(missing: missing, covered: total - missing.count, total: total, hasEverything: missing.isEmpty && proteinsKnown)
    }

    /// "sherry or rice wine" → ["sherry", "rice wine"]; one name → [].
    static func alternatives(_ name: String) -> [String] {
        let parts = name.replacingOccurrences(of: " / ", with: " or ")
            .components(separatedBy: " or ").map(\.trimmed).filter { !$0.isEmpty }
        return parts.count > 1 ? parts : []
    }

    /// "sherry or rice wine" → "sherry"; "cornflour / cornstarch" → "cornflour";
    /// "sliced bamboo shoots" → "bamboo shoots". Keeps the recipe's own casing ("Lao Gan Ma").
    static func shortName(_ name: String) -> String {
        var n = name
        if let r = n.range(of: " or ", options: .caseInsensitive) { n = String(n[..<r.lowerBound]) }
        if let r = n.range(of: " / ") { n = String(n[..<r.lowerBound]) }
        var words = n.split(separator: " ").map(String.init)
        while words.count > 1, let first = words.first,
              IngredientCatalog.prepWords.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        return words.joined(separator: " ").trimmed
    }

    // MARK: Matching helpers

    /// A query ingredient matches a recipe ingredient with the same catalog ID, or one in the same
    /// family ("chicken" ↔ "chicken-thigh", same category). Avoiding a word that is also a tag
    /// ("pork", "beef", "fish") rules out everything carrying that tag (bacon, pork belly).
    static func matches(query: QueryIngredient, ingredient: Ingredient, entry: CatalogEntry?, catalog: IngredientCatalog, avoiding: Bool) -> Bool {
        if let qid = query.catalogID {
            if let entry {
                if entry.id == qid { return true }
                if let qEntry = catalog.entry(id: qid), qEntry.category == entry.category, familyCategories.contains(entry.category),
                   family(qid) == family(entry.id), catalog.entry(id: family(qid)) != nil { return true }
                if avoiding, let tag = IngredientTag(rawValue: qid), catalog.effectiveTags(for: ingredient).contains(tag) { return true }
                return false
            }
            return false
        }
        let name = " \(IngredientCatalog.normalise(ingredient.name)) "
        return name.contains(" \(IngredientCatalog.normalise(query.term)) ")
    }

    /// Families ("chicken" → chicken, chicken-breast, chicken-thigh) only for proteins, so
    /// "rice noodles" never matches "rice".
    static let familyCategories: Set<String> = ["meat", "seafood", "protein"]

    static func family(_ id: String) -> String { String(id.split(separator: "-").first ?? Substring(id)) }

    static func recipe(_ recipe: Recipe, hasCuisine cuisine: String, catalog: IngredientCatalog) -> Bool {
        let key = cuisine.lowercased().filter(\.isLetter)
        if let given = recipe.cuisine, !given.isEmpty {
            // Page cuisines can be lists: "Asian, Indian", "American/Chinese".
            let parts = given.split(whereSeparator: { ",/&;|".contains($0) }).map { $0.lowercased().filter(\.isLetter) }
            if parts.contains(key) { return true }
            if recipe.hasGivenCuisine, CuisineGuesser.vocabulary.contains(where: { parts.contains($0.lowercased().filter(\.isLetter)) }) {
                return false
            }
        }
        return CuisineGuesser(catalog: catalog).guess(recipe) == cuisine
    }

    static func tagName(_ tags: Set<IngredientTag>, avoidTags: Set<IngredientTag>) -> String {
        if avoidTags.isSuperset(of: SwapEngine.forbiddenTags(for: .vegetarian)), !tags.isDisjoint(with: SwapEngine.forbiddenTags(for: .vegetarian)) {
            return "meat or fish"
        }
        for tag: IngredientTag in [.pork, .beef, .poultry, .fish, .shellfish, .meat, .dairy, .egg, .gluten, .nuts, .peanuts, .soy, .alcohol, .honey, .spicy]
        where tags.contains(tag) {
            return tag == .poultry ? "poultry" : tag.rawValue
        }
        return tags.map(\.rawValue).sorted().first ?? "something you ruled out"
    }
}

/// Detects `CookStyle`s in a recipe from its title, ingredients and steps.
public struct RecipeStyleDetector: Sendable {
    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    static let heavyIDs: Set<String> = ["pork-belly", "cream", "bacon", "cheese", "cheddar", "sour-cream", "pancetta", "mozzarella", "parmesan"]

    public func has(_ style: CookStyle, _ recipe: Recipe) -> Bool {
        let title = " \(IngredientCatalog.normalise(recipe.title)) "
        let ids = Set(recipe.ingredients.compactMap { $0.catalogID ?? catalog.match($0.name)?.id })
        let steps = recipe.steps.joined(separator: " ").lowercased()
        func titleHas(_ words: [String]) -> Bool { words.contains { title.contains(" \(IngredientCatalog.normalise($0)) ") } }
        switch style {
        case .spicy:
            return recipe.ingredients.contains { catalog.effectiveTags(for: $0).contains(.spicy) }
                || titleHas(["spicy", "chili", "chilli", "hot", "sichuan", "szechuan", "kung pao", "mala", "fiery", "vindaloo", "kimchi"])
        case .light:
            let heavy = !ids.isDisjoint(with: Self.heavyIDs) || steps.contains("deep fry") || steps.contains("deep-fry")
                || titleHas(["fried", "creamy", "cheesy", "pancake", "cake", "braised"])
            let produce = ids.filter { catalog.entry(id: $0)?.category == "produce" }.count
            return !heavy && (titleHas(["salad", "soup", "steamed", "poached", "light"]) || produce >= 3)
        case .comforting:
            return titleHas(["braise", "braised", "stew", "curry", "soup", "chili", "pie", "casserole", "bake", "roast", "congee",
                             "dal", "mac", "pot", "ragu", "bolognese", "lasagna", "noodle soup", "red braised"])
                || !ids.isDisjoint(with: ["pork-belly", "cream", "cheese", "potato"])
                || steps.contains("braise")
        case .noodles:
            return !ids.isDisjoint(with: ["egg-noodles", "rice-noodles", "pasta"])
                || titleHas(["noodle", "mein", "ramen", "udon", "soba", "pho", "pasta", "spaghetti", "pad thai", "japchae"])
        case .soup:
            return titleHas(["soup", "broth", "pho", "ramen", "chowder", "bisque", "stew", "jjigae", "tom yum"])
                || Rx.firstMatch(#"\b(soup|broth)\b"#, in: steps) != nil && titleHas(["noodle"])
        case .rice:
            return ids.contains("rice") || titleHas(["rice", "biryani", "congee", "risotto", "pilaf", "pulao", "bibimbap", "donburi"])
                || Rx.firstMatch(#"\b(over|with)\s+(steamed |cooked |white |jasmine |plain )?rice\b(?!\s+(vinegar|wine|noodle|flour|paper|stick))"#, in: steps) != nil
        case .stirFry:
            return titleHas(["stir fry", "stir fried", "kung pao", "chow mein", "lo mein", "fried rice"])
                || Rx.firstMatch(#"\b(stir[- ]?fr(y|ied|ying)|wok)\b"#, in: steps) != nil
        case .curry:
            return titleHas(["curry", "masala", "korma", "vindaloo", "massaman", "dal"])
                || !ids.isDisjoint(with: ["curry-powder", "thai-curry-paste"])
        }
    }
}

/// The one-line "why" on a result card, from computed facts only.
public enum CookWhy {
    /// Parts, joined with " · ": what it uses, cuisine and styles, time, then pantry
    /// ("you have everything" / "Missing Shaoxing wine — dry sherry works"), and for close
    /// matches what it breaks ("has pork", "~1 hr 5 min, over your 30 min").
    public static func line(for match: CookMatch) -> String {
        var parts: [String] = []
        if !match.usedIngredients.isEmpty { parts.append("uses \(list(match.usedIngredients))") }
        if let c = match.matchedCuisine { parts.append(c) }
        if !match.matchedStyles.isEmpty { parts.append(list(match.matchedStyles.map(\.label))) }
        var timeShown = false
        for failure in match.failures {
            switch failure {
            case .contains(let what): parts.append("has \(what)")
            case .tooLong(let minutes, let limit):
                parts.append("~\(CookFinderFormat.duration(minutes)), over your \(CookFinderFormat.duration(limit))")
                timeShown = true
            case .needsShopping: break // the missing part below says what
            }
        }
        if !timeShown, let m = match.minutes { parts.append("~\(CookFinderFormat.duration(m))") }
        if match.hasEverything {
            parts.append("you have everything")
        } else if !match.missing.isEmpty {
            parts.append(missingText(match.missing))
        }
        guard let first = parts.first else { return "" }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        return parts.joined(separator: " · ")
    }

    /// "Missing Lao Gan Ma — chili flakes works" (one item), "Missing pork belly and star anise",
    /// "Missing bean sprouts, oyster sauce +2 more" (unswappable first), or when every item has a
    /// swap, "Missing Shaoxing wine — dry sherry works +1 more".
    static func missingText(_ missing: [MissingIngredient]) -> String {
        let uncovered = missing.filter { $0.swap == nil }
        if uncovered.isEmpty || missing.count == 1, let first = uncovered.first ?? missing.first {
            let head = first.swap.map { "missing \(first.name) — \($0) works" } ?? "missing \(first.name)"
            return head + (missing.count > 1 ? " +\(missing.count - 1) more" : "")
        }
        let names = (uncovered + missing.filter { $0.swap != nil }).map(\.name)
        if names.count <= 2 { return "missing \(list(names))" }
        return "missing \(names.prefix(2).joined(separator: ", ")) +\(names.count - 2) more"
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
