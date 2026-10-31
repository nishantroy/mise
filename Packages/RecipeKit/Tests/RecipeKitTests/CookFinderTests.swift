import Foundation
import Testing
@testable import RecipeKit

// MARK: - Query parsing

@Suite("What can I cook: query parsing")
struct CookQueryParsingTests {
    let parser = CookQueryParser()

    struct Expect: Sendable, CustomTestStringConvertible {
        var text: String
        var ingredients: [String] = []      // catalog IDs (or terms), "*" suffix = use up
        var avoid: [String] = []
        var avoidTags: Set<IngredientTag> = []
        var missing: [String] = []
        var maxMinutes: Int? = nil
        var cuisines: [String] = []
        var styles: [CookStyle] = []
        var avoidStyles: [CookStyle] = []
        var keywords: [String] = []
        var servings: Int? = nil
        var pantryOnly = false
        var testDescription: String { text }
    }

    static let cases: [Expect] = [
        Expect(text: "I have chicken and some sad broccoli", ingredients: ["chicken", "broccoli*"]),
        Expect(text: "something spicy with ground beef under 30 min", ingredients: ["beef"], maxMinutes: 30, styles: [.spicy]),
        // Dictation run-ons: no punctuation, filler words.
        Expect(text: "i have chicken and some sad broccoli and i want something quick no pork",
               ingredients: ["chicken", "broccoli*"], avoid: ["pork"], maxMinutes: 30),
        Expect(text: "um so i got some ground beef in the fridge and like i dont want anything with pork what can i make thats under thirty minutes",
               ingredients: ["beef"], avoid: ["pork"], maxMinutes: 30),
        Expect(text: "no pork or beef something spicy", avoid: ["pork", "beef"], styles: [.spicy]),
        Expect(text: "quick vegetarian dinner for 4", avoidTags: SwapEngine.forbiddenTags(for: .vegetarian), maxMinutes: 30, servings: 4),
        Expect(text: "noodles in less than half an hour", maxMinutes: 30, styles: [.noodles]),
        Expect(text: "dinner for two in forty five minutes with rice", maxMinutes: 45, styles: [.rice], servings: 2),
        Expect(text: "anything with ground beef thats ready in under an hour and a half", ingredients: ["beef"], maxMinutes: 90),
        Expect(text: "What can I make with what I have?", pantryOnly: true),
        Expect(text: "I'm out of Shaoxing wine, what can I make with chicken?", ingredients: ["chicken"], missing: ["shaoxing-wine"]),
        Expect(text: "something Chinese but not too spicy for the two of us", cuisines: ["Chinese"], avoidStyles: [.spicy], servings: 2),
        Expect(text: "gluten free and dairy free something fast", avoidTags: [.gluten, .dairy], maxMinutes: 30),
        Expect(text: "use up the bean sprouts before they go bad", ingredients: ["bean-sprouts*"]),
        Expect(text: "no rush chicken", ingredients: ["chicken"]),
        Expect(text: "leftover chicken thighs and a sad looking carrot", ingredients: ["chicken-thigh*", "carrot*"]),
        Expect(text: "Mongolian beef", ingredients: ["beef"], keywords: ["mongolian"]),
        Expect(text: "spicy Sichuan chicken with peanuts", ingredients: ["chicken", "peanuts"], cuisines: ["Chinese"], styles: [.spicy]),
        Expect(text: "something light, nothing too heavy", styles: [.light]),
        Expect(text: "a Korean stew that takes more than an hour", cuisines: ["Korean"], styles: [.comforting]),
        Expect(text: "no more than 20 minutes", maxMinutes: 20),
        Expect(text: "pancakes", keywords: ["pancake"]),
    ]

    @Test(arguments: cases)
    func parses(_ e: Expect) {
        let q = parser.parse(e.text)
        #expect(q.ingredients.map { $0.key + ($0.useUp ? "*" : "") } == e.ingredients)
        #expect(q.avoid.map(\.key) == e.avoid)
        #expect(q.avoidTags == e.avoidTags)
        #expect(q.missing.map(\.key) == e.missing)
        #expect(q.maxMinutes == e.maxMinutes)
        #expect(q.cuisines == e.cuisines)
        #expect(q.styles == e.styles)
        #expect(q.avoidStyles == e.avoidStyles)
        #expect(q.keywords == e.keywords)
        #expect(q.servings == e.servings)
        #expect(q.pantryOnly == e.pantryOnly)
    }

