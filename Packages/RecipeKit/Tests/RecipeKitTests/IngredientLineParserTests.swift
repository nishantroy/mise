import Foundation
import Testing
@testable import RecipeKit

@Suite("Ingredient lines")
struct IngredientLineParserTests {
    @Test func mixedUnicodeFraction() {
        let i = IngredientLineParser.parse("1 ½ cups flour")
        #expect(i.quantity == 1.5)
        #expect(i.unit == "cup")
        #expect(i.name == "flour")
        #expect(i.note == nil)
    }

    @Test func attachedUnicodeFraction() {
        let i = IngredientLineParser.parse("1½ tablespoons dark soy sauce")
        #expect(i.quantity == 1.5)
        #expect(i.unit == "tbsp")
        #expect(i.name == "dark soy sauce")
    }

    @Test func rangeTakesUpperAndCommaNote() {
        let i = IngredientLineParser.parse("2-3 cloves garlic, minced")
        #expect(i.quantity == 3)
        #expect(i.unit == "clove")
        #expect(i.name == "garlic")
        #expect(i.note == "minced")
    }

    @Test func wordRange() {
        let i = IngredientLineParser.parse("½ to ¾ teaspoon salt")
        #expect(i.quantity == 0.75)
        #expect(i.unit == "tsp")
    }

    @Test func toTaste() {
        let i = IngredientLineParser.parse("Salt to taste")
        #expect(i.quantity == nil)
        #expect(i.unit == nil)
        #expect(i.name == "Salt")
        #expect(i.note == "to taste")
    }

    @Test func parentheticalSizeBeforeUnit() {
        let i = IngredientLineParser.parse("1 (14 oz) can coconut milk")
        #expect(i.quantity == 1)
        #expect(i.unit == "can")
        #expect(i.name == "coconut milk")
        #expect(i.note == "14 oz")
    }

    @Test func asciiFractionsAndDecimals() {
        #expect(IngredientLineParser.parse("1/2 tsp sesame oil").quantity == 0.5)
        #expect(IngredientLineParser.parse("1 1/2 tbsp soy sauce").quantity == 1.5)
        #expect(IngredientLineParser.parse("0.5 kg chicken").unit == "kg")
        #expect(IngredientLineParser.parse("200g chicken").unit == "g")
    }

    @Test func unitWithoutNameIsTheName() {
        let i = IngredientLineParser.parse("4 cloves")
        #expect(i.quantity == 4)
        #expect(i.unit == nil)
        #expect(i.name == "cloves")
    }

    @Test func pluralAndLongUnits() {
        #expect(IngredientLineParser.parse("2 pounds pork belly").unit == "lb")
        #expect(IngredientLineParser.parse("3 Tbsp. butter").unit == "tbsp")
        #expect(IngredientLineParser.parse("2 pinches saffron").unit == "pinch")
        #expect(IngredientLineParser.parse("500 millilitres stock").unit == "ml")
        #expect(IngredientLineParser.parse("1 litre water").unit == "l")
        #expect(IngredientLineParser.parse("2 ounces cheese").unit == "oz")
        #expect(IngredientLineParser.parse("a pinch of salt").quantity == 1)
        #expect(IngredientLineParser.parse("a pinch of salt").name == "salt")
    }

    @Test func descriptorsStayWithName() {
        let i = IngredientLineParser.parse("1 lb boneless, skinless chicken thighs, cut into cubes")
        #expect(i.name == "boneless, skinless chicken thighs")
        #expect(i.note == "cut into cubes")
    }

    @Test func noQuantityWordsNotUnits() {
        let i = IngredientLineParser.parse("3 large eggs")
        #expect(i.quantity == 3)
        #expect(i.unit == nil)
        #expect(i.name == "large eggs")
    }

    @Test func orAlternativeAfterComma() {
        let i = IngredientLineParser.parse("2 tbsp Shaoxing wine, or dry sherry")
        #expect(i.name == "Shaoxing wine")
        #expect(i.note == "or dry sherry")
    }

