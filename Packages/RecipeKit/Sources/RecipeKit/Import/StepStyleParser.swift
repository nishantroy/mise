import Foundation

/// Pasted recipes whose ingredients only appear inside the steps ("Slice ½ onion, 1 green bell
/// pepper…"), with no "Ingredients" heading, often markdown copied from a chat app. The first
/// line is the title (servings from "(serves 4)"). Short section labels ("**Prep first**",
/// "## Sauce", "Cook") are dropped. Prose that isn't an instruction is sorted by `PasteProse`:
/// tips and variations become notes, commentary aimed at the reader is dropped. Every other
/// line is a step, kept verbatim apart from markdown and list markers. Ingredients come from
/// `StepIngredientExtractor` (steps only, so a tip's amounts never become ingredients).
public enum StepStyleParser {
    /// What the rules make of a pasted write-up, before ingredient extraction.
    public struct Analysis: Hashable, Sendable {
        public var title: String
        public var servings: Int?
        public var steps: [String]
        /// Tips and variations ("For a clear tingle, use ½–1 tsp Sichuan peppercorn.").
        public var notes: [String]
        /// Commentary that was left out ("The salt … are the fixes for the low flavor.").
        public var dropped: [String]
    }

    /// Returns nil when there are no steps or fewer than two ingredient mentions (so arbitrary
    /// prose isn't taken for a recipe).
    public static func parse(text: String) -> Recipe? {
        guard let analysis = analyse(text: text), !analysis.steps.isEmpty else { return nil }
        let ingredients = StepIngredientExtractor.extract(from: analysis.steps)
        guard ingredients.count >= 2 else { return nil }
        return Recipe(title: analysis.title.isEmpty ? "Untitled recipe" : analysis.title, servings: analysis.servings,
                      ingredients: ingredients, steps: analysis.steps, notes: analysis.notes)
    }

    struct Line {
        var text: String
        /// "- ", "* ", "• ", "1." or "1)" at the start.
        var isListItem: Bool
        /// "# Heading", "**Whole line bold**", "__Whole line__".
        var isMarkdownHeading: Bool
    }

    static func lines(of text: String) -> [Line] {
        text.components(separatedBy: .newlines).map(\.collapsedWhitespace).filter { !$0.isEmpty }.compactMap { raw in
            let heading = Rx.test("^#{1,6}\\s", raw) || Rx.test("^(\\*\\*|__)[^*_]+\\1\\s*:?$", raw)
            let listItem = Rx.test("^(?:[-*•–·▢□☐]\\s+|\\d{1,2}[.)]\\s+)", raw)
            let cleaned = JSONLDRecipeParser.stripStepNumber(TextRecipeParser.stripBullet(cleanMarkdown(raw)))
            return cleaned.isEmpty ? nil : Line(text: cleaned, isListItem: listItem, isMarkdownHeading: heading)
        }
    }

    public static func analyse(text: String) -> Analysis? {
        let all = lines(of: text)
        guard let first = all.first else { return nil }
        let (title, titleServings) = titleAndServings(first.text)
        var servings = titleServings
        let body = Array(all.dropFirst())
        // In a list-style write-up, unbulleted prose after the last list item is commentary or a
        // tip unless it reads like an instruction ("Serve hot").
        let listItems = body.indices.filter { body[$0].isListItem }
        let lastListItem = listItems.count >= 2 ? listItems.last : nil

        var steps: [String] = [], notes: [String] = [], dropped: [String] = []
        var inNotesSection = false
        for (i, line) in body.enumerated() {
            let cleaned = line.text
            // A "Serves 4" line on its own.
            if servings == nil, cleaned.count <= 30,
               let m = Rx.firstMatch("^(?:serves|servings|makes|yield)\\s*:?\\s*(\\d+)\\b[^.]*$", in: cleaned) {
                servings = Int(m[1]!)
                continue
            }
            let next = body.dropFirst(i + 1).first?.text
            if isHeading(line) || isSectionLabel(cleaned, next: next) {
                inNotesSection = PasteProse.isNotesHeading(cleaned)
                continue
            }
            let isStep: Bool
            if inNotesSection || PasteProse.hasNotePrefix(cleaned) {
                isStep = false
            } else if line.isListItem {
                isStep = true
            } else if let lastListItem, i > lastListItem, !PasteProse.startsLikeInstruction(cleaned) {
                isStep = false
            } else {
                isStep = !PasteProse.isAllProse(cleaned)
            }
            if isStep {
                steps.append(cleaned)
            } else {
                let sorted = PasteProse.sort(cleaned)
                notes += sorted.notes
                dropped += sorted.dropped
            }
        }
        return Analysis(title: title, servings: servings, steps: steps, notes: notes, dropped: dropped)
    }

    /// A short markdown heading ("**Prep first**", "## Cook"), not a sentence.
    static func isHeading(_ line: Line) -> Bool {
        line.isMarkdownHeading && line.text.count <= 40 && line.text.split(separator: " ").count <= 6
            && !Rx.test("[.!?]$", line.text)
    }

    /// "Mongolian Ground Beef (serves 4)" → ("Mongolian Ground Beef", 4). Also "– serves 4",
    /// "(Serves 4–6)" (the lower number), "[makes 12]".
    public static func titleAndServings(_ line: String) -> (title: String, servings: Int?) {
        let text = cleanMarkdown(line)
        let pattern = "\\s*(?:[-–—,:|]\\s*)?[(\\[]?\\s*(?:serves|servings?|makes|yield|feeds)\\s*:?\\s*(\\d+)\\b[^)\\]]*[)\\]]?\\s*$"
        if let m = Rx.firstMatch(pattern, in: text) {
            let title = String(text.dropLast(m[0]!.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -–—,:|"))
            return (title, Int(m[1]!))
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

    /// Markdown that chat apps add when copied: "## Sauce", "**Cook**", "- step".
    static func cleanMarkdown(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        s = Rx.replace("^#{1,6}\\s*", in: s, with: "")
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
