import Foundation
import Testing
@testable import RecipeKit

@Suite("JSON-LD shapes")
struct JSONLDTests {
    func page(_ json: String) -> String {
        "<html><head><script type=\"application/ld+json\">\(json)</script></head><body></body></html>"
    }

    @Test func graphNode() throws {
        let json = """
        {"@context":"https://schema.org","@graph":[{"@type":"WebPage","name":"Page"},
         {"@type":["Recipe","NewsArticle"],"name":"Graph Dal","recipeIngredient":["1 cup toor dal","2 cups water"],
          "recipeInstructions":"Rinse the dal.\\nBoil until soft.","recipeYield":4,"cookTime":"PT40M","prepTime":"PT5M"}]}
        """
        let r = try #require(RecipeImporter.parse(html: page(json), url: nil))
        #expect(r.title == "Graph Dal")
        #expect(r.ingredients.count == 2)
        #expect(r.steps == ["Rinse the dal.", "Boil until soft."])
        #expect(r.servings == 4)
        #expect(r.totalMinutes == 45)
    }

    @Test func topLevelArray() throws {
        let json = """
        [{"@type":"Organization","name":"Site"},{"@type":"Recipe","name":"Array Soup","recipeIngredient":["1 onion"],
          "recipeInstructions":["Chop.","Simmer."],"recipeYield":["6","6 bowls"],"image":"https://x.test/a.jpg"}]
        """
        let r = try #require(RecipeImporter.parse(html: page(json), url: nil))
        #expect(r.steps == ["Chop.", "Simmer."])
        #expect(r.servings == 6)
        #expect(r.imageURL == URL(string: "https://x.test/a.jpg"))
    }

    @Test func howToSectionFlattens() throws {
        let json = """
        {"@type":"Recipe","name":"Sections","recipeIngredient":["1 egg"],"recipeInstructions":[
          {"@type":"HowToSection","name":"Batter","itemListElement":[{"@type":"HowToStep","text":"Whisk."},{"@type":"HowToStep","text":"Rest."}]},
          {"@type":"HowToSection","name":"Cook","itemListElement":[{"@type":"HowToStep","text":"Fry &amp; flip."}]}]}
        """
        let r = try #require(RecipeImporter.parse(html: page(json), url: nil))
        #expect(r.steps == ["Whisk.", "Rest.", "Fry & flip."])
    }

    @Test func entityAndTagDecoding() throws {
        let json = """
        {"@type":"Recipe","name":"Mac &amp; Cheese &#8211; Baked","recipeIngredient":["1 cup &quot;sharp&quot; cheddar &#x2013; grated"],
         "recipeInstructions":[{"@type":"HowToStep","text":"<p>Bake at 200&deg;C &amp;amp; serve.</p>"}],"recipeYield":"Serves 4-6"}
        """
        let r = try #require(RecipeImporter.parse(html: page(json), url: nil))
        #expect(r.title == "Mac & Cheese – Baked")
        #expect(r.ingredients[0].raw == "1 cup \"sharp\" cheddar – grated")
        #expect(r.steps == ["Bake at 200°C & serve."])
        #expect(r.servings == 4)
    }

    @Test func isoDurations() {
        #expect(ISODuration.minutes("PT1H30M") == 90)
        #expect(ISODuration.minutes("PT105M") == 105)
        #expect(ISODuration.minutes("P0DT2H") == 120)
        #expect(ISODuration.minutes("P1DT1H") == 1500)
        #expect(ISODuration.minutes("PT0S") == nil)
        #expect(ISODuration.minutes("30 minutes") == nil)
        #expect(ISODuration.minutes(nil) == nil)
    }
}
