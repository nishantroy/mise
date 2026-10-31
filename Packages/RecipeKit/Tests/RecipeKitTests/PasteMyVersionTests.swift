import Foundation
import Testing
@testable import RecipeKit

@Suite("Step-style parsing")
struct StepStyleParsingTests {
    @Test func parsesTheUsersVersion() throws {
        let text = try Fixture.text("mongolian-beef-my-version")
        let pasted = try #require(RecipeImporter.parsePasted(text: text))
        let recipe = pasted.recipe
        #expect(pasted.ingredientsFromSteps)
        #expect(recipe.title == "Mongolian Ground Beef")
        #expect(recipe.servings == 4)

        // Steps are the user's lines, verbatim; the section labels are dropped.
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let expectedSteps = lines.dropFirst().filter { !["Prep first", "Sauce", "Cook"].contains($0) }
        #expect(recipe.steps == Array(expectedSteps))
        #expect(recipe.steps.count == 11)

        let got = recipe.ingredients.map { ing in
            [ing.quantity.map { QuantityFormatter.string(from: $0, unit: ing.unit) } ?? "", ing.unit ?? "", ing.name, ing.note ?? "", ing.catalogID ?? ""]
                .joined(separator: "|")
        }
        #expect(got == [
            "½||onion||onion",
            "1||green bell pepper||bell-pepper",
            "2||Fresnos|in rings|fresno-chili",
            "1||Thai chili|optional|green-chili",
            "3||green onions||scallion",
            "1|handful|cilantro||cilantro",
            "¼|tsp|Sichuan peppercorn|optional|sichuan-peppercorns",
            "1 ½|tbsp|ginger garlic paste||ginger-garlic-paste",
            "1|tbsp|Lao Gan Ma||chili-oil",
            "¼|cup|soy sauce|or tamari|soy-sauce",
            "¼|cup|water||water",
            "3|tbsp|sugar||sugar",
            "1|tbsp|sherry||dry-sherry",
            "1|tsp|sesame oil||sesame-oil",
            "1|tsp|cornstarch|if using|cornstarch",
            "1|tbsp|oil||neutral-oil",
            "1|lb|lean ground beef||beef",
            "½|tsp|salt||salt",
            "1|tsp|rice vinegar||rice-vinegar",
        ])
    }

    @Test func pastingAsANewRecipe() throws {
        let text = """
        Garlic Noodles - serves 2

        1. Boil 200 g noodles for 4 minutes.
        2. Fry 4 cloves garlic in 2 tbsp butter, then add 1 tbsp soy sauce and a pinch of sugar.
        Serve hot
        """
        let recipe = try #require(RecipeImporter.parse(text: text))
        #expect(recipe.title == "Garlic Noodles")
        #expect(recipe.servings == 2)
        #expect(recipe.steps == [
            "Boil 200 g noodles for 4 minutes.",
            "Fry 4 cloves garlic in 2 tbsp butter, then add 1 tbsp soy sauce and a pinch of sugar.",
            "Serve hot",  // a closing line is never taken for a section label
        ])
        #expect(recipe.ingredients.map(\.name) == ["noodles", "garlic", "butter", "soy sauce", "sugar"])
        #expect(recipe.ingredients.first { $0.name == "garlic" }?.unit == "clove")
        #expect(recipe.ingredients.first { $0.name == "butter" }?.quantity == 2)
    }

    @Test func classicPasteIsUnchanged() throws {
        let text = """
        Toast
        Ingredients
        2 slices bread
        1 tbsp butter
        Method
        Toast the bread.
        """
        let pasted = try #require(RecipeImporter.parsePasted(text: text))
        #expect(!pasted.ingredientsFromSteps)
        #expect(pasted.recipe.ingredients.count == 2)
    }

    @Test func proseIsNotARecipe() {
        #expect(RecipeImporter.parse(text: "Hello\nIt was a lovely day and we went for 2 hours to the beach.") == nil)
        #expect(RecipeImporter.parse(text: "Just a title") == nil)
    }

    @Test func rejectsTimesAndSizes() {
        let found = StepIngredientExtractor.extract(from: [
            "Cut 2 chicken breasts into 2-inch pieces and cook for 3–4 min at 200°C.",
            "Simmer 10 minutes, then add 1 cup stock.",
        ])
        #expect(found.map(\.name) == ["chicken breasts", "stock"])
    }

    @Test func markdownFromChatApps() throws {
        let text = """
        # **Quick Dal** (serves 3)
        ## Cook
        - Rinse 1 cup red lentils and boil with 3 cups water.
        - Stir in 1 tsp turmeric and 1 tsp salt.
        """
        let recipe = try #require(RecipeImporter.parse(text: text))
        #expect(recipe.title == "Quick Dal")
        #expect(recipe.servings == 3)
        #expect(recipe.steps.count == 2)
        #expect(recipe.ingredients.map(\.name) == ["red lentils", "water", "turmeric", "salt"])
    }
}

