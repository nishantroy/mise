import Foundation
import Testing
@testable import RecipeKit

@Suite("Catalog")
struct CatalogTests {
    let catalog = IngredientCatalog.shared

    @Test func bundledDataLoadsAndSwapIDsExist() throws {
        #expect(catalog.entries.count >= 150)
        #expect(catalog.swapRules.count >= 60)
        let ids = Set(catalog.entries.map(\.id))
        #expect(ids.count == catalog.entries.count, "duplicate ids")
        for (forID, options) in catalog.swapRules {
            #expect(ids.contains(forID), "swap target \(forID) not in catalog")
            for option in options {
                for component in option.use {
                    #expect(ids.contains(component.id), "swap for \(forID) uses unknown \(component.id)")
                    #expect((component.ratio == nil) != (component.amount == nil), "\(forID): ratio xor amount")
                }
            }
        }
        for id in IngredientCatalog.quickPickIDs { #expect(ids.contains(id), "quick pick \(id)") }
    }

    @Test func rawJSONFilesDecode() throws {
        // Load the files directly too, so a malformed resource fails here rather than at app launch.
        let ing = try #require(IngredientCatalog.resourceBundle.url(forResource: "ingredients", withExtension: "json"))
        let sw = try #require(IngredientCatalog.resourceBundle.url(forResource: "swaps", withExtension: "json"))
        let c = try IngredientCatalog(ingredientsJSON: Data(contentsOf: ing), swapsJSON: Data(contentsOf: sw))
        #expect(c.entry(id: "shaoxing-wine")?.commonness == .specialty)
    }

    @Test func longestAliasWins() {
        #expect(catalog.match("garlic powder")?.id == "garlic-powder")
        #expect(catalog.match("garlic")?.id == "garlic")
        #expect(catalog.match("dark soy sauce")?.id == "dark-soy-sauce")
        #expect(catalog.match("light soy sauce")?.id == "soy-sauce")
        #expect(catalog.match("toasted sesame oil")?.id == "sesame-oil")
        #expect(catalog.match("oil")?.id == "neutral-oil")
        #expect(catalog.match("Shaoxing wine")?.id == "shaoxing-wine")
        #expect(catalog.match("rice wine vinegar")?.id == "rice-vinegar")
        #expect(catalog.match("coriander powder")?.id == "coriander-powder")
        #expect(catalog.match("fresh coriander leaves")?.id == "cilantro")
    }

    @Test func wholeWordsOnly() {
        #expect(catalog.match("saltine crackers") == nil)
        #expect(catalog.match("pineapple") == nil)  // contains "pine" and "apple" letters, not words
        #expect(catalog.match("dragon fruit") == nil)
    }

    @Test func pluralsAndPrepWords() {
        #expect(catalog.match("large eggs")?.id == "egg")
        #expect(catalog.match("onions, finely chopped")?.id == "onion")
        #expect(catalog.match("finely chopped fresh cilantro")?.id == "cilantro")
        #expect(catalog.match("Kashmiri red chili powder")?.id == "kashmiri-chili-powder")
        #expect(catalog.match("cloves")?.id == "cloves")
        #expect(catalog.match("crushed red pepper flakes")?.id == "chili-flakes")
    }

    @Test func pantryKeys() {
        let known = IngredientLineParser.parse("2 tbsp Shaoxing wine")
        #expect(catalog.pantryKey(for: known) == "shaoxing-wine")
        let unknown = IngredientLineParser.parse("1 cup finely chopped Dragon Fruit")
        #expect(catalog.pantryKey(for: unknown) == "dragon fruit")
    }

    @Test func importerAnnotates() throws {
        let r = try #require(RecipeImporter.parse(html: try Fixture.html("woksoflife-red-braised-pork-belly"), url: nil))
        #expect(r.ingredients.first { $0.name == "Shaoxing wine" }?.catalogID == "shaoxing-wine")
        #expect(r.ingredients.first { $0.name == "dark soy sauce" }?.catalogID == "dark-soy-sauce")
        #expect(r.ingredients.first { $0.name == "light soy sauce" }?.catalogID == "soy-sauce")
    }
}

@Suite("Swap engine")
struct SwapEngineTests {
    let engine = SwapEngine()

    func recipe(_ lines: [String], steps: [String] = []) -> Recipe {
        IngredientCatalog.shared.annotate(Recipe(title: "Test", ingredients: lines.map(IngredientLineParser.parse), steps: steps))
    }

