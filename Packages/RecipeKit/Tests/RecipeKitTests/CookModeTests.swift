import Foundation
import Testing
@testable import RecipeKit

private func chowMein() throws -> Recipe {
    try #require(RecipeImporter.parse(html: Fixture.html("recipetineats-chow-mein"), url: nil))
}

private func mongolianBeef() throws -> Recipe {
    try #require(RecipeImporter.parse(html: Fixture.html("woksoflife-shortcut-mongolian-ground-beef"), url: nil))
}

private func recipe(_ lines: [String], steps: [String], servings: Int? = nil) -> Recipe {
    IngredientCatalog.shared.annotate(Recipe(title: "Test", servings: servings, ingredients: lines.map(IngredientLineParser.parse), steps: steps))
}

private func names(_ ids: [UUID], in recipe: Recipe) -> [String] {
    ids.compactMap { recipe.ingredient(id: $0)?.name }
}

@Suite("Step ingredient linking")
struct StepLinkingTests {
    @Test func chowMeinForThisStep() throws {
        let r = try chowMein()
        let links = StepIngredientLinker().links(for: r)
        let got = r.steps.indices.map { names(links.forStep($0), in: r) }
        #expect(got == [
            // Step 1 also lists what no step mentions.
            ["cornflour / cornstarch", "soy sauce", "oyster sauce", "Chinese cooking wine", "sugar", "sesame oil", "White pepper"],
            [],                                                  // "Stir Fry Sauce" stays unresolved
            ["chicken breast or thigh fillets"],                 // "the chicken"; "Sauce" unresolved
            ["chow mein noodles", "water"],
            ["peanut oil"],                                      // "oil": peanut oil has 9× the sesame oil
            ["garlic"],
            ["chicken breast or thigh fillets"],
            ["green cabbage", "carrot"],                         // "shallots" isn't in the recipe
            ["chow mein noodles", "water"],
            ["bean sprouts", "green onions"],                    // "scallions" is a catalog alias
            [],
        ])
        #expect(names(links.unmentioned, in: r) == ["oyster sauce", "Chinese cooking wine", "sugar", "sesame oil", "White pepper"])
    }

    @Test func longestFirstAndPlurals() {
        let r = recipe(["1 tbsp soy sauce", "1 tsp dark soy sauce", "2 onions", "1 berry"],
                       steps: ["Add the dark soy sauce, then the soy sauce.", "Fry the onion, then add berries.", "Add spring onions."])
        let links = StepIngredientLinker().links(for: r)
        #expect(names(links.steps[0], in: r) == ["dark soy sauce", "soy sauce"])
        #expect(links.mentions[0].count == 2, "\"dark soy sauce\" is not also a \"soy sauce\" mention")
        #expect(names(links.steps[1], in: r) == ["onions", "berry"])
        #expect(links.steps[2].isEmpty, "spring onions are a different ingredient")
    }

    @Test func duplicateLinesByAmountNoteAndOrder() throws {
        let r = try mongolianBeef()
        let links = StepIngredientLinker().links(for: r)
        func amounts(_ step: Int, _ name: String) -> [String] {
            links.steps[step].compactMap(r.ingredient(id:)).filter { $0.name == name }.compactMap { RecipeEdit.amount($0) }
        }
        #expect(amounts(0, "soy sauce") == ["1 tsp"])        // first step to mention it: the first line
        #expect(amounts(1, "soy sauce") == ["¼ cup"])        // second: the second line
        #expect(amounts(1, "cornstarch") == ["1 tbsp"])      // "slurry" is in that line's note
        #expect(amounts(2, "cornstarch") == ["⅓ cup"])       // the step says "⅓ cup cornstarch"
        #expect(amounts(5, "cornstarch") == ["1 tbsp"])      // "slurry" again
        #expect(names(links.steps[4], in: r) == ["dried red chili peppers", "ginger", "scallions", "garlic"])
    }

    @Test func otherCatalogWordsNeedTheSameCategory() {
        let r = recipe(["1 tsp rice vinegar", "300 g chicken thigh fillets"], steps: ["Serve the chicken over rice."])
        #expect(names(StepIngredientLinker().links(for: r).steps[0], in: r) == ["chicken thigh fillets"])
    }

    @Test func genericWordsStayUnresolved() {
        let r = recipe(["1 tbsp soy sauce", "1 tbsp tomato paste"], steps: ["Pour in the sauce and the paste."])
        #expect(StepIngredientLinker().links(for: r).steps[0].isEmpty)
    }
}