@Suite("Model ingredient extraction mapping")
struct ModelIngredientLinesTests {
    let steps = [
        "Chop 3 green onions and a handful of cilantro.",
        "Whisk ¼ cup soy sauce or tamari with 3 tbsp sugar.",
    ]

    @Test func keepsGroundedLines() {
        let mapped = ModelIngredientLines.map([
            "3 green onions", "- 1 handful cilantro", "¼ cup soy sauce or tamari", "3 tbsp sugar",
        ], steps: steps)
        #expect(mapped.map(\.name) == ["green onions", "cilantro", "soy sauce", "sugar"])
        #expect(mapped[2].note == "or tamari")
        #expect(mapped[0].catalogID == "scallion")
    }

    @Test func dropsInventedStepLikeAndJunkLines() {
        let mapped = ModelIngredientLines.map([
            "2 tbsp oyster sauce",                       // not in the steps
            "Chop the green onions. Then whisk the sauce.",  // a step, not an ingredient
            "5 min",                                     // a duration
            "1 tbsp",                                    // a bare amount
            "",
            "3 green onions",
            "3 green onions",                            // repeat
            "4 scallions",                               // an alias of something the steps mention
        ], steps: steps)
        #expect(mapped.map(\.name) == ["green onions", "scallions"])
    }

    @Test func fallsBackToRulesWhenTheModelDropsTooMuch() {
        let rules = StepIngredientExtractor.extract(from: steps)
        #expect(rules.count == 4)
        let thin = ModelIngredientLines.map(["3 green onions"], steps: steps)
        #expect(ModelIngredientLines.choose(model: thin, rules: rules) == rules)
        let good = ModelIngredientLines.map(["3 green onions", "1 handful cilantro", "¼ cup soy sauce"], steps: steps)
        #expect(ModelIngredientLines.choose(model: good, rules: rules) == good)
    }
}

@Suite("Recipe diff")
struct RecipeDiffTests {
    func recipe(_ lines: [String], steps: [String] = ["Cook."], title: String = "Test", servings: Int? = nil) -> Recipe {
        IngredientCatalog.shared.annotate(Recipe(title: title, servings: servings, ingredients: lines.map(IngredientLineParser.parse), steps: steps))
    }

