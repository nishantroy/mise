import Foundation

/// Parses one ingredient line ("1 ½ cups flour, sifted") into quantity, unit, name and note.
public enum IngredientLineParser {
    static let number = "(?:\\d+\\s+\\d+/\\d+|\\d+/\\d+|\\d*\\.\\d+|\\d+)"

    private static let vulgarFractions: [(String, String)] = [
        ("½", "1/2"), ("⅓", "1/3"), ("⅔", "2/3"), ("¼", "1/4"), ("¾", "3/4"), ("⅕", "1/5"),
        ("⅖", "2/5"), ("⅗", "3/5"), ("⅘", "4/5"), ("⅙", "1/6"), ("⅚", "5/6"), ("⅛", "1/8"),
        ("⅜", "3/8"), ("⅝", "5/8"), ("⅞", "7/8"),
    ]

    /// Words that describe an ingredient without naming it; a comma segment made only of
    /// these is kept with the name ("boneless, skinless chicken thighs").
    static let descriptorWords: Set<String> = [
        "boneless", "skinless", "skin-on", "bone-in", "fresh", "dried", "large", "small", "medium",
        "extra", "virgin", "extra-virgin", "ripe", "raw", "cooked", "unsalted", "salted", "whole",
        "ground", "light", "dark", "low-sodium", "organic", "frozen", "thawed", "plain", "hot", "cold",
        "warm", "softened", "melted", "room", "temperature", "firm", "soft", "sweet", "packed",
    ]

    public static func parse(_ line: String) -> Ingredient {
        let raw = HTMLText.clean(line)
        var s = raw
        // Leading bullets and checkboxes from pasted lists or recipe plugins.
        s = Rx.replace("^[\\s\\-–•*▢□☐·]+", in: s, with: "")
        // WP Recipe Maker doubles note parentheses: "((optional))". Only collapse matched pairs.
        s = Rx.replace("\\(\\(([^()]*)\\)\\)", in: s, with: "($1)")
        s = normaliseNumbers(s)

        var notes: [String] = []
        let (withoutParens, parens) = extractParentheticals(s)
        notes += parens
        s = withoutParens.collapsedWhitespace

        // Quantity, including ranges ("1-2", "2 to 3": take the upper bound).
        var quantity: Double?
        if let m = Rx.firstMatch("^(?:about|approx\\.?|approximately|~|scant|heaped)?\\s*(\(number))(?:\\s*(?:-|to)\\s*(\(number)))?(?![\\d/])", in: s) {
            let lower = value(of: m[1]!)
            let upper = m[2].flatMap(value(of:))
            if let lower, let upper, upper < lower {
                // "1-1/2 cups" is a mixed number written with a hyphen, not a range.
                quantity = upper < 1 ? lower + upper : lower
            } else {
                quantity = upper ?? lower
            }
            s = String(s.dropFirst(m[0]!.count)).trimmed
        } else if let m = Rx.firstMatch("^(?:a|an|one)\\s+(?=[a-z])", in: s) {
            // "a pinch of salt": only treat "a" as 1 when a unit follows.
            let after = String(s.dropFirst(m[0]!.count))
            if unitToken(at: after) != nil {
                quantity = 1
                s = after
            }
        }
        s = Rx.replace("^x\\s+", in: s, with: "")  // "2 x 400g tins"

        var unit: String?
        if quantity != nil, let (canonical, length) = unitToken(at: s) {
            let rest = String(s.dropFirst(length)).trimmed
            // "4 cloves" (the spice) has no name after the unit; keep the word as the name.
            if !rest.isEmpty && !rest.hasPrefix(",") {
                unit = canonical
                s = rest
            }
        }
        // Alternative measure after the unit: "200g / 6 oz chicken".
        if let m = Rx.firstMatch("^/\\s*(\(number)\\s*[a-zA-Z]+\\.?)\\s+", in: s) {
            notes.insert(m[1]!.collapsedWhitespace, at: 0)
            s = String(s.dropFirst(m[0]!.count))
        }
        s = Rx.replace("^of\\s+", in: s, with: "")

        // Comma notes, keeping leading descriptor-only segments with the name.
        var segments = s.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmed }
        var name = segments.isEmpty ? "" : segments.removeFirst()
        while !segments.isEmpty, isDescriptorOnly(name) {
            name += ", " + segments.removeFirst()
        }
        let commaNote = segments.filter { !$0.isEmpty }.joined(separator: ", ")