@Suite("Cook timers")
struct CookTimerTests {
    @Test func chowMeinTimers() throws {
        let timers = CookTimers.timers(for: try chowMein())
        let got = timers.enumerated().filter { !$0.element.isEmpty }.map { step, list in
            "\(step + 1): " + list.map { "\($0.label)=\($0.seconds)" }.joined(separator: ", ")
        }
        #expect(got == ["3: 10 min=600", "4: 1 min=60", "6: 10 sec=10", "7: 1 min=60", "8: 1 ½ min=90", "9: 1 min=60", "10: 30 sec=30"])
        #expect(timers[2][0].passiveLabel == "marinating")
    }

    @Test func rangesUseTheUpperBoundAsOneValue() {
        let t = CookTimers.timers(in: "Cook the onion and bell pepper for 3–4 min. Simmer 2-3 minutes, then rest 30-40 mins.", step: 0)
        #expect(t.map(\.label) == ["4 min", "3 min", "40 min"])
        #expect(t.map(\.seconds) == [240, 180, 2400])
        #expect(t[2].passiveLabel == "resting")
    }

    @Test func secondsToAMinuteIsOneTimer() throws {
        let t = CookTimers.timers(for: try mongolianBeef())[4]
        #expect(t.map(\.label) == ["1 min", "30 sec", "1 min"])
        #expect(t.map(\.seconds) == [60, 30, 60])
    }

    @Test func perSideOvernightStorageAndWords() {
        #expect(CookTimers.timers(in: "Sear 1 min on each side.", step: 0).map(\.seconds) == [60])
        #expect(CookTimers.timers(in: "Marinate 4 hours or overnight.", step: 0).isEmpty)
        #expect(CookTimers.timers(in: "Keeps for up to 3 days in the fridge.", step: 0).isEmpty)
        let words = CookTimers.timers(in: "Bake for half an hour, then 1 hr 30 min more.", step: 0)
        #expect(words.map(\.label) == ["30 min", "1 hr 30 min"])
        #expect(words.map(\.seconds) == [1800, 5400])
        #expect(CookTimers.timers(in: "Add the garlic.", step: 0).isEmpty)
    }

    @Test func formatting() {
        #expect(CookTimers.format(seconds: 45) == "45 sec")
        #expect(CookTimers.format(seconds: 90) == "1 ½ min")
        #expect(CookTimers.format(seconds: 3600) == "1 hr")
        #expect(CookTimers.clock(245) == "4:05")
        #expect(CookTimers.clock(3725) == "1:02:05")
        #expect(CookTimers.clock(-3) == "0:00")
        #expect(CookTimers.clock(0.2) == "0:01", "rounds up, so 0:00 means done")
    }

