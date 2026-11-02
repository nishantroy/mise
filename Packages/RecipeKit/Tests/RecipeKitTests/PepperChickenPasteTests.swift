import Foundation
import Testing
@testable import RecipeKit

/// The owner's "Paste my version" of Pepper Chicken (fixture `pepper-chicken-my-version.txt`,
/// verbatim) used to come out as 24 steps: the ingredient list followed by the method.
enum PepperChicken {
    static let fixtures = [
        "pepper-chicken-my-version",                        // verbatim: Ingredients/Steps, italic groups, all "- " bullets
        "pepper-chicken-my-version-groups",                 // "For the …" bold groups, Method, numbered bold labels
        "pepper-chicken-my-version-no-ingredients-heading", // "Pepper masala" / "Chicken" groups only, Instructions
        "pepper-chicken-my-version-no-bullets",             // ## headings, no list markers
        "pepper-chicken-my-version-plain",                  // no markdown, no headings, no blank lines
    ]

    static let ingredients = [
        "1 ¾|tbsp|black peppercorns||black-pepper",
        "1|tsp|cumin seeds||cumin-seeds",
        "1|lb|bone-in chicken|450 g, or boneless thighs|chicken",
        "2 ½|tbsp|oil|coconut oil preferred|neutral-oil",
        "½|tsp|cumin seeds|for tempering, optional|cumin-seeds",
        "2||medium onions|thinly sliced, ~270 g|onion",
        "3||green chillies|slit|green-chili",
        "1|sprig|curry leaves||curry-leaves",
        "1 ¾|tbsp|ginger garlic paste||ginger-garlic-paste",
        "1|tsp|turmeric powder|scant|turmeric",
        "1 ¾|tbsp|coriander powder||coriander-powder",
        "1 ¾|tsp|garam masala||garam-masala",
        "||Salt|to taste|salt",
        "1|tsp|lemon juice||lemon-juice",
        "||Cilantro|to garnish|cilantro",
    ]

    static let steps = [
        "Toast: Dry pan, medium-low heat. Toast peppercorns and cumin 1–2 min until fragrant. Don't let them smoke.",
        "Grind: Cool completely, then grind coarse. Set aside.",
        "Temper: Heat oil in a kadai. Add cumin seeds and let them sizzle (or skip).",
        "Onions: Add onions, curry leaves, green chillies. Sauté 5–10 min until light golden.",
        "Aromatics: Add ginger garlic paste. Sauté 1–2 min until the raw smell goes.",
        "Spices: Lower heat. Add turmeric, coriander powder, garam masala, salt. Stir 20–30 sec.",
        "Chicken: Add chicken and coat well. Cover and cook on low 25–35 min until tender (boneless: ~15–20 min). No water needed.",
        "Dry out: Uncover, raise heat, cook until the masala clings to the chicken.",
        "Finish: Toss in the pepper masala (keep a pinch back to adjust), then lemon juice and cilantro.",
        "Serve: With rice, roti, or naan.",
    ]

    static func describe(_ ing: Ingredient) -> String {
        [ing.quantity.map { QuantityFormatter.string(from: $0, unit: ing.unit) } ?? "", ing.unit ?? "", ing.name, ing.note ?? "", ing.catalogID ?? ""]
            .joined(separator: "|")
    }

    /// The saved recipe before the paste (yummytummyaarthi.com, fennel already swapped to cumin seeds).
    static func original() -> Recipe {
        let lines = [
            "0.5 kg chicken", "3 tbsp oil", "1 tsp cumin seeds", "2 large onions", "3 green chilli", "1 sprig curry leaves",
            "2 tbsp ginger garlic paste", "1 tsp turmeric", "2 tbsp coriander powder", "2 tsp garam masala", "salt",
            "2 tbsp black pepper", "1 tsp lemon juice", "coriander leaves",
        ]
        let steps = (1...10).map { "Original step \($0)." }
        return IngredientCatalog.shared.annotate(Recipe(title: "Pepper Chicken", servings: 4,
                                                        ingredients: lines.map(IngredientLineParser.parse), steps: steps))
    }
}

