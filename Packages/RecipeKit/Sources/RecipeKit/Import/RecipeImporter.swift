import Foundation

/// Entry point for turning a fetched page or pasted text into a `Recipe`.
public enum RecipeImporter {
    /// JSON-LD first, then the text fallback. Nil when neither finds ingredients and steps.
    public static func parse(html: String, url: URL?) -> Recipe? {
        if let recipe = JSONLDRecipeParser.parse(html: html, url: url), !recipe.ingredients.isEmpty {
            return recipe
        }
        if let recipe = TextRecipeParser.parse(html: html, url: url) { return recipe }
        // JSON-LD with steps but no ingredient list is still better than nothing.
        return JSONLDRecipeParser.parse(html: html, url: url)
    }

    /// Recipe text pasted by the user. Falls back to HTML parsing if it looks like markup.
    public static func parse(text: String) -> Recipe? {
        if text.contains("</") || text.contains("application/ld+json") {
            return parse(html: text, url: nil)
        }
        return TextRecipeParser.parse(text: text)
    }
}
