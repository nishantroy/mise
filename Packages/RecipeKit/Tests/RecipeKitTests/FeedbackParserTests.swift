import Foundation
import Testing
@testable import RecipeKit

@Suite("Feedback parser")
struct FeedbackParserTests {
    let recipe: Recipe = IngredientCatalog.shared.annotate(Recipe(title: "Stir fry", servings: 2, ingredients: [
        "500 g chicken breast",
        "2 tbsp soy sauce",
        "Salt to taste",
        "3 cloves garlic",
        "2 green chilies",
        "1 tbsp sugar",
        "1 bunch cilantro",
        "1 tsp sesame oil",
    ].map(IngredientLineParser.parse), steps: ["Fry the chicken breast.", "Add soy sauce."]))

    func id(_ name: String) -> UUID { recipe.ingredients.first { $0.name == name }!.id }
    func edits(_ text: String) -> [RecipeEdit] { FeedbackParser.edits(from: text, recipe: recipe) }

    // MARK: Replace

    @Test func usedInsteadOf() throws {
        let e = edits("Used chicken thighs instead of breast")
        #expect(e.count == 1)
        guard case let .replaceIngredient(target, with, _) = try #require(e.first) else { Issue.record("not replace"); return }
        #expect(target == id("chicken breast"))
        #expect(with.first?.name == "chicken thighs")
        #expect(with.first?.catalogID == "chicken-thigh")
        // Amendment 7: keeps the original quantity and unit.
        #expect(with.first?.quantity == 500)
        #expect(with.first?.unit == "g")
    }

    @Test func replacedWith() {
        guard case let .replaceIngredient(target, with, _) = edits("Replaced the soy sauce with tamari").first else { Issue.record("not replace"); return }
        #expect(target == id("soy sauce"))
        #expect(with.map(\.name) == ["tamari"])
        #expect(with.first?.quantity == 2)
    }

    @Test func subbedFor() {
        guard case let .replaceIngredient(target, with, _) = edits("subbed honey for the sugar").first else { Issue.record("not replace"); return }
        #expect(target == id("sugar"))
        #expect(with.map(\.name) == ["honey"])
    }

    @Test func replacementWithOwnAmount() {
        guard case let .replaceIngredient(_, with, _) = edits("used 1 tsp honey instead of sugar").first else { Issue.record("not replace"); return }
        #expect(with.first?.quantity == 1)
        #expect(with.first?.unit == "tsp")
    }

    // MARK: Remove

    @Test(arguments: ["Skipped the cilantro", "left out cilantro", "Omitted the cilantro", "didn't use cilantro", "No cilantro", "Left the cilantro out"])
    func removePatterns(_ text: String) {
        #expect(edits(text) == [.removeIngredient(id: id("cilantro"))])
    }

    @Test func removeList() {
        #expect(edits("skipped the cilantro and sesame oil") == [.removeIngredient(id: id("cilantro")), .removeIngredient(id: id("sesame oil"))])
    }

    @Test(arguments: ["No problem", "no changes", "No issues!", "Nothing else."])
    func noPhrasesIgnored(_ text: String) {
        #expect(edits(text).isEmpty)
    }

    @Test func noUnknownIngredientIsANote() {
        #expect(edits("no rice on the side") == [.addNote("No rice on the side")])
    }

    // MARK: Add

    @Test func addedNew() throws {
        let e = edits("Added a squeeze of lime")
        guard case let .addIngredient(ing) = try #require(e.first) else { Issue.record("not add"); return }
        #expect(ing.name == "lime")
        #expect(ing.catalogID == "lime")
    }

    @Test func threwIn() {
        guard case let .addIngredient(ing) = edits("threw in 1 cup peas").first else { Issue.record("not add"); return }
        #expect(ing.quantity == 1)
        #expect(ing.name == "peas")
    }

    @Test func addedExistingBecomesMore() {
        #expect(edits("added more garlic") == [.scaleIngredient(id: id("garlic"), factor: 1.25)])
    }

