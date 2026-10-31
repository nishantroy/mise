import Foundation
import Testing
@testable import RecipeKit

private func recipe(_ title: String, ingredients: [String], steps: [String] = [], minutes: Int? = nil, cuisine: String? = nil) -> Recipe {
    IngredientCatalog.shared.annotate(Recipe(title: title, totalMinutes: minutes, cuisine: cuisine,
                                             ingredients: ingredients.map(IngredientLineParser.parse), steps: steps))
}

private func fixture(_ name: String) throws -> Recipe {
    try #require(RecipeImporter.parse(html: try Fixture.html(name), url: nil))
}

// MARK: - Cuisine

@Suite("Cuisine guess")
struct CuisineGuessTests {
    struct Case: Sendable, CustomStringConvertible {
        var fixture: String
        var cuisine: String?
        var description: String { fixture }
    }

    /// The guesser runs on the parsed recipe regardless of the page's own cuisine.
    static let cases: [Case] = [
        .init(fixture: "wikibooks-kung-pao-chicken", cuisine: "Chinese"),
        .init(fixture: "wikibooks-kung-pao-chicken-mobile", cuisine: "Chinese"),
        .init(fixture: "indianhealthyrecipes-chicken-curry", cuisine: "Indian"),
        .init(fixture: "recipetineats-chow-mein", cuisine: "Chinese"),
        .init(fixture: "woksoflife-red-braised-pork-belly", cuisine: "Chinese"),
        .init(fixture: "bbcgoodfood-easy-pancakes", cuisine: nil),  // flour, eggs, milk: no signal
    ]

