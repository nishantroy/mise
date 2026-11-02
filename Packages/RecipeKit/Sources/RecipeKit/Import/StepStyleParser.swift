import Foundation

/// Pasted write-ups (often markdown copied from a chat app), sorted line by line into a title,
/// ingredient lines, steps, notes and dropped commentary.
///
/// **Sections decide first.** An "Ingredients" heading ("**Ingredients (3–4 servings)**",
/// "What you'll need") starts the ingredient list, a method heading ("Steps", "Method",
/// "Instructions"…) starts the steps, a notes heading starts notes. Sub-group labels
/// ("*Pepper masala:*", "For the chicken", "## Sauce") are dropped and keep the current section.
/// Under an ingredients heading every line is an ingredient, unless it reads like an
/// instruction ("Rinse the rice."), which starts the method. Under a method heading every line
/// is a step (prose aside). Bullets never decide: both lists are often "- " bullets.
///
/// **Without headings** a line that looks like an ingredient line (`ingredientLineKind`: a
/// leading amount, "Salt to taste", or just a catalog ingredient, never a cooking verb or a
/// sentence) is an ingredient when it comes before the first step, or when every line of its
/// labelled block is one. Anything else follows the step-style rules: a step, kept verbatim
/// apart from markdown and list markers ("Toast: Dry pan…" keeps its label; it reads well in
/// cook mode), or prose sorted by `PasteProse` (tips → notes, commentary → dropped).
///
/// With no listed ingredients, they come from the steps (`StepIngredientExtractor`).
public enum StepStyleParser {
    /// What the rules make of a pasted write-up.
    public struct Analysis: Hashable, Sendable {
        public var title: String
        public var servings: Int?
        /// "Serves 3–4" / "(3–4 servings)": `servings` is the lower bound.
        public var servingsRange: ClosedRange<Int>?
        /// Listed ingredient lines, markdown and list markers removed ("1¾ tbsp black peppercorns").
        public var ingredients: [String]
        public var steps: [String]
        /// Tips and variations ("For a clear tingle, use ½–1 tsp Sichuan peppercorn.").
        public var notes: [String]
        /// Commentary that was left out ("The salt … are the fixes for the low flavor.").
        public var dropped: [String]
    }

    /// Returns nil when there are no steps, or (without listed ingredients) fewer than two
    /// ingredient mentions in the steps (so arbitrary prose isn't taken for a recipe).
    public static func parse(text: String) -> Recipe? {
        guard let analysis = analyse(text: text), !analysis.steps.isEmpty else { return nil }
        let ingredients: [Ingredient]
        if !analysis.ingredients.isEmpty {
            ingredients = analysis.ingredients.map(IngredientLineParser.parse)
        } else {
            ingredients = StepIngredientExtractor.extract(from: analysis.steps)
            guard ingredients.count >= 2 else { return nil }
        }
        return Recipe(title: analysis.title.isEmpty ? "Untitled recipe" : analysis.title, servings: analysis.servings,
                      ingredients: ingredients, steps: analysis.steps, notes: analysis.notes)
    }

    struct Line {
        var text: String
        /// "- ", "* ", "• ", "1." or "1)" at the start.
        var isListItem: Bool
        /// "# Heading", "**Whole line bold**", "*Whole line italic:*", "__Whole line__".
        var isMarkdownHeading: Bool
        /// A blank line (or the start of the text) comes right before it.
        var followsBlank: Bool
    }

    static func lines(of text: String) -> [Line] {
        var out: [Line] = []
        var blank = true
        for raw in text.components(separatedBy: .newlines).map(\.collapsedWhitespace) {
            guard !raw.isEmpty else { blank = true; continue }
            let heading = Rx.test("^#{1,6}\\s", raw) || Rx.test("^(\\*\\*|__|\\*|_)(?=\\S)[^*_]+\\1\\s*:?$", raw)
            let listItem = Rx.test("^(?:[-*•–·▢□☐]\\s+|\\d{1,2}[.)]\\s+)", raw)
            let cleaned = JSONLDRecipeParser.stripStepNumber(TextRecipeParser.stripBullet(cleanMarkdown(raw)))
            guard !cleaned.isEmpty else { continue }
            out.append(Line(text: cleaned, isListItem: listItem, isMarkdownHeading: heading, followsBlank: blank))
            blank = false
        }
        return out
    }

