import Foundation

/// Which ingredients each step uses, for cook mode's "For this step" and the prep list.
///
/// Rules:
/// - Phrases per ingredient: its name (split on "or" and "/", prep words dropped) and its catalog
///   aliases. Matched as whole words, case- and accent-insensitive, longest first in one pass, with
///   plural forms ("onions", "chilies") accepted.
/// - Longer catalog names that contain a recipe phrase but belong to an ingredient the recipe
///   doesn't have ("spring onions" in a recipe with "onion") are matched and ignored, so they never
///   link the shorter one.
/// - Single-word fallbacks ("chicken" for "chicken breast or thigh fillets", "oil" for "peanut
///   oil"): a recipe ingredient's last word, or a one-word catalog alias, that only one recipe
///   ingredient's name contains. When several contain it, the one with at least twice the amount
///   (in comparable units) wins; otherwise it stays unresolved. Generic words ("sauce", "paste")
///   are never fallbacks, so "the sauce" stays unresolved.
/// - An ingredient listed twice (soy sauce in the marinade and the sauce): a step that shows one
///   line's amount ("⅓ cup cornstarch") gets that line; then one whose note shares a word with the
///   step ("slurry"); otherwise the n-th step mentioning it gets the n-th line.
public struct StepIngredientLinker: Sendable {
    public struct Mention: Hashable, Sendable {
        public var ingredientID: UUID
        /// Position in the step's folded (lowercased, accent-free) text.
        public var range: NSRange
    }

    public struct Links: Hashable, Sendable {
        /// Per step, the ingredients it mentions, in order of first mention.
        public var steps: [[UUID]]
        /// Per step, every mention with its position.
        public var mentions: [[Mention]]
        /// Ingredients no step mentions, in recipe order.
        public var unmentioned: [UUID]

        /// "For this step": the step's ingredients; step 1 also gets everything no step mentions.
        public func forStep(_ index: Int) -> [UUID] {
            guard steps.indices.contains(index) else { return [] }
            return index == 0 ? steps[0] + unmentioned.filter { !steps[0].contains($0) } : steps[index]
        }
    }