    @Test func fixturePair() throws {
        let original = try #require(RecipeImporter.parse(html: Fixture.html("woksoflife-shortcut-mongolian-ground-beef"), url: nil))
        #expect(original.title == "Shortcut Mongolian Ground Beef")
        let mine = try #require(RecipeImporter.parse(text: Fixture.text("mongolian-beef-my-version")))
        let diff = RecipeDiff.compare(current: original, mine: mine)
        #expect(diff.edits.map { $0.summary(in: original) } == [
            "Swapped ginger and garlic for ginger garlic paste",
            "Swapped Shaoxing wine for sherry",
            "Swapped brown sugar for sugar",
            "Leave out soy sauce (1 tsp)",
            "Leave out baking soda",
            "Leave out dark soy sauce",
            "Leave out cornstarch (⅓ cup)",
            "Leave out dried red chili peppers",
            "Less hot water: ¾ cup → ¼ cup",
            "Change cornstarch: 1 tbsp → 1 tsp",
            "Change neutral oil: ¼ cup → 1 tbsp",
            "Less scallions: 4 → 3",
            "Add ½ onion",
            "Add 1 green bell pepper",
            "Add 2 Fresnos",
            "Add 1 Thai chili",
            "Add 1 handful cilantro",
            "Add ¼ tsp Sichuan peppercorn",
            "Add 1 tbsp Lao Gan Ma",
            "Add 1 tsp sesame oil",
            "Add ½ tsp salt",
            "Add 1 tsp rice vinegar",
            "Use your steps (11 steps)",
        ])
        // Only the specialty swap-out is marked missing: using a paste doesn't mean they're out
        // of ginger, garlic or brown sugar.
        #expect(diff.pantryUpdates.map(\.summary) == [
            "Pantry: Shaoxing wine → don't have",
            "Pantry: Sichuan peppercorn → have",
            "Pantry: Ginger garlic paste → have",
            "Pantry: Lao Gan Ma → have",
            "Pantry: Sherry → have",
            "Pantry: Sesame oil → have",
        ])
        #expect(diff.title == "Mongolian Ground Beef")
        #expect(diff.servings == 4)

        // Applying everything gives the user's ingredients (by catalog ID) and steps.
        let applied = original.applying(diff.edits)
        #expect(applied.steps == mine.steps)
        #expect(Set(applied.ingredients.compactMap(\.catalogID)) == Set(mine.ingredients.compactMap(\.catalogID)))
        #expect(applied.ingredients.count == mine.ingredients.count)
        #expect(applied.title == original.title, "the title only changes if the user opts in")
    }

    @Test func gingerGarlicPasteIsOneMultiReplace() {
        let original = recipe(["2 tsp ginger, minced", "3 cloves garlic", "1 tbsp soy sauce"],
                              steps: ["Fry the ginger and garlic.", "Add the soy sauce."])
        let mine = recipe(["1 ½ tbsp ginger garlic paste", "1 tbsp soy sauce"])
        let diff = RecipeDiff.compare(current: original, mine: mine)
        let replaces = diff.edits.filter { if case .replaceIngredients = $0 { true } else { false } }
        #expect(replaces.count == 1)
        #expect(!diff.edits.contains { if case .removeIngredient = $0 { true } else if case .addIngredient = $0 { true } else { false } })
        guard case let .replaceIngredients(ids, with, _) = replaces[0] else { return }
        #expect(ids == [original.ingredients[0].id, original.ingredients[1].id])
        #expect(with.map(\.name) == ["ginger garlic paste"])
        #expect(replaces[0].summary(in: original) == "Swapped ginger and garlic for ginger garlic paste")

        // Applied without the step replacement: the paste takes ginger's place and steps are rewritten.
        let applied = original.applying(replaces)
        #expect(applied.ingredients.map(\.name) == ["ginger garlic paste", "soy sauce"])
        #expect(applied.ingredients[0].quantity == 1.5)
        #expect(applied.steps[0] == "Fry the ginger garlic paste.", "repeats of the new name are collapsed")
    }

    @Test func onlyOneOfASetBecomesASingleReplace() {
        let diff = RecipeDiff.compare(current: recipe(["3 cloves garlic", "1 onion"]), mine: recipe(["1 tbsp ginger garlic paste", "1 onion"]))
        #expect(diff.edits.count == 1)
        guard case .replaceIngredient = diff.edits[0] else { Issue.record("expected a single replace"); return }
    }

    @Test func swapsTablePairing() {
        let original = recipe(["2 tsp Shaoxing wine", "1 tbsp soy sauce", "4 dried chilies"],
                              steps: ["Add the Shaoxing wine and soy sauce."])
        let mine = recipe(["1 tbsp dry sherry", "1 tbsp soy sauce", "2 Fresno chilies"], steps: original.steps)
        let diff = RecipeDiff.compare(current: original, mine: mine)
        #expect(diff.edits.map { $0.summary(in: original) } == [
            "Swapped Shaoxing wine for dry sherry",
            "Leave out dried chilies",  // no swap pairs dried chilies with Fresnos
            "Add 2 Fresno chilies",
        ])
        guard case let .replaceIngredient(_, with, _) = diff.edits[0] else { return }
        #expect(with.first?.quantity == 1)
        #expect(with.first?.unit == "tbsp", "the user's amount, not the original's")
        #expect(original.applying([diff.edits[0]]).steps == ["Add the dry sherry and soy sauce."])
    }

    @Test func swapsTableReadBackwards() {
        // The table lists sugar → … only under brown sugar; the pair still works from sugar to brown sugar.
        let diff = RecipeDiff.compare(current: recipe(["3 tbsp sugar"]), mine: recipe(["3 tbsp brown sugar"]))
        #expect(diff.edits.map { $0.summary(in: recipe(["3 tbsp sugar"])) }.first?.hasPrefix("Swapped") == true)
    }

    @Test func scaleThreshold() {
        let original = recipe(["1 tbsp soy sauce", "2 tbsp sugar", "¼ cup oil", "1 tbsp vinegar", "4 scallions", "1 tsp salt"])
        let mine = recipe(["1.1 tbsp soy sauce", "3 tbsp sugar", "1 tbsp oil", "3 tsp vinegar", "4 scallions", "salt to taste"])
        let diff = RecipeDiff.compare(current: original, mine: mine)
        let sugar = original.ingredients[1].id
        #expect(diff.edits.count == 2)
        #expect(diff.edits[0] == .scaleIngredient(id: sugar, factor: 1.5))         // same unit → scale
        #expect(diff.edits[0].summary(in: original) == "More sugar: 2 tbsp → 3 tbsp")
        #expect(diff.edits[1].summary(in: original) == "Change oil: ¼ cup → 1 tbsp")  // different units → amount change
        // Soy sauce +10% (under 15%), vinegar 1 tbsp = 3 tsp, scallions equal, salt without an amount: no edit.
        let applied = original.applying(diff.edits)
        #expect(applied.ingredients[2].name == "oil")
        #expect(applied.ingredients[2].quantity == 1)
        #expect(applied.ingredients[2].unit == "tbsp")
    }

    @Test func scaleSummaryWording() {
        let r = recipe(["¾ cup water"])
        #expect(RecipeEdit.scaleIngredient(id: r.ingredients[0].id, factor: 1.0 / 3).summary(in: r) == "Less water: ¾ cup → ¼ cup")
        #expect(RecipeEdit.scaleIngredient(id: r.ingredients[0].id, factor: 3).summary(in: r).hasPrefix("More water"))
    }

    @Test func pantryUpdatesSkipWhatThePantryKnows() {
        let original = recipe(["2 tsp Shaoxing wine", "1 tsp sesame oil"])
        let mine = recipe(["2 tsp dry sherry", "1 tsp sesame oil", "1 tbsp fish sauce"])
        let pantry = PantrySnapshot(have: ["sesame-oil"], missing: ["shaoxing-wine", "fish-sauce"])
        let updates = RecipeDiff.compare(current: original, mine: mine, pantry: pantry).pantryUpdates
        // Shaoxing is already missing and sesame oil already "have"; fish sauce was marked missing but they used it.
        #expect(updates.map(\.summary) == ["Pantry: Dry sherry → have", "Pantry: Fish sauce → have"])
        #expect(updates.map(\.key) == ["dry-sherry", "fish-sauce"])
    }

    @Test func titleAndServingsOnlyWhenDifferent() {
        let same = RecipeDiff.compare(current: recipe(["1 onion"], title: "Soup", servings: 2), mine: recipe(["1 onion"], title: "soup", servings: nil))
        #expect(same.title == nil)
        #expect(same.servings == nil)
        #expect(same.edits.isEmpty, "same steps, same ingredients: nothing to do")
    }
}

