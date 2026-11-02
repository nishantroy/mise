import Foundation
import Testing
@testable import RecipeKit

@Suite("Fixture imports")
struct FixtureImportTests {
    struct Expectation: Sendable, CustomStringConvertible {
        var fixture: String
        var title: String
        var ingredients: Int
        var steps: Int
        var servings: Int?
        var minutes: Int?
        var description: String { fixture }
    }

    static let cases: [Expectation] = [
        // @graph (Yoast) + plain HowToStep list
        .init(fixture: "woksoflife-red-braised-pork-belly", title: "Chairman Mao’s Red Braised Pork Belly",
              ingredients: 13, steps: 4, servings: 8, minutes: 105),
        // Indian food blog: @graph + HowToSection
        .init(fixture: "indianhealthyrecipes-chicken-curry", title: "Chicken Curry Recipe",
              ingredients: 18, steps: 13, servings: 3, minutes: 50),
        // Top-level Recipe object, yield "Makes 12", image as ImageObject
        .init(fixture: "bbcgoodfood-easy-pancakes", title: "Easy pancakes",
              ingredients: 6, steps: 5, servings: 12, minutes: 30),
        // HowToSection with three sections
        .init(fixture: "recipetineats-chow-mein", title: "Chow Mein",
              ingredients: 16, steps: 11, servings: 2, minutes: 15),
        // No JSON-LD: text fallback with <h2>/<h3> headings and an infobox
        .init(fixture: "wikibooks-kung-pao-chicken", title: "Kung Pao Chicken",
              ingredients: 22, steps: 11, servings: 4, minutes: nil),
        // Same page as the phone gets it: mobile skin with "edit" links beside each heading
        .init(fixture: "wikibooks-kung-pao-chicken-mobile", title: "Kung Pao Chicken",
              ingredients: 22, steps: 11, servings: 4, minutes: nil),
    ]

    @Test(arguments: cases)
    func importsFixture(_ e: Expectation) throws {
        let html = try Fixture.html(e.fixture)
        let recipe = try #require(RecipeImporter.parse(html: html, url: URL(string: "https://example.com/r")))
        #expect(recipe.title == e.title)
        #expect(recipe.ingredients.count == e.ingredients)
        #expect(recipe.steps.count == e.steps)
        #expect(recipe.servings == e.servings)
        #expect(recipe.totalMinutes == e.minutes)
        #expect(recipe.steps.allSatisfy { !$0.contains("<") && !$0.contains("&#") && !$0.contains("&amp;") })
        #expect(recipe.ingredients.allSatisfy { !$0.name.isEmpty && !$0.raw.contains("&amp;") })
    }

    @Test func woksOfLifeDetails() throws {
        let recipe = try #require(RecipeImporter.parse(html: try Fixture.html("woksoflife-red-braised-pork-belly"), url: nil))
        #expect(recipe.cuisine == "Chinese")
        #expect(recipe.imageURL?.absoluteString.hasPrefix("https://thewoksoflife.com/") == true)
        let wine = try #require(recipe.ingredients.first { $0.name.lowercased() == "shaoxing wine" })
        #expect(wine.quantity == 0.5)
        #expect(wine.unit == "cup")
        let dark = try #require(recipe.ingredients.first { $0.name.lowercased() == "dark soy sauce" })
        #expect(dark.quantity == 1.5)
        #expect(dark.unit == "tbsp")
        let chili = try #require(recipe.ingredients.first { $0.name.contains("dried chili") })
        #expect(chili.quantity == 2)
        #expect(chili.note == "optional")
    }

    @Test func indianCurryDetails() throws {
        let recipe = try #require(RecipeImporter.parse(html: try Fixture.html("indianhealthyrecipes-chicken-curry"), url: nil))
        #expect(recipe.cuisine == "Asian, Indian")
        let yogurt = try #require(recipe.ingredients.first { $0.name == "yogurt" })
        #expect(yogurt.note?.contains("& pureed") == true)  // &amp; decoded
        let cloves = try #require(recipe.ingredients.first { $0.raw == "4 cloves" })
        #expect(cloves.unit == nil)
        #expect(cloves.name == "cloves")
        let salt = try #require(recipe.ingredients.first { $0.name == "salt" })
        #expect(salt.quantity == 0.75)
        #expect(salt.unit == "tsp")
    }