    @Test func plusPhraseIsNote() {
        let i = IngredientLineParser.parse("1 tbsp sunflower or vegetable oil plus a little extra for frying")
        #expect(i.name == "sunflower or vegetable oil")
        #expect(i.note == "plus a little extra for frying")
    }
}

@Suite("Quantities and scaling")
struct QuantityTests {
    @Test func formatsFractions() {
        #expect(QuantityFormatter.string(from: 0.5) == "½")
        #expect(QuantityFormatter.string(from: 1.25) == "1 ¼")
        #expect(QuantityFormatter.string(from: 0.333) == "⅓")
        #expect(QuantityFormatter.string(from: 2) == "2")
        #expect(QuantityFormatter.string(from: 2.97) == "3")
        #expect(QuantityFormatter.string(from: 0.66) == "⅔")
        #expect(QuantityFormatter.string(from: 0.02) == "⅛")
        #expect(QuantityFormatter.string(from: 12.4) == "12")
    }

    @Test func formatsMetricAsDecimals() {
        #expect(QuantityFormatter.string(from: 150, unit: "g") == "150")
        #expect(QuantityFormatter.string(from: 333.3, unit: "g") == "335")
        #expect(QuantityFormatter.string(from: 0.75, unit: "kg") == "0.8")
        #expect(QuantityFormatter.string(from: 1.5, unit: "l") == "1.5")
    }

    @Test func displayText() {
        #expect(IngredientLineParser.parse("1 ½ cups flour").displayText == "1 ½ cups flour")
        #expect(IngredientLineParser.parse("1 cup flour").displayText == "1 cup flour")
        #expect(IngredientLineParser.parse("2 cloves garlic").displayText == "2 cloves garlic")
        #expect(IngredientLineParser.parse("Salt to taste").displayText == "Salt")
    }

    @Test func scalesRecipe() {
        let recipe = Recipe(title: "T", servings: 4, ingredients: [
            IngredientLineParser.parse("1 cup rice"),
            IngredientLineParser.parse("Salt to taste"),
        ])
        let half = recipe.scaled(to: 2)
        #expect(half.servings == 2)
        #expect(half.ingredients[0].quantity == 0.5)
        #expect(half.ingredients[1].quantity == nil)
        #expect(half.ingredients[0].id == recipe.ingredients[0].id)
        #expect(recipe.scaled(to: 4) == recipe)
        #expect(Recipe(title: "No servings").scaled(to: 3).servings == nil)
    }
}

@Suite("Text recipes")
struct TextRecipeTests {
    @Test func pastedText() throws {
        let text = """
        Quick Dal
        Serves 3
        Ingredients
        - 1 cup red lentils
        - 3 cups water
        For the tadka:
        • 1 tbsp ghee
        • 1 tsp cumin seeds
        Method
        1. Rinse the lentils.
        2. Simmer with water for 20 minutes.
        3. Fry cumin in ghee and pour over.
        Notes
        Keeps for 3 days.
        """
        let r = try #require(RecipeImporter.parse(text: text))
        #expect(r.title == "Quick Dal")
        #expect(r.servings == 3)
        #expect(r.ingredients.map(\.name) == ["red lentils", "water", "ghee", "cumin seeds"])
        #expect(r.steps == ["Rinse the lentils.", "Simmer with water for 20 minutes.", "Fry cumin in ghee and pour over."])
    }

    @Test func pastedTextWithoutStepsFails() {
        #expect(RecipeImporter.parse(text: "Toast\nIngredients\n1 slice bread") == nil)
    }

    @Test func htmlEntitiesHelper() {
        #expect(HTMLText.decodeEntities("Tom &amp; Jerry&#39;s &frac12; cup") == "Tom & Jerry's ½ cup")
        #expect(HTMLText.clean("<b>Hot</b>&nbsp;&nbsp;sauce") == "Hot sauce")
    }
}
