import Foundation

/// "I'm out of X" while cooking: an ingredient swapped or skipped for this cooking session only.
/// The saved recipe is untouched; "I made this" offers each swap as an unticked edit.
public struct CookSwap: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The ingredient as it was in the session's (scaled) recipe.
    public var original: Ingredient
    /// The swap chosen; nil means "Skip it".
    public var suggestion: SwapSuggestion?
    /// The new ingredient lines (fixed IDs, amounts at the session's servings). Empty for a skip.
    public var replacements: [Ingredient]
    /// One line shown with the choice: the swap's note, or what skipping costs ("Less depth; fine to skip").
    public var consequence: String?
    /// A model's tidier wording of a step, applied only while the step still reads `from`.
    public var reworded: [StepPatch]

    public init(id: UUID = UUID(), original: Ingredient, suggestion: SwapSuggestion?, replacements: [Ingredient],
                consequence: String? = nil, reworded: [StepPatch] = []) {
        self.id = id
        self.original = original
        self.suggestion = suggestion
        self.replacements = replacements
        self.consequence = consequence
        self.reworded = reworded
    }

    /// A swap (or skip, when `suggestion` is nil or "Leave it out") of `original`, with
    /// replacement amounts from the suggestion's ratios.
    public static func make(original: Ingredient, suggestion: SwapSuggestion?, consequence: String? = nil) -> CookSwap {
        let chosen = suggestion?.isLeaveOut == true ? nil : suggestion
        return CookSwap(original: original, suggestion: chosen,
                        replacements: chosen?.replacementIngredients(for: original) ?? [], consequence: consequence)
    }

    public var isSkip: Bool { replacements.isEmpty }

    /// "mirin", "soy sauce and sugar".
    public var newName: String { replacements.map(\.name).joined(separator: " and ") }

    /// "Swapped: mirin for sherry", "Skipped: sherry".
    public var label: String {
        isSkip ? "Skipped: \(original.name)" : "Swapped: \(newName) for \(original.name)"
    }

    /// The edits that keep this swap in the saved recipe `base` (unscaled): the ingredient change
    /// with amounts recomputed from `base`, then the step texts as cook mode showed them.
    /// Empty when `base` no longer has the ingredient.
    public func recipeEdits(in base: Recipe, catalog: IngredientCatalog = .shared) -> [RecipeEdit] {
        guard let ingredient = base.ingredient(id: original.id) else { return [] }
        let edit: RecipeEdit = suggestion?.edit(for: ingredient) ?? .removeIngredient(id: ingredient.id)
        var rebased = CookSwap.make(original: ingredient, suggestion: suggestion)
        rebased.reworded = reworded
        let shown = CookSwapApplier.replay([rebased], on: base, catalog: catalog).recipe
        let plain = base.applying([edit], catalog: catalog)
        var edits = [edit]
        for s in shown.steps.indices where s < plain.steps.count && shown.steps[s] != plain.steps[s] {
            edits.append(.updateStep(index: s, text: shown.steps[s]))
        }
        return edits
    }
}

/// A rewrite of one step, valid only on top of the text it was made from.
public struct StepPatch: Codable, Hashable, Sendable {
    public var stepIndex: Int
    public var from: String
    public var to: String

    public init(stepIndex: Int, from: String, to: String) {
        self.stepIndex = stepIndex
        self.from = from
        self.to = to
    }
}

/// Applies cook-mode swaps to a recipe: ingredient lines, and the step text where the
/// ingredient is mentioned (found with `StepIngredientLinker`, as "For this step" does).
///
/// - A swap renames each mention ("1 tbsp sherry" → "1 tbsp mirin"); when the new amount isn't
///   the same as the old one (a ratio), an amount written just before the name is rescaled
///   ("¼ cup soy sauce" → "2 tbsp fish sauce" stays in the same unit: "⅛ cup fish sauce").
///   Repeats of the new name joined by "and"/commas collapse ("X and X" → "X").
/// - A skip removes the item from a list when it's plainly one ("a, 1 tbsp sherry, b" → "a, b";
///   "beef and garlic" → "beef"; "with ½ tsp salt."); otherwise the text stays and the step's
///   "Skipped" note says so.
public enum CookSwapApplier {
    public struct Result: Hashable, Sendable {
        public var recipe: Recipe
        /// Steps whose text changed.
        public var changedSteps: [Int]
        /// Steps that used the ingredient (changed or not), for the "Swapped: …" note.
        public var affectedSteps: [Int]
    }

