import Foundation

/// Entry point for turning a fetched page or pasted text into a `Recipe`.
public enum RecipeImporter {
    /// JSON-LD first, then the text fallback. Nil when neither finds ingredients and steps.
    /// Ingredients are matched against `catalog`.
    public static func parse(html: String, url: URL?, catalog: IngredientCatalog = .shared) -> Recipe? {
        parseUnannotated(html: html, url: url).map(catalog.annotate)
    }

    /// Recipe text pasted by the user. Falls back to HTML parsing if it looks like markup, and to
    /// step-style parsing (ingredients written inside the steps) when there's no "Ingredients" heading.
    public static func parse(text: String, catalog: IngredientCatalog = .shared) -> Recipe? {
        parsePasted(text: text, catalog: catalog)?.recipe
    }

    /// A parsed paste, and whether its ingredients were pulled out of the steps (so a model may
    /// be asked to assemble the recipe better; see `RecipeAssembly`).
    public struct PastedRecipe: Hashable, Sendable {
        public var recipe: Recipe
        public var ingredientsFromSteps: Bool
        /// "(3–4 servings)": `recipe.servings` holds the lower bound, and a recipe already within
        /// the range isn't offered a servings change (`RecipeDiff.compare(…servingsRange:)`).
        public var servingsRange: ClosedRange<Int>?

        public init(recipe: Recipe, ingredientsFromSteps: Bool, servingsRange: ClosedRange<Int>? = nil) {
            self.recipe = recipe
            self.ingredientsFromSteps = ingredientsFromSteps
            self.servingsRange = servingsRange
        }
    }

    /// HTML → the page parsers. Otherwise the write-up rules (`StepStyleParser.analyse`) decide
    /// first: listed ingredients (an "Ingredients" section or a block of ingredient lines) plus
    /// steps give the recipe directly, no model needed. Then the classic "Ingredients … Method"
    /// parser, then step-style extraction (amounts written inside the steps).
    public static func parsePasted(text: String, catalog: IngredientCatalog = .shared) -> PastedRecipe? {
        if text.contains("</") || text.contains("application/ld+json") {
            return parse(html: text, url: nil, catalog: catalog).map { PastedRecipe(recipe: $0, ingredientsFromSteps: false) }
        }
        let analysis = StepStyleParser.analyse(text: text)
        if let analysis, !analysis.ingredients.isEmpty, !analysis.steps.isEmpty,
           let recipe = StepStyleParser.parse(text: text) {
            return PastedRecipe(recipe: catalog.annotate(recipe), ingredientsFromSteps: false,
                                servingsRange: analysis.servingsRange)
        }
        if let recipe = TextRecipeParser.parse(text: text) {
            return PastedRecipe(recipe: catalog.annotate(recipe), ingredientsFromSteps: false)
        }
        if let recipe = StepStyleParser.parse(text: text) {
            return PastedRecipe(recipe: catalog.annotate(recipe), ingredientsFromSteps: true,
                                servingsRange: analysis?.servingsRange)
        }
        return nil
    }

    static func parseUnannotated(html: String, url: URL?) -> Recipe? {
        if let recipe = JSONLDRecipeParser.parse(html: html, url: url), !recipe.ingredients.isEmpty {
            return recipe
        }
        if let recipe = TextRecipeParser.parse(html: html, url: url) { return recipe }
        // JSON-LD with steps but no ingredient list is still better than nothing.
        return JSONLDRecipeParser.parse(html: html, url: url)
    }
}
