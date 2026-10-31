import Foundation

/// Rule-based feedback → edits. Used directly when the on-device model is unavailable,
/// and as hints for the model when it is.
public struct FeedbackParser: Sendable {
    public let catalog: IngredientCatalog

    public init(catalog: IngredientCatalog = .shared) {
        self.catalog = catalog
    }

    public static func edits(from feedback: String, recipe: Recipe, catalog: IngredientCatalog = .shared) -> [RecipeEdit] {
        FeedbackParser(catalog: catalog).edits(from: feedback, recipe: recipe)
    }

    /// Words that start a new clause after "and" / "but" / "so".
    static let clauseStarters = "it|i|we|they|that|this|was|were|needed|need|used|use|added|add|skipped|left|omitted|replaced|subbed|substituted|swapped|threw|tossed|cooked|baked|simmered|took|too|less|more|cut|doubled|double|halved|didn't|did not|no|not|next|the (?:\\w+ )?(?:was|were|needed)"

    /// Clauses that carry no information; dropped rather than kept as notes.
    static let filler = "^(?:no (?:changes?|problems?|issues?|complaints?)|nothing(?: else)?|none|n/?a|ok(?:ay)?|that'?s it|thanks?)$"

    public func edits(from feedback: String, recipe: Recipe) -> [RecipeEdit] {
        var edits: [RecipeEdit] = []
        for sentence in Self.sentences(feedback) {
            var unmatched: [String] = []
            for clause in Self.clauses(sentence) {
                let found = parse(clause: clause, recipe: recipe)
                if found.isEmpty {
                    if !Rx.test(Self.filler, Self.bare(clause)) { unmatched.append(clause) }
                } else {
                    for e in found where !edits.contains(e) { edits.append(e) }
                }
            }
            if !unmatched.isEmpty {
                // Feedback is never lost: whatever the rules didn't understand is kept as a note.
                let text = unmatched.joined(separator: ", ")
                let note = text.prefix(1).uppercased() + text.dropFirst()
                if !edits.contains(.addNote(note)) { edits.append(.addNote(note)) }
            }
        }
        return Self.resolvingConflicts(edits)
    }

    /// An explicit replace or remove beats a scale of the same ingredient ("too salty" + "used
    /// light soy sauce instead of dark" shouldn't also shrink the dark soy sauce), and only the
    /// first scale per ingredient is kept.
    static func resolvingConflicts(_ edits: [RecipeEdit]) -> [RecipeEdit] {
        var replaced: Set<UUID> = []
        for edit in edits {
            switch edit {
            case .replaceIngredient(let id, _, _), .removeIngredient(let id): replaced.insert(id)
            default: break
            }
        }
        var scaled: Set<UUID> = []
        return edits.filter { edit in
            guard case .scaleIngredient(let id, _) = edit else { return true }
            if replaced.contains(id) || scaled.contains(id) { return false }
            scaled.insert(id)
            return true
        }
    }

