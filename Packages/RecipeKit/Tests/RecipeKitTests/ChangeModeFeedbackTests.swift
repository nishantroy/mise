import Foundation
import Testing
@testable import RecipeKit

/// "Change recipe" (`FeedbackKind.change`): phrasing doesn't matter. Past tense, statements and
/// questions become the same edits as the imperatives in `ImperativeFeedbackTests`; a note only
/// when asked for, or when nothing could be resolved (then it is marked unresolved).
@Suite("Change mode: any phrasing")
struct ChangeModeFeedbackTests {
    static let pepperStep7 = "Step 7: Chicken: Add chicken and coat well. "
    static let chowStep7 = "Step 7: Add chicken and stir fry until lightly browned outside but still raw in the middle - about 3 minutes."

    /// (fixture, what the cook typed, the proposals' summaries in order).
    static let cases: [(fixture: String, text: String, expect: [String])] = [
        // Pepper chicken (the owner's version).
        ("pepper-chicken", "used 2 tbsp oil", ["Change oil: 2 ½ tbsp → 2 tbsp"]),
        ("pepper-chicken", "2 tbsp oil is enough", ["Change oil: 2 ½ tbsp → 2 tbsp"]),
        ("pepper-chicken", "I cooked the chicken 10 min on high",
         [pepperStep7 + "Cover and cook on high 10 min until tender. No water needed."]),
        ("pepper-chicken", "the chicken only needs 10 minutes",
         [pepperStep7 + "Cover and cook on low 10 min until tender. No water needed."]),
        ("pepper-chicken", "it doesn't need the dry-out step", ["Remove step 8 (Dry out)"]),
        ("pepper-chicken", "can we cook the chicken on high?",
         [pepperStep7 + "Cover and cook on high 25–35 min until tender (boneless: ~15–20 min). No water needed."]),
        ("pepper-chicken", "the chicken should be cooked uncovered",
         [pepperStep7 + "Cook uncovered on low 25–35 min until tender (boneless: ~15–20 min). No water needed."]),
        ("pepper-chicken", "didn't use cilantro", ["Leave out Cilantro"]),
        ("pepper-chicken", "the green chillies aren't needed", ["Leave out green chillies"]),
        ("pepper-chicken", "added lime at the end", ["Add lime (at the end)"]),
        // Salt has no amount here: a note, without "than last time".
        ("pepper-chicken", "it's usually too salty", ["Note: Use less salt"]),
        // Shortcut Mongolian beef.
        ("woksoflife-shortcut-mongolian-ground-beef", "used 2 tbsp oil", ["Change neutral oil: ¼ cup → 2 tbsp"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "more garlic would be good", ["More garlic: 3 cloves → 4 cloves"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "the garlic should be 4 cloves", ["Change garlic: 3 cloves → 4 cloves"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "it's usually too salty",
         ["Less soy sauce: 1 tsp → ¾ tsp", "Less soy sauce: ¼ cup → ⅛ cup", "Less dark soy sauce: 1 tsp → ¾ tsp"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "I'd use mirin instead of the Shaoxing wine", ["Swapped Shaoxing wine for mirin"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "could we leave out the dried chili peppers?", ["Leave out dried red chili peppers"]),
        ("woksoflife-shortcut-mongolian-ground-beef", "the beef only needs to marinate for 10 minutes",
         ["Step 1: Combine the ground beef, Shaoxing wine, soy sauce and baking soda in a medium bowl. Leave the beef to marinate for 10 minutes while you prep the other ingredients. (Or if making ahead, cover and refrigerate overnight.)"]),
        // Chow mein.
        ("recipetineats-chow-mein", "prawns work better than chicken", ["Swapped chicken breast or thigh fillets for prawns"]),
        ("recipetineats-chow-mein", "half the sugar is plenty", ["Half the sugar: 2 tsp → 1 tsp"]),
        ("recipetineats-chow-mein", "the bean sprouts aren't necessary", ["Leave out bean sprouts"]),
        ("recipetineats-chow-mein", "stir fried the chicken for 3 minutes", [chowStep7]),
        ("recipetineats-chow-mein", "the chicken should stir fry for 3 minutes", [chowStep7]),
    ]

    @Test(arguments: cases.indices)
    func phrasing(_ i: Int) throws {
        let c = Self.cases[i]
        let recipe = try StepFixtures.recipe(c.fixture)
        let analysis = FeedbackParser(kind: .change).analyse(c.text, recipe: recipe)
        #expect(analysis.edits.map { $0.summary(in: recipe) } == c.expect, "\(c.fixture): \(c.text)")
        // Only the salt fallback is a note, and it's offered as a choice, not saved silently.
        let notes = analysis.edits.filter { if case .addNote = $0 { true } else { false } }
        #expect(analysis.unresolved.map(\.note) == notes.compactMap { if case let .addNote(n) = $0 { n } else { nil } })
    }

    @Test(arguments: [
        ("note: the kids like it mild", "The kids like it mild"),
        ("add a note that it's better the next day", "It's better the next day"),
        ("remember that the wok must be very hot", "The wok must be very hot"),
        ("Note: use 2 tbsp oil", "Use 2 tbsp oil"),
    ])
    func explicitNotesStayNotes(_ text: String, _ note: String) throws {
        let recipe = try StepFixtures.recipe("recipetineats-chow-mein")
        for kind in [FeedbackKind.change, .cooked] {
            let analysis = FeedbackParser(kind: kind).analyse(text, recipe: recipe)
            #expect(analysis.edits == [.addNote(note)], "\(kind): \(text)")
            #expect(analysis.explicitNotes == [note])
            #expect(analysis.unresolved.isEmpty)
        }
    }

    @Test func severalStatementsInOneSentence() throws {
        let recipe = try StepFixtures.pepperChicken()
        let analysis = FeedbackParser(kind: .change).analyse(
            "used 2 tbsp oil, the chicken only needs 10 minutes and it doesn't need the dry-out step", recipe: recipe)
        #expect(analysis.edits.map { $0.summary(in: recipe) } == [
            "Change oil: 2 ½ tbsp → 2 tbsp",
            Self.pepperStep7 + "Cover and cook on low 10 min until tender. No water needed.",
            "Remove step 8 (Dry out)",
        ])
        #expect(analysis.unresolved.isEmpty)
    }

    @Test func aNoteAndAChangeInOneGo() throws {
        let recipe = try StepFixtures.pepperChicken()
        let analysis = FeedbackParser(kind: .change).analyse("used 2 tbsp oil. Note: serve with roti", recipe: recipe)
        #expect(analysis.edits.map { $0.summary(in: recipe) } == ["Change oil: 2 ½ tbsp → 2 tbsp", "Note: Serve with roti"])
        #expect(analysis.unresolved.isEmpty)
    }

    @Test func unresolvedClausesBecomeChoicesWithTheirLikelyStep() throws {
        let recipe = try StepFixtures.pepperChicken()
        let analysis = FeedbackParser(kind: .change).analyse("2 tbsp oil is enough, and the chicken was a bit dry", recipe: recipe)
        #expect(analysis.edits.map { $0.summary(in: recipe) } == ["Change oil: 2 ½ tbsp → 2 tbsp", "Note: The chicken was a bit dry"])
        let note = try #require(analysis.unresolved.first)
        #expect(analysis.unresolved.count == 1)
        #expect(note.said == "The chicken was a bit dry")
        #expect(note.stepIndex == 6, "the chicken step is pre-selected")
        #expect(note.ingredientID.flatMap { recipe.ingredient(id: $0)?.name } == "bone-in chicken")
        // The model gets it as a step rewrite request in change mode only.
        let edits = analysis.edits
        let change = StepRewrites.feedbackRequests(recipe: recipe, edits: edits, feedback: "2 tbsp oil is enough, and the chicken was a bit dry", kind: .change)
        #expect(change.map(\.stepIndex) == [6])
        #expect(change.first?.editIndex == 1)
        #expect(StepRewrites.feedbackRequests(recipe: recipe, edits: edits, feedback: "2 tbsp oil is enough, and the chicken was a bit dry").isEmpty)
    }

    @Test func tasteFallbackDropsLastTimeOnlyInChangeMode() throws {
        let recipe = try StepFixtures.pepperChicken()
        #expect(FeedbackParser.edits(from: "it's usually too salty", recipe: recipe) == [.addNote("Use less salt than last time")])
        let analysis = FeedbackParser(kind: .change).analyse("it's usually too salty", recipe: recipe)
        #expect(analysis.edits == [.addNote("Use less salt")])
        #expect(analysis.unresolved.first?.ingredientID.flatMap { recipe.ingredient(id: $0)?.name } == "Salt")
        // A time with no step to put it on stays in the cook's words.
        #expect(FeedbackParser(kind: .change).analyse("it needs 10 more minutes", recipe: recipe).edits == [.addNote("It needs 10 more minutes")])
    }

    @Test func reportsInIMadeThisAreUnchanged() throws {
        let recipe = try StepFixtures.recipe("recipetineats-chow-mein")
        // The same words as a report of a cook stay a note there (but are offered as a choice).
        let cooked = FeedbackParser().analyse("added lime at the end", recipe: recipe)
        #expect(cooked.edits == [.addNote("Added lime at the end")])
        #expect(cooked.unresolved.map(\.note) == ["Added lime at the end"])
        #expect(FeedbackParser(kind: .change).analyse("added lime at the end", recipe: recipe).edits.map { $0.summary(in: recipe) }
                == ["Add lime (at the end)"])
    }

    @Test func instructionReading() {
        let cases = [
            ("I used 2 tbsp oil", "use 2 tbsp oil"),
            ("2 tbsp oil is enough", "use 2 tbsp oil"),
            ("the chicken only needs 10 minutes", "cook the chicken 10 minutes"),
            ("it doesn't need the dry-out step", "skip the dry-out step"),
            ("no need to marinate the beef", "don't marinate the beef"),
            ("can we cook the chicken on high?", "cook the chicken on high"),
            ("didn't use cilantro", "don't use cilantro"),
            ("the oil is too much", "less oil"),
            ("the oil should be 2 tbsp", "change the oil to 2 tbsp"),
            ("the oil should be fine", "the oil should be fine"),
            ("the chicken was overcooked", "the chicken was overcooked"),
            ("it's usually too salty", "it's usually too salty"),
        ]
        for (text, expected) in cases {
            #expect(ChangeIntent.instruction(text) == expected, "\(text)")
        }
    }

    // MARK: Whole units

    @Test func countedIngredientsScaleToWholeNumbers() {
        let catalog = IngredientCatalog.shared
        let recipe = catalog.annotate(Recipe(title: "R", ingredients: ["3 cloves garlic", "3 eggs", "2 onions", "3 green chillies", "2 tbsp oil", "1 egg yolk"]
            .map(IngredientLineParser.parse)))
        func summary(_ text: String) -> [String] {
            FeedbackParser(kind: .change).analyse(text, recipe: recipe).edits.map { $0.summary(in: recipe) }
        }
        #expect(summary("more garlic") == ["More garlic: 3 cloves → 4 cloves"])
        #expect(summary("less garlic") == ["Less garlic: 3 cloves → 2 cloves"])
        #expect(summary("more eggs") == ["More eggs: 3 → 4"])
        // 1.5 rounds back to 2, so it moves one: the summary reads it as half.
        #expect(summary("less onions") == ["Half the onions: 2 → 1"])
        #expect(summary("less green chillies") == ["Less green chillies: 3 → 2"])
        #expect(summary("double the eggs") == ["Double the eggs: 3 → 6"])
        // Measured amounts keep their fraction.
        #expect(summary("less oil") == ["Less oil: 2 tbsp → 1 ½ tbsp"])
    }
}