    @Test(arguments: cases)
    func guessesFixture(_ c: Case) throws {
        let guess = CuisineGuesser().analyse(try fixture(c.fixture))
        #expect(guess.cuisine == c.cuisine, "\(guess)")
        if c.cuisine != nil { #expect(guess.isStrong, "fixtures are clear enough to skip the model") }
    }

    @Test func kungPaoSignals() throws {
        let guess = CuisineGuesser().analyse(try fixture("wikibooks-kung-pao-chicken"))
        #expect(guess.signals.contains("oyster sauce"))
        #expect(guess.signals.contains("hoisin"))
        #expect(guess.signals.contains("title: kung pao"))
    }

    @Test func soySauceAloneIsNotChinese() {
        let r = recipe("Garlic noodles", ingredients: ["200 g noodles", "2 tbsp soy sauce", "4 cloves garlic", "1 tbsp butter"])
        let guess = CuisineGuesser().analyse(r)
        #expect(guess.cuisine == nil)
        #expect(guess.score <= 1)
    }

    @Test func genericAsianPantryIsAmbiguous() {
        // soy sauce + sesame oil + rice vinegar: Chinese, Japanese and Korean all score.
        let r = recipe("Cucumber salad", ingredients: ["1 cucumber", "1 tbsp soy sauce", "1 tsp sesame oil",
                                                       "1 tbsp rice vinegar", "1 clove garlic"])
        #expect(CuisineGuesser().guess(r) == nil)
    }

    @Test func conflictingSignalsAreAmbiguous() {
        let r = recipe("Glazed salmon", ingredients: ["2 salmon fillets", "1 tbsp miso", "1 tbsp gochujang", "1 tbsp honey"])
        #expect(CuisineGuesser().guess(r) == nil)
    }

    @Test(arguments: [
        ("Chicken tikka masala", ["500 g chicken", "1 cup yogurt"], "Indian"),
        ("Spaghetti carbonara", ["200 g spaghetti", "100 g pancetta", "50 g parmesan", "2 eggs"], "Italian"),
        ("Beef bulgogi", ["500 g beef", "2 tbsp soy sauce", "1 tbsp sugar"], "Korean"),
        ("Pad thai", ["200 g rice noodles", "2 tbsp fish sauce", "1 tbsp tamarind paste"], "Thai"),
        ("Pork tacos", ["500 g pork shoulder", "2 chipotles in adobo", "8 corn tortillas"], "Mexican"),
        ("Roast cauliflower", ["1 cauliflower", "3 tbsp tahini", "1 tsp sumac", "1 tbsp za'atar"], "Middle Eastern"),
        ("Glazed salmon", ["2 salmon fillets", "2 tbsp miso", "1 tbsp mirin", "1 tsp dashi"], "Japanese"),
        ("Weeknight dal", ["1 cup red lentils", "1 tsp turmeric", "1 tbsp ghee", "1 tsp cumin seeds", "pinch asafoetida"], "Indian"),
    ])
    func guessesFromSignals(_ title: String, _ ingredients: [String], _ expected: String) {
        #expect(CuisineGuesser().guess(recipe(title, ingredients: ingredients)) == expected)
    }

    @Test func vocabularyMatchesOnboarding() throws {
        #expect(CuisineGuesser.vocabulary == UserPreferences.cuisineChoices)
        let catalog = IngredientCatalog.shared
        for entry in catalog.entries {
            for c in entry.cuisines ?? [] { #expect(CuisineGuesser.vocabulary.contains(c), "\(entry.id): \(c)") }
        }
        for k in CuisineGuesser.titleKeywords { #expect(CuisineGuesser.vocabulary.contains(k.cuisine)) }
        // Generic ingredients carry no cuisine weight.
        for id in ["garlic", "onion", "ginger", "salt", "neutral-oil", "scallion"] {
            #expect(try #require(catalog.entry(id: id)).cuisineVote == 0, "\(id)")
        }
        #expect(try #require(catalog.entry(id: "soy-sauce")).cuisineVote == 1)
        #expect(try #require(catalog.entry(id: "oyster-sauce")).cuisineVote == 3)
    }

    @Test func pancettaMasaAndTomatilloAreTheirOwnEntries() {
        let catalog = IngredientCatalog.shared
        #expect(catalog.match("diced pancetta")?.id == "pancetta")
        #expect(catalog.match("masa harina")?.id == "masa-harina")
        #expect(catalog.match("garam masala")?.id == "garam-masala")
        #expect(catalog.match("polenta")?.id == "cornmeal")
        #expect(catalog.match("tomatillos")?.id == "tomatillo")
        #expect(catalog.match("streaky bacon")?.id == "bacon")
    }

    @Test(arguments: [
        ("Chinese", "Chinese"), ("middle eastern", "Middle Eastern"), ("MiddleEastern", "Middle Eastern"),
        ("Middle-Eastern", "Middle Eastern"), (" thai ", "Thai"),
    ])
    func mapsModelChoice(_ raw: String, _ expected: String) {
        #expect(CuisineGuesser.mapModelChoice(raw) == expected)
    }

    @Test func modelOtherOrUnknownIsNil() {
        #expect(CuisineGuesser.mapModelChoice("Other") == nil)
        #expect(CuisineGuesser.mapModelChoice("Vietnamese") == nil)
        #expect(CuisineGuesser.mapModelChoice("") == nil)
    }
}

// MARK: - Durations

@Suite("Time estimate")
struct TimeEstimateTests {
    func minutes(_ text: String) -> [Double] { TimeEstimator.durations(in: text).map(\.minutes) }

    @Test(arguments: [
        ("Simmer for 4 minutes.", [4.0]),
        ("Stir fry for about 2–3 minutes.", [3.0]),
        ("Cook 30-40 mins until tender.", [40.0]),
        ("Saute for 7 to 8 mins.", [8.0]),
        ("Allow to marinate for ½ hour.", [30.0]),
        ("Rest for half an hour.", [30.0]),
        ("Bake for 1 hr 30 min.", [90.0]),
        ("Braise for 1 hour and 15 minutes.", [75.0]),
        ("Roast for an hour and a half.", [90.0]),
        ("Stir fry for 1 1/2 minutes.", [1.5]),
        ("Cook for 1½ hours.", [90.0]),
        ("Simmer for 1.5 hours.", [90.0]),
        ("Simmer for one more minute.", [1.0]),
        ("Saute for about a minute.", [1.0]),
        ("Toss for 30 seconds.", [0.5]),
        ("Cook for 1 min on each side.", [2.0]),
        ("Rest the dough for a 10-minute break.", [10.0]),
        ("Simmer 10 minutes, then add the peas and cook 5 minutes more.", [10.0, 5.0]),
    ])
    func extractsDurations(_ text: String, _ expected: [Double]) {
        #expect(minutes(text) == expected, "\(text)")
    }

    @Test func untilGoldenHasNoTime() {
        #expect(minutes("Fry the onions until golden.").isEmpty)
        #expect(minutes("Add 2 eggs and 1 cup flour.").isEmpty)
        #expect(minutes("Preheat the oven to 200C.").isEmpty)
    }

    @Test func overnight() throws {
        let found = TimeEstimator.durations(in: "Cover and marinate for at least 4 hours or overnight.")
        #expect(found.count == 1)
        #expect(found.first?.minutes == 480)
        #expect(found.first?.overnight == true)

        let r = recipe("Yogurt chicken", ingredients: ["1 kg chicken", "1 cup yogurt"],
                       steps: ["Mix the chicken with the yogurt and refrigerate overnight.", "Grill for 20 minutes."])
        let e = TimeEstimator().estimate(r)
        #expect(e.isOvernight)
        #expect(e.passiveMinutes == 480)
        #expect(e.passiveLabel == "chilling")
        #expect(e.reason.contains("overnight"))
    }

    @Test(arguments: [
        ("Set aside to marinate for 10 minutes.", "marinating"),
        ("Let the dough rise for 1 hour.", "rising"),
        ("Proof for 45 minutes.", "rising"),
        ("Leave to rest for 10 minutes.", "resting"),
        ("Chill for 2 hours.", "chilling"),
        ("Refrigerate for 30 minutes.", "chilling"),
        ("Soak the beans for 8 hours.", "soaking"),
        ("Leave to set for 4 hours.", "setting"),
        ("Allow to cool for 15 minutes.", "cooling"),
        ("Let it stand for 5 minutes.", "standing"),
        ("Marinate overnight.", "marinating"),
        ("Leave overnight.", "overnight"),
    ])
    func classifiesPassive(_ clause: String, _ label: String) {
        #expect(TimeEstimator.passiveLabel(clause) == label, "\(clause)")
    }

    @Test(arguments: [
        "Simmer for 20 minutes.", "Bake for 25 minutes.", "Stir fry for 2 minutes.",
        "Serve the rest of the sauce on the side.", "Rinse in cool water for 1 minute.", "Beat in a stand mixer for 5 minutes.",
    ])
    func classifiesActive(_ clause: String) {
        #expect(TimeEstimator.passiveLabel(clause) == nil, "\(clause)")
    }

    @Test func storageAdviceIsIgnored() {
        let r = recipe("Pancakes", ingredients: ["100 g flour", "2 eggs", "300 ml milk"],
                       steps: ["Cook for 2 minutes.", "Wrap in cling film and freeze for up to 2 months.",
                               "Leftovers keep for 3 days; reheat for 1 minute."])
        #expect(TimeEstimator().analyse(r).durations.map(\.minutes) == [2])
    }

    @Test func meanwhileStepsDoNotAdd() {
        let r = recipe("Pasta", ingredients: ["200 g pasta", "1 jar sauce"],
                       steps: ["Boil the pasta for 10 minutes.", "Meanwhile, warm the sauce for 5 minutes.",
                               "Drain the pasta, then stir through the sauce for 1 minute while the pasta is hot."])
        let a = TimeEstimator().analyse(r)
        #expect(a.activeCookingMinutes == 10)
        #expect(a.durations.filter(\.isParallel).count == 2)
    }

    @Test func untimedDefaults() {
        let r = recipe("Soup", ingredients: ["1 onion", "1 l stock"],
                       steps: ["Fry the onion until soft.", "Add the stock and bring to a boil.", "Simmer for 20 minutes."])
        let a = TimeEstimator().analyse(r)
        #expect(a.untimed.map(\.step) == [0, 1])
        #expect(a.untimedMinutes == TimeEstimator.untilDefaultMinutes + TimeEstimator.boilDefaultMinutes)
        // An "until" step that is timed elsewhere in the step gets no default.
        let timed = recipe("Chicken", ingredients: ["1 chicken"], steps: ["Fry until white. This takes around 3 mins."])
        #expect(TimeEstimator().analyse(timed).untimed.isEmpty)
    }

    @Test func prepAllowanceIsClamped() {
        let few = recipe("Toast", ingredients: ["1 slice bread", "butter", "salt", "water"])
        #expect(TimeEstimator().analyse(few).prepIngredientCount == 2)
        #expect(TimeEstimator().analyse(few).prepMinutes == 5)
        let many = recipe("Big", ingredients: (1...40).map { "1 tbsp spice \($0)" })
        #expect(TimeEstimator().analyse(many).prepMinutes == 25)
    }

    // MARK: Mismatch

    @Test func fifteenMinuteRecipeWithMarinadeIsAMismatch() {
        let r = recipe("Quick chicken", ingredients: ["500 g chicken", "2 tbsp soy sauce", "1 tbsp honey", "2 cloves garlic", "1 tbsp oil"],
                       steps: ["Marinate the chicken in the soy sauce, honey and garlic for 30 minutes.",
                               "Fry in the oil for 6 minutes until cooked."], minutes: 15)
        let e = TimeEstimator().estimate(r)
        #expect(e.passiveMinutes == 30)
        #expect(e.passiveLabel == "marinating")
        #expect(e.totalMinutes == 40)  // 5 prep + 6 cooking + 30 marinating → nearest 5
        #expect(e.source == .rules)
        let saved = r.withInsights(cuisineGuess: nil, estimate: e)
        #expect(saved.timeMismatch)
        #expect(saved.totalMinutes == 15, "stated time is never overwritten")
        #expect(saved.displayTime?.minutes == 15)
        #expect(saved.displayTime?.isEstimate == false)
    }

    @Test(arguments: [
        (30, 15, true),    // 2×, +15
        (25, 15, false),   // ≥1.5× but only +10
        (60, 50, false),   // +10, 1.2×
        (90, 50, true),
        (40, nil, false),  // nothing stated
    ] as [(Int, Int?, Bool)])
    func mismatchRule(_ estimate: Int, _ stated: Int?, _ expected: Bool) {
        #expect(TimeEstimator.isMismatch(estimate: estimate, stated: stated) == expected)
    }

    @Test func missingStatedTimeShowsEstimate() throws {
        var r = try fixture("wikibooks-kung-pao-chicken")
        r.timeEstimate = TimeEstimator().estimate(r)
        #expect(r.totalMinutes == nil)
        #expect(r.displayTime?.isEstimate == true)
        #expect(r.displayTime?.minutes == r.timeEstimate?.totalMinutes)
        #expect(!r.timeMismatch)
    }

    @Test func weeknightHint() {
        var r = recipe("Stew", ingredients: ["1 kg beef"], minutes: 30)
        r.timeEstimate = TimeEstimate(totalMinutes: 55, activeMinutes: 25, passiveMinutes: 30, reason: "", source: .rules)
        #expect(r.realisticMinutes == 55)
        #expect(r.exceedsWeeknightTime(UserPreferences(weeknightMinutes: 45)))
        #expect(!r.exceedsWeeknightTime(UserPreferences(weeknightMinutes: 60)))
        #expect(!r.exceedsWeeknightTime(UserPreferences(weeknightMinutes: nil)))
    }

    /// The numbers reported for the fixtures (stated vs estimate).
    @Test(arguments: [
        ("wikibooks-kung-pao-chicken", nil, 65, false),
        ("recipetineats-chow-mein", 15, 30, true),
        ("indianhealthyrecipes-chicken-curry", 50, 40, false),
        ("bbcgoodfood-easy-pancakes", 30, 40, false),
        ("woksoflife-red-braised-pork-belly", 105, 80, false),
    ] as [(String, Int?, Int, Bool)])
    func fixtureEstimates(_ name: String, _ stated: Int?, _ total: Int, _ mismatch: Bool) throws {
        let r = try fixture(name)
        let e = TimeEstimator().estimate(r)
        #expect(r.totalMinutes == stated)
        #expect(e.totalMinutes == total, "\(e)")
        #expect(TimeEstimator.isMismatch(estimate: e.totalMinutes, stated: r.totalMinutes) == mismatch)
        #expect(!e.reason.isEmpty)
    }

    // MARK: Model gaps

    @Test func modelGapsReplaceRuleDefaults() throws {
        let r = try fixture("wikibooks-kung-pao-chicken")
        let rules = TimeEstimator().analyse(r)
        let e = TimeEstimator().estimate(r, gaps: TimeGapProposal(prepMinutes: 15, untimedMinutes: 5,
                                                                  reason: "Chopping takes about 15 minutes and heating the wok 5."))
        #expect(e.source == .model)
        #expect(e.passiveMinutes == 30)
        // prep 15 + timed cooking + untimed 5 (replacing the rules' 3) + 30 passive
        let expected = 15 + rules.activeCookingMinutes + 5 + 30
        #expect(e.totalMinutes == Int(expected / 5 + 0.5) * 5)
        #expect(e.reason == "Chopping takes about 15 minutes and heating the wok 5.")
    }

    @Test func modelGapsAreClamped() throws {
        let absurd = try #require(TimeEstimator.clamp(TimeGapProposal(prepMinutes: 900, untimedMinutes: 5000,
                                                                     reason: "Line one\nline two")))
        #expect(absurd.prepMinutes == 60)
        #expect(absurd.untimedMinutes == 120)
        #expect(absurd.reason == "Line one")
        let tiny = try #require(TimeEstimator.clamp(TimeGapProposal(prepMinutes: 0, untimedMinutes: 0, reason: "   ")))
        #expect(tiny.prepMinutes == 2)
        #expect(!tiny.reason.isEmpty, "empty reason gets a default")
        #expect(TimeEstimator.clamp(TimeGapProposal(prepMinutes: -5, untimedMinutes: 10, reason: "x")) == nil)
        let long = try #require(TimeEstimator.clamp(TimeGapProposal(prepMinutes: 10, untimedMinutes: 0, reason: String(repeating: "word ", count: 80))))
        #expect(long.reason.count <= 160)
        // An unusable proposal leaves the rules in charge.
        let r = recipe("x", ingredients: ["1 egg"], steps: ["Boil for 8 minutes."])
        #expect(TimeEstimator().estimate(r, gaps: TimeGapProposal(prepMinutes: -1, untimedMinutes: -1, reason: "")).source == .rules)
    }

