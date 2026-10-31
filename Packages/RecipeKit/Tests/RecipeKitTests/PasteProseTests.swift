import Foundation
import Testing
@testable import RecipeKit

@Suite("Markdown write-ups and prose")
struct PasteProseTests {
    @Test func markdownFixture() throws {
        let text = try Fixture.text("mongolian-beef-my-version-markdown")
        let pasted = try #require(RecipeImporter.parsePasted(text: text))
        let recipe = pasted.recipe
        #expect(pasted.ingredientsFromSteps)
        #expect(recipe.title == "Mongolian Ground Beef")
        #expect(recipe.servings == 4)

        // The same steps as the plain fixture: no headers, no markdown, no commentary.
        let plain = try #require(RecipeImporter.parse(text: Fixture.text("mongolian-beef-my-version")))
        #expect(recipe.steps == plain.steps)
        #expect(recipe.steps.count == 11)
        #expect(recipe.steps.first == "Slice ½ onion, 1 green bell pepper, 1–2 Fresnos (in rings), and 1 Thai chili (optional).")
        #expect(recipe.steps.last == "Top with cilantro and the rest of the green onions, and serve over rice.")
        #expect(!recipe.steps.contains { $0.contains("**") || $0.hasPrefix("-") || $0.contains("fixes") || $0.contains("tingle") })

        #expect(recipe.notes == ["For a clear tingle, use ½–1 tsp Sichuan peppercorn."])
        #expect(recipe.ingredients.map(\.raw) == plain.ingredients.map(\.raw))
        #expect(recipe.ingredients.map(\.catalogID) == plain.ingredients.map(\.catalogID))
        func amount(_ id: String) -> String? {
            recipe.ingredients.first { $0.catalogID == id }
                .map { QuantityFormatter.string(from: $0.quantity ?? 0, unit: $0.unit) + " " + ($0.unit ?? "") }
        }
        #expect(amount("sesame-oil") == "1 tsp")
        #expect(amount("rice-vinegar") == "1 tsp")
        #expect(amount("dry-sherry") == "1 tbsp")
        #expect(amount("sichuan-peppercorns") == "¼ tsp", "the step's amount, not the tip's")

        let analysis = try #require(StepStyleParser.analyse(text: text))
        #expect(analysis.dropped == ["The salt, harder browning, and longer simmer are the fixes for the low flavor."])
    }

    @Test func trailingParagraphInAPlainWriteUp() throws {
        let text = """
        Garlic Noodles (serves 2)
        Boil 200 g noodles for 4 minutes.
        Fry 4 cloves garlic in 2 tbsp butter, then add 1 tbsp soy sauce.
        This version works because the butter browns first. If it tastes flat, add a splash more soy sauce.
        Enjoy!
        """
        let analysis = try #require(StepStyleParser.analyse(text: text))
        #expect(analysis.steps.count == 2)
        #expect(analysis.notes == ["If it tastes flat, add a splash more soy sauce."])
        #expect(analysis.dropped == ["This version works because the butter browns first.", "Enjoy!"])
    }

    @Test func notesSectionsAndPrefixes() throws {
        let text = """
        ## Dal (serves 3)
        ### Cook
        1. Rinse 1 cup red lentils and boil with 3 cups water.
        2. Stir in 1 tsp turmeric. If using, add 1 tsp ghee.
        3. Serve over rice.
        Tip: for more heat, add 1 green chili.
        ### Notes
        - Keeps for 3 days in the fridge.
        """
        let analysis = try #require(StepStyleParser.analyse(text: text))
        #expect(analysis.title == "Dal")
        #expect(analysis.servings == 3)
        #expect(analysis.steps == [
            "Rinse 1 cup red lentils and boil with 3 cups water.",
            "Stir in 1 tsp turmeric. If using, add 1 tsp ghee.",
            "Serve over rice.",
        ])
        #expect(analysis.notes == ["For more heat, add 1 green chili.", "Keeps for 3 days in the fridge."])
    }

    @Test func classification() {
        #expect(PasteProse.classify("Go up to ½–1 tsp Sichuan peppercorn if you want a clear tingle.") == .tip)
        #expect(PasteProse.classify("For more heat, add another chili.") == .tip)
        #expect(PasteProse.classify("If it tastes flat, add lime.") == .tip)
        #expect(PasteProse.classify("If using, add the peanuts.") == .other)
        #expect(PasteProse.classify("The salt, harder browning, and longer simmer are the fixes for the low flavor.") == .commentary)
        #expect(PasteProse.classify("Let me know how it turns out!") == .commentary)
        #expect(PasteProse.classify("Simmer until sticky, 3–4 min.") == .other)
        #expect(PasteProse.tidyTip("Go up to ½–1 tsp Sichuan peppercorn if you want a clear tingle.")
                == "For a clear tingle, use ½–1 tsp Sichuan peppercorn.")
    }
}