    @Test func keepsTheCooksWordsForDisplay() {
        let q = parser.parse("i have chicken and some sad broccoli and i want something quick no pork")
        #expect(q.ingredients.map(\.term) == ["chicken", "broccoli"])
        #expect(q.summary == ["chicken", "use up broccoli", "under 30 min", "no pork"])
        #expect(q.maxFromQuickWord)
    }

    @Test func avoidWinsOverWant() {
        let q = parser.parse("chicken but no chicken")
        #expect(q.ingredients.isEmpty)
        #expect(q.avoid.map(\.key) == ["chicken"])
    }
}

// MARK: - Ranking over the fixtures

private func fixtureCandidates() throws -> [CookCandidate] {
    let pages = ["bbcgoodfood-easy-pancakes", "indianhealthyrecipes-chicken-curry", "recipetineats-chow-mein",
                 "wikibooks-kung-pao-chicken", "woksoflife-red-braised-pork-belly", "woksoflife-shortcut-mongolian-ground-beef"]
    var recipes = try pages.map { try #require(RecipeImporter.parse(html: Fixture.html($0), url: nil)) }
    recipes.append(try #require(RecipeImporter.parse(text: Fixture.text("mongolian-beef-my-version"))))
    return recipes.map { CookCandidate(id: UUID(), recipe: $0) }
}

/// A kitchen with the usual Chinese pantry items but no Shaoxing wine.
private let pantry = PantrySnapshot(
    have: ["soy-sauce", "sesame-oil", "rice-vinegar", "chili-flakes", "ginger", "scallion", "cornstarch", "oyster-sauce", "dry-sherry"],
    missing: ["shaoxing-wine"])

@Suite("What can I cook: ranking")
struct RecipeMatcherTests {
    let matcher = RecipeMatcher()

    func search(_ text: String, pantry: PantrySnapshot = pantry, candidates: [CookCandidate]? = nil) throws -> CookSearchResult {
        try matcher.search(CookQueryParser().parse(text), in: candidates ?? fixtureCandidates(), pantry: pantry)
    }

    @Test func spicyGroundBeefUnderThirty() throws {
        let r = try search("something spicy with ground beef under 30 min")
        #expect(r.status == .matched)
        // The owner's version is ~35 min, so only the shortcut recipe (stated 30; its overnight
        // marinade is a make-ahead option) passes.
        #expect(r.matches.map(\.title) == ["Shortcut Mongolian Ground Beef"])
        #expect(r.matches[0].why == "Uses ground beef · spicy · ~30 min · missing Shaoxing wine — dry sherry works +2 more")
    }

    @Test func mongolianBeefFindsBothVersions() throws {
        let r = try search("Mongolian beef")
        #expect(r.matches.map(\.title) == ["Shortcut Mongolian Ground Beef", "Mongolian Ground Beef"])
        #expect(r.matches.allSatisfy { $0.matchedKeywords == ["mongolian"] })
    }

    @Test func kungPaoForSichuanChickenWithPeanuts() throws {
        let r = try search("spicy Sichuan chicken with peanuts")
        #expect(r.matches.first?.title == "Kung Pao Chicken")
        #expect(r.matches.first?.why.hasPrefix("Uses chicken and peanuts · Chinese · spicy · ~1 hr 5 min") == true)
    }

    @Test func dictatedRunOnWithAvoidAndQuick() throws {
        let r = try search("i have chicken and some sad broccoli and i want something quick no pork")
        #expect(r.matches.map(\.title) == ["Chow Mein"])
        #expect(r.unmatchedIngredients == ["broccoli"])
        #expect(r.matches[0].why == "Uses chicken · ~30 min · missing bean sprouts — cabbage works +2 more")
    }

    @Test func useUpWeighsMoreThanHaving() throws {
        let r = try search("leftover carrot and some chicken")
        // Chow mein has both; the curry and kung pao only the chicken.
        #expect(r.matches.first?.title == "Chow Mein")
        #expect(r.matches.first?.usedIngredients == ["carrot", "chicken"])
    }

    @Test func avoidIsAHardFilter() throws {
        let r = try search("no pork or beef something spicy")
        let titles = Set(r.matches.map(\.title))
        #expect(titles == ["Chicken Curry Recipe", "Kung Pao Chicken"])
    }

    @Test func noodles() throws {
        let r = try search("noodles")
        #expect(r.matches.map(\.title) == ["Chow Mein"])
    }

    @Test func youHaveEverything() throws {
        var p = pantry
        p.have.formUnion(["shaoxing-wine", "dark-soy-sauce", "dried-chili"])
        p.missing = []
        let r = try search("ground beef", pantry: p)
        let shortcut = try #require(r.matches.first { $0.title == "Shortcut Mongolian Ground Beef" })
        #expect(shortcut.why == "Uses ground beef · ~30 min · you have everything")
    }

    @Test func missingItemWithAKnownSwap() throws {
        var p = pantry
        p.have.formUnion(["bean-sprouts", "white-pepper"])
        let r = try search("chicken", pantry: p)
        let chowMein = try #require(r.matches.first { $0.title == "Chow Mein" })
        #expect(chowMein.missing == [MissingIngredient(name: "Chinese cooking wine", catalogID: "shaoxing-wine", swap: "dry sherry")])
        #expect(chowMein.why == "Uses chicken · ~30 min · missing Chinese cooking wine — dry sherry works")
    }

    @Test func withWhatIHaveDropsRecipesThatNeedShopping() throws {
        let r = try search("what can I make with what I have")
        #expect(r.status == .matched)
        #expect(r.matches.first?.title == "Easy pancakes")
        #expect(r.matches.first?.why == "~40 min · you have everything")
        // Pork belly needs star anise and pork belly, with no swap the pantry covers.
        #expect(!r.matches.contains { $0.title.contains("Pork Belly") })
    }

    @Test func nothingKoreanShowsCloseMatches() throws {
        let r = try search("something fast thats korean")
        #expect(r.status == .closeOnly)
        #expect(r.matches.isEmpty)
        #expect(r.closeMatches.count == 3)
        #expect(r.relaxed == ["under 30 min", "Korean"])
    }

    @Test func tooShortATimeLimitRelaxesIt() throws {
        let r = try search("no more than 20 minutes")
        #expect(r.status == .closeOnly)
        #expect(r.relaxed == ["under 20 min"])
        #expect(r.closeMatches.allSatisfy { $0.why.contains("over your 20 min") })
    }

    @Test func vegetarianQuickRelaxesBoth() throws {
        let r = try search("quick vegetarian dinner for 4")
        #expect(r.status == .closeOnly)
        #expect(r.closeMatches.first?.title == "Easy pancakes")
        #expect(r.closeMatches.first?.why == "~40 min, over your 30 min · you have everything")
        #expect(Set(r.relaxed) == ["under 30 min", "no meat or fish"])
    }

    @Test func emptyQueryRanksEverything() throws {
        let r = try search("what can I cook")
        #expect(r.status == .matched)
        #expect(r.matches.count == 7)
    }

    @Test func noRecipesSaved() {
        let r = matcher.search(CookQueryParser().parse("chicken"), in: [], pantry: pantry)
        #expect(r.status == .noRecipes)
    }

    @Test func ratingBreaksTies() throws {
        let recipe = try fixtureCandidates()[2].recipe
        let plain = CookCandidate(id: UUID(), recipe: recipe)
        var liked = CookCandidate(id: UUID(), recipe: recipe, rating: 1)
        liked.recipe.title = "Chow Mein (liked)"
        let r = matcher.search(CookQueryParser().parse("noodles"), in: [plain, liked], pantry: pantry)
        #expect(r.matches.map(\.title) == ["Chow Mein (liked)", "Chow Mein"])
    }

    @Test func overnightMakeAheadDoesNotCountWhenTimeIsStated() throws {
        let shortcut = try #require(try fixtureCandidates().first { $0.recipe.title == "Shortcut Mongolian Ground Beef" })
        #expect(TimeEstimator().estimate(shortcut.recipe).isOvernight)
        #expect(matcher.realisticMinutes(shortcut.recipe) == 30)
    }
}

// MARK: - Model reading, validated

@Suite("What can I cook: model query merge")
struct CookQueryMergeTests {
    let parser = CookQueryParser()

    @Test func addsGroundedIngredientsOnly() {
        let rules = parser.parse("got some leftover roast chook and a bit of brocoli")
        let merged = CookQueryMerge.merge(ProposedCookQuery(ingredients: ["chicken", "broccoli", "rice"], useUp: ["chicken"]), rules: rules)
        // "chicken" and "rice" aren't in the text and "chook" isn't a catalog alias; misspelt
        // "brocoli" isn't either, so nothing the model said is grounded.
        #expect(merged.ingredients.map(\.key) == rules.ingredients.map(\.key))
        #expect(!merged.styles.contains(.rice))
    }

    @Test func groundedViaCatalogAlias() {
        let rules = parser.parse("whatever goes with my scallions")
        #expect(rules.ingredients.map(\.key) == ["scallion"])
        let merged = CookQueryMerge.merge(ProposedCookQuery(ingredients: ["green onions"], useUp: ["green onions"]), rules: rules)
        #expect(merged.ingredients.map(\.key) == ["scallion"])
        #expect(merged.ingredients[0].useUp, "the model can mark a rules ingredient as use-up")
    }

    @Test func numbersMustAppearInTheText() {
        let rules = parser.parse("something quick")
        #expect(rules.maxMinutes == 30)
        let invented = CookQueryMerge.merge(ProposedCookQuery(maxMinutes: 20, servings: 4), rules: parser.parse("something for dinner"))
        #expect(invented.maxMinutes == nil)
        #expect(invented.servings == nil)
        let written = CookQueryMerge.merge(ProposedCookQuery(maxMinutes: 25, servings: 3),
                                           rules: parser.parse("dinner in twenty five, three of us"))
        #expect(written.maxMinutes == 25)
        #expect(written.servings == 3)
    }

    @Test func rulesNegationBeatsModelWant() {
        let rules = parser.parse("anything but pork")
        #expect(rules.avoid.map(\.key) == ["pork"])
        let merged = CookQueryMerge.merge(ProposedCookQuery(ingredients: ["pork"]), rules: rules)
        #expect(merged.ingredients.isEmpty)
        #expect(merged.avoid.map(\.key) == ["pork"])
    }

    @Test func modelAvoidNeverRemovesARulesWant() {
        let rules = parser.parse("chicken with mushrooms")
        let merged = CookQueryMerge.merge(ProposedCookQuery(avoid: ["chicken", "mushrooms"]), rules: rules)
        #expect(merged.avoid.isEmpty)
        #expect(merged.ingredients.map(\.key) == rules.ingredients.map(\.key))
    }

    @Test func cuisineMustBeNamedStylesAreFree() {
        let rules = parser.parse("kung pao or something like it but nothing too greasy")
        let merged = CookQueryMerge.merge(ProposedCookQuery(cuisines: ["Chinese"], styles: ["light", "stirFry", "bogus"]), rules: rules)
        #expect(merged.cuisines.isEmpty, "no cuisine word in the text")
        #expect(merged.styles == [.light, .stirFry])
        let sichuan = CookQueryMerge.merge(ProposedCookQuery(cuisines: ["chinese"]), rules: parser.parse("szechuan please"))
        #expect(sichuan.cuisines == ["Chinese"])
    }

    @Test func pantryOnlyNeedsAPantryWord() {
        #expect(!CookQueryMerge.merge(ProposedCookQuery(pantryOnly: true), rules: parser.parse("spicy noodles")).pantryOnly)
        #expect(CookQueryMerge.merge(ProposedCookQuery(pantryOnly: true), rules: parser.parse("stuff I've got lying around")).pantryOnly)
    }
}