    enum Section { case none, ingredients, method, notes }

    public static func analyse(text: String) -> Analysis? {
        let all = lines(of: text)
        guard !all.isEmpty else { return nil }

        // Title: the first line, unless it's a section heading or chat prose ("A pound is about
        // 450 g, so…"); prose before the title is sorted like any other prose.
        var title = ""
        var titleServings: (Int, ClosedRange<Int>?)?
        var titleIndex: Int?
        for (i, line) in all.enumerated() {
            if sectionKind(line.text) != nil || line.isListItem { break }
            if let kind = ingredientLineKind(line.text), kind != .name { break }
            if isProse(line.text) { continue }
            let parsed = titleAndServingsRange(line.text)
            title = parsed.title
            titleServings = parsed.servings
            titleIndex = i
            break
        }
        var servings = titleServings?.0
        var servingsRange = titleServings?.1
        let body = all.enumerated().filter { $0.offset != titleIndex }.map(\.element)

        // In a list-style write-up, unbulleted prose after the last list item is commentary or a
        // tip unless it reads like an instruction ("Serve hot").
        let listItems = body.indices.filter { body[$0].isListItem }
        let lastListItem = listItems.count >= 2 ? listItems.last : nil
        // …and so is unbulleted prose before the first one ("A pound is about 450 g, so…").
        let firstListItem = listItems.count >= 2 ? listItems.first : nil

        var ingredients: [String] = [], steps: [String] = [], notes: [String] = [], dropped: [String] = []
        var section = Section.none
        var i = 0
        while i < body.count {
            defer { i += 1 }
            let line = body[i]
            let cleaned = line.text
            let next = body.dropFirst(i + 1).first?.text

            // A "Serves 4" line on its own.
            if servings == nil, cleaned.count <= 30,
               let m = Rx.firstMatch("^(?:serves|servings|makes|yield)\\s*:?\\s*(\\d+)\\b[^.]*$", in: cleaned) {
                servings = Int(m[1]!)
                continue
            }
            // Section headings.
            if !line.isListItem, let kind = sectionKind(cleaned) {
                section = kind
                if kind == .ingredients, servings == nil, let found = headingServings(cleaned) {
                    servings = found.lowerBound
                    servingsRange = found.count > 1 ? found : nil
                }
                continue
            }
            if isSubLabel(line, next: next, section: section, previous: i > 0 ? body[i - 1] : nil) {
                if section == .notes || PasteProse.isNotesHeading(cleaned) {
                    section = PasteProse.isNotesHeading(cleaned) ? .notes : .none
                }
                continue
            }

            switch section {
            case .notes:
                sortProse(cleaned, notes: &notes, dropped: &dropped)
                continue
            case .ingredients:
                if ingredientLineKind(cleaned) != nil || !readsLikeInstruction(cleaned) {
                    ingredients.append(cleaned)
                    continue
                }
                section = .method  // "Rinse the rice." with no method heading: the steps have started.
            case .none:
                if !PasteProse.hasNotePrefix(cleaned), ingredientLineKind(cleaned) != nil,
                   steps.isEmpty || blockIsAllIngredients(body, around: i) {
                    ingredients.append(cleaned)
                    continue
                }
            case .method:
                break
            }

            let isStep: Bool
            if PasteProse.hasNotePrefix(cleaned) {
                isStep = false
            } else if line.isListItem {
                isStep = true
            } else if let lastListItem, i > lastListItem, !PasteProse.startsLikeInstruction(cleaned) {
                isStep = false
            } else if let firstListItem, i < firstListItem, section != .method, !PasteProse.startsLikeInstruction(cleaned) {
                isStep = false
            } else {
                isStep = !PasteProse.isAllProse(cleaned)
            }
            if isStep {
                steps.append(cleaned)
            } else {
                sortProse(cleaned, notes: &notes, dropped: &dropped)
            }
        }
        return Analysis(title: title, servings: servings, servingsRange: servingsRange, ingredients: ingredients,
                        steps: steps, notes: notes, dropped: dropped)
    }