@Suite("Pasted write-ups with an ingredient list")
struct PepperChickenParseTests {
    @Test(arguments: PepperChicken.fixtures)
    func everyVariantSplitsIngredientsFromSteps(_ name: String) throws {
        let text = try Fixture.text(name)
        let pasted = try #require(RecipeImporter.parsePasted(text: text))
        #expect(!pasted.ingredientsFromSteps)  // listed: deterministic, no model assembly
        #expect(pasted.recipe.ingredients.map(PepperChicken.describe) == PepperChicken.ingredients)
        #expect(pasted.recipe.steps == PepperChicken.steps)
        #expect(pasted.recipe.notes.isEmpty)
        #expect(!StepStyleParser.stepsLookLikeIngredients(pasted.recipe.steps))
    }

    @Test func theOwnersPasteVerbatim() throws {
        let text = try Fixture.text("pepper-chicken-my-version")
        let analysis = try #require(StepStyleParser.analyse(text: text))
        // The opening line is commentary: not the title, not a step, not a note.
        #expect(analysis.title == "")
        #expect(analysis.dropped == ["A pound is about 450 g, so this is roughly 90% of the original.", "Small tweaks only."])
        #expect(analysis.servings == 3)
        #expect(analysis.servingsRange == 3...4)
        #expect(analysis.ingredients.contains("Salt to taste"))
        #expect(!analysis.ingredients.contains { $0.contains("masala:") || $0 == "Chicken:" })
        let pasted = try #require(RecipeImporter.parsePasted(text: text))
        #expect(pasted.recipe.title == "Untitled recipe")
        #expect(pasted.servingsRange == 3...4)
    }

    @Test func titledVariantsKeepTheirTitleAndServings() throws {
        let groups = try #require(StepStyleParser.analyse(text: Fixture.text("pepper-chicken-my-version-groups")))
        #expect(groups.title == "Pepper Chicken")
        #expect(groups.servings == 4)
        #expect(groups.servingsRange == nil)
        let plain = try #require(StepStyleParser.analyse(text: Fixture.text("pepper-chicken-my-version-plain")))
        #expect(plain.title == "Pepper Chicken")
        #expect(plain.servings == 4)
    }

    @Test func ingredientLineShapes() {
        for line in ["1¾ tbsp black peppercorns", "Scant 1 tsp turmeric powder", "2–3 green chillies, slit",
                     "2 medium onions (~270 g), thinly sliced", "Salt to taste", "Cilantro to garnish", "Cilantro",
                     "a handful of cilantro", "1 lb (450 g) bone-in chicken (or boneless thighs)"] {
            #expect(StepStyleParser.isBareIngredientLine(line), "\(line)")
        }
        for line in PepperChicken.steps + ["Slice ½ onion, 1 green bell pepper.", "Add 1 lb lean ground beef with ½ tsp salt.",
                                            "Serve hot", "With rice, roti, or naan.", "2–3 min until golden"] {
            #expect(!StepStyleParser.isBareIngredientLine(line), "\(line)")
        }
    }

    @Test func theBadSavedStepsLookLikeIngredients() {
        // What was saved on the device: the 14 listed lines, then the method.
        let saved = [
            "1¾ tbsp black peppercorns", "1 tsp cumin seeds", "1 lb (450 g) bone-in chicken (or boneless thighs)",
            "2½ tbsp oil (coconut oil preferred)", "½ tsp cumin seeds (for tempering, optional)",
            "2 medium onions (~270 g), thinly sliced", "2–3 green chillies, slit", "1 sprig curry leaves",
            "1¾ tbsp ginger garlic paste", "Scant 1 tsp turmeric powder", "1¾ tbsp coriander powder", "1¾ tsp garam masala",
            "1 tsp lemon juice", "Cilantro to garnish",
        ] + PepperChicken.steps
        #expect(saved.filter(StepStyleParser.isBareIngredientLine).count == 14)
        #expect(StepStyleParser.stepsLookLikeIngredients(saved))
    }