        // Trailing phrases that are really notes.
        if let m = Rx.firstMatch("\\s+((?:to taste|as needed|as required|to serve|optional|for (?:garnish|garnishing|serving|frying|greasing|dusting|the [a-z]+)|plus (?:more|extra|a little|some).*)(?:\\s+.*)?)$", in: name) {
            notes.insert(m[1]!, at: 0)
            name = String(name.dropLast(m[0]!.count))
        }
        if !commaNote.isEmpty { notes.insert(commaNote, at: 0) }

        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–")).collapsedWhitespace
        if name.isEmpty { name = raw }
        let note = notes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        return Ingredient(raw: raw, quantity: quantity, unit: unit, name: name, note: note.isEmpty ? nil : note)
    }

    /// "1½" → "1 1/2", "½" → "1/2", en dashes in ranges → "-".
    static func normaliseNumbers(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "⁄", with: "/")
        for (glyph, ascii) in vulgarFractions where s.contains(glyph) {
            s = s.replacingOccurrences(of: glyph, with: " \(ascii) ")
        }
        s = Rx.replace("(\\d)\\s*[–—]\\s*(\\d)", in: s, with: "$1-$2")
        s = Rx.replace("(\\d) +- *(\\d)", in: s, with: "$1-$2")
        s = Rx.replace("(\\d/\\d+) +(?=[-–])", in: s, with: "$1")  // "½-inch" → "1/2-inch", not "1/2 -inch"
        return s.collapsedWhitespace
    }

    static func value(of text: String) -> Double? {
        let parts = text.split(separator: " ").map(String.init)
        var total = 0.0
        for part in parts {
            if part.contains("/") {
                let nd = part.split(separator: "/").compactMap { Double($0) }
                guard nd.count == 2, nd[1] != 0 else { return nil }
                total += nd[0] / nd[1]
            } else {
                guard let v = Double(part) else { return nil }
                total += v
            }
        }
        return total
    }

    /// Canonical unit and the length of the matched text at the start of `text`.
    static func unitToken(at text: String) -> (String, Int)? {
        if let m = Rx.firstMatch("^(fl\\.? oz\\.?|fluid ounces?)(?![a-zA-Z])", in: text) {
            return ("fl oz", m[0]!.count)
        }
        guard let m = Rx.firstMatch("^([a-zA-Z]+)\\.?(?![a-zA-Z])", in: text, []),
              let canonical = Units.canonical(for: m[1]!) else { return nil }
        return (canonical, m[0]!.count)
    }

    static func isDescriptorOnly(_ segment: String) -> Bool {
        let words = segment.lowercased().split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy { descriptorWords.contains($0) }
    }

    /// Removes top-level "( … )" groups and returns their contents.
    static func extractParentheticals(_ text: String) -> (String, [String]) {
        var outside = ""
        var groups: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "(" || ch == "[" {
                if depth > 0 { current.append(ch) }
                depth += 1
            } else if (ch == ")" || ch == "]") && depth > 0 {
                depth -= 1
                if depth == 0 {
                    groups.append(current.collapsedWhitespace)
                    current = ""
                    outside.append(" ")
                } else {
                    current.append(ch)
                }
            } else if depth > 0 {
                current.append(ch)
            } else {
                outside.append(ch)
            }
        }
        if depth > 0 { outside += " " + current }  // unbalanced: keep the text
        let cleaned = groups.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")) }.filter { !$0.isEmpty }
        // "chicken ( , thinly sliced)" leaves a dangling comma; tidy it.
        return (Rx.replace("\\s+,", in: outside, with: ","), cleaned)
    }
}