    static func sortProse(_ line: String, notes: inout [String], dropped: inout [String]) {
        let sorted = PasteProse.sort(line)
        notes += sorted.notes
        dropped += sorted.dropped
    }

    // MARK: Headings and labels

    static let ingredientsHeading = "^(?:the\\s+)?(?:ingredients?|what you(?:'|’)?ll need|what you need|you(?:'|’)?ll need|shopping list)\\b"
    static let methodHeading = "^(?:the\\s+)?(?:instructions?|directions?|method|steps?|preparation|procedure|how to (?:make|cook)(?: it)?|to make)(?:\\s+for\\b.*)?(?:\\s*\\([^)]*\\))?$"

    /// "Ingredients (3–4 servings)" → .ingredients, "Steps" → .method, "Notes" → .notes; nil
    /// for anything else.
    static func sectionKind(_ text: String) -> Section? {
        guard text.count <= 60, text.split(separator: " ").count <= 8, !Rx.test("[.!?]$", text) else { return nil }
        let t = TextRecipeParser.normalise(text)
        if Rx.test(ingredientsHeading, t) { return .ingredients }
        if Rx.test(methodHeading, t) { return .method }
        if PasteProse.isNotesHeading(t), !t.contains(":") || t.hasSuffix(":") { return .notes }
        return nil
    }

    /// "Ingredients (3–4 servings)", "Ingredients for 4" → 3...4, 4...4.
    static func headingServings(_ text: String) -> ClosedRange<Int>? {
        let range = "(\\d+)(?:\\s*(?:[-–—]|to)\\s*(\\d+))?"
        let m = Rx.firstMatch("\(range)\\s*(?:servings?|people|portions)\\b", in: text)
            ?? Rx.firstMatch("\\b(?:serves|for|makes|feeds)\\s+\(range)\\b", in: text)
        guard let m, let low = m[1].flatMap(Int.init) else { return nil }
        let high = m[2].flatMap(Int.init) ?? low
        return high >= low ? low...high : nil
    }

    /// A line that labels a group rather than saying what to use or do.
    static func isSubLabel(_ line: Line, next: String?, section: Section, previous: Line?) -> Bool {
        if line.isListItem { return false }  // "- Salt to taste" is an ingredient, never a label.
        if isHeading(line) { return true }
        let text = line.text
        if text.hasSuffix(":") && text.count <= 40 && !text.dropLast().contains(":") { return true }
        switch section {
        case .ingredients:
            // "For the tadka", or a bare name after a blank line that heads a group ("Chicken").
            if Rx.test("^for (?:the )?\\w", text), looksLikeLabel(text) { return true }
            return startsGroup(line, next: next)
        case .none:
            switch ingredientLineKind(text) {
            case .amount, .note:
                return false
            case .name:
                // "Sauce" / "Chicken" heading a group, but not "Salt" or "Cilantro" inside a list.
                if startsGroup(line, next: next) { return true }
                if let previous, !line.followsBlank, ingredientLineKind(previous.text) != nil { return false }
                if let next, ingredientLineKind(next) != nil { return false }
                return isSectionLabel(text, next: next)
            case nil:
                return isSectionLabel(text, next: next)
            }
        case .method, .notes:
            return isSectionLabel(text, next: next)
        }
    }

    /// A short bare line after a blank line, followed by an ingredient line with an amount:
    /// "Chicken" heading its group. "Salt" inside a list (no blank before it) stays an ingredient.
    static func startsGroup(_ line: Line, next: String?) -> Bool {
        guard line.followsBlank, looksLikeLabel(line.text), let next,
              ingredientLineKind(line.text) != .amount, ingredientLineKind(line.text) != .note else { return false }
        return ingredientLineKind(next) == .amount
    }

