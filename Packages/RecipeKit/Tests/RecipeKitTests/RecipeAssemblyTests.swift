import Foundation
import Testing
@testable import RecipeKit

@Suite("Model recipe assembly validation")
struct RecipeAssemblyTests {
    let text: String
    let rules: Recipe

    init() throws {
        text = try Fixture.text("mongolian-beef-my-version-markdown")
        rules = try #require(RecipeImporter.parsePasted(text: text)).recipe
    }

    /// What a well-behaved model might return for the markdown fixture.
    static let goodSteps = [
        "Slice ½ onion, 1 green bell pepper, 1–2 Fresnos into rings, and 1 Thai chili (optional).",
        "Chop 3 green onions and a handful of cilantro.",
        "Toast and grind ¼ tsp Sichuan peppercorn (optional).",
        "Put 1½ tbsp ginger garlic paste and 1 tbsp Lao Gan Ma in a small bowl.",
        "Whisk together ¼ cup soy sauce or tamari, ¼ cup water, 3 tbsp sugar, 1 tbsp sherry, 1 tsp sesame oil, and 1 tsp cornstarch (if using).",
        "Step 6: Heat 1 tbsp oil over medium-high. Cook the onion and bell pepper for 3–4 min.",
        "Add 1 lb lean ground beef with ½ tsp salt. Let it sit for 2–3 min to brown, then break it up and cook until done, 6–7 min total.",
        "Add the ginger garlic paste, chilis, Lao Gan Ma, and Sichuan peppercorn. Stir for 30–60 sec.",
        "Pour in the sauce and simmer until sticky, 3–4 min.",
        "Off the heat, stir in 1 tsp rice vinegar and most of the green onions. Taste and adjust the salt.",
        "Top with cilantro and the rest of the green onions, and serve over rice.",
    ]

    static let goodIngredients = [
        "½ onion", "1 green bell pepper", "1–2 Fresno chilies", "1 Thai chili (optional)", "3 green onions",
        "1 handful cilantro", "¼ tsp Sichuan peppercorn (optional)", "1½ tbsp ginger garlic paste", "1 tbsp Lao Gan Ma",
        "¼ cup soy sauce or tamari", "¼ cup water", "3 tbsp sugar", "1 tbsp sherry", "1 tsp sesame oil",
        "1 tsp cornstarch (if using)", "1 tbsp oil", "1 lb lean ground beef", "½ tsp salt", "1 tsp rice vinegar", "rice",
    ]

    var good: ProposedRecipe {
        ProposedRecipe(servings: 4, ingredients: Self.goodIngredients, steps: Self.goodSteps,
                       notes: ["For a clear tingle, use up to ½–1 tsp Sichuan peppercorn."])
    }

    @Test func acceptsAFaithfulAssembly() {
        let result = RecipeAssembly.merge(good, text: text, rules: rules)
        #expect(result.usedModelSteps)
        #expect(result.usedModelIngredients)
        #expect(result.usedModelNotes)
        #expect(result.recipe.steps.count == 11)
        #expect(result.recipe.steps[5] == "Heat 1 tbsp oil over medium-high. Cook the onion and bell pepper for 3–4 min.", "\"Step 6:\" stripped")
        #expect(result.recipe.ingredients.count == 20)
        #expect(result.recipe.ingredients.last?.name == "rice", "an amount-less ingredient from the steps is fine")
        #expect(result.recipe.notes == ["For a clear tingle, use up to ½–1 tsp Sichuan peppercorn."])
        #expect(result.recipe.title == "Mongolian Ground Beef")
        #expect(result.recipe.servings == 4)
    }

    @Test func rejectsAStepMadeFromCommentary() {
        var proposal = good
        proposal.steps.append("The salt, harder browning, and longer simmer are the fixes for the low flavor.")
        let result = RecipeAssembly.merge(proposal, text: text, rules: rules)
        #expect(!result.usedModelSteps)
        #expect(result.recipe.steps == rules.steps)

        proposal = good
        proposal.steps.append("Go up to ½–1 tsp Sichuan peppercorn if you want a clear tingle.")
        #expect(RecipeAssembly.validSteps(proposal.steps, source: rules.steps, prose: proseOfFixture()) == nil)
    }

    @Test func rejectsAnInventedStep() {
        var proposal = good
        proposal.steps.insert("Marinate the beef in the soy sauce for 30 minutes.", at: 6)
        #expect(!RecipeAssembly.merge(proposal, text: text, rules: rules).usedModelSteps)
    }

    @Test func rejectsChangedOrMissingNumbersAndDroppedSteps() {
        var changed = Self.goodSteps
        changed[8] = "Pour in the sauce and simmer until sticky, 5 min."  // 3–4 min → 5 min
        #expect(RecipeAssembly.validSteps(changed, source: rules.steps, prose: proseOfFixture()) == nil)

        var dropped = Self.goodSteps
        dropped.removeLast()  // "Top with cilantro…" has no numbers, but it can't vanish
        #expect(RecipeAssembly.validSteps(dropped, source: rules.steps, prose: proseOfFixture()) == nil)
    }

    @Test func rejectsQuantitiesNotInTheText() {
        let mapped = RecipeAssembly.validIngredients([
            "2 tsp sesame oil",       // the paste says 1 tsp
            "3 tbsp soy sauce",       // 3 tbsp is the sugar's amount, in the same step
            "1 tbsp sesame seeds",    // not in the paste at all
            "1 tsp sesame oil",
            "¼ cup soy sauce",
        ], sourceSteps: rules.steps)
        #expect(mapped.map(\.raw) == ["1 tsp sesame oil", "¼ cup soy sauce"])
    }

    @Test func thinOrInvalidPartsFallBackToTheRules() {
        var proposal = good
        proposal.ingredients = ["1 tsp sesame oil", "2 lb ground beef"]
        proposal.notes = ["Taste and adjust the salt."]  // a step, not a tip
        let result = RecipeAssembly.merge(proposal, text: text, rules: rules)
        #expect(result.usedModelSteps)
        #expect(!result.usedModelIngredients)
        #expect(result.recipe.ingredients == rules.ingredients)
        #expect(!result.usedModelNotes)
        #expect(result.recipe.notes == rules.notes)
    }

    @Test func notesMustComeFromTheProse() {
        let notes = RecipeAssembly.validNotes([
            "The salt and longer simmer are the fixes for the low flavor.",  // commentary
            "Use 2 tsp Sichuan peppercorn for a clear tingle.",              // numbers are only checked loosely: "2" is in the paste (2–3 min)
            "Serve with a fried egg for a clear tingle.",                    // egg isn't in the paste
            "For a clear tingle, use ½–1 tsp Sichuan peppercorn.",
        ], text: text, sourceSteps: rules.steps, prose: proseOfFixture())
        #expect(notes.last == "For a clear tingle, use ½–1 tsp Sichuan peppercorn.")
        #expect(!notes.contains { $0.contains("fixes") || $0.contains("egg") })
    }

    @Test func amounts() {
        #expect(RecipeAssembly.amountValues(in: "Put 1½ tbsp paste, 1 1/2 cups, 1/4 tsp, 1–2 Fresnos") == [1.5, 1.5, 0.25, 1, 2])
    }

    func proseOfFixture() -> [String] {
        let analysis = StepStyleParser.analyse(text: text)!
        return analysis.notes + analysis.dropped
    }
}
