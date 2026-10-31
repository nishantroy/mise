import Foundation

/// Fallback for pages without JSON-LD, and for pasted recipe text: finds an "Ingredients"
/// heading, takes lines until a method heading, then steps until the next heading.
public enum TextRecipeParser {
    static let ingredientsHeading = "^(?:the\\s+)?ingredients?(?:\\s+(?:for|list)\\b.*)?:?$"
    static let stepsHeading = "^(?:the\\s+)?(?:instructions?|directions?|method|steps?|preparation|procedure|how to (?:make|cook)(?: it)?|to make)(?:\\s+for\\b.*)?:?$"
    static let endHeading = "^(?:notes?|tips?|notes,? tips.*|nutrition.*|serving suggestions?|storage|video|equipment|variations?|faqs?|warnings?|recipe notes?)\\b.*:?$"
    /// Wiki section-edit links ("edit", "[edit]", "[edit | edit source]") render as their own lines.
    static let editLink = "^\\[?\\s*edit(?:\\s+source)?(?:\\s*\\|\\s*edit source)?\\s*\\]?$"

    public static func parse(html: String, url: URL?) -> Recipe? {
        let title = HTMLText.metaContent("og:title", in: html) ?? HTMLText.titleTag(in: html)
        let lines = HTMLText.lines(fromHTML: html).filter { !Rx.test(editLink, $0.text.lowercased()) }
        guard var recipe = parse(lines: lines, title: title.map(cleanTitle), url: url) else { return nil }
        recipe.imageURL = HTMLText.metaContent("og:image", in: html).flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        return recipe
    }

    /// Pasted text. The first line is the title unless it's a heading.
    public static func parse(text: String) -> Recipe? {
        let lines = HTMLText.lines(fromText: text)
        guard let first = lines.first else { return nil }
        let firstIsHeading = Rx.test(ingredientsHeading, normalise(first.text))
        return parse(lines: firstIsHeading ? lines : Array(lines.dropFirst()), title: firstIsHeading ? nil : first.text, url: nil)
    }

    static func parse(lines: [HTMLText.Line], title: String?, url: URL?) -> Recipe? {
        let hasMarkup = lines.contains { $0.isHeading }
        func isHeading(_ line: HTMLText.Line, _ pattern: String) -> Bool {
            line.text.count <= 60 && Rx.test(pattern, normalise(line.text))
        }
        // Prefer real heading elements; fall back to any matching line.
        let start = lines.firstIndex { $0.isHeading && isHeading($0, ingredientsHeading) }
            ?? lines.firstIndex { isHeading($0, ingredientsHeading) }
        guard let start else { return nil }

        var ingredients: [String] = []
        var i = start + 1
        var stepsStart: Int?
        while i < lines.count {
            let line = lines[i]
            if isHeading(line, stepsHeading) { stepsStart = i; break }
            if isHeading(line, endHeading) { break }
            // Sub-headings ("For the sauce:", <h3>Spices</h3>) are skipped, not treated as ingredients.
            if !line.isHeading && !line.text.hasSuffix(":") {
                let cleaned = stripBullet(line.text)
                if !cleaned.isEmpty { ingredients.append(cleaned) }
            }
            i += 1
        }
        if stepsStart == nil {
            stepsStart = lines.indices.first { $0 > start && isHeading(lines[$0], stepsHeading) }
        }
        var steps: [String] = []
        if let s = stepsStart {
            var j = s + 1
            while j < lines.count {
                let line = lines[j]
                if hasMarkup ? (line.isHeading && !Rx.test("^step\\s*\\d", line.text)) : isHeading(line, endHeading) { break }
                let cleaned = JSONLDRecipeParser.stripStepNumber(stripBullet(line.text))
                if !cleaned.isEmpty && !Rx.test("^step\\s*\\d+:?$", cleaned) { steps.append(cleaned) }
                j += 1
            }
        }
        guard !ingredients.isEmpty, !steps.isEmpty else { return nil }

        // Pair each line with the next so table layouts ("Servings" | "4") still match.
        let preambleLines = lines[..<start].map(\.text)
        let preamble = preambleLines.indices.map { i in
            i + 1 < preambleLines.count ? preambleLines[i] + " " + preambleLines[i + 1] : preambleLines[i]
        }
        let servings = preamble.lazy.compactMap { line -> Int? in
            guard let m = Rx.firstMatch("\\b(?:serves|servings|yield|yields|makes)\\b\\s*:?\\s*(\\d+)", in: line) else { return nil }
            return Int(m[1]!)
        }.first

        return Recipe(
            title: (title?.isEmpty == false ? title! : "Untitled recipe"),
            sourceURL: url,
            servings: servings,
            ingredients: ingredients.map(IngredientLineParser.parse),
            steps: steps
        )
    }

    static func normalise(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " :#*-–•")).collapsedWhitespace
    }

    static func stripBullet(_ text: String) -> String {
        Rx.replace("^[\\-–•*▢□☐·]+\\s*", in: text, with: "").trimmed
    }

    /// "Chow Mein - RecipeTin Eats" → "Chow Mein". Only strips a short trailing site name,
    /// and a wiki namespace prefix ("Cookbook:Kung Pao Chicken" → "Kung Pao Chicken").
    static func cleanTitle(_ title: String) -> String {
        var title = title
        if let m = Rx.firstMatch("^(.+?)\\s+[-|–—]\\s+[^-|–—]{2,60}$", in: title), let head = m[1], head.count >= 3 {
            title = head.trimmed
        }
        if let m = Rx.firstMatch("^[A-Z][A-Za-z]+:(\\S.*)$", in: title), let rest = m[1] {
            title = rest
        }
        return title
    }
}