    /// The labelled block (between headings or labels) holding line `index` consists only of
    /// ingredient lines: "**Sauce**\n- 2 tbsp soy sauce\n- 1 tsp sugar" after some steps.
    static func blockIsAllIngredients(_ body: [Line], around index: Int) -> Bool {
        func isBoundary(_ k: Int) -> Bool {
            let line = body[k]
            return !line.isListItem && (isHeading(line) || sectionKind(line.text) != nil
                || (line.text.hasSuffix(":") && line.text.count <= 40))
        }
        var start = index
        while start > 0, !isBoundary(start - 1) { start -= 1 }
        var end = index
        while end + 1 < body.count, !isBoundary(end + 1) { end += 1 }
        guard start > 0 || end + 1 < body.count, end > start else { return false }
        return body[start...end].allSatisfy { ingredientLineKind($0.text) != nil }
    }

    /// A short markdown heading ("**Prep first**", "## Cook"), not a sentence.
    static func isHeading(_ line: Line) -> Bool {
        line.isMarkdownHeading && line.text.count <= 40 && line.text.split(separator: " ").count <= 6
            && !Rx.test("[.!?]$", line.text)
    }

    /// A sentence or chat rather than a title: two sentences, a long sentence, or commentary.
    static func isProse(_ text: String) -> Bool {
        if text.count > 80 || PasteProse.sentences(text).count >= 2 { return true }
        if Rx.test("[.!?]$", text) && text.split(separator: " ").count > 6 { return true }
        return PasteProse.classify(text) == .commentary
    }

    /// Starts with a cooking verb, has a "Label: sentence" shape, or holds more than one sentence.
    static func readsLikeInstruction(_ text: String) -> Bool {
        PasteProse.startsLikeInstruction(text) || Rx.test(labelledStep, text) || PasteProse.sentences(text).count >= 2
    }

    /// "Toast: Dry pan, medium-low heat." A short label, a colon, then the instruction.
    static let labelledStep = "^[\\p{L}][\\p{L}' -]{0,30}:\\s+\\S"

    // MARK: Ingredient lines

    enum IngredientLineKind: Hashable { case amount, note, name }

    static let ingredientNoteTail = "\\b(?:to taste|to garnish|for garnish(?:ing)?|to serve|for serving|as needed|as required|optional|to finish)\\b"
    static let looseAmount = "^(?:a (?:few|couple(?: of)?|handful|pinch|dash|splash|sprig|bunch|knob|drizzle|little)|handful|pinch|dash|splash|juice of|zest of|some)\\b"

    /// How a line reads as an ingredient line, or nil when it doesn't: `.amount` "1 lb (450 g)
    /// bone-in chicken", "Scant 1 tsp turmeric", "a handful of cilantro"; `.note` "Salt to taste",
    /// "Cilantro to garnish"; `.name` a catalog ingredient and nothing more ("Cilantro"). Never a
    /// line that starts with a cooking verb, has a "Label: …" shape, holds more than one sentence,
    /// a duration or a temperature.
    static func ingredientLineKind(_ text: String, catalog: IngredientCatalog = .shared) -> IngredientLineKind? {
        let words = text.split(separator: " ")
        guard text.count <= 90, words.count <= 14, !Rx.test("[.!?]\\s+\\S", text), !Rx.test("[!?]$", text),
              !Rx.test(labelledStep, text), !text.contains("°"), !PasteProse.startsLikeInstruction(text),
              !Rx.test("\\d\\s*(?:min|mins|minutes?|secs?|seconds?|hours?|hrs?)\\b", text),
              !Rx.test("^(?:with|in|on|at|until|then|and|or|it|this|that|they|you|i|we)\\b", text) else { return nil }
        let ing = IngredientLineParser.parse(text)
        if ing.quantity != nil, StepIngredientExtractor.isPlausibleName(ing.name), ing.name.rangeOfCharacter(from: .letters) != nil {
            return .amount
        }
        if Rx.test(looseAmount, text) { return .amount }
        let nameWords = ing.name.split(separator: " ").count
        if nameWords <= 4, let note = ing.note, Rx.test(ingredientNoteTail, note) || Rx.test(ingredientNoteTail, text) {
            return .note
        }
        if nameWords <= 4, words.count <= 6, catalog.exactMatch(ing.name) != nil { return .name }
        return nil
    }