    // MARK: Scale

    @Test(arguments: [("less soy sauce", 0.75), ("Cut back on the soy sauce", 0.75), ("too much soy sauce", 0.75),
                      ("half the soy sauce", 0.5), ("more soy sauce", 1.25), ("extra soy sauce", 1.25),
                      ("not enough soy sauce", 1.25), ("double the soy sauce", 2.0)])
    func scalePatterns(_ text: String, _ factor: Double) {
        #expect(edits(text) == [.scaleIngredient(id: id("soy sauce"), factor: factor)])
    }

    @Test func tooSalty() {
        // Amendment 6: salt has no quantity, so it becomes a note.
        #expect(edits("It was too salty") == [.scaleIngredient(id: id("soy sauce"), factor: 0.75), .addNote("Use less salt than last time")])
    }

    @Test func tooSpicy() {
        #expect(edits("way too spicy") == [.scaleIngredient(id: id("green chilies"), factor: 0.5)])
        #expect(edits("Too hot for the kids") == [.scaleIngredient(id: id("green chilies"), factor: 0.5)])
    }

    @Test func blandOrNotSpicyEnough() {
        #expect(edits("Not spicy enough") == [.scaleIngredient(id: id("green chilies"), factor: 1.5)])
        #expect(edits("a bit bland") == [.scaleIngredient(id: id("green chilies"), factor: 1.5)])
    }

    @Test func tooSweet() {
        #expect(edits("too sweet") == [.scaleIngredient(id: id("sugar"), factor: 0.75)])
    }

    @Test func tasteWithoutTargetsIsANote() {
        let plain = Recipe(title: "Rice", ingredients: [IngredientLineParser.parse("1 cup rice")])
        #expect(FeedbackParser.edits(from: "too spicy", recipe: plain) == [.addNote("Make it milder next time")])
    }

    @Test func scaleWithoutQuantityIsANote() {
        #expect(edits("more salt") == [.addNote("Use more salt than last time")])
    }

    // MARK: Time

    @Test(arguments: ["needed 10 more minutes", "Cooked it 10 extra minutes", "it needed another 10 minutes"])
    func extraTime(_ text: String) {
        #expect(edits(text) == [.addNote("Needed about 10 more minutes than written")])
    }

    @Test func neededMoreTimeChip() {
        #expect(edits("Needed more time") == [.addNote("Needed more time than written")])
    }

    // MARK: Mixed and unmatched

    static let mixed = "Used chicken thighs instead of breast and it was too salty, needed 10 more minutes"

    @Test func mixedSentence() throws {
        let simple = IngredientCatalog.shared.annotate(Recipe(title: "Roast", ingredients: [
            "2 chicken breasts", "1 tsp salt", "3 cloves garlic",
        ].map(IngredientLineParser.parse)))
        let e = FeedbackParser.edits(from: Self.mixed, recipe: simple)
        #expect(e.count == 3, "\(e)")
        guard case .replaceIngredient(let target, let with, _) = e[0] else { Issue.record("first should replace"); return }
        #expect(target == simple.ingredients[0].id)
        #expect(with.first?.quantity == 2)
        #expect(e[1] == .scaleIngredient(id: simple.ingredients[1].id, factor: 0.75))
        #expect(e[2] == .addNote("Needed about 10 more minutes than written"))
    }

