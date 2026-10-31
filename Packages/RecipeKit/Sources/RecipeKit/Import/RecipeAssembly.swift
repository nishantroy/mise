import Foundation

/// A whole recipe assembled by a language model from a pasted write-up, before validation.
public struct ProposedRecipe: Hashable, Sendable {
    /// 0 when the model didn't find one.
    public var servings: Int
    /// "1 tbsp sherry", "1–2 Fresnos, sliced into rings".
    public var ingredients: [String]
    public var steps: [String]
    public var notes: [String]

    public init(servings: Int = 0, ingredients: [String] = [], steps: [String] = [], notes: [String] = []) {
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.notes = notes
    }
}

/// Validates a model's `ProposedRecipe` against the paste and the rules' parse
/// (`StepStyleParser.analyse`), part by part. Each part the model gets wrong falls back to the
/// rules' version of that part, so the result is never worse than the rules:
/// - **Steps** (all or nothing): every number in the source steps is kept; a model step has no
///   number the source steps don't; each model step's words come mostly from the source steps,
///   never mostly from the prose (so commentary can't become a step); every source step is
///   still covered; 1–20 steps of one paragraph each.
/// - **Ingredients**: grounded like `ModelIngredientLines`, and an amount must be traceable to
///   one list item of a source step ("3 tbsp sugar") that also names the ingredient (the same
///   number, and the unit if any).
///   The list is used only if it's not much thinner than the rules' (`ModelIngredientLines.choose`).
/// - **Notes**: short, not commentary, numbers from the paste, words from the paste with at
///   least one from its prose (so a step can't be repeated as a note). Used only if there are at
///   least as many as the rules found. (At least ¾ of a note's words must be in the paste.)
/// - **Title** is always the rules' (the first line); **servings** the rules', else the model's
///   when the paste says "serves N" with that number.
public enum RecipeAssembly {
    public struct Result: Hashable, Sendable {
        public var recipe: Recipe
        public var usedModelSteps: Bool
        public var usedModelIngredients: Bool
        public var usedModelNotes: Bool
    }

    public static let maxSteps = 20
    public static let maxNotes = 4

    public static func merge(_ proposal: ProposedRecipe, text: String, rules: Recipe,
                             catalog: IngredientCatalog = .shared) -> Result {
        guard let analysis = StepStyleParser.analyse(text: text), !analysis.steps.isEmpty else {
            return Result(recipe: rules, usedModelSteps: false, usedModelIngredients: false, usedModelNotes: false)
        }
        var recipe = rules
        let prose = analysis.notes + analysis.dropped

        let steps = validSteps(proposal.steps, source: analysis.steps, prose: prose)
        if let steps { recipe.steps = steps }

        let modelIngredients = validIngredients(proposal.ingredients, sourceSteps: analysis.steps, catalog: catalog)
        let ingredients = ModelIngredientLines.choose(model: modelIngredients, rules: rules.ingredients)
        recipe.ingredients = ingredients

        let notes = validNotes(proposal.notes, text: text, sourceSteps: analysis.steps, prose: prose)
        let useNotes = !notes.isEmpty && notes.count >= rules.notes.count
        if useNotes { recipe.notes = notes }

        if recipe.servings == nil, (1...24).contains(proposal.servings),
           Rx.test("\\b(?:serves|servings?|feeds|makes)\\b\\W{0,3}\(proposal.servings)\\b", text) {
            recipe.servings = proposal.servings
        }
        return Result(recipe: recipe, usedModelSteps: steps != nil,
                      usedModelIngredients: !modelIngredients.isEmpty && ingredients == modelIngredients,
                      usedModelNotes: useNotes)
    }

    // MARK: Steps

    /// The model's steps, tidied, or nil when any check fails.
    public static func validSteps(_ proposed: [String], source: [String], prose: [String]) -> [String]? {
        let steps = proposed.map(tidyStep).filter { !$0.isEmpty }
        guard !steps.isEmpty, steps.count <= maxSteps, proposed.allSatisfy({ !$0.contains("\n\n") }),
              steps.allSatisfy({ $0.count <= 500 }) else { return nil }

        // Numbers: none lost, none invented.
        let sourceNumbers = Set(source.flatMap(StepRewrites.numberTokens))
        let modelNumbers = Set(steps.flatMap(StepRewrites.numberTokens))
        guard sourceNumbers.isSubset(of: modelNumbers), modelNumbers.isSubset(of: sourceNumbers) else { return nil }
        let sourceTemps = Set(source.flatMap(StepRewrites.temperatureTokens))
        guard sourceTemps.isSubset(of: Set(steps.flatMap(StepRewrites.temperatureTokens))) else { return nil }

        // Words: each model step comes from the source steps, not from the prose.
        let stepVocab = Set(source.flatMap(contentWords))
        let proseVocab = Set(prose.flatMap(contentWords)).subtracting(stepVocab)
        for step in steps {
            let words = contentWords(step)
            guard !words.isEmpty else { return nil }
            let fromSteps = Double(words.filter(stepVocab.contains).count) / Double(words.count)
            let fromProse = Double(words.filter(proseVocab.contains).count) / Double(words.count)
            guard fromSteps >= 0.7, fromProse < 0.25 else { return nil }
        }
        // Coverage: nothing the cook wrote is dropped.
        let modelVocab = Set(steps.flatMap(contentWords))
        for line in source {
            let words = contentWords(line)
            guard !words.isEmpty else { continue }
            guard Double(words.filter(modelVocab.contains).count) / Double(words.count) >= 0.6 else { return nil }
        }
        return steps
    }