    /// A step that is really an ingredient line ("1 tsp cumin seeds", "Cilantro to garnish").
    public static func isBareIngredientLine(_ text: String) -> Bool {
        ingredientLineKind(StepStyleParser.cleanMarkdown(text)) != nil
    }

    /// Steps that look like a pasted ingredient list rather than a method: at least two such
    /// lines, or a quarter of them.
    public static func stepsLookLikeIngredients(_ steps: [String]) -> Bool {
        let bare = steps.filter(isBareIngredientLine).count
        return bare >= 2 || (bare > 0 && Double(bare) / Double(max(steps.count, 1)) >= 0.25)
    }

    // MARK: Title

    /// "Mongolian Ground Beef (serves 4)" → ("Mongolian Ground Beef", 4). Also "– serves 4",
    /// "(Serves 4–6)" (the lower number), "[makes 12]".
    public static func titleAndServings(_ line: String) -> (title: String, servings: Int?) {
        let parsed = titleAndServingsRange(line)
        return (parsed.title, parsed.servings?.0)
    }

    static func titleAndServingsRange(_ line: String) -> (title: String, servings: (Int, ClosedRange<Int>?)?) {
        let text = cleanMarkdown(line)
        let pattern = "\\s*(?:[-–—,:|]\\s*)?[(\\[]?\\s*(?:serves|servings?|makes|yield|feeds)\\s*:?\\s*(\\d+)\\b(?:\\s*[-–—]\\s*(\\d+))?[^)\\]]*[)\\]]?\\s*$"
        if let m = Rx.firstMatch(pattern, in: text), let low = Int(m[1]!) {
            let title = String(text.dropLast(m[0]!.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -–—,:|"))
            let high = m[2].flatMap(Int.init)
            return (title, (low, high.flatMap { $0 > low ? low...$0 : nil }))
        }
        return (text, nil)
    }

    /// Short lines that label a section rather than say what to do: at most 4 words and 32
    /// characters, no digits, no sentence punctuation, and followed by a line that isn't itself
    /// a label. "For the sauce:" (ending in a colon) always counts. The last line is never a
    /// label, so a closing "Serve hot" is kept.
    static func isSectionLabel(_ text: String, next: String?) -> Bool {
        if text.hasSuffix(":") && text.count <= 40 && !text.dropLast().contains(":") { return true }
        guard let next, !next.isEmpty else { return false }
        return looksLikeLabel(text) && !looksLikeLabel(next)
    }

    static func looksLikeLabel(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return text.count <= 32 && words.count <= 4
            && !Rx.test("[.!?;]$", text)
            && text.rangeOfCharacter(from: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "½⅓⅔¼¾⅛"))) == nil
    }

    /// Markdown that chat apps add when copied: "## Sauce", "**Cook**", "*Chicken:*", "- step".
    static func cleanMarkdown(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        s = Rx.replace("^#{1,6}\\s*", in: s, with: "")
        // Single-asterisk italics ("*Pepper masala:*"), but not a "* " bullet.
        s = Rx.replace("(?<![\\w*])\\*(?=\\S)([^*]+?)(?<=\\S)\\*(?![\\w*])", in: s, with: "$1")
        return s.collapsedWhitespace
    }
}

/// Finds "quantity + unit + name" mentions in step text and parses each with
/// `IngredientLineParser`: "Whisk together ¼ cup soy sauce or tamari, ¼ cup water, …".
public enum StepIngredientExtractor {
    /// Words that end a mention: "1 tbsp Lao Gan Ma | in a small bowl", "1 tbsp oil | over medium-high".
    static let stopPrepositions = ["in", "into", "over", "on", "onto", "to", "for", "until", "at", "from", "inside", "under", "then"]
    /// Words that separate list items at the top level (outside parentheses).
    static let listSeparators = ["and", "with", "plus", "then", "along with"]
    /// A number right after one of these is a time, size or temperature, not an amount.
    static let nonAmountLeadIns: Set<String> = ["for", "into", "every", "after", "within", "at", "by", "to", "than", "from", "until", "under", "about"]
    /// Names that are really durations, sizes or counts of something other than an ingredient.
    static let nonIngredientWords: Set<String> = [
        "min", "mins", "minute", "minutes", "sec", "secs", "second", "seconds", "hour", "hours", "hr", "hrs",
        "degree", "degrees", "inch", "inches", "cm", "mm", "time", "times", "batch", "batches", "part", "parts",
        "piece", "pieces", "side", "sides", "serving", "servings", "people", "portion", "portions", "total",
        "more", "day", "days", "night", "nights", "step", "steps", "way", "ways", "x",
    ]