    @Test func specialtyAsksCommonAssumed() {
        let r = recipe(["2 tbsp Shaoxing wine", "1 tbsp soy sauce", "1 tsp salt", "1 cup dragon fruit"])
        let items = engine.review(recipe: r, pantry: .empty, prefs: UserPreferences())
        #expect(items.count == 1)
        #expect(items[0].kind == .askHave)
        #expect(items[0].pantryKey == "shaoxing-wine")
        #expect(items[0].headline == "Do you have Shaoxing wine?")
        #expect(items[0].swaps.first?.items.first?.catalogID == "dry-sherry")
    }

    @Test func missingSkipsTheQuestion() {
        let r = recipe(["2 tbsp Shaoxing wine"])
        let items = engine.review(recipe: r, pantry: PantrySnapshot(missing: ["shaoxing-wine"]), prefs: UserPreferences())
        #expect(items.map(\.kind) == [.missing])
        #expect(!items[0].swaps.isEmpty)
    }

    @Test func haveIsFine() {
        let r = recipe(["2 tbsp Shaoxing wine"])
        #expect(engine.review(recipe: r, pantry: PantrySnapshot(have: ["shaoxing-wine"]), prefs: UserPreferences()).isEmpty)
    }

    @Test func conflictBeatsPantry() {
        let r = recipe(["2 tbsp Shaoxing wine"])
        let prefs = UserPreferences(avoid: [.alcohol])
        let items = engine.review(recipe: r, pantry: PantrySnapshot(have: ["shaoxing-wine"]), prefs: prefs)
        #expect(items.count == 1)
        guard case .conflict(let reasons) = items[0].kind else { Issue.record("expected conflict"); return }
        #expect(reasons == ["Contains alcohol"])
        // Alcoholic swaps are dropped; stock and leave-out remain.
        let ids = items[0].swaps.map(\.id)
        #expect(ids == ["chicken-stock", "leave-out"])
    }

    @Test func dislikeFlagged() {
        let r = recipe(["1 bunch fresh coriander"])
        let items = engine.review(recipe: r, pantry: .empty, prefs: UserPreferences(dislikes: ["cilantro"]))
        #expect(items.map(\.kind) == [.dislike("cilantro")])
        #expect(items[0].swaps.contains { $0.isLeaveOut })
    }

    @Test func vegetarianDropsChickenStockAndSuggestsVegetableStock() {
        let prefs = UserPreferences(diet: .vegetarian)
        let wine = engine.review(recipe: recipe(["2 tbsp Shaoxing wine"]), pantry: .empty, prefs: prefs)
        #expect(!wine[0].swaps.contains { $0.id == "chicken-stock" })

        let stock = engine.review(recipe: recipe(["2 cups chicken stock"]), pantry: .empty, prefs: prefs)
        guard case .conflict(let reasons) = stock[0].kind else { Issue.record("expected conflict"); return }
        #expect(reasons == ["Not vegetarian"])
        #expect(stock[0].swaps.first?.id == "vegetable-stock")
        #expect(!stock[0].swaps.contains { $0.id == "beef-stock" })
    }

    @Test func rankingPrefersPantry() {
        let pantry = PantrySnapshot(have: ["chicken-stock"])
        let s = engine.suggestions(for: "shaoxing-wine", pantry: pantry, prefs: UserPreferences())
        #expect(s.first?.id == "chicken-stock")  // ok (1) + pantry (3) + common (1) = 5 beats great (3)
        #expect(s.first?.fromPantry == true)
        #expect(s.first?.score == 5)
        #expect(s.count == 3)
    }

    @Test func rankingDropsMissingComponents() {
        let pantry = PantrySnapshot(missing: ["dry-sherry"])
        let s = engine.suggestions(for: "shaoxing-wine", pantry: pantry, prefs: UserPreferences())
        #expect(!s.contains { $0.id == "dry-sherry" })
        #expect(s.first?.id == "mirin")
    }

    @Test func spicyAndMild() {
        let r = recipe(["2 green chilies", "1 tsp cumin"])
        let items = engine.review(recipe: r, pantry: .empty, prefs: UserPreferences(spiceLevel: 1))
        #expect(items.map(\.kind) == [.tooSpicy])
        #expect(items[0].suggestedScale == 0.5)
        #expect(engine.review(recipe: r, pantry: .empty, prefs: UserPreferences(spiceLevel: 3)).isEmpty)
    }

    @Test func veganConflicts() {
        let r = recipe(["2 tbsp honey", "1 tbsp butter", "2 tbsp fish sauce", "1 tbsp soy sauce"])
        let items = engine.review(recipe: r, pantry: .empty, prefs: UserPreferences(diet: .vegan))
        #expect(items.count == 3)
        #expect(items.allSatisfy { if case .conflict = $0.kind { true } else { false } })
    }

