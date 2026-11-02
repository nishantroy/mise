import Foundation

/// Reads schema.org `Recipe` data from `<script type="application/ld+json">` blocks.
public enum JSONLDRecipeParser {
    public static func parse(html: String, url: URL?) -> Recipe? {
        for block in scriptBlocks(in: html) {
            guard let json = decode(block), let node = findRecipe(in: json) else { continue }
            if let recipe = map(node, url: url) { return recipe }
        }
        return nil
    }

    static func scriptBlocks(in html: String) -> [String] {
        Rx.matches("<script[^>]*type\\s*=\\s*[\"']?application/ld\\+json[\"']?[^>]*>(.*?)</script\\s*>", in: html,
                   [.caseInsensitive, .dotMatchesLineSeparators])
            .compactMap { $0[1] }
    }

    static func decode(_ block: String) -> Any? {
        var text = block.trimmed
        if text.hasPrefix("<!--") { text = String(text.dropFirst(4)) }
        if text.hasSuffix("-->") { text = String(text.dropLast(3)) }
        if text.hasPrefix("<![CDATA[") { text = String(text.dropFirst(9).dropLast(3)) }
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return json
        }
        // Some sites put raw newlines or tabs inside JSON strings; JSON forbids them.
        let relaxed = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard let data = relaxed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func isRecipe(_ node: [String: Any]) -> Bool {
        if let t = node["@type"] as? String { return t == "Recipe" || t.hasSuffix("/Recipe") }
        if let ts = node["@type"] as? [String] { return ts.contains("Recipe") }
        return false
    }

    /// Depth-first search through arrays, `@graph` and nested objects (e.g. `mainEntity`).
    static func findRecipe(in json: Any, depth: Int = 0) -> [String: Any]? {
        guard depth < 6 else { return nil }
        if let dict = json as? [String: Any] {
            if isRecipe(dict) { return dict }
            if let graph = dict["@graph"], let found = findRecipe(in: graph, depth: depth + 1) { return found }
            for key in ["mainEntity", "mainEntityOfPage", "itemListElement", "item"] {
                if let child = dict[key], let found = findRecipe(in: child, depth: depth + 1) { return found }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let found = findRecipe(in: item, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    static func map(_ node: [String: Any], url: URL?) -> Recipe? {
        let title = strings(node["name"]).first.map(HTMLText.clean) ?? ""
        let ingredientLines = strings(node["recipeIngredient"] ?? node["ingredients"])
            .map(HTMLText.clean).filter { !$0.isEmpty }
        let steps = instructions(node["recipeInstructions"])
        guard !ingredientLines.isEmpty || !steps.isEmpty else { return nil }

        var total = ISODuration.minutes(strings(node["totalTime"]).first)
        if total == nil {
            let prep = ISODuration.minutes(strings(node["prepTime"]).first) ?? 0
            let cook = ISODuration.minutes(strings(node["cookTime"]).first) ?? 0
            total = prep + cook > 0 ? prep + cook : nil
        }
        let cuisines = strings(node["recipeCuisine"]).map(HTMLText.clean).filter { !$0.isEmpty }

        return Recipe(
            title: title.isEmpty ? "Untitled recipe" : RecipeTitle.clean(title),
            sourceURL: url,
            imageURL: imageURL(node["image"], base: url),
            servings: servings(node["recipeYield"] ?? node["yield"]),
            totalMinutes: total,
            cuisine: cuisines.isEmpty ? nil : cuisines.joined(separator: ", "),
            ingredients: ingredientLines.map(IngredientLineParser.parse),
            steps: steps,
            notes: []
        )
    }

    /// A string, a number, or an array of either, as strings.
    static func strings(_ value: Any?) -> [String] {
        switch value {
        case let s as String: [s]
        case let n as NSNumber: [n.stringValue]
        case let a as [Any]: a.flatMap { strings($0) }
        default: []
        }
    }

    /// First integer found in a yield that may be "4", 4, "Serves 4-6", or ["4", "4 people"].
    static func servings(_ value: Any?) -> Int? {
        for s in strings(value) {
            if let m = Rx.firstMatch("(\\d+)", in: s), let n = Int(m[1]!), n > 0 { return n }
        }
        return nil
    }

    static func imageURL(_ value: Any?, base: URL?) -> URL? {
        var candidate: String?
        switch value {
        case let s as String: candidate = s
        case let d as [String: Any]: candidate = (d["url"] as? String) ?? (d["contentUrl"] as? String)
        case let a as [Any]: return a.lazy.compactMap { imageURL($0, base: base) }.first
        default: break
        }
        guard let c = candidate?.trimmed, !c.isEmpty else { return nil }
        return URL(string: c, relativeTo: base)?.absoluteURL
    }

    /// Flattens string / [String] / [HowToStep] / [HowToSection] instructions into step strings.
    static func instructions(_ value: Any?) -> [String] {
        switch value {
        case let s as String:
            // A single block may be HTML or newline-separated text.
            let lines = s.contains("<") ? HTMLText.lines(fromHTML: s).map(\.text) : s.components(separatedBy: .newlines)
            return lines.map(HTMLText.clean).map(stripStepNumber).filter { !$0.isEmpty }
        case let a as [Any]:
            return a.flatMap { instructions($0) }
        case let d as [String: Any]:
            if let items = d["itemListElement"] { return instructions(items) }
            let text = strings(d["text"]).first ?? strings(d["name"]).first ?? ""
            let cleaned = stripStepNumber(HTMLText.clean(text))
            return cleaned.isEmpty ? [] : [cleaned]
        default:
            return []
        }
    }

    static func stripStepNumber(_ text: String) -> String {
        Rx.replace("^(?:step\\s*)?\\d{1,2}\\s*[.):]\\s+", in: text, with: "").trimmed
    }
}