    @Test func mixedSentenceOnChowMeinFixture() throws {
        // The fixture the app's UI test imports: chicken breast/thigh, soy + oyster sauce, no salt line.
        let r = try #require(RecipeImporter.parse(html: try Fixture.html("recipetineats-chow-mein"), url: nil))
        let e = FeedbackParser.edits(from: Self.mixed, recipe: r)
        #expect(e.count == 3, "\(e)")
        #expect(e.map { $0.summary(in: r) } == [
            "Swapped chicken breast or thigh fillets for chicken thighs",
            "Less soy sauce: 1 ½ tbsp → 1 ⅛ tbsp",
            "Note: Needed about 10 more minutes than written",
        ])
    }

    @Test func mixedSentenceWithSoyAndSaltToTaste() {
        // "Too salty" scales soy sauce and turns quantity-less salt into a note (amendment 6).
        let e = edits(Self.mixed)
        #expect(e.count == 4)
        #expect(e.contains(.addNote("Use less salt than last time")))
    }

    @Test func replaceBeatsTasteScaleOnSameIngredient() {
        let r = IngredientCatalog.shared.annotate(Recipe(title: "Pork", ingredients: [
            "3 tbsp light soy sauce", "1 tbsp dark soy sauce",
        ].map(IngredientLineParser.parse)))
        let e = FeedbackParser.edits(from: "Too salty. Used light soy sauce instead of dark soy sauce", recipe: r)
        #expect(e.count == 2, "\(e)")
        #expect(e[0] == .scaleIngredient(id: r.ingredients[0].id, factor: 0.75))
        guard case .replaceIngredient(let target, _, _) = e[1] else { Issue.record("replace"); return }
        #expect(target == r.ingredients[1].id)
    }

    @Test func unmatchedBecomesNote() {
        #expect(edits("The kids loved it. Serve with rice") == [.addNote("The kids loved it"), .addNote("Serve with rice")])
    }

    @Test func partlyUnmatchedSentence() {
        let e = edits("Skipped the cilantro but my partner wanted it crispier")
        #expect(e == [.removeIngredient(id: id("cilantro")), .addNote("My partner wanted it crispier")])
    }

    // MARK: Summaries

    @Test func summaries() {
        let wine = IngredientLineParser.parse("½ cup Shaoxing wine")
        let r = Recipe(title: "x", ingredients: [wine, IngredientLineParser.parse("2 tbsp soy sauce")])
        let sherry = Ingredient(raw: "½ cup dry sherry", quantity: 0.5, unit: "cup", name: "dry sherry")
        #expect(RecipeEdit.replaceIngredient(id: wine.id, with: [sherry], reason: nil).summary(in: r) == "Swapped Shaoxing wine for dry sherry")
        #expect(RecipeEdit.scaleIngredient(id: r.ingredients[1].id, factor: 0.75).summary(in: r) == "Less soy sauce: 2 tbsp → 1 ½ tbsp")
        #expect(RecipeEdit.scaleIngredient(id: r.ingredients[1].id, factor: 0.5).summary(in: r) == "Half the soy sauce: 2 tbsp → 1 tbsp")
        #expect(RecipeEdit.scaleIngredient(id: r.ingredients[1].id, factor: 2).summary(in: r) == "Double the soy sauce: 2 tbsp → 4 tbsp")
        #expect(RecipeEdit.removeIngredient(id: wine.id).summary(in: r) == "Leave out Shaoxing wine")
        #expect(RecipeEdit.addIngredient(IngredientLineParser.parse("1 lime")).summary(in: r) == "Add 1 lime")
        #expect(RecipeEdit.addNote("Great").summary(in: r) == "Note: Great")
        #expect(RecipeEdit.updateStep(index: 0, text: "Fry").summary(in: r) == "Step 1: Fry")
        #expect([RecipeEdit.addNote("A"), .addNote("B")].summary(in: r) == "Note: A; Note: B")
    }

    // MARK: Assistant

    @Test func ruleBasedAssistant() async throws {
        let a = RuleBasedAssistant()
        let e = try await a.proposeEdits(recipe: recipe, feedback: "too sweet", prefs: UserPreferences())
        #expect(e == [.scaleIngredient(id: id("sugar"), factor: 0.75)])
        let wine = IngredientCatalog.shared.annotate(IngredientLineParser.parse("2 tbsp Shaoxing wine"))
        let swaps = try await a.suggestSwaps(for: wine, in: recipe, pantry: .empty, prefs: UserPreferences())
        #expect(swaps.first?.id == "dry-sherry")
        #expect(swaps.contains { $0.isLeaveOut })
    }
}