    public static func extract(from steps: [String]) -> [Ingredient] {
        steps.flatMap { mentions(in: $0) }.compactMap(parseMention)
    }

    /// Mention texts in one step, in order: "½ onion", "1–2 Fresnos (in rings)", "a handful of cilantro".
    static func mentions(in step: String) -> [String] {
        segments(of: step).flatMap(allMentions(in:))
    }

    /// Every mention in a segment: after a stop preposition the rest may hold another amount
    /// ("4 cloves garlic | in 2 tbsp butter").
    static func allMentions(in segment: String) -> [String] {
        var out: [String] = []
        var rest = segment
        while !rest.isEmpty, let (found, remainder) = mentionAndRest(in: rest) {
            if let found { out.append(found) }
            guard remainder.count < rest.count else { break }
            rest = remainder
        }
        return out
    }

    static func mention(in segment: String) -> String? {
        mentionAndRest(in: segment).flatMap { $0.0 }
    }

    /// Splits at top-level commas, semicolons, sentence ends and list words ("and", "with"…),
    /// keeping parenthesised text with its item.
    static func segments(of text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        var depth = 0
        var i = 0
        func flush() {
            let t = current.trimmed
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "[" { depth += 1 }
            if (c == ")" || c == "]") && depth > 0 { depth -= 1 }
            if depth == 0 {
                if c == "," || c == ";" || c == ":" { flush(); i += 1; continue }
                if c == "." || c == "!" || c == "?" {
                    let prevDigit = i > 0 && chars[i - 1].isNumber
                    let nextDigit = i + 1 < chars.count && chars[i + 1].isNumber
                    if !(c == "." && prevDigit && nextDigit) { flush(); i += 1; continue }
                }
                if c == " " {
                    let rest = String(chars[(i + 1)...]).lowercased()
                    if let sep = listSeparators.first(where: { rest.hasPrefix($0 + " ") }) {
                        flush()
                        i += 1 + sep.count
                        continue
                    }
                }
            }
            current.append(c)
            i += 1
        }
        flush()
        return out
    }

    static let fractionGlyphs = "½⅓⅔¼¾⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞"