    /// The session's working recipe: `swaps` applied in order on `base`, plus each swap's step
    /// patches where the step still reads as they expect. `notes` maps a step to its swap labels.
    public static func replay(_ swaps: [CookSwap], on base: Recipe, catalog: IngredientCatalog = .shared)
        -> (recipe: Recipe, notes: [Int: [String]]) {
        var recipe = base
        var notes: [Int: [String]] = [:]
        for swap in swaps {
            let result = apply(swap, to: recipe, catalog: catalog)
            recipe = result.recipe
            for patch in swap.reworded where recipe.steps.indices.contains(patch.stepIndex) && recipe.steps[patch.stepIndex] == patch.from {
                recipe.steps[patch.stepIndex] = patch.to
            }
            for s in result.affectedSteps where !(notes[s] ?? []).contains(swap.label) { notes[s, default: []].append(swap.label) }
        }
        return (recipe, notes)
    }

    public static func apply(_ swap: CookSwap, to recipe: Recipe, catalog: IngredientCatalog = .shared) -> Result {
        guard let index = recipe.ingredients.firstIndex(where: { $0.id == swap.original.id }) else {
            return Result(recipe: recipe, changedSteps: [], affectedSteps: [])
        }
        let original = recipe.ingredients[index]
        let links = StepIngredientLinker(catalog: catalog).links(for: recipe)
        var out = recipe
        out.ingredients.replaceSubrange(index...index, with: swap.replacements)
        let ratio = amountRatio(original, swap.replacements)
        var changed: [Int] = []
        var affected: [Int] = []
        for s in recipe.steps.indices {
            let mentions = links.mentions[s].filter { $0.ingredientID == original.id }
            if !mentions.isEmpty { affected.append(s) }
            var text = recipe.steps[s]
            // Mention ranges are in folded text; only use them when the lengths agree.
            guard !mentions.isEmpty, (StepIngredientLinker.folded(text) as NSString).length == (text as NSString).length else { continue }
            for m in mentions.sorted(by: { $0.range.location > $1.range.location }) {
                text = swap.isSkip ? removeItem(at: m.range, in: text) : rename(at: m.range, in: text, to: swap.newName, ratio: ratio)
            }
            if !swap.isSkip { text = StepRewriter.collapseRepeats(of: swap.newName, in: text) }
            if text != recipe.steps[s] {
                out.steps[s] = text
                changed.append(s)
            }
        }
        // Nothing linked (e.g. an unusual name): fall back to the alias rewrite saved edits use.
        if affected.isEmpty, !swap.isSkip {
            for s in recipe.steps.indices {
                let text = StepRewriter.replace(catalog.aliases(for: original), with: swap.newName, in: recipe.steps[s], catalog: catalog)
                if text != recipe.steps[s] {
                    out.steps[s] = text
                    changed.append(s)
                    affected.append(s)
                }
            }
        }
        // Ingredients no step mentions are shown on step 1's "For this step".
        if affected.isEmpty, links.unmentioned.contains(original.id), !recipe.steps.isEmpty { affected.append(0) }
        return Result(recipe: out, changedSteps: changed, affectedSteps: affected)
    }

    // MARK: Text

    /// New quantity ÷ old, when it isn't 1 and both are in the same unit.
    static func amountRatio(_ original: Ingredient, _ replacements: [Ingredient]) -> Double? {
        guard replacements.count == 1, let new = replacements[0].quantity, let old = original.quantity, old > 0,
              replacements[0].unit == original.unit else { return nil }
        let ratio = new / old
        return abs(ratio - 1) < 0.01 ? nil : ratio
    }

    static let numberPattern = "(?:\\d+\\s*[½¼¾⅓⅔⅛]|\\d+\\s+\\d+/\\d+|\\d+/\\d+|\\d*\\.\\d+|\\d+|[½¼¾⅓⅔⅛])"
    static let unitPattern: String = {
        let forms = Units.table.flatMap(\.forms).filter { $0.count >= 2 || $0 == "g" }
        return forms.sorted { $0.count > $1.count }.map(Rx.escape).joined(separator: "|")
    }()

    /// The amount written right before `location` ("1 tbsp ", "200g of the "): the range of the
    /// number(s) and unit, the quantity (a range's upper bound) and the canonical unit.
    static func amount(before location: Int, in text: String) -> (range: NSRange, quantity: Double, unit: String?)? {
        let ns = text as NSString
        let prefix = ns.substring(to: location)
        let pattern = "(?:^|(?<=[\\s(,:]))(\(numberPattern)(?:\\s*(?:-|–|to)\\s*\(numberPattern))?)\\s*(?:(\(unitPattern))\\.?(?=\\s))?\\s+(?:of\\s+)?(?:the\\s+)?$"
        let pns = prefix as NSString
        guard let m = Rx.re(pattern).firstMatch(in: prefix, range: NSRange(location: 0, length: pns.length)) else { return nil }
        let numbers = pns.substring(with: m.range(at: 1))
        let unitToken = m.range(at: 2).location == NSNotFound ? nil : pns.substring(with: m.range(at: 2))
        guard let quantity = IngredientLineParser.parse("\(numbers) \(unitToken ?? "") x").quantity else { return nil }
        let end = unitToken == nil ? m.range(at: 1).location + m.range(at: 1).length : m.range(at: 2).location + m.range(at: 2).length
        return (NSRange(location: m.range(at: 1).location, length: end - m.range(at: 1).location), quantity,
                unitToken.flatMap(Units.canonical(for:)))
    }

