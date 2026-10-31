import Foundation
import Testing
@testable import RecipeKit

private func ownersMongolianBeef() throws -> Recipe {
    try #require(RecipeImporter.parse(text: Fixture.text("mongolian-beef-my-version")))
}

private func chowMein() throws -> Recipe {
    try #require(RecipeImporter.parse(html: Fixture.html("recipetineats-chow-mein"), url: nil))
}

private func recipe(_ lines: [String], steps: [String], servings: Int? = nil) -> Recipe {
    IngredientCatalog.shared.annotate(Recipe(title: "Test", servings: servings, ingredients: lines.map(IngredientLineParser.parse), steps: steps))
}

private func ingredient(_ name: String, in recipe: Recipe) throws -> Ingredient {
    try #require(recipe.ingredients.first { $0.name.lowercased() == name.lowercased() })
}

private func swap(_ name: String, to id: String?, in recipe: Recipe) throws -> CookSwap {
    let ing = try ingredient(name, in: recipe)
    let suggestion = id.map { SwapSuggestion(items: [.init(catalogID: $0, name: IngredientCatalog.shared.displayName(for: $0))], quality: .good, note: "") }
    return CookSwap.make(original: ing, suggestion: suggestion)
}

@Suite("Out of something: swaps in a cooking session")
struct CookSwapTests {
    /// The owner's walk-through: out of sherry at step 5 of their Mongolian beef.
    @Test func ownersMongolianBeefOutOfSherry() throws {
        let r = try ownersMongolianBeef()
        let sherry = try ingredient("sherry", in: r)
        let pantry = PantrySnapshot(have: ["mirin"], missing: ["shaoxing-wine"])
        let options = SwapEngine().suggestions(for: sherry.catalogID, pantry: pantry, prefs: UserPreferences(), ensureLeaveOut: true)
        #expect(options.map(\.title) == ["Mirin", "White wine", "Leave it out"])
        #expect(options[0].fromPantry)
        #expect(options[0].replacementIngredients(for: sherry).map(\.displayText) == ["1 tbsp mirin"])

        let chosen = CookSwap.make(original: sherry, suggestion: options[0])
        let (working, notes) = CookSwapApplier.replay([chosen], on: r)
        #expect(working.steps[4] == "Whisk together ¼ cup soy sauce or tamari, ¼ cup water, 3 tbsp sugar, 1 tbsp mirin, 1 tsp sesame oil, and 1 tsp cornstarch (if using).")
        #expect(working.steps.enumerated().filter { $0.offset != 4 }.map(\.element) == r.steps.enumerated().filter { $0.offset != 4 }.map(\.element))
        #expect(notes == [4: ["Swapped: mirin for sherry"]])
        #expect(working.ingredients.map(\.displayText).contains("1 tbsp mirin"))
        #expect(!working.ingredients.contains { $0.id == sherry.id })

        // "For this step" and the prep list follow.
        let links = StepIngredientLinker().links(for: working)
        let stepNames = links.forStep(4).compactMap { working.ingredient(id: $0)?.name }
        #expect(stepNames.contains("mirin"))
        let plan = PrepPlanner().plan(for: r)
        let shown = plan.substituting([sherry.id: chosen.replacements.map(\.id)]).visible(in: working)
        #expect(shown.group(.mixAhead)?.items.last?.text(in: working)
            == "Whisk together ¼ cup soy sauce (or tamari), ¼ cup water, 3 tbsp sugar, 1 tbsp mirin, 1 tsp sesame oil and 1 tsp cornstarch (if using)")
        #expect(plan.itemIDs(covering: sherry.id) == [shown.group(.mixAhead)!.items.last!.id])
        // Timers are unchanged (same IDs, same durations).
        #expect(CookTimers.timers(for: working) == CookTimers.timers(for: r))
    }

    @Test func skippingRemovesTheListItem() throws {
        let r = try ownersMongolianBeef()
        let skip = try swap("sherry", to: nil, in: r)
        #expect(skip.isSkip && skip.label == "Skipped: sherry")
        let (working, notes) = CookSwapApplier.replay([skip], on: r)
        #expect(working.steps[4] == "Whisk together ¼ cup soy sauce or tamari, ¼ cup water, 3 tbsp sugar, 1 tsp sesame oil, and 1 tsp cornstarch (if using).")
        #expect(notes == [4: ["Skipped: sherry"]])
        // The prep item drops it; an item left with nothing is hidden.
        let shown = PrepPlanner().plan(for: r).visible(in: working)
        #expect(shown.group(.mixAhead)?.items.last?.text(in: working).contains("sherry") == false)
    }

    @Test func skipShapes() {
        func skip(_ name: String, _ step: String, lines: [String]) -> String {
            let r = recipe(lines, steps: [step])
            let ing = r.ingredients.first { $0.name == name }!
            return CookSwapApplier.apply(CookSwap.make(original: ing, suggestion: nil), to: r).recipe.steps[0]
        }
        #expect(skip("garlic", "Add the beef and garlic.", lines: ["1 lb beef", "2 cloves garlic"]) == "Add the beef.")
        #expect(skip("salt", "Add 1 lb beef with ½ tsp salt.", lines: ["1 lb beef", "½ tsp salt"]) == "Add 1 lb beef.")
        #expect(skip("sugar", "Whisk 1 tbsp soy sauce, 1 tbsp vinegar, and 1 tsp sugar.", lines: ["1 tbsp soy sauce", "1 tbsp vinegar", "1 tsp sugar"])
            == "Whisk 1 tbsp soy sauce and 1 tbsp vinegar.")
        #expect(skip("garlic", "Add the garlic, ginger and beef.", lines: ["2 cloves garlic", "1 tsp ginger", "1 lb beef"]) == "Add the ginger and beef.")
        #expect(skip("cilantro", "Cilantro and lime to finish.", lines: ["cilantro", "1 lime"]) == "Lime to finish.")
        // Not plainly a list item: the text stays (the step's note says it was skipped).
        #expect(skip("sherry", "Pour in the sherry. Simmer 2 min.", lines: ["1 tbsp sherry"]) == "Pour in the sherry. Simmer 2 min.")
    }

    @Test func ratioRescalesTheAmountWrittenInTheStep() throws {
        let r = recipe(["¼ cup soy sauce", "1 tbsp sugar"], steps: ["Whisk ¼ cup soy sauce and 1 tbsp sugar.", "Add the soy sauce mixture."])
        let soy = try ingredient("soy sauce", in: r)
        let fish = SwapSuggestion(items: [.init(catalogID: "fish-sauce", name: "fish sauce", ratio: 0.5)], quality: .ok, note: "Much funkier; use half")
        let s = CookSwap.make(original: soy, suggestion: fish)
        let working = CookSwapApplier.replay([s], on: r).recipe
        #expect(working.steps == ["Whisk ⅛ cup fish sauce and 1 tbsp sugar.", "Add the fish sauce mixture."])
        #expect(working.ingredients.map(\.displayText) == ["⅛ cup fish sauce", "1 tbsp sugar"])
    }

    @Test func repeatsOfTheNewNameCollapse() throws {
        let r = recipe(["1 tbsp Shaoxing wine", "1 tbsp dry sherry"], steps: ["Add the Shaoxing wine and the dry sherry, then simmer."])
        let s = try swap("Shaoxing wine", to: "dry-sherry", in: r)
        #expect(CookSwapApplier.replay([s], on: r).recipe.steps == ["Add the dry sherry, then simmer."])
    }

    @Test func undoReplaysTheRemainingSwaps() throws {
        let r = try ownersMongolianBeef()
        let sherry = try swap("sherry", to: "mirin", in: r)
        let sesame = try swap("sesame oil", to: nil, in: r)
        let both = CookSwapApplier.replay([sherry, sesame], on: r).recipe
        #expect(both.steps[4] == "Whisk together ¼ cup soy sauce or tamari, ¼ cup water, 3 tbsp sugar, 1 tbsp mirin, and 1 tsp cornstarch (if using).")
        let undone = CookSwapApplier.replay([sesame], on: r).recipe
        #expect(undone.steps[4] == "Whisk together ¼ cup soy sauce or tamari, ¼ cup water, 3 tbsp sugar, 1 tbsp sherry, and 1 tsp cornstarch (if using).")
        #expect(undone.ingredients.contains { $0.name == "sherry" })
    }

    @Test func modelPatchAppliesOnlyOnTheTextItWasMadeFrom() throws {
        let r = recipe(["1 tbsp Shaoxing wine", "1 tbsp dry sherry"], steps: ["Add the Shaoxing wine. Add the dry sherry."])
        var s = try swap("Shaoxing wine", to: "dry-sherry", in: r)
        let rules = CookSwapApplier.replay([s], on: r).recipe.steps[0]
        #expect(rules == "Add the dry sherry. Add the dry sherry.")
        s.reworded = [StepPatch(stepIndex: 0, from: rules, to: "Add all the dry sherry.")]
        #expect(CookSwapApplier.replay([s], on: r).recipe.steps[0] == "Add all the dry sherry.")
        s.reworded = [StepPatch(stepIndex: 0, from: "something else", to: "Add all the dry sherry.")]
        #expect(CookSwapApplier.replay([s], on: r).recipe.steps[0] == rules)
    }

    /// "Keep this swap in the recipe?": amounts come from the saved (unscaled) recipe and the
    /// step reads as it did in cook mode.
    @Test func recipeEditsUseTheSavedAmounts() throws {
        let base = recipe(["¼ cup soy sauce", "1 tsp sugar", "1 tbsp sherry"], steps: ["Whisk ¼ cup soy sauce, 1 tbsp sherry, and 1 tsp sugar."], servings: 2)
        let scaled = base.scaled(to: 4)
        let soy = try ingredient("soy sauce", in: scaled)
        let fish = SwapSuggestion(items: [.init(catalogID: "fish-sauce", name: "fish sauce", ratio: 0.5)], quality: .ok, note: "")
        let session = CookSwap.make(original: soy, suggestion: fish)
        #expect(session.replacements.map(\.displayText) == ["¼ cup fish sauce"])
        let saved = base.applying(session.recipeEdits(in: base))
        #expect(saved.ingredients.map(\.displayText) == ["⅛ cup fish sauce", "1 tsp sugar", "1 tbsp sherry"])
        #expect(saved.steps == ["Whisk ⅛ cup fish sauce, 1 tbsp sherry, and 1 tsp sugar."])

        let skip = try swap("sherry", to: nil, in: scaled)
        let skipped = base.applying(skip.recipeEdits(in: base))
        #expect(skipped.steps == ["Whisk ¼ cup soy sauce and 1 tsp sugar."])
        #expect(!skipped.ingredients.contains { $0.name == "sherry" })
        #expect(skip.recipeEdits(in: Recipe(title: "Other")).isEmpty)
    }

    @Test func typedOrDictatedNames() throws {
        let chow = try chowMein()
        #expect(MissingIngredientMatcher.query("Ah damn, I'm out of Shaoxing wine.") == "Shaoxing wine")
        #expect(MissingIngredientMatcher.matches("out of shaoxing wine", in: chow).map(\.name) == ["Chinese cooking wine"])
        #expect(MissingIngredientMatcher.matches("no oyster sauce", in: chow).map(\.name) == ["oyster sauce"])
        #expect(MissingIngredientMatcher.matches("oyst", in: chow).map(\.name) == ["oyster sauce"])
        #expect(MissingIngredientMatcher.matches("saffron", in: chow).isEmpty)
        let beef = try ownersMongolianBeef()
        #expect(MissingIngredientMatcher.matches("I don't have any sherry", in: beef).map(\.name) == ["sherry"])
    }

    @Test func skipConsequences() {
        func line(_ name: String) -> String? { SkipConsequence.text(for: IngredientCatalog.shared.annotate(Ingredient(raw: name, name: name))) }
        #expect(line("Shaoxing wine") == "Less depth; fine to skip")
        #expect(line("kasuri methi") == "Leave it out; a squeeze of lemon at the end helps")
        #expect(line("cornstarch") == "The sauce will be thinner; simmer it a little longer")
        #expect(line("chicken thighs") == "It's a main part of the dish; a swap is better")
        #expect(line("unobtainium") == nil)
    }
}

