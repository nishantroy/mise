import Foundation
import Testing
@testable import RecipeKit

/// Regression tests for the code-review findings, using the exact repro inputs.
@Suite("Review fixes")
struct ReviewRegressionTests {
    let catalog = IngredientCatalog.shared

    func recipe(_ lines: [String], steps: [String] = []) -> Recipe {
        catalog.annotate(Recipe(title: "R", ingredients: lines.map(IngredientLineParser.parse), steps: steps))
    }

    func swap(_ r: Recipe, _ index: Int, to items: [(String, String)]) -> Recipe {
        let s = SwapSuggestion(items: items.map { .init(catalogID: $0.0, name: $0.1) }, quality: .good, note: "")
        return r.applying([s.edit(for: r.ingredients[index])])
    }

    // MARK: #1 step rewriting in one pass

    @Test func vegetableOilToOliveOil() {
        let r = recipe(["2 tbsp vegetable oil"], steps: ["Heat the vegetable oil.", "Add a little more oil."])
        #expect(swap(r, 0, to: [("olive-oil", "olive oil")]).steps == ["Heat the olive oil.", "Add a little more olive oil."])
    }

    @Test func wholeMilkToCoconutMilkAndWater() {
        let r = recipe(["1 cup whole milk"], steps: ["Pour in the whole milk.", "Simmer the milk gently."])
        let out = swap(r, 0, to: [("coconut-milk", "coconut milk"), ("water", "water")])
        #expect(out.steps == ["Pour in the coconut milk and water.", "Simmer the coconut milk and water gently."])
    }

    @Test func sugarGingerPaprika() {
        let sugar = recipe(["1 tbsp white sugar"], steps: ["Add the white sugar and stir until the sugar dissolves."])
        #expect(swap(sugar, 0, to: [("brown-sugar", "brown sugar")]).steps == ["Add the brown sugar and stir until the brown sugar dissolves."])
        let ginger = recipe(["1 tbsp ginger"], steps: ["Fry the ginger."])
        #expect(swap(ginger, 0, to: [("ground-ginger", "ground ginger")]).steps == ["Fry the ground ginger."])
        let paprika = recipe(["1 tsp paprika"], steps: ["Sprinkle with paprika."])
        #expect(swap(paprika, 0, to: [("smoked-paprika", "smoked paprika")]).steps == ["Sprinkle with smoked paprika."])
    }

    @Test func onionToShallotsKeepsSpringOnions() {
        let r = recipe(["1 onion", "2 spring onions"], steps: ["Fry the onion, then add the spring onions."])
        #expect(swap(r, 0, to: [("shallot", "shallots")]).steps == ["Fry the shallots, then add the spring onions."])
    }

    // MARK: #2 matching picks the wrong ingredient

    let chickenRecipe: Recipe = IngredientCatalog.shared.annotate(Recipe(title: "Teriyaki", ingredients: [
        "500 g chicken thighs", "1 cup rice", "3 tbsp soy sauce", "1 tbsp honey",
    ].map(IngredientLineParser.parse)))

    func edits(_ text: String, _ r: Recipe? = nil) -> [RecipeEdit] { FeedbackParser.edits(from: text, recipe: r ?? chickenRecipe) }

    @Test(arguments: [
        "Didn't have time to marinate the chicken",
        "Forgot to rest the chicken",
        "No rice cooker so I used a pot",
        "No sauce left over",
    ])
    func noSpuriousRemovals(_ text: String) {
        let e = edits(text)
        #expect(!e.contains { if case .removeIngredient = $0 { true } else { false } }, "\(e)")
        #expect(e.allSatisfy { if case .addNote = $0 { true } else { false } })
        #expect(!e.isEmpty, "kept as a note")
    }

    @Test func moreFishSauceIsNotMoreSoySauce() {
        let e = edits("more fish sauce")
        #expect(!e.contains { $0.targetID == chickenRecipe.ingredients[2].id }, "\(e)")
    }

    @Test func modelRemoveFishSauceDoesNotRemoveSoySauce() {
        #expect(ProposedEdit(kind: .remove, ingredient: "fish sauce").map(in: chickenRecipe) == nil)
    }

    @Test func genericCatalogNameStillFindsSpecificIngredient() {
        #expect(edits("skipped the chicken") == [.removeIngredient(id: chickenRecipe.ingredients[0].id)])
    }

    // MARK: #3 negation and context in taste rules