    static func rename(at range: NSRange, in text: String, to name: String, ratio: Double?) -> String {
        let ns = text as NSString
        // Capitalised only at the start of a sentence ("Shaoxing wine" is capitalised mid-sentence too).
        let before = ns.substring(to: range.location)
        let capital = before.trimmed.isEmpty || Rx.test("[.!?:]\\s*$", before)
        let newName = capital ? name.prefix(1).uppercased() + name.dropFirst() : name
        var result = ns.replacingCharacters(in: range, with: newName)
        if let ratio, let amount = amount(before: range.location, in: text) {
            let q = amount.quantity * ratio
            var written = QuantityFormatter.string(from: q, unit: amount.unit)
            if let unit = amount.unit { written += " " + Units.display(unit, quantity: q) }
            result = (result as NSString).replacingCharacters(in: amount.range, with: written)
        }
        return result
    }

    /// Takes the item at `range` out of a list, or returns `text` unchanged when it isn't plainly
    /// a list item.
    static func removeItem(at range: NSRange, in text: String) -> String {
        let ns = text as NSString
        var start = amount(before: range.location, in: text)?.range.location ?? range.location
        var end = range.location + range.length
        // "the", "some" before the item go with it, except when the next item takes them over.
        let articleStart: Int = {
            let before = ns.substring(to: start)
            guard let m = Rx.re("(?:\\b(?:the|a|an|some)\\s+)$").firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return start }
            return m.range.location
        }()
        // Trailing "(optional)" and "or tamari" belong to the item.
        func extend(_ pattern: String) {
            let after = ns.substring(from: end)
            if let m = Rx.re(pattern).firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
                end += m.range.length
            }
        }
        extend("^\\s*\\([^)]*\\)")
        extend("^\\s+or\\s+[^,.;()]+?(?=\\s*(?:[,.;)]|\\band\\b|$))")
        extend("^\\s*\\([^)]*\\)")

        let prefix = ns.substring(to: articleStart)
        let pns = prefix as NSString
        let suffix = ns.substring(from: end)
        func match(_ pattern: String, _ s: String) -> NSRange? {
            Rx.re(pattern).firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range
        }
        // "a, ITEM" / "a, and ITEM": drop from the comma.
        if let m = match(",\\s*(?:(?:and|or)\\s+)?$", prefix) {
            let hadAnd = Rx.test("\\b(?:and|or)\\s+$", pns.substring(with: m))
            var head = pns.substring(to: m.location)
            var tail = suffix
            if hadAnd || Rx.test("^\\s*[.;!?]|^\\s*$", suffix) { head = joinLastComma(head) }
            // "a, ITEM, and b" → "a and b" when only two items are left.
            if let joiner = match("^\\s*,\\s*(?=(?:and|or)\\s)", suffix), !Rx.test(",", sentenceTail(head)) {
                tail = " " + (suffix as NSString).substring(from: joiner.length)
            }
            return head + tail
        }
        // "a and ITEM", "beef with ½ tsp salt." : drop from the joiner.
        if let m = match("\\s+(?:and|&)\\s+$", prefix) {
            return joinLastComma(pns.substring(to: m.location)) + suffix
        }
        if let m = match("\\s+with\\s+$", prefix), Rx.test("^\\s*(?:[.;!?]|$)", suffix) {
            return pns.substring(to: m.location) + suffix
        }
        // "ITEM, b" / "ITEM and b": drop the item and its joiner, keep any article for the next one.
        if let m = match("^\\s*,\\s*(?:and\\s+)?|^\\s+and\\s+", suffix) {
            start = articleStart < start ? start : articleStart
            let head = ns.substring(to: start)
            var rest = (suffix as NSString).substring(from: m.length)
            if head.trimmed.isEmpty || Rx.test("[.!?:]\\s*$", head) { rest = rest.prefix(1).uppercased() + rest.dropFirst() }
            return head + rest
        }
        return text
    }

    /// The text after the last sentence break.
    static func sentenceTail(_ text: String) -> String {
        let ns = text as NSString
        let start = Rx.re("[.!?;:](?=\\s)").matches(in: text, range: NSRange(location: 0, length: ns.length)).last.map { $0.range.location + 1 } ?? 0
        return ns.substring(from: start)
    }

    /// "a, b" → "a and b" for the last comma of the sentence being built, when no "and" follows it.
    static func joinLastComma(_ text: String) -> String {
        let ns = text as NSString
        let sentenceStart = Rx.re("[.!?;:](?=\\s)").matches(in: text, range: NSRange(location: 0, length: ns.length)).last.map { $0.range.location + 1 } ?? 0
        let tail = ns.substring(from: sentenceStart)
        let tns = tail as NSString
        guard let comma = Rx.re(",\\s*").matches(in: tail, range: NSRange(location: 0, length: tns.length)).last else { return text }
        let afterComma = tns.substring(from: comma.range.location + comma.range.length)
        guard !Rx.test("\\b(?:and|or)\\b", afterComma), !Rx.test("^(?:and|or)\\b", afterComma) else { return text }
        let joined = tns.replacingCharacters(in: comma.range, with: " and ")
        return ns.substring(to: sentenceStart) + joined
    }
}

