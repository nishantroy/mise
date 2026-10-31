import Foundation

/// Deterministic ingredient review and swap ranking.
public struct SwapEngine: Sendable {
    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    // MARK: Review

    /// One item per ingredient that needs attention, in recipe order.
    public func review(recipe: Recipe, pantry: PantrySnapshot, prefs: UserPreferences) -> [ReviewItem] {
        recipe.ingredients.compactMap { review(ingredient: $0, pantry: pantry, prefs: prefs) }
    }

    public func review(ingredient: Ingredient, pantry: PantrySnapshot, prefs: UserPreferences) -> ReviewItem? {
        let entry = ingredient.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ingredient.name)
        let key = entry?.id ?? IngredientCatalog.normalisedName(ingredient.name)
        let tags = catalog.effectiveTags(for: ingredient)
        let spicyScale: Double? = (tags.contains(.spicy) && prefs.spiceLevel <= 1) ? 0.5 : nil
        func item(_ kind: ReviewKind, leaveOut: Bool = false) -> ReviewItem {
            ReviewItem(ingredient: ingredient, kind: kind,
                       swaps: suggestions(for: entry?.id, pantry: pantry, prefs: prefs, ensureLeaveOut: leaveOut),
                       pantryKey: key, suggestedScale: spicyScale)
        }

        let reasons = conflictReasons(tags: tags, prefs: prefs)
        if !reasons.isEmpty { return item(.conflict(reasons), leaveOut: true) }
        if let dislike = matchingDislike(ingredient: ingredient, entry: entry, prefs: prefs) {
            return item(.dislike(dislike), leaveOut: true)
        }
        if pantry.missing.contains(key) { return item(.missing, leaveOut: true) }
        if pantry.have.contains(key) {
            return spicyScale == nil ? nil : ReviewItem(ingredient: ingredient, kind: .tooSpicy, swaps: [], pantryKey: key, suggestedScale: spicyScale)
        }
        if let entry, entry.commonness == .specialty || entry.commonness == .rare {
            return item(.askHave, leaveOut: true)
        }
        if spicyScale != nil {
            return ReviewItem(ingredient: ingredient, kind: .tooSpicy, swaps: [], pantryKey: key, suggestedScale: spicyScale)
        }
        return nil
    }

    /// Tags each diet rules out.
    public static func forbiddenTags(for diet: Diet) -> Set<IngredientTag> {
        switch diet {
        case .omnivore: []
        case .pescatarian: [.meat, .pork, .beef, .poultry]
        case .vegetarian: [.meat, .pork, .beef, .poultry, .fish, .shellfish]
        case .vegan: [.meat, .pork, .beef, .poultry, .fish, .shellfish, .dairy, .egg, .honey]
        }
    }

    public func conflictReasons(tags: Set<IngredientTag>, prefs: UserPreferences) -> [String] {
        var reasons: [String] = []
        let dietClash = tags.intersection(Self.forbiddenTags(for: prefs.diet))
        if !dietClash.isEmpty { reasons.append("Not \(prefs.diet.rawValue)") }
        for avoid in prefs.avoid.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let tag = IngredientTag(rawValue: avoid.rawValue), tags.contains(tag) {
                reasons.append("Contains \(avoid.label.lowercased())")
            }
        }
        return reasons
    }

    func matchingDislike(ingredient: Ingredient, entry: CatalogEntry?, prefs: UserPreferences) -> String? {
        let name = " \(IngredientCatalog.normalise(ingredient.name)) "
        for dislike in prefs.dislikes {
            let d = dislike.trimmed
            guard !d.isEmpty else { continue }
            if let entry, let dEntry = catalog.match(d), dEntry.id == entry.id { return d }
            let norm = IngredientCatalog.normalise(d)
            if !norm.isEmpty, name.contains(" \(norm) ") { return d }
        }
        return nil
    }

    func isAllowed(_ entry: CatalogEntry, pantry: PantrySnapshot, prefs: UserPreferences) -> Bool {
        if pantry.missing.contains(entry.id) { return false }
        if !conflictReasons(tags: entry.tags, prefs: prefs).isEmpty { return false }
        let fake = Ingredient(raw: entry.displayName, name: entry.displayName, catalogID: entry.id)
        return matchingDislike(ingredient: fake, entry: entry, prefs: prefs) == nil
    }

    // MARK: Ranking

    /// Ranked swaps for a catalog ID from the bundled table, top 3. With `ensureLeaveOut`,
    /// "Leave it out" is added when the table offers it but it didn't make the top 3.
    public func suggestions(for catalogID: String?, pantry: PantrySnapshot, prefs: UserPreferences, ensureLeaveOut: Bool = false) -> [SwapSuggestion] {
        guard let catalogID else { return [] }
        var ranked: [(SwapSuggestion, Int)] = []
        for (index, option) in catalog.swaps(for: catalogID).enumerated() {
            guard let s = score(option, pantry: pantry, prefs: prefs) else { continue }
            ranked.append((s, index))
        }
        ranked.sort { a, b in a.0.score != b.0.score ? a.0.score > b.0.score : a.1 < b.1 }
        var top = Array(ranked.prefix(3).map(\.0))
        if ensureLeaveOut, !top.contains(where: \.isLeaveOut), let leave = ranked.first(where: { $0.0.isLeaveOut }) {
            top.append(leave.0)
        }
        return top
    }

    /// Scores one option, or nil when it uses something missing or off-limits.
    public func score(_ option: SwapOption, pantry: PantrySnapshot, prefs: UserPreferences) -> SwapSuggestion? {
        var items: [SwapSuggestion.Item] = []
        var allHave = !option.use.isEmpty
        var allEasy = !option.use.isEmpty
        for component in option.use {
            guard let entry = catalog.entry(id: component.id), isAllowed(entry, pantry: pantry, prefs: prefs) else { return nil }
            if !pantry.have.contains(entry.id) { allHave = false }
            if !(entry.commonness == .staple || entry.commonness == .common) { allEasy = false }
            items.append(.init(catalogID: entry.id, name: entry.displayName, ratio: component.ratio, amount: component.amount))
        }
        let score = option.quality.score + (allHave ? 3 : 0) + (allEasy ? 1 : 0)
        return SwapSuggestion(items: items, quality: option.quality, note: option.note, fromPantry: allHave, score: score)
    }
}