    @Test func mongolianBeefStepsAreStillSteps() throws {
        for name in ["mongolian-beef-my-version", "mongolian-beef-my-version-markdown"] {
            let pasted = try #require(RecipeImporter.parsePasted(text: Fixture.text(name)))
            #expect(pasted.ingredientsFromSteps)
            #expect(pasted.recipe.steps.count == 11)
            #expect(!StepStyleParser.stepsLookLikeIngredients(pasted.recipe.steps))
        }
    }

    @Test func plainListsKeepBareNamesAndDropGroupLabels() throws {
        let text = """
        Rice Bowl

        Chicken
        300 g chicken thighs
        1 tbsp soy sauce
        Salt
        1 tsp sesame oil

        Rice
        1 cup rice
        Cilantro
        Cook the rice. Fry the chicken in the sesame oil with the soy sauce.
        Serve the chicken over the rice.
        """
        let analysis = try #require(StepStyleParser.analyse(text: text))
        #expect(analysis.ingredients == ["300 g chicken thighs", "1 tbsp soy sauce", "Salt", "1 tsp sesame oil", "1 cup rice", "Cilantro"])
        #expect(analysis.steps == ["Cook the rice. Fry the chicken in the sesame oil with the soy sauce.", "Serve the chicken over the rice."])
    }

    @Test func anIngredientsHeadingWithoutAMethodHeading() throws {
        let text = """
        Plain Rice
        Ingredients (serves 2)
        - 1 cup rice
        - 2 cups water
        - Salt
        - Rinse the rice.
        - Simmer covered for 15 minutes.
        """
        let pasted = try #require(RecipeImporter.parsePasted(text: text))
        #expect(pasted.recipe.ingredients.map(\.name) == ["rice", "water", "Salt"])
        #expect(pasted.recipe.steps == ["Rinse the rice.", "Simmer covered for 15 minutes."])
        #expect(pasted.recipe.servings == 2)
    }
}

@Suite("Model assembly of a write-up with an ingredient list")
struct PepperChickenAssemblyTests {
    @Test func modelStepsThatRepeatTheIngredientListAreRejected() throws {
        let text = try Fixture.text("pepper-chicken-my-version")
        let rules = try #require(RecipeImporter.parsePasted(text: text)).recipe
        let listed = rules.ingredients.map(\.raw)
        // A model that copies the list into the method, as the rules used to.
        let bad = ProposedRecipe(servings: 4, ingredients: ["1 lb chicken"], steps: listed + PepperChicken.steps)
        let result = RecipeAssembly.merge(bad, text: text, rules: rules)
        #expect(!result.usedModelSteps)
        #expect(result.recipe.steps == PepperChicken.steps)
        // Listed ingredients are the cook's own; the model's list is never used for them.
        #expect(!result.usedModelIngredients)
        #expect(result.recipe.ingredients.map(PepperChicken.describe) == PepperChicken.ingredients)

        let good = ProposedRecipe(servings: 4, steps: PepperChicken.steps)
        #expect(RecipeAssembly.merge(good, text: text, rules: rules).usedModelSteps)
    }

    @Test func oneIngredientLineAmongModelStepsIsEnough() throws {
        let text = try Fixture.text("mongolian-beef-my-version-markdown")
        let rules = try #require(RecipeImporter.parsePasted(text: text)).recipe
        #expect(RecipeAssembly.validSteps(rules.steps, source: rules.steps, prose: []) != nil)
        #expect(RecipeAssembly.validSteps(["1 tbsp Lao Gan Ma"] + rules.steps, source: rules.steps, prose: []) == nil)
    }
}