    /// Strips "Step 3:", "3.", list markers, quotes and markdown.
    static func tidyStep(_ step: String) -> String {
        var text = StepStyleParser.cleanMarkdown(step.collapsedWhitespace)
        text = Rx.replace("^(?:step\\s*\\d+\\s*[:.)-]\\s*)", in: text, with: "")
        text = JSONLDRecipeParser.stripStepNumber(TextRecipeParser.stripBullet(text))
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")).trimmed
    }

    // MARK: Ingredients

    /// Grounded lines whose amount is traceable to a source step naming the ingredient.
    public static func validIngredients(_ lines: [String], sourceSteps: [String],
                                        catalog: IngredientCatalog = .shared) -> [Ingredient] {
        let mapped = ModelIngredientLines.map(lines, steps: sourceSteps, catalog: catalog)
        var out: [Ingredient] = []
        for ing in mapped {
            if ing.quantity == nil {
                // "rice", "salt to taste": fine unless it repeats an ingredient listed with an amount.
                let key = catalog.pantryKey(for: ing)
                guard !mapped.contains(where: { $0.quantity != nil && catalog.pantryKey(for: $0) == key }) else { continue }
                out.append(ing)
                continue
            }
            // Per list item ("3 tbsp sugar" | "1 tbsp sherry"), so an amount can't be borrowed
            // from a neighbour in the same step.
            let pieces = sourceSteps.flatMap(StepIngredientExtractor.segments(of:))
            guard pieces.contains(where: { isTraceable(ing, to: $0, catalog: catalog) }) else { continue }
            out.append(ing)
        }
        return out
    }

    /// The step text names the ingredient and says its amount (and unit, if it has one).
    static func isTraceable(_ ing: Ingredient, to step: String, catalog: IngredientCatalog) -> Bool {
        guard let quantity = ing.quantity else { return true }
        let normalised = " " + IngredientCatalog.normalise(step) + " "
        guard ModelIngredientLines.isGrounded(ing, in: normalised, catalog: catalog) else { return false }
        var values = amountValues(in: step)
        if Rx.test("\\b(?:a|an|one)\\s+\\w", step) { values.append(1) }
        guard values.contains(where: { abs($0 - quantity) < 0.01 }) else { return false }
        if let unit = ing.unit, let forms = Units.table.first(where: { $0.canonical == unit })?.forms {
            let lower = step.lowercased()
            // Single letters ("t", "c") would match stray letters; only "g" and "l" are kept.
            return forms.filter { $0.count > 1 || $0 == unit }.contains { Rx.test("(?<![\\p{L}])\(Rx.escape($0))\\.?(?![\\p{L}])", lower) }
        }
        return true
    }

    static let glyphValues: [Character: Double] = [
        "½": 0.5, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "¼": 0.25, "¾": 0.75, "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8,
        "⅙": 1.0 / 6, "⅚": 5.0 / 6, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
    ]

    /// Every amount written in the text: "1½" and "1 ½" → 1.5, "1/2" → 0.5, "1–2" → 1 and 2.
    static func amountValues(in text: String) -> [Double] {
        let glyphs = String(glyphValues.keys)
        let pattern = "(\\d+(?:\\.\\d+)?)?(?:\\s*([\(glyphs)])|\\s+(\\d+)/(\\d+)|/(\\d+))?"
        var out: [Double] = []
        for m in Rx.matches(pattern, in: text) {
            guard m[0].map({ !$0.trimmed.isEmpty }) == true else { continue }
            var value = m[1].flatMap(Double.init) ?? 0
            if let g = m[2]?.first, let v = glyphValues[g] { value += v }
            if let n = m[3].flatMap(Double.init), let d = m[4].flatMap(Double.init), d > 0 { value += n / d }
            if let d = m[5].flatMap(Double.init), d > 0, let whole = m[1].flatMap(Double.init) { value = whole / d }
            if value > 0 { out.append(value) }
        }
        return out
    }

    // MARK: Notes

    public static func validNotes(_ notes: [String], text: String, sourceSteps: [String], prose: [String]) -> [String] {
        let pasteNumbers = Set(StepRewrites.numberTokens(text))
        let stepVocab = Set(sourceSteps.flatMap(contentWords))
        let proseOnly = Set(prose.flatMap(contentWords)).subtracting(stepVocab)
        var out: [String] = []
        for note in notes {
            let tidy = StepStyleParser.cleanMarkdown(TextRecipeParser.stripBullet(note.collapsedWhitespace))
            guard !tidy.isEmpty, tidy.count <= 200, !tidy.contains("\n"),
                  PasteProse.sentences(tidy).allSatisfy({ PasteProse.classify($0) != .commentary }),
                  Set(StepRewrites.numberTokens(tidy)).isSubset(of: pasteNumbers) else { continue }
            let words = contentWords(tidy)
            guard !words.isEmpty,
                  Double(words.filter { stepVocab.contains($0) || proseOnly.contains($0) }.count) / Double(words.count) >= 0.75,
                  words.contains(where: proseOnly.contains),
                  !out.contains(where: { $0.lowercased() == tidy.lowercased() }) else { continue }
            out.append(tidy)
            if out.count == maxNotes { break }
        }
        return out
    }

    // MARK: Words

    static let extraStopWords: Set<String> = [
        "and", "the", "for", "with", "into", "then", "until", "your", "you", "that", "this", "are", "was", "its",
        "use", "add", "about", "from", "over", "all", "but", "not", "any",
    ]

    /// Lowercased words of 3+ letters, without stop words, singularised by a trailing "s".
    static func contentWords(_ text: String) -> [String] {
        IngredientCatalog.normalise(text).split(whereSeparator: { !$0.isLetter }).compactMap { sub in
            var w = String(sub)
            guard w.count >= 3, !FeedbackParser.stopWords.contains(w), !extraStopWords.contains(w) else { return nil }
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            return w
        }
    }
}