@Suite("Cook session persistence")
struct CookSessionTests {
    @Test func roundTrip() throws {
        let r = try ownersMongolianBeef()
        let plan = PrepPlanner().plan(for: r)
        let s = try swap("sherry", to: "mirin", in: r)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timer = CookSessionTimer(id: UUID(), specID: "6.0", step: 6, name: "Brown the beef", endDate: now.addingTimeInterval(120),
                                     finished: false, alarmID: UUID())
        let session = CookSession(recipeID: UUID(), fingerprint: PrepPlanner.fingerprint(r), servings: 4, page: 7,
                                  checkedPrep: [plan.items[0].id], plan: plan, swaps: [s], timers: [timer], startedAt: now, updatedAt: now)
        let data = try #require(session.encoded())
        let decoded = try #require(CookSession.decode(data))
        #expect(decoded == session)
        #expect(decoded.plan?.text(in: r) == plan.text(in: r))
        #expect(CookSwapApplier.replay(decoded.swaps, on: r).recipe == CookSwapApplier.replay([s], on: r).recipe)

        #expect(decoded.isResumable(for: r, at: now.addingTimeInterval(3600)))
        #expect(!decoded.isResumable(for: r, at: now.addingTimeInterval(13 * 3600)))  // expired
        var edited = r
        edited.steps[0] += " Carefully."
        #expect(!decoded.isResumable(for: edited, at: now))  // the recipe changed since
        // Scaling doesn't change the fingerprint.
        #expect(decoded.isResumable(for: r.scaled(to: 8), at: now))
        let fresh = CookSession(recipeID: UUID(), fingerprint: PrepPlanner.fingerprint(r), servings: 4, startedAt: now, updatedAt: now)
        #expect(!fresh.isResumable(for: r, at: now))  // nothing to resume
    }