@Suite("Replace steps and revision compatibility")
struct ReplaceStepsTests {
    @Test func applyAndSummary() {
        let r = Recipe(title: "T", steps: ["Old one.", "Old two."])
        let edit = RecipeEdit.replaceSteps(["New one.", "New two.", "New three."])
        #expect(r.applying([edit]).steps == ["New one.", "New two.", "New three."])
        #expect(edit.summary(in: r) == "Use your steps (3 steps)")
        #expect(RecipeEdit.replaceSteps(["Only."]).summary(in: r) == "Use your steps (1 step)")
    }

    /// Revisions saved by v1 builds (before `replaceIngredients` and `replaceSteps` existed).
    @Test func decodesV1Revisions() throws {
        let json = """
        [{"id":"7B0C3F0A-4F55-4C8B-9E36-0D5E3F5C2A11","date":750000000,"summary":"Cooked it: Less soy sauce",
          "edits":[
            {"scaleIngredient":{"id":"5F1B7B3E-2C1F-4D7A-8B0E-6A2B9C3D4E5F","factor":0.75}},
            {"replaceIngredient":{"id":"5F1B7B3E-2C1F-4D7A-8B0E-6A2B9C3D4E5F","with":[{"id":"1A2B3C4D-1111-2222-3333-444455556666","raw":"2 tbsp dry sherry","quantity":2,"unit":"tbsp","name":"dry sherry","catalogID":"dry-sherry"}],"reason":"Used dry sherry instead of Shaoxing wine"}},
            {"removeIngredient":{"id":"5F1B7B3E-2C1F-4D7A-8B0E-6A2B9C3D4E5F"}},
            {"addIngredient":{"_0":{"id":"1A2B3C4D-1111-2222-3333-444455556667","raw":"1 lime","quantity":1,"name":"lime"}}},
            {"updateStep":{"index":0,"text":"Fry it."}},
            {"addNote":{"_0":"Needed about 10 more minutes than written"}}
          ]},
         {"id":"7B0C3F0A-4F55-4C8B-9E36-0D5E3F5C2A12","date":750000100,"summary":"Reset to original","edits":[]}]
        """
        let revisions = try JSONDecoder().decode([RecipeRevision].self, from: Data(json.utf8))
        #expect(revisions.count == 2)
        #expect(revisions[0].edits.count == 6)
        #expect(revisions[0].edits[0] == .scaleIngredient(id: UUID(uuidString: "5F1B7B3E-2C1F-4D7A-8B0E-6A2B9C3D4E5F")!, factor: 0.75))
        #expect(revisions[0].edits[5] == .addNote("Needed about 10 more minutes than written"))
    }

