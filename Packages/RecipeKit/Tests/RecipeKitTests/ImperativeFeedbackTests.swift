import Foundation
import Testing
@testable import RecipeKit

/// "Change recipe": instructions ("use 2 tbsp oil", "skip step 8") rather than reports of a cook.
/// The same rules serve both; these phrasings are the imperative ones.
@Suite("Imperative feedback (Change recipe)")
struct ImperativeFeedbackTests {
    static let pepperStep7High = "Step 7: Chicken: Add chicken and coat well. Cover and cook on high 10 min until tender. No water needed."

    /// (fixture, instruction, the proposals' summaries in order).
    static let cases: [(fixture: String, text: String, expect: [String])] = [
        // Pepper chicken (the owner's version).
        ("pepper-chicken", "use 2 tbsp oil", ["Change oil: 2 ½ tbsp → 2 tbsp"]),
        ("pepper-chicken", "remove the green chillies", ["Leave out green chillies"]),
        ("pepper-chicken", "no cilantro", ["Leave out Cilantro"]),
        ("pepper-chicken", "cook the chicken 10 min on high", [pepperStep7High]),
        ("pepper-chicken", "skip the dry-out step", ["Remove step 8 (Dry out)"]),
        ("pepper-chicken", "don't cover the chicken",
         ["Step 7: Chicken: Add chicken and coat well. Cook uncovered on low 25–35 min until tender (boneless: ~15–20 min). No water needed."]),
        ("pepper-chicken", "please add a squeeze of lime at the end", ["Add lime (a squeeze, at the end)"]),
        ("pepper-chicken", "it's usually too salty", ["Note: Use less salt than last time"]),
        // Shortcut Mongolian beef.
        ("woksoflife-shortcut-mongolian-ground-beef", "swap the Shaoxing wine for mirin", ["Swapped Shaoxing wine for mirin"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "use 2 tbsp oil", ["Change neutral oil: ¼ cup → 2 tbsp"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "remove the dried chili peppers", ["Leave out dried red chili peppers"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "next time use more garlic", ["More garlic: 3 cloves → 3 ¾ cloves"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "marinate the beef for 10 minutes",
         ["Step 1: Combine the ground beef, Shaoxing wine, soy sauce and baking soda in a medium bowl. Leave the beef to marinate for 10 minutes while you prep the other ingredients. (Or if making ahead, cover and refrigerate overnight.)"]),
        // Chow mein.
        ("recipetineats-chow-mein", "replace the chicken with prawns", ["Swapped chicken breast or thigh fillets for prawns"]),
        ("recipetineats-chow-mein", "use half the sugar", ["Half the sugar: 2 tsp → 1 tsp"]),
        ("recipetineats-chow-mein", "don't add the bean sprouts", ["Leave out bean sprouts"]),
        ("recipetineats-chow-mein", "stir fry the chicken for 3 minutes",
         ["Step 7: Add chicken and stir fry until lightly browned outside but still raw in the middle - about 3 minutes."]),
        // Kung pao chicken.
        ("wikibooks-kung-pao-chicken", "swap the sherry for mirin", ["Swapped sherry or rice wine for mirin"]),
        ("wikibooks-kung-pao-chicken", "reduce the oil to 2 tbsp", ["Change cooking oil: 4 tbsp → 2 tbsp"]),
        ("wikibooks-kung-pao-chicken", "use less soy sauce and no peanuts", ["Less soy sauce: 2 tbsp → 1 ½ tbsp", "Leave out shelled peanuts"]),
        ("wikibooks-kung-pao-chicken", "cook the sauce 2 minutes longer",
         ["Step 9: Stir sauce and add to wok. After the sauce comes to a boil, cook for about 3 minutes (until sauce thickens)."]),
        ("wikibooks-kung-pao-chicken", "skip step 1 and cook the chicken 10 minutes on high",
         ["Remove step 1", "Step 7: Add chicken mixture to wok and stir fry on high for about 10 minutes (until chicken is cooked through)."]),
    ]

    @Test(arguments: cases.indices)
    func instruction(_ i: Int) throws {
        let c = Self.cases[i]
        let recipe = try StepFixtures.recipe(c.fixture)
        let analysis = FeedbackParser().analyse(c.text, recipe: recipe)
        #expect(analysis.edits.map { $0.summary(in: recipe) } == c.expect, "\(c.fixture): \(c.text)")
        #expect(analysis.servings == nil)
    }

    @Test func severalInstructionsInOneSentence() throws {
        let recipe = try StepFixtures.pepperChicken()
        let analysis = FeedbackParser().analyse("use 2 tbsp oil, no green chillies and cook the chicken 10 min on high", recipe: recipe)
        #expect(analysis.edits.map { $0.summary(in: recipe) } == ["Change oil: 2 ½ tbsp → 2 tbsp", "Leave out green chillies", Self.pepperStep7High])
        #expect(analysis.otherFeedback == "use 2 tbsp oil, no green chillies")
    }

    @Test func amountChangeKeepsTheIngredientAndItsSteps() throws {
        let recipe = try StepFixtures.pepperChicken()
        let edits = FeedbackParser.edits(from: "use 2 tbsp oil", recipe: recipe)
        let applied = recipe.applying(edits)
        let oil = try #require(applied.ingredients.first { $0.name == "oil" })
        #expect(oil.quantity == 2 && oil.unit == "tbsp")
        #expect(applied.ingredients.count == recipe.ingredients.count)
        #expect(applied.steps == recipe.steps)
        // Saying what the recipe already says changes nothing (kept as a note, like any unmatched text).
        #expect(FeedbackParser.edits(from: "use 2 1/2 tbsp oil", recipe: recipe) == [.addNote("Use 2 1/2 tbsp oil")])
    }

    @Test func servingsAreUnderstoodButNotAnEdit() throws {
        let recipe = try StepFixtures.recipe("wikibooks-kung-pao-chicken")
        for (text, n) in [("make it serve 6", 6), ("please make it for four people", 4), ("scale it to 8 servings", 8), ("change servings to 2", 2)] {
            let analysis = FeedbackParser().analyse(text, recipe: recipe)
            #expect(analysis.servings == n, "\(text)")
            #expect(analysis.edits.isEmpty, "\(text): \(analysis.edits)")
            #expect(analysis.otherFeedback.isEmpty, "the model isn't asked about servings")
        }
        let mixed = FeedbackParser().analyse("make it serve 6, and no peanuts", recipe: recipe)
        #expect(mixed.servings == 6)
        #expect(mixed.edits.map { $0.summary(in: recipe) } == ["Leave out shelled peanuts"])
    }

    @Test func reportsOfACookAreUnchanged() throws {
        let recipe = try StepFixtures.recipe("recipetineats-chow-mein")
        // "added … at the end" is still a remark, not a new ingredient line.
        #expect(FeedbackParser.edits(from: "added lime at the end", recipe: recipe) == [.addNote("Added lime at the end")])
        // A product named after an ingredient isn't that ingredient.
        #expect(FeedbackParser.edits(from: "no peanuts", recipe: recipe) == [.addNote("No peanuts")])
        #expect(FeedbackParser.edits(from: "cut the chicken to bite-size pieces", recipe: recipe) == [.addNote("Cut the chicken to bite-size pieces")])
    }
}