    @Test func hintsListDurations() throws {
        let hints = TimeEstimator().analyse(try fixture("wikibooks-kung-pao-chicken")).hintLines
        #expect(hints.first == "step 2: 30 min marinating, waiting")
        #expect(hints.last == "untimed steps: 4")
    }
}

// MARK: - Recipe storage and enrichment

@Suite("Recipe insights")
struct RecipeInsightsTests {
    @Test func decodesRecipeSavedBeforeInsights() throws {
        // JSON as written by the v1 build: no cuisineIsGuess, no timeEstimate.
        let json = """
        {"title":"Chow Mein","servings":2,"totalMinutes":15,"cuisine":"Chinese",
         "ingredients":[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","raw":"2 tbsp soy sauce","quantity":2,"unit":"tbsp","name":"soy sauce","catalogID":"soy-sauce"}],
         "steps":["Fry."],"notes":[]}
        """
        let r = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        #expect(r.title == "Chow Mein")
        #expect(r.cuisine == "Chinese")
        #expect(r.cuisineIsGuess == false)
        #expect(r.timeEstimate == nil)
        #expect(r.ingredients.count == 1)
    }

    @Test func roundTripsNewFields() throws {
        var r = recipe("Kung pao", ingredients: ["1 tbsp oyster sauce"], steps: ["Marinate for 30 minutes."])
        r = r.withInsights(cuisineGuess: "Chinese", estimate: TimeEstimator().estimate(r))
        let decoded = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(r))
        #expect(decoded == r)
        #expect(decoded.cuisineIsGuess)
        #expect(decoded.timeEstimate?.passiveLabel == "marinating")
    }

    @Test func toleratesPartialEstimate() throws {
        let json = #"{"title":"X","ingredients":[],"steps":[],"notes":[],"timeEstimate":{"totalMinutes":40}}"#
        let r = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        #expect(r.timeEstimate?.totalMinutes == 40)
        #expect(r.timeEstimate?.source == .rules)
        let broken = #"{"title":"X","timeEstimate":"soon"}"#
        let r2 = try JSONDecoder().decode(Recipe.self, from: Data(broken.utf8))
        #expect(r2.timeEstimate == nil)
        #expect(r2.ingredients.isEmpty)
    }

    @Test func pageCuisineIsNeverOverwritten() {
        let r = recipe("Chow mein", ingredients: ["1 tbsp oyster sauce"], cuisine: "Cantonese")
        let out = r.withInsights(cuisineGuess: "Chinese", estimate: nil)
        #expect(out.cuisine == "Cantonese")
        #expect(!out.cuisineIsGuess)
    }

    @Test func guessReplacesOnlyAGuess() {
        var r = recipe("Mystery", ingredients: ["1 egg"])
        r = r.withInsights(cuisineGuess: "Thai", estimate: nil)
        #expect(r.cuisine == "Thai" && r.cuisineIsGuess)
        r = r.withInsights(cuisineGuess: "Korean", estimate: nil)
        #expect(r.cuisine == "Korean")
        r = r.withInsights(cuisineGuess: nil, estimate: nil)
        #expect(r.cuisine == "Korean", "a nil re-guess keeps the earlier guess")
        // A cuisine the user picked counts as given.
        r.cuisine = "Japanese"
        r.cuisineIsGuess = false
        #expect(r.withInsights(cuisineGuess: "Korean", estimate: nil).cuisine == "Japanese")
    }

    @Test func enrichWithRules() async throws {
        let r = try fixture("wikibooks-kung-pao-chicken")
        let out = await RecipeInsights.enrich(r, using: RuleBasedAssistant())
        #expect(out.cuisine == "Chinese")
        #expect(out.cuisineIsGuess)
        #expect(out.timeEstimate?.totalMinutes == 65)
        #expect(out.timeEstimate?.source == .rules)
        #expect(out.steps == r.steps && out.ingredients == r.ingredients)
    }

    struct FailingAssistant: RecipeAssistant {
        struct Boom: Error {}
        var displayName: String { "Failing" }
        func proposeEdits(recipe: Recipe, feedback: String, prefs: UserPreferences) async throws -> [RecipeEdit] { throw Boom() }
        func suggestSwaps(for ingredient: Ingredient, in recipe: Recipe, pantry: PantrySnapshot, prefs: UserPreferences) async throws -> [SwapSuggestion] { throw Boom() }
        func guessCuisine(recipe: Recipe) async throws -> String? { throw Boom() }
        func estimateTime(recipe: Recipe) async throws -> TimeEstimate { throw Boom() }
    }

    @Test func enrichFallsBackToRulesOnError() async throws {
        let r = try fixture("recipetineats-chow-mein")
        let out = await RecipeInsights.enrich(r, using: FailingAssistant())
        #expect(out.cuisine == "Chinese")
        #expect(!out.cuisineIsGuess, "the page gave Chinese")
        #expect(out.timeEstimate?.totalMinutes == 30)
        #expect(out.timeMismatch)
    }
}