    @Test func titlesComeFromTheWordsBeforeTheTime() throws {
        let t = CookTimers.timers(in: "Cook the onion and bell pepper for 3–4 min. Simmer 2-3 minutes, then rest 30-40 mins.", step: 0)
        #expect(t.map(\.title) == ["Cook the onion and bell pepper", "Simmer", "Rest"])
        #expect(CookTimers.timers(in: "Simmer the sauce for about 10 minutes, stirring.", step: 0).map(\.title) == ["Simmer the sauce"])
        #expect(CookTimers.timers(in: "Marinate the chicken in the fridge for at least 30 minutes.", step: 0).map(\.title)
                == ["Marinate the chicken"], "cut to 32 characters on a word")
        // The time first: the passive label, else "Timer".
        #expect(CookTimers.timers(in: "10 minutes later, flip.", step: 0).map(\.title) == ["Timer"])
        #expect(CookTimers.timers(in: "Leave the dough to rise in a warm spot, covered with a damp towel, for 1 hour.", step: 0)
            .allSatisfy { $0.title.count <= 32 && !$0.title.hasSuffix(",") })
        let chow = CookTimers.timers(for: try chowMein()).flatMap { $0 }
        #expect(chow.allSatisfy { !$0.title.isEmpty && $0.title.count <= 32 })
        // The nearest phrase before the time, past headings ("Marinate Chicken:") and amounts.
        #expect(chow.map(\.title) == ["Set aside to marinate", "My pack says soak in boiled", "Add garlic and stir fry",
                                      "Add chicken and stir fry", "Stir fry", "Stir fry", "Toss through"])
    }

    @Test func adjustingClampsAtTenSeconds() {
        #expect(CookTimerAdjust.adjusted(remaining: 240, by: 60) == 300)
        #expect(CookTimerAdjust.adjusted(remaining: 240, by: -60) == 180)
        #expect(CookTimerAdjust.adjusted(remaining: 50, by: -60) == 10)
        #expect(CookTimerAdjust.adjusted(remaining: 5, by: -60) == 5, "never lengthens on −1 min")
        #expect(CookTimerAdjust.adjusted(remaining: 12 * 3600 - 30, by: 60) == 12 * 3600)
        #expect(CookTimerAdjust.canShorten(remaining: 11))
        #expect(!CookTimerAdjust.canShorten(remaining: 10))
    }
}