    @Test func bbcImageObject() throws {
        let recipe = try #require(RecipeImporter.parse(html: try Fixture.html("bbcgoodfood-easy-pancakes"), url: nil))
        #expect(recipe.imageURL?.host() == "images.immediate.co.uk")
        let flour = try #require(recipe.ingredients.first)
        #expect(flour.quantity == 100)
        #expect(flour.unit == "g")
        #expect(flour.name == "plain flour")
    }

    @Test func recipeTinAlternativeMeasure() throws {
        let recipe = try #require(RecipeImporter.parse(html: try Fixture.html("recipetineats-chow-mein"), url: nil))
        let chicken = try #require(recipe.ingredients.first)
        #expect(chicken.quantity == 200)
        #expect(chicken.unit == "g")
        #expect(chicken.name == "chicken breast or thigh fillets")
        #expect(chicken.note?.hasPrefix("6 oz") == true, "\(chicken)")
    }

    @Test func wikibooksTextFallback() throws {
        let recipe = try #require(RecipeImporter.parse(html: try Fixture.html("wikibooks-kung-pao-chicken"), url: nil))
        #expect(recipe.ingredients.first?.name == "boneless, skinless chicken meat")
        #expect(!recipe.ingredients.contains { $0.name == "Spices" })  // sub-headings skipped
        #expect(recipe.steps.first == "Measure and prepare all ingredients before cooking.")
        #expect(recipe.steps.last == "Pour onto large platter and serve immediately.")
    }

    @Test func wikibooksMobileSkipsEditLinks() throws {
        let recipe = try #require(RecipeImporter.parse(html: try Fixture.html("wikibooks-kung-pao-chicken-mobile"), url: nil))
        #expect(!recipe.ingredients.contains { $0.raw.lowercased() == "edit" })
        #expect(!recipe.steps.contains { $0.lowercased() == "edit" })
        #expect(recipe.steps.first == "Measure and prepare all ingredients before cooking.")
        #expect(recipe.imageURL == nil)  // the page has no og:image
    }

    @Test func textFallbackTakesOGImage() throws {
        let html = """
        <html><head><title>Toast - Example</title><meta property="og:image" content="/img/toast.jpg"></head><body>
        <h2>Ingredients</h2><ul><li>2 slices bread</li></ul><h2>Method</h2><ol><li>Toast the bread.</li></ol></body></html>
        """
        let recipe = try #require(RecipeImporter.parse(html: html, url: URL(string: "https://example.com/r/toast")))
        #expect(recipe.title == "Toast")
        #expect(recipe.imageURL?.absoluteString == "https://example.com/img/toast.jpg")
    }

    @Test func seoTitleKeepsTheFirstName() {
        #expect(RecipeTitle.clean("Pepper Chicken | Pepper Chicken Recipe | Pepper Chicken Dry Recipe") == "Pepper Chicken")
        #expect(RecipeTitle.clean("Chow Mein") == "Chow Mein")
        #expect(RecipeTitle.clean("Mac & Cheese") == "Mac & Cheese")
    }

    @Test func cleanTitleKeepsOrdinaryColons() {
        #expect(TextRecipeParser.cleanTitle("Cookbook:Kung Pao Chicken - Wikibooks, open books for an open world") == "Kung Pao Chicken")
        #expect(TextRecipeParser.cleanTitle("Dal: A Weeknight Version") == "Dal: A Weeknight Version")
    }

    @Test func returnsNilForNonRecipePage() {
        let html = "<html><head><title>Hello</title></head><body><p>Nothing to cook here.</p></body></html>"
        #expect(RecipeImporter.parse(html: html, url: nil) == nil)
    }
}