    @Test func v1EncodingIsUnchanged() throws {
        // The JSON shape of the original cases must stay exactly as v1 wrote it.
        let id = UUID(uuidString: "5F1B7B3E-2C1F-4D7A-8B0E-6A2B9C3D4E5F")!
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode([RecipeEdit.scaleIngredient(id: id, factor: 0.75), .addNote("x")])
        #expect(String(decoding: data, as: UTF8.self) == #"[{"scaleIngredient":{"factor":0.75,"id":"5F1B7B3E-2C1F-4D7A-8B0E-6A2B9C3D4E5F"}},{"addNote":{"_0":"x"}}]"#)
    }

    @Test func newCasesRoundTrip() throws {
        let edits: [RecipeEdit] = [
            .replaceSteps(["One.", "Two."]),
            .replaceIngredients(ids: [UUID(), UUID()], with: [IngredientLineParser.parse("1 tbsp ginger garlic paste")], reason: "r"),
        ]
        let revision = RecipeRevision(summary: "Your version", edits: edits)
        let decoded = try JSONDecoder().decode(RecipeRevision.self, from: JSONEncoder().encode(revision))
        #expect(decoded == revision)
    }
}

@Suite("Title matching")
struct TitleMatcherTests {
    @Test func bestMatchFirst() throws {
        let text = try Fixture.text("mongolian-beef-my-version")
        #expect(TitleMatcher.title(ofPasted: text) == "Mongolian Ground Beef")
        let titles = ["Chow Mein", "Chairman Mao’s Red Braised Pork Belly", "Shortcut Mongolian Ground Beef", "Beef and Broccoli"]
        let ranked = TitleMatcher.ranked(titles, title: { $0 }, against: text)
        #expect(ranked.first == "Shortcut Mongolian Ground Beef")
        #expect(ranked[1] == "Beef and Broccoli")
        #expect(TitleMatcher.score("Chow Mein", "Mongolian Ground Beef") == 0)
    }
}