    static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
            .map { $0.collapsedWhitespace }
            .filter { !$0.isEmpty }
    }

    static func clauses(_ sentence: String) -> [String] {
        var s = sentence
        // Mark boundaries: commas, and "and/but/so/then" when a new clause follows.
        s = Rx.replace("\\s*,\\s*(?:and|but|so|then)?\\s+", in: s, with: "\u{1}")
        s = Rx.replace("\\s+(?:but|so|then|although|though|because)\\s+", in: s, with: "\u{1}")
        s = Rx.replace("\\s+and\\s+(?=(?:\(clauseStarters))\\b)", in: s, with: "\u{1}")
        return s.split(separator: "\u{1}").map { String($0).collapsedWhitespace }.filter { !$0.isEmpty }
    }

    /// Lowercased, without leading "I " / "we " / "it was" and trailing "next time" etc.
    static func bare(_ clause: String) -> String {
        var s = clause.lowercased().replacingOccurrences(of: "’", with: "'").collapsedWhitespace
        s = Rx.replace("^(?:i|we|also|then|but|and|so|just)\\s+", in: s, with: "")
        s = Rx.replace("^(?:i|we)\\s+", in: s, with: "")
        s = Rx.replace("\\s+(?:next time|this time|than (?:written|the recipe said|listed)|in it|overall|though|too)$", in: s, with: "")
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
    }

    // MARK: Patterns

    func parse(clause: String, recipe: Recipe) -> [RecipeEdit] {
        let s = Self.bare(clause)
        guard !s.isEmpty else { return [] }

        // Time: "needed 10 more minutes", "cooked it 5 extra minutes", "needed more time".
        if let m = Rx.firstMatch("(\\d+)\\s*(?:more|extra|additional|further)\\s*(?:min|minutes|mins)\\b", in: s)
            ?? Rx.firstMatch("(?:another|an extra|an additional|extra)\\s+(\\d+)\\s*(?:min|minutes|mins)\\b", in: s) {
            return [.addNote("Needed about \(m[1]!) more minutes than written")]
        }
        if Rx.test("^(?:it\\s+)?(?:needed|took|needs)\\s+(?:a bit |a little |a lot |much )?(?:more|longer)(?:\\s+time)?$", s) {
            return [.addNote("Needed more time than written")]
        }

        // Replacements.
        if let m = Rx.firstMatch("^(?:used|use|tried|went with|had to use)\\s+(.+?)\\s+instead of\\s+(.+)$", in: s)
            ?? Rx.firstMatch("^(.+?)\\s+instead of\\s+(.+)$", in: s) {
            return replacement(new: m[1]!, old: m[2]!, recipe: recipe)
        }
        if let m = Rx.firstMatch("^replaced\\s+(.+?)\\s+with\\s+(.+)$", in: s) {
            return replacement(new: m[2]!, old: m[1]!, recipe: recipe)
        }
        if let m = Rx.firstMatch("^(?:subbed|substituted|subbed in|substituted in)\\s+(.+?)\\s+for\\s+(.+)$", in: s) {
            return replacement(new: m[1]!, old: m[2]!, recipe: recipe)
        }
        if let m = Rx.firstMatch("^swapped(?: out)?\\s+(.+?)\\s+(?:for|with)\\s+(.+)$", in: s) {
            return replacement(new: m[2]!, old: m[1]!, recipe: recipe)
        }

        // Taste.
        if Rx.test("\\b(?:too|very|a bit|a little|slightly|way too|overly)\\s+salty\\b|\\boversalted\\b", s) {
            return adjust(ids: ["salt", "soy-sauce", "dark-soy-sauce", "tamari", "fish-sauce"], factor: 0.75, recipe: recipe, fallbackNote: "Use less salt than last time")
        }
        if Rx.test("\\bnot (?:spicy|hot) enough\\b|\\b(?:too |a bit |a little |very |quite )?bland\\b|\\bneeded more heat\\b|\\bneeds more heat\\b", s) {
            return adjust(tags: .spicy, factor: 1.5, recipe: recipe, fallbackNote: "Season more boldly next time")
        }
        if Rx.test("\\b(?:too|very|a bit|a little|way too|overly)\\s+(?:spicy|hot)\\b", s) {
            return adjust(tags: .spicy, factor: 0.5, recipe: recipe, fallbackNote: "Make it milder next time")
        }
        if Rx.test("\\b(?:too|very|a bit|a little|way too|overly)\\s+sweet\\b", s) {
            return adjust(ids: ["sugar", "honey", "brown-sugar", "palm-sugar", "maple-syrup", "rock-sugar"], factor: 0.75, recipe: recipe, fallbackNote: "Use less sugar than last time")
        }

        // Removals. "left the X out" / "skipped X" / "no X" (only when X is in the recipe).
        if let m = Rx.firstMatch("^left\\s+(.+?)\\s+out$", in: s)
            ?? Rx.firstMatch("^(?:skipped|skip|left out|leave out|omitted|omit|didn't use|did not use|didn't add|did not add|didn't have|did not have|went without|forgot)\\s+(.+)$", in: s) {
            return removals(m[1]!, recipe: recipe)
        }
        if let m = Rx.firstMatch("^no\\s+(.+)$", in: s) {
            return removals(m[1]!, recipe: recipe)
        }

        // Scaling.
        let scales: [(String, Double)] = [
            ("^(?:used\\s+)?(?:double|doubled)\\s+(.+)$", 2),
            ("^(?:used\\s+)?(?:half|halved)\\s+(?:of\\s+)?(.+)$", 0.5),
            ("^(?:there was\\s+|it had\\s+)?too much\\s+(.+)$", 0.75),
            ("^(?:used\\s+|use\\s+|add\\s+|added\\s+|needs\\s+|needed\\s+)?less\\s+(.+)$", 0.75),
            ("^(?:cut back on|cut down on|cut down|reduced|reduce)\\s+(.+)$", 0.75),
            ("^(?:there was\\s+|it had\\s+)?not enough\\s+(.+)$", 1.25),
            ("^(?:used\\s+|use\\s+|add\\s+|added\\s+|needs\\s+|needed\\s+|wanted\\s+|could use\\s+)?(?:more|extra)\\s+(.+)$", 1.25),
        ]
        for (pattern, factor) in scales {
            if let m = Rx.firstMatch(pattern, in: s) {
                let edits = scalings(m[1]!, factor: factor, recipe: recipe)
                if !edits.isEmpty { return edits }
            }
        }

        // Additions: "added X", "threw in X". Items already in the recipe become "more X".
        if let m = Rx.firstMatch("^(?:added|add|threw in|tossed in|stirred in|put in|topped (?:it )?with|finished (?:it )?with|garnished with)\\s+(.+)$", in: s) {
            return additions(m[1]!, recipe: recipe)
        }
        return []
    }

    // MARK: Builders

    func replacement(new: String, old: String, recipe: Recipe) -> [RecipeEdit] {
        guard let original = findIngredient(old, in: recipe), let edit = replace(original, with: new) else { return [] }
        return [edit]
    }

    func removals(_ text: String, recipe: Recipe) -> [RecipeEdit] {
        let parts = Self.listItems(text)
        let found = parts.compactMap { findIngredient($0, in: recipe) }
        // All-or-nothing: "no problems with the chicken" shouldn't remove the chicken.
        guard !found.isEmpty, found.count == parts.count else { return [] }
        return found.map { .removeIngredient(id: $0.id) }
    }

    func scalings(_ text: String, factor: Double, recipe: Recipe) -> [RecipeEdit] {
        let parts = Self.listItems(text)
        let found = parts.compactMap { findIngredient($0, in: recipe) }
        guard !found.isEmpty, found.count == parts.count else { return [] }
        return found.map { scale($0, factor: factor) }
    }

    func additions(_ text: String, recipe: Recipe) -> [RecipeEdit] {
        var edits: [RecipeEdit] = []
        for part in Self.listItems(text) {
            if let m = Rx.firstMatch("^(?:more|extra|a bit more|a little more|some more)\\s+(.+)$", in: part) {
                if let ing = findIngredient(m[1]!, in: recipe) { edits.append(scale(ing, factor: 1.25)); continue }
            }
            let parsed = catalog.annotate(IngredientLineParser.parse(Self.stripArticles(part)))
            guard !parsed.name.isEmpty else { continue }
            if parsed.quantity == nil, let existing = findIngredient(part, in: recipe), existing.catalogID != nil {
                edits.append(scale(existing, factor: 1.25))
            } else {
                edits.append(.addIngredient(parsed))
            }
        }
        return edits
    }

    /// Replaces `original` with an ingredient parsed from `text` ("chicken thighs", "1 tbsp lime juice"),
    /// keeping the original amount unless `text` gives one. Nil if `text` has no name.
    public func replace(_ original: Ingredient, with text: String) -> RecipeEdit? {
        let parsed = IngredientLineParser.parse(Self.stripArticles(text))
        guard !parsed.name.isEmpty, parsed.name.lowercased() != original.name.lowercased() else { return nil }
        let hasOwnAmount = parsed.quantity != nil
        var replacement = catalog.annotate(Ingredient(
            raw: "",
            quantity: hasOwnAmount ? parsed.quantity : original.quantity,
            unit: hasOwnAmount ? parsed.unit : original.unit,
            name: parsed.name, note: parsed.note))
        replacement.raw = replacement.displayText
        return .replaceIngredient(id: original.id, with: [replacement], reason: "Used \(parsed.name) instead of \(original.name)")
    }

    /// A new ingredient parsed from free text, matched to the catalog.
    public func newIngredient(_ text: String) -> Ingredient? {
        let parsed = catalog.annotate(IngredientLineParser.parse(Self.stripArticles(text)))
        return parsed.name.isEmpty ? nil : parsed
    }

    /// Amendment: scaling an ingredient without a quantity becomes a note instead of a no-op.
    public func scale(_ ingredient: Ingredient, factor: Double) -> RecipeEdit {
        if ingredient.quantity == nil {
            let word = factor < 1 ? "less" : "more"
            return .addNote("Use \(word) \(ingredient.name.lowercased()) than last time")
        }
        return .scaleIngredient(id: ingredient.id, factor: factor)
    }

    func adjust(ids: Set<String>, factor: Double, recipe: Recipe, fallbackNote: String) -> [RecipeEdit] {
        let targets = recipe.ingredients.filter { ($0.catalogID ?? catalog.match($0.name)?.id).map(ids.contains) ?? false }
        return targets.isEmpty ? [.addNote(fallbackNote)] : targets.map { scale($0, factor: factor) }
    }

    func adjust(tags tag: IngredientTag, factor: Double, recipe: Recipe, fallbackNote: String) -> [RecipeEdit] {
        let targets = recipe.ingredients.filter { ing in
            let entry = ing.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ing.name)
            return entry?.tags.contains(tag) == true
        }
        return targets.isEmpty ? [.addNote(fallbackNote)] : targets.map { scale($0, factor: factor) }
    }

    // MARK: Matching

    static let stopWords: Set<String> = ["the", "a", "an", "some", "of", "my", "our", "it", "them", "bit", "little", "more", "less", "fresh", "whole", "and", "with"]

    static func stripArticles(_ text: String) -> String {
        Rx.replace("^(?:a little bit of|a bit of|a little|a splash of|a squeeze of|a handful of|a pinch of|a dash of|the|a|an|some|my|our)\\s+", in: text.trimmed, with: "")
    }

    static func listItems(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",&"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { stripArticles($0.collapsedWhitespace) }
            .filter { !$0.isEmpty }
    }

    /// Recipe ingredient referred to by `text`: same catalog ID first, then best word overlap.
    public func findIngredient(_ text: String, in recipe: Recipe) -> Ingredient? {
        let cleaned = Self.stripArticles(text)
        guard !cleaned.isEmpty else { return nil }
        if let id = catalog.match(cleaned)?.id,
           let hit = recipe.ingredients.first(where: { ($0.catalogID ?? catalog.match($0.name)?.id) == id }) {
            return hit
        }
        let words = Set(IngredientCatalog.normalise(cleaned).split(separator: " ").map(String.init)).subtracting(Self.stopWords)
        guard !words.isEmpty else { return nil }
        var best: (Ingredient, Int)?
        for ing in recipe.ingredients {
            let ingWords = Set(IngredientCatalog.normalise(ing.name).split(separator: " ").map(String.init))
            let overlap = words.intersection(ingWords).count
            if overlap > 0, overlap > (best?.1 ?? 0) { best = (ing, overlap) }
        }
        return best?.0
    }
}