    @Test(arguments: ["Perfect, not too spicy", "It wasn't too salty at all", "Not too sweet, just right", "Not bland at all"])
    func negatedTasteIsNoEditAndNoNote(_ text: String) {
        let r = recipe(["2 green chilies", "1 tsp salt", "1 tbsp sugar"])
        #expect(FeedbackParser.edits(from: text, recipe: r).isEmpty)
    }

    @Test func hotPanIsNotSpicy() {
        let r = recipe(["2 green chilies", "3 cloves garlic"])
        let e = FeedbackParser.edits(from: "The pan was too hot and the garlic burned", recipe: r)
        #expect(!e.contains { if case .scaleIngredient = $0 { true } else { false } })
        #expect(e.contains { if case .addNote(let n) = $0 { n.contains("garlic burned") } else { false } }, "\(e)")
    }

    @Test func leftoverOfTasteClauseIsKept() {
        let r = recipe(["1 tsp salt", "3 cloves garlic"])
        let e = FeedbackParser.edits(from: "It was too salty and the garlic burned", recipe: r)
        #expect(e == [.scaleIngredient(id: r.ingredients[0].id, factor: 0.75), .addNote("The garlic burned")])
    }

    // MARK: #4 hyphenated mixed numbers

    @Test func hyphenatedMixedNumbers() {
        #expect(IngredientLineParser.parse("1-1/2 cups flour").quantity == 1.5)
        #expect(IngredientLineParser.parse("1-1/2 cups flour").name == "flour")
        #expect(IngredientLineParser.parse("2-1/4 tsp yeast").quantity == 2.25)
        #expect(IngredientLineParser.parse("1-2 cups flour").quantity == 2)
    }

    // MARK: #5 false diet and allergen conflicts

    @Test func qualifiersAndNewEntriesAvoidFalseConflicts() {
        let prefs = UserPreferences(diet: .vegan, avoid: [.gluten])
        let r = recipe(["1 cup gluten-free flour", "1 cup rice flour", "2 tbsp gluten-free soy sauce", "1 cup soy milk",
                        "1 cup oat milk", "2 tbsp vegan butter", "2 tbsp vegan mayonnaise"])
        let items = SwapEngine().review(recipe: r, pantry: PantrySnapshot(have: Set(r.ingredients.compactMap(\.catalogID))), prefs: prefs)
        #expect(items.isEmpty, "\(items.map { ($0.ingredient.name, $0.kind) })")
        // Unqualified versions still conflict.
        let plain = recipe(["1 cup flour", "2 tbsp butter", "1 cup milk"])
        #expect(SwapEngine().review(recipe: plain, pantry: .empty, prefs: prefs).count == 3)
    }

    @Test func exactMatchForPantryEntries() {
        #expect(catalog.exactMatch("soy milk")?.id == "soy-milk")
        #expect(catalog.exactMatch("fresh ginger")?.id == "ginger")
        #expect(catalog.exactMatch("almond butter") == nil)
        #expect(catalog.exactMatch("smoked salt") == nil)
    }

    // MARK: #6 "added X at the end"

    @Test(arguments: ["I added the garlic at the end", "Added the noodles too early"])
    func addedWithTimingIsANote(_ text: String) {
        let r = recipe(["3 cloves garlic", "200 g egg noodles"])
        let e = FeedbackParser.edits(from: text, recipe: r)
        #expect(e.count == 1)
        guard case .addNote = e.first else { Issue.record("expected a note, got \(e)"); return }
    }

    @Test func addedJustTheNameIsMore() {
        let r = recipe(["3 cloves garlic"])
        #expect(FeedbackParser.edits(from: "I added the garlic", recipe: r) == [.scaleIngredient(id: r.ingredients[0].id, factor: 1.25)])
    }

    // MARK: #9 splitter

    @Test func decimalsAreNotSentenceBreaks() {
        #expect(FeedbackParser.sentences("Used 1.5 tbsp soy sauce") == ["Used 1.5 tbsp soy sauce"])
        let r = recipe(["2 tbsp soy sauce"])
        guard case .replaceIngredient(_, let with, _) = FeedbackParser.edits(from: "Used 1.5 tbsp tamari instead of soy sauce", recipe: r).first else {
            Issue.record("expected replace"); return
        }
        #expect(with.first?.quantity == 1.5)
    }

    @Test func soOnlySplitsBeforeAClause() {
        #expect(FeedbackParser.clauses("It was so good") == ["It was so good"])
        #expect(FeedbackParser.clauses("It was flat so I added lime") == ["It was flat", "I added lime"])
        #expect(FeedbackParser.edits(from: "It was so good", recipe: chickenRecipe).isEmpty)
    }
}