    /// Words that name a kind of thing rather than an ingredient; never used as fallbacks.
    static let genericWords: Set<String> = [
        "sauce", "paste", "powder", "mixture", "mix", "seed", "leaf", "leave", "juice", "extract", "fillet",
        "piece", "part", "stock", "broth", "water", "spice", "seasoning", "filling", "dough", "batter", "base",
        "topping", "garnish", "marinade", "dressing", "glaze", "cream", "flake", "bit", "slice", "cube",
    ]

    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    /// Lowercased, accent-folded text used for matching. Same length as the input in practice.
    public static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased()
    }

    public func links(for recipe: Recipe) -> Links {
        let table = phraseTable(for: recipe)
        guard let regex = table.regex else {
            return Links(steps: recipe.steps.map { _ in [] }, mentions: recipe.steps.map { _ in [] },
                         unmentioned: recipe.ingredients.map(\.id))
        }
        var stepIDs: [[UUID]] = []
        var stepMentions: [[Mention]] = []
        var groupUses: [String: Int] = [:]  // duplicate group key → steps that used it so far
        for step in recipe.steps {
            let text = Self.folded(step)
            let ns = text as NSString
            var mentions: [Mention] = []
            var usedGroups: Set<String> = []
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let phrase = table.phrase(for: ns.substring(with: m.range)) else { continue }
                let owners = table.owners[phrase] ?? []
                guard !owners.isEmpty else { continue }  // a protected longer name, or unresolved
                let id: UUID
                if owners.count == 1 {
                    id = owners[0]
                } else {
                    let key = owners.map(\.uuidString).joined(separator: ",")
                    id = pickDuplicate(owners, step: text, uses: groupUses[key] ?? 0, recipe: recipe)
                    usedGroups.insert(key)
                }
                mentions.append(Mention(ingredientID: id, range: m.range))
            }
            for key in usedGroups { groupUses[key, default: 0] += 1 }
            var ids: [UUID] = []
            for mention in mentions where !ids.contains(mention.ingredientID) { ids.append(mention.ingredientID) }
            stepIDs.append(ids)
            stepMentions.append(mentions)
        }
        let mentioned = Set(stepIDs.flatMap { $0 })
        return Links(steps: stepIDs, mentions: stepMentions,
                     unmentioned: recipe.ingredients.map(\.id).filter { !mentioned.contains($0) })
    }

    // MARK: Phrases

    struct PhraseTable {
        /// Normalised phrase → ingredient IDs (empty = matched but ignored).
        var owners: [String: [UUID]]
        var regex: NSRegularExpression?

        /// The normalised phrase for matched text.
        func phrase(for matched: String) -> String? {
            let key = IngredientCatalog.normalise(matched)
            if owners[key] != nil { return key }
            // "chilies" normalises to "chilie"; try the forms the pattern allows.
            let candidates = [String(key.dropLast()), String(key.dropLast(2)), String(key.dropLast(2)) + "y", String(key.dropLast(3)) + "y"]
            for candidate in candidates where owners[candidate] != nil {
                return candidate
            }
            return nil
        }
    }

    func phraseTable(for recipe: Recipe) -> PhraseTable {
        var owners: [String: [UUID]] = [:]
        func add(_ phrase: String, _ id: UUID) {
            guard phrase.count >= 3 else { return }
            if !(owners[phrase]?.contains(id) ?? false) { owners[phrase, default: []].append(id) }
        }
        var nameWords: [UUID: Set<String>] = [:]
        var recipeEntryIDs: Set<String> = []
        for ing in recipe.ingredients {
            for part in Self.nameParts(ing.name) {
                add(part, ing.id)
                nameWords[ing.id, default: []].formUnion(part.split(separator: " ").map(String.init))
            }
            if let entry = (ing.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ing.name)) {
                recipeEntryIDs.insert(entry.id)
                for alias in entry.names { add(IngredientCatalog.normalise(alias), ing.id) }
            }
        }
        let exact = Set(owners.keys)

        // Single-word fallbacks.
        var fallbackWords: Set<String> = []
        for ing in recipe.ingredients {
            for part in Self.nameParts(ing.name) {
                if let last = part.split(separator: " ").last { fallbackWords.insert(String(last)) }
            }
        }
        // A word that is another catalog entry's name ("rice", "chicken") only stands for a recipe
        // ingredient of the same category: "chicken" → chicken breast, but "rice" ≠ rice vinegar.
        var wordCategories: [String: Set<String>] = [:]
        for entry in catalog.entries where !recipeEntryIDs.contains(entry.id) {
            for alias in entry.names {
                let n = IngredientCatalog.normalise(alias)
                if !n.contains(" ") {
                    fallbackWords.insert(n)
                    wordCategories[n, default: []].insert(entry.category)
                }
            }
        }
        func category(_ ing: Ingredient) -> String? {
            (ing.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ing.name))?.category
        }
        for word in fallbackWords where !exact.contains(word) && !Self.genericWords.contains(word) && word.count >= 3 {
            let holders = recipe.ingredients.filter { ing in
                guard nameWords[ing.id]?.contains(word) ?? false else { return false }
                guard let categories = wordCategories[word] else { return true }
                return category(ing).map(categories.contains) ?? false
            }
            guard !holders.isEmpty else { continue }
            if holders.count == 1 {
                add(word, holders[0].id)
            } else if let dominant = Self.dominant(holders) {
                add(word, dominant.id)
            } else {
                owners[word] = []  // ambiguous: match it so it can't link anything shorter
            }
        }

        // Longer names of other catalog entries that contain a recipe phrase are matched and ignored.
        let recipePhrases = Set(owners.keys)
        for entry in catalog.entries where !recipeEntryIDs.contains(entry.id) {
            for alias in entry.names {
                let n = IngredientCatalog.normalise(alias)
                guard owners[n] == nil else { continue }
                if recipePhrases.contains(where: { n.count > $0.count && " \(n) ".contains(" \($0) ") }) {
                    owners[n] = []
                }
            }
        }

        guard !owners.isEmpty else { return PhraseTable(owners: owners, regex: nil) }
        let sorted = owners.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + sorted.map(Self.pattern(for:)).joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        return PhraseTable(owners: owners, regex: Rx.re(pattern))
    }

    /// "chicken breast or thigh fillets" → ["chicken breast", "thigh fillet"]; "cornflour / cornstarch"
    /// → ["cornflour", "cornstarch"]. Normalised, with prep words dropped.
    static func nameParts(_ name: String) -> [String] {
        let pieces = Rx.replace("\\s+or\\s+|/|\\(|\\)|,", in: name, with: "\u{1}").split(separator: "\u{1}")
        var out: [String] = []
        for piece in pieces {
            let n = IngredientCatalog.normalisedName(String(piece))
            if !n.isEmpty && !out.contains(n) { out.append(n) }
        }
        let whole = IngredientCatalog.normalisedName(name)
        if !whole.isEmpty && !out.contains(whole) { out.insert(whole, at: 0) }
        return out
    }

    /// A regex for a normalised phrase that also accepts plurals ("chili pepper" → "chili peppers",
    /// "berry" → "berries") and "/" or "-" between words.
    static func pattern(for phrase: String) -> String {
        phrase.split(separator: " ").map { word -> String in
            let w = Rx.escape(String(word))
            if word.hasSuffix("y") && word.count > 3 {
                return "(?:\(w)s?|\(Rx.escape(String(word.dropLast())))ies)"
            }
            return "\(w)(?:s|es)?"
        }.joined(separator: "(?:\\s*[/-]\\s*|\\s+)")
    }

    /// The holder with at least twice everyone else's amount, when all amounts are comparable
    /// (all volumes or all weights).
    static func dominant(_ holders: [Ingredient]) -> Ingredient? {
        let amounts = holders.compactMap { ing -> (ing: Ingredient, isVolume: Bool, value: Double)? in
            guard let q = ing.quantity, let base = baseAmount(q, unit: ing.unit) else { return nil }
            return (ing, base.isVolume, base.value)
        }
        guard amounts.count == holders.count, Set(amounts.map(\.isVolume)).count == 1 else { return nil }
        let sorted = amounts.sorted { $0.value > $1.value }
        guard sorted.count >= 2, sorted[0].value >= 2 * sorted[1].value else { return nil }
        return sorted[0].ing
    }

    /// Volume in teaspoons, or weight in grams.
    static func baseAmount(_ quantity: Double, unit: String?) -> (isVolume: Bool, value: Double)? {
        switch unit {
        case "tsp": (true, quantity)
        case "tbsp": (true, quantity * 3)
        case "cup": (true, quantity * 48)
        case "ml": (true, quantity / 5)
        case "l": (true, quantity * 200)
        case "fl oz": (true, quantity * 6)
        case "g": (false, quantity)
        case "kg": (false, quantity * 1000)
        case "oz": (false, quantity * 28)
        case "lb": (false, quantity * 454)
        default: nil
        }
    }

    // MARK: Duplicates

    func pickDuplicate(_ owners: [UUID], step: String, uses: Int, recipe: Recipe) -> UUID {
        let lines = owners.compactMap(recipe.ingredient(id:))
        // 1. The step shows this line's amount.
        let byAmount = lines.filter { ing in
            guard let amount = RecipeEdit.amount(ing) else { return false }
            return step.contains(Self.folded(amount))
        }
        if byAmount.count == 1 { return byAmount[0].id }
        // 2. The line's note shares a distinctive word with the step ("slurry").
        let stepWords = Set(IngredientCatalog.normalise(step).split(separator: " ").map(String.init))
        let byNote = lines.filter { ing in
            guard let note = ing.note else { return false }
            return IngredientCatalog.normalise(note).split(separator: " ")
                .contains { $0.count >= 5 && !Self.noteStopWords.contains(String($0)) && stepWords.contains(String($0)) }
        }
        if byNote.count == 1 { return byNote[0].id }
        // 3. In order of use.
        return owners[min(uses, owners.count - 1)]
    }

    static let noteStopWords: Set<String> = ["optional", "about", "fresh", "plus", "extra", "more", "divided", "other", "taste", "using"]
}