@Suite("Prep planner")
struct PrepPlannerTests {
    @Test func chowMeinPlan() throws {
        let r = try chowMein()
        #expect(PrepPlanner().plan(for: r).text(in: r) == """
        Start early
        - Marinate the chicken · 10 min (step 3)
        - Boil water for the noodles (step 4)
        Chop and prep
        - Thinly slice 200 g chicken breast or thigh fillets
        - Finely shred 4 cups green cabbage
        - Finely chop 2 cloves garlic
        - Julienne 1 carrot
        - Cut 3 green onions into 5cm/2" pieces
        Mix ahead
        - Mix together 2 tsp cornflour / cornstarch and 1 ½ tbsp soy sauce (all purpose or light)
        Get out
        - 1 ½ tbsp peanut oil (or other cooking oil)
        - 200 g chow mein noodles
        - 1 ½ cups bean sprouts
        - ¼ cup water
        - 1 ½ tbsp oyster sauce (sub Hoisin)
        - 1 ½ tbsp Chinese cooking wine (or Mirin)
        - 2 tsp sugar (reduce to 1 tsp if using Mirin)
        - ½ tsp sesame oil
        - White pepper (sub black)
        """)
    }

    @Test func mongolianBeefPlan() throws {
        let r = try mongolianBeef()
        #expect(PrepPlanner().plan(for: r).text(in: r) == """
        Start early
        - Marinate 1 lb ground beef with 2 tsp Shaoxing wine (or dry cooking sherry, optional), 1 tsp soy sauce and ¼ tsp baking soda · 20 min (step 1)
        Chop and prep
        - Mince 2 tsp ginger
        - Cut 4 scallions (white and green parts separated, on a diagonal into 2-inch/5cm pieces)
        - Chop 3 cloves garlic
        Mix ahead
        - Mix the sauce: ¾ cup hot water (or hot low sodium chicken or beef stock), ¼ cup soy sauce, 1 tsp dark soy sauce (optional), ¼ cup brown sugar (light or dark) and 1 tbsp cornstarch (mixed with 2 tablespoons water to make a slurry)
        - Put ⅓ cup cornstarch in a shallow dish
        Get out
        - ¼ cup neutral oil
        - 8 dried red chili peppers (optional; use as little as 3 for mild heat or as many as 8 for a kick!)
        """)
    }

    @Test func theOwnersStepStyleVersion() throws {
        let r = try #require(RecipeImporter.parse(text: Fixture.text("mongolian-beef-my-version")))
        #expect(PrepPlanner().plan(for: r).text(in: r) == """
        Chop and prep
        - Slice ½ onion, 1 green bell pepper, 2 Fresnos (in rings) and 1 Thai chili (optional)
        - Chop 3 green onions and 1 handful cilantro
        - Toast and grind ¼ tsp Sichuan peppercorn (optional)
        Mix ahead
        - Put 1 ½ tbsp ginger garlic paste and 1 tbsp Lao Gan Ma in a small bowl
        - Whisk together ¼ cup soy sauce (or tamari), ¼ cup water, 3 tbsp sugar, 1 tbsp sherry, 1 tsp sesame oil and 1 tsp cornstarch (if using)
        Get out
        - 1 tbsp oil
        - 1 lb lean ground beef
        - ½ tsp salt
        - 1 tsp rice vinegar
        """)
    }

    @Test func everyIngredientExactlyOnceInEveryFixture() throws {
        var recipes: [Recipe] = []
        for name in ["recipetineats-chow-mein", "woksoflife-shortcut-mongolian-ground-beef", "woksoflife-red-braised-pork-belly",
                     "indianhealthyrecipes-chicken-curry", "bbcgoodfood-easy-pancakes", "wikibooks-kung-pao-chicken",
                     "wikibooks-kung-pao-chicken-mobile"] {
            recipes.append(try #require(RecipeImporter.parse(html: Fixture.html(name), url: nil)))
        }
        recipes.append(try #require(RecipeImporter.parse(text: Fixture.text("mongolian-beef-my-version"))))
        for r in recipes {
            let covered = PrepPlanner().plan(for: r).coveredIDs
            #expect(covered.count == r.ingredients.count, "\(r.title)")
            #expect(Set(covered) == Set(r.ingredients.map(\.id)), "\(r.title)")
        }
    }

    @Test func amountsFollowTheServings() throws {
        let r = try chowMein()
        let plan = PrepPlanner().plan(for: r)
        let doubled = r.scaled(to: 4)
        let chop = try #require(plan.group(.chopAndPrep))
        #expect(chop.items[0].text(in: doubled) == "Thinly slice 400 g chicken breast or thigh fillets")
        #expect(plan.group(.getOut)?.items[2].text(in: doubled) == "3 cups bean sprouts")
    }

    @Test func ovenRoomTemperatureAndSoftened() {
        let r = recipe(["115 g butter, softened", "2 eggs", "200 g flour", "1 tsp vanilla"],
                       steps: ["Preheat the oven to 180°C (350°F). Bring the eggs to room temperature.",
                               "Beat the butter with the sugar, then whisk in the eggs, flour and vanilla.",
                               "Bake for 25 minutes."])
        let text = PrepPlanner().plan(for: r).text(in: r)
        #expect(text == """
        Start early
        - Bring 115 g butter to room temperature
        - Preheat the oven to 180°C (step 1)
        - Bring the eggs to room temperature (step 1)
        Mix ahead
        - Whisk 2 eggs, 200 g flour and 1 tsp vanilla
        """)
    }

    @Test func passiveWaitAfterCookingIsNotStartEarly() {
        let r = recipe(["2 steaks", "1 tbsp oil"], steps: ["Sear the steaks in the oil for 3 minutes per side.", "Rest for 10 minutes."])
        #expect(PrepPlanner().plan(for: r).group(.startEarly) == nil)
    }
}

@Suite("Model prep plan mapping")
struct ModelPrepPlanTests {
    @Test func mapsNamesAndAddsWhatIsLeftOut() throws {
        let r = try chowMein()
        let rules = PrepPlanner().plan(for: r)
        let proposal = [
            ProposedPrepGroup(kind: .chopAndPrep, items: [
                ProposedPrepItem(action: "Thinly slice", ingredients: ["chicken breast or thigh fillets"]),
                ProposedPrepItem(action: "Shred and julienne:", ingredients: ["green cabbage", "carrot"]),
                ProposedPrepItem(action: "Chop 2 cloves", ingredients: ["garlic", "green onions"]),  // digits → default verb
            ]),
            ProposedPrepGroup(kind: .mixAhead, items: [
                ProposedPrepItem(action: "Whisk the sauce", ingredients: ["soy sauce", "cornstarch", "oyster sauce", "Shaoxing wine", "sugar", "sesame oil", "water"]),
            ]),
            ProposedPrepGroup(kind: .getOut, items: [ProposedPrepItem(action: "", ingredients: ["peanut oil", "noodles", "garlic"])]),  // garlic repeated
        ]
        let plan = try #require(PrepPlanner().map(proposal, recipe: r, rules: rules))
        #expect(plan.source == .model)
        #expect(plan.text(in: r) == """
        Start early
        - Marinate the chicken · 10 min (step 3)
        - Boil water for the noodles (step 4)
        Chop and prep
        - Thinly slice 200 g chicken breast or thigh fillets
        - Shred and julienne 4 cups green cabbage and 1 carrot
        - Prep 2 cloves garlic (finely chopped) and 3 green onions (cut into 5cm/2" pieces)
        Mix ahead
        - Whisk the sauce 1 ½ tbsp soy sauce (all purpose or light), 2 tsp cornflour / cornstarch, 1 ½ tbsp oyster sauce (sub Hoisin), 1 ½ tbsp Chinese cooking wine (or Mirin), 2 tsp sugar (reduce to 1 tsp if using Mirin), ½ tsp sesame oil and ¼ cup water
        Get out
        - 1 ½ tbsp peanut oil (or other cooking oil)
        - 200 g chow mein noodles
        - 1 ½ cups bean sprouts
        - White pepper (sub black)
        """)
        #expect(Set(plan.coveredIDs) == Set(r.ingredients.map(\.id)))
        #expect(plan.coveredIDs.count == r.ingredients.count)
    }

    @Test func inventedIngredientsInvalidateThePlan() throws {
        let r = try chowMein()
        let rules = PrepPlanner().plan(for: r)
        let proposal = [ProposedPrepGroup(kind: .chopAndPrep, items: [
            ProposedPrepItem(action: "Chop", ingredients: ["garlic", "shallots", "red onion", "basil"]),
        ])]
        #expect(PrepPlanner().map(proposal, recipe: r, rules: rules) == nil)
        #expect(PrepPlanner().map([], recipe: r, rules: rules) == nil)
    }

    @Test func listedTwiceMapsToTheNextLine() throws {
        let r = try mongolianBeef()
        let rules = PrepPlanner().plan(for: r)
        let proposal = [ProposedPrepGroup(kind: .mixAhead, items: [
            ProposedPrepItem(action: "Dredge", ingredients: ["cornstarch"]),
            ProposedPrepItem(action: "Slurry", ingredients: ["cornstarch"]),
        ])]
        let plan = try #require(PrepPlanner().map(proposal, recipe: r, rules: rules))
        let mix = try #require(plan.group(.mixAhead))
        #expect(mix.items.map { $0.text(in: r) } == [
            "Dredge 1 tbsp cornstarch (mixed with 2 tablespoons water to make a slurry)",
            "Slurry ⅓ cup cornstarch",
        ])
        // The rules' start-early marinade keeps its ingredients.
        #expect(plan.group(.startEarly)?.items.first?.ingredientIDs.count == 4)
    }

    @Test func actionCleaning() {
        #expect(PrepPlanner.cleanAction("Mix the sauce:") == "Mix the sauce")
        #expect(PrepPlanner.cleanAction("slice ½") == nil)
        #expect(PrepPlanner.cleanAction(String(repeating: "chop ", count: 12)) == nil)
        #expect(PrepPlanner.cleanAction("toast\nthen grind") == "Toast")
    }
}