    @Test func amountComponentsHaveNoQuantity() {
        let buttermilk = IngredientCatalog.shared.annotate(IngredientLineParser.parse("1 cup buttermilk"))
        let s = engine.suggestions(for: "buttermilk", pantry: .empty, prefs: UserPreferences())
        let milkLemon = try! #require(s.first { $0.id == "milk+lemon-juice" })
        let ings = milkLemon.replacementIngredients(for: buttermilk)
        #expect(ings[0].quantity == 1)
        #expect(ings[0].unit == "cup")
        #expect(ings[1].quantity == nil)
        #expect(ings[1].note == "1 tbsp per cup")
        #expect(milkLemon.title == "Milk + lemon juice")
    }
}

@Suite("Applying edits")
struct ApplyingTests {
    let engine = SwapEngine()

    @Test func swapRewritesSteps() throws {
        var r = Recipe(title: "Pork", ingredients: [
            IngredientLineParser.parse("½ cup Shaoxing wine"),
            IngredientLineParser.parse("1 tbsp soy sauce"),
        ], steps: ["Add the Shaoxing wine and soy sauce.", "shaoxing wine goes in last.", "Splash of Chinese cooking wine."])
        r = IngredientCatalog.shared.annotate(r)
        let wine = r.ingredients[0]
        let sherry = try #require(engine.suggestions(for: "shaoxing-wine", pantry: .empty, prefs: UserPreferences()).first)
        let out = r.applying([sherry.edit(for: wine)])
        #expect(out.ingredients[0].name == "dry sherry")
        #expect(out.ingredients[0].quantity == 0.5)
        #expect(out.ingredients[0].unit == "cup")
        #expect(out.ingredients[0].catalogID == "dry-sherry")
        #expect(out.steps == ["Add the dry sherry and soy sauce.", "Dry sherry goes in last.", "Splash of dry sherry."])
    }

    @Test func longerAliasesAreProtected() {
        let r = IngredientCatalog.shared.annotate(Recipe(title: "Pork", ingredients: [
            IngredientLineParser.parse("3 tbsp soy sauce"),
            IngredientLineParser.parse("1 tbsp dark soy sauce"),
        ], steps: ["Add the soy sauce, then the dark soy sauce.", "Stir in light soy sauce."]))
        let tamari = SwapSuggestion(items: [.init(catalogID: "tamari", name: "tamari")], quality: .great, note: "")
        let out = r.applying([tamari.edit(for: r.ingredients[0])])
        #expect(out.steps == ["Add the tamari, then the dark soy sauce.", "Stir in tamari."])
        #expect(out.ingredients.map(\.name) == ["tamari", "dark soy sauce"])
    }

    @Test func multiComponentSwapJoinsNames() {
        let r = IngredientCatalog.shared.annotate(Recipe(title: "Cake", ingredients: [IngredientLineParser.parse("1 cup buttermilk")],
                                                         steps: ["Whisk in the buttermilk."]))
        let s = engine.suggestions(for: "buttermilk", pantry: .empty, prefs: UserPreferences()).first!
        let out = r.applying([s.edit(for: r.ingredients[0])])
        #expect(out.steps == ["Whisk in the milk and lemon juice."])
        #expect(out.ingredients.count == 2)
    }

    @Test func leaveOutRemoves() {
        let r = IngredientCatalog.shared.annotate(Recipe(title: "x", ingredients: [IngredientLineParser.parse("1 tsp msg")]))
        let leave = SwapSuggestion(items: [], quality: .ok, note: "")
        #expect(r.applying([leave.edit(for: r.ingredients[0])]).ingredients.isEmpty)
    }

    @Test func otherEdits() {
        let a = IngredientLineParser.parse("2 cups rice")
        let r = Recipe(title: "x", ingredients: [a], steps: ["One"])
        let out = r.applying([
            .scaleIngredient(id: a.id, factor: 0.5),
            .addIngredient(IngredientLineParser.parse("1 tsp salt")),
            .updateStep(index: 0, text: "Uno"),
            .updateStep(index: 1, text: "Dos"),
            .updateStep(index: 5, text: "ignored"),
            .addNote("Good"),
            .removeIngredient(id: UUID()),
        ])
        #expect(out.ingredients.map(\.quantity) == [1, 1])
        #expect(out.steps == ["Uno", "Dos"])
        #expect(out.notes == ["Good"])
    }
}