    @Test func unknownVersionOrGarbageIsIgnored() throws {
        #expect(CookSession.decode(Data("nope".utf8)) == nil)
        var session = CookSession(recipeID: UUID(), fingerprint: "x", servings: nil, page: 2)
        session.version = 99
        #expect(CookSession.decode(try #require(session.encoded())) == nil)
    }

    @Test func timerReconciliation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func timer(_ endIn: TimeInterval, finished: Bool = false, alarm: UUID? = UUID()) -> CookSessionTimer {
            CookSessionTimer(id: UUID(), specID: "1.0", step: 1, name: "Simmer", endDate: now.addingTimeInterval(endIn), finished: finished, alarmID: alarm)
        }
        let running = timer(300)
        let cancelledElsewhere = timer(300)
        let rangOut = timer(-60)
        let ringing = timer(-5)
        let notification = timer(200, alarm: nil)
        let notificationPassed = timer(-200, alarm: nil)
        let alreadyDone = timer(-600, finished: true)
        let alarms: [UUID: CookAlarmState] = [running.alarmID!: .pending, ringing.alarmID!: .alerting]
        let out = CookTimerReconciler.reconcile([running, cancelledElsewhere, rangOut, ringing, notification, notificationPassed, alreadyDone],
                                                alarms: alarms, now: now)
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        #expect(byID[running.id] == running)
        #expect(byID[cancelledElsewhere.id] == nil)
        #expect(byID[rangOut.id]?.finished == true && byID[rangOut.id]?.alarmID == nil)
        #expect(byID[ringing.id]?.finished == true && byID[ringing.id]?.alarmID == ringing.alarmID)
        #expect(byID[notification.id] == notification)
        #expect(byID[notificationPassed.id]?.finished == true)
        #expect(byID[alreadyDone.id]?.finished == true && byID[alreadyDone.id]?.alarmID == nil)
        #expect(out.map(\.id) == [running, rangOut, ringing, notification, notificationPassed, alreadyDone].map(\.id))

        // Alarm list unreadable: trust the stored alarms.
        let blind = CookTimerReconciler.reconcile([cancelledElsewhere], alarms: nil, now: now)
        #expect(blind == [cancelledElsewhere])
    }
}