    /// The first mention in a segment (from the first amount to the first stop preposition) and
    /// the text after it. The mention is nil when the amount is really a time, size or
    /// temperature ("for 3 min", "into 2-inch pieces", "200°C"). Nil when there's no amount.
    static func mentionAndRest(in segment: String) -> (String?, String)? {
        let unitWords = Units.table.flatMap(\.forms).filter { $0.count > 2 }.map(Rx.escape).joined(separator: "|")
        let amount = "(?<![\\w/.])(?:\\d|[\(fractionGlyphs)])|\\b(?:a|an|one)\\s+(?:\(unitWords))\\b"
        let ns = segment as NSString
        guard let m = Rx.re(amount).firstMatch(in: segment, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let before = ns.substring(to: m.range.location)
        let lead = before.split(separator: " ").last.map { $0.lowercased() }
        let chars = Array(ns.substring(from: m.range.location))
        // Cut at the first stop preposition outside parentheses ("… Lao Gan Ma in a small bowl").
        let stops = stopPrepositions.joined(separator: "|")
        var depth = 0
        var cut = chars.count
        for (i, c) in chars.enumerated() {
            if c == "(" || c == "[" { depth += 1 }
            if (c == ")" || c == "]") && depth > 0 { depth -= 1 }
            guard depth == 0, c == " ", i > 0 else { continue }
            if Rx.test("^(?:\(stops))\\b", String(chars[(i + 1)...])) {
                cut = i
                break
            }
        }
        let text = String(chars[..<cut])
        let rest = String(chars[cut...])
        if let lead, nonAmountLeadIns.contains(lead) { return (nil, rest) }
        if text.contains("°") { return (nil, rest) }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-–"))
        return (trimmed.isEmpty ? nil : trimmed, rest)
    }

    /// Parses one mention, splits "soy sauce or tamari" into name + note, and rejects things that
    /// aren't ingredients ("3–4 min", "2-inch pieces").
    static func parseMention(_ text: String) -> Ingredient? {
        var ing = IngredientLineParser.parse(text)
        guard ing.quantity != nil else { return nil }
        splitAlternative(&ing)
        return isPlausibleName(ing.name) ? ing : nil
    }

    /// "soy sauce or tamari" → name "soy sauce", note "or tamari" (prepended to any other note).
    static func splitAlternative(_ ing: inout Ingredient) {
        guard let m = Rx.firstMatch("^(.+?)\\s+(or\\s+.+)$", in: ing.name) else { return }
        ing.name = m[1]!.trimmed
        ing.note = [m[2]!.trimmed, ing.note].compactMap { $0 }.joined(separator: ", ")
    }

    static func isPlausibleName(_ name: String) -> Bool {
        let words = name.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first, words.count <= 6, name.count <= 60,
              name.rangeOfCharacter(from: .letters) != nil else { return false }
        if nonIngredientWords.contains(first) { return false }
        if Units.canonical(for: name) != nil { return false }
        return true
    }
}

/// Ingredient lines proposed by a language model for a step-style recipe, validated before use.
/// The model only ever proposes ingredients; steps always come from the user's text.
public enum ModelIngredientLines {
    public static let maxLines = 40

    /// Parses each line and keeps it only when it names something the steps actually mention
    /// (by a content word of the name, or any alias of its catalog entry). Drops empty, overlong
    /// and step-like lines, bare amounts, durations, and repeats. Annotated with catalog IDs.
    public static func map(_ lines: [String], steps: [String], catalog: IngredientCatalog = .shared) -> [Ingredient] {
        let stepText = " " + IngredientCatalog.normalise(steps.joined(separator: " ")) + " "
        var out: [Ingredient] = []
        var seen: Set<String> = []
        for line in lines.prefix(maxLines * 2) {
            let cleaned = TextRecipeParser.stripBullet(line.trimmed)
            guard !cleaned.isEmpty, cleaned.count <= 80, !Rx.test("[.!?]\\s+\\S", cleaned) else { continue }
            var ing = IngredientLineParser.parse(cleaned)
            StepIngredientExtractor.splitAlternative(&ing)
            guard StepIngredientExtractor.isPlausibleName(ing.name) else { continue }
            ing = catalog.annotate(ing)
            guard isGrounded(ing, in: stepText, catalog: catalog) else { continue }
            let key = IngredientCatalog.normalisedName(ing.name) + "|" + (ing.unit ?? "") + "|" + (ing.quantity.map { String($0) } ?? "")
            guard seen.insert(key).inserted else { continue }
            out.append(ing)
            if out.count == maxLines { break }
        }
        return out
    }

    static func isGrounded(_ ing: Ingredient, in stepText: String, catalog: IngredientCatalog) -> Bool {
        if let id = ing.catalogID, let entry = catalog.entry(id: id),
           entry.names.contains(where: { stepText.contains(" \(IngredientCatalog.normalise($0)) ") }) {
            return true
        }
        let words = IngredientCatalog.normalisedName(ing.name).split(separator: " ").map(String.init)
            .filter { !FeedbackParser.stopWords.contains($0) && !FeedbackParser.genericWords.contains($0) && $0.count > 2 }
        return !words.isEmpty && words.allSatisfy { stepText.contains(" \($0) ") }
    }

    /// The model's list when it's usable: at least two lines and at least ¾ as many as the rules
    /// found (a model that drops ingredients is worse than the rules). Otherwise the rules.
    public static func choose(model: [Ingredient], rules: [Ingredient]) -> [Ingredient] {
        let needed = max(2, Int((Double(rules.count) * 0.75).rounded(.up)))
        return model.count >= needed ? model : rules
    }
}