/// Finds which recipe ingredient a typed or dictated "out of …" means.
public enum MissingIngredientMatcher {
    /// "I'm out of Shaoxing wine." → "Shaoxing wine".
    public static func query(_ text: String) -> String {
        var q = text.collapsedWhitespace
        q = Rx.replace("^(?:ah+,?\\s+)?(?:damn,?\\s+)?(?:i'?m|i am|we'?re|we are)?\\s*(?:all\\s+)?(?:out of|ran out of|run out of|have run out of|don'?t have(?: any)?|do not have(?: any)?|have no|no more|there'?s no|no)\\s+", in: q, with: "")
        q = Rx.replace("^(?:any|the|some)\\s+", in: q, with: "")
        q = Rx.replace("[.!?,]+$", in: q, with: "")
        return q.trimmed
    }

    /// Recipe ingredients the text names, in recipe order: same catalog entry first, then names
    /// containing every word typed, then (for a partial word) names containing the text.
    public static func matches(_ text: String, in recipe: Recipe, catalog: IngredientCatalog = .shared) -> [Ingredient] {
        let q = query(text)
        guard q.count >= 2 else { return [] }
        if let entry = catalog.match(q) {
            let same = recipe.ingredients.filter { ($0.catalogID ?? catalog.match($0.name)?.id) == entry.id }
            if !same.isEmpty { return same }
        }
        let words = IngredientCatalog.normalisedName(q).split(separator: " ").map(String.init)
        let byWords = recipe.ingredients.filter { ing in
            let name = Set(IngredientCatalog.normalise(ing.name).split(separator: " ").map(String.init))
            return !words.isEmpty && words.allSatisfy(name.contains)
        }
        if !byWords.isEmpty { return byWords }
        let folded = IngredientCatalog.normalise(q)
        guard folded.count >= 3 else { return [] }
        return recipe.ingredients.filter { IngredientCatalog.normalise($0.name).contains(folded) }
    }
}

/// What leaving an ingredient out costs, in one short line, or nil when there's nothing useful
/// to say.
public enum SkipConsequence {
    public static func text(for ingredient: Ingredient, catalog: IngredientCatalog = .shared) -> String? {
        guard let entry = ingredient.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ingredient.name) else { return nil }
        // The swap table's own advice wins when it says more than "Leave it out".
        if let leave = catalog.swaps(for: entry.id).first(where: { $0.use.isEmpty }),
           leave.note.lowercased() != "leave it out" {
            return RecipeFormatText.capitalisedFirst(leave.note)
        }
        let tags = entry.tags
        switch entry.id {
        case "cornstarch": return "The sauce will be thinner; simmer it a little longer"
        case "baking-soda": return "The meat will be a little less tender"
        case "salt": return "Season to taste at the end"
        case "sugar", "brown-sugar", "honey": return "Less balance; taste and adjust at the end"
        case "water": return "Fine to skip if there's enough liquid"
        default: break
        }
        if tags.contains(.alcohol) { return "Less depth; fine to skip" }
        if tags.contains(.spicy) { return "Milder; fine to skip" }
        switch entry.category {
        case "herb": return "Less fresh flavour; fine to skip"
        case "spice": return "A little less flavour; usually fine to skip"
        case "nuts": return "Less crunch; fine to skip"
        case "condiment": return "Less savoury depth; taste and season at the end"
        case "oil": return entry.id == "sesame-oil" ? "Less nutty aroma; fine to skip" : "Use another oil if you can"
        case "liquid": return "Use water to keep the liquid"
        case "meat", "seafood", "protein", "grain", "legume": return "It's a main part of the dish; a swap is better"
        default: return nil
        }
    }
}
