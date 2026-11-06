import Foundation
import Testing
@testable import RecipeKit

private func ingredient(_ name: String, in recipe: Recipe) throws -> Ingredient {
    try #require(recipe.ingredients.first { $0.name.lowercased() == name.lowercased() })
}

private func tableSwaps(for ing: Ingredient, pantry: PantrySnapshot = PantrySnapshot()) -> [SwapSuggestion] {
    SwapEngine().suggestions(for: ing.catalogID ?? IngredientCatalog.shared.match(ing.name)?.id,
                             pantry: pantry, prefs: UserPreferences(), ensureLeaveOut: true)
}

private func names(_ recipe: Recipe) -> [String] { recipe.ingredients.map(\.displayText) }

@Suite("Find a substitute on the recipe page")
struct RecipeSwapTests {
    /// Pepper Chicken: ginger garlic paste → ginger + garlic, kept in the recipe.
    @Test func updateTheRecipeAtItsOwnServings() throws {
        let base = try StepFixtures.pepperChicken()
        let paste = try ingredient("ginger garlic paste", in: base)
        let options = tableSwaps(for: paste, pantry: PantrySnapshot(have: ["ginger", "garlic"]))
        let ginger = try #require(options.first)
        #expect(ginger.title == "Ginger + garlic")
        #expect(ginger.fromPantry)

        // Chosen while the page shows double the servings: amounts still come from the saved recipe.
        let shown = base.scaled(to: (base.servings ?? 4) * 2)
        let shownPaste = try #require(shown.ingredient(id: paste.id))
        #expect(ginger.replacementIngredients(for: shownPaste).map(\.displayText) == ["1 ¾ tbsp ginger", "1 ¾ tbsp garlic"])

        let edits = RecipeSwap.edits(for: paste.id, suggestion: ginger, in: base)
        #expect(RecipeSwap.summary(of: edits, in: base) == "Swapped ginger garlic paste for ginger and garlic")
        let updated = base.applying(edits)
        let index = try #require(base.ingredients.firstIndex { $0.id == paste.id })
        // Half of 1 ¾ tbsp each (shown rounded to the nearest common fraction).
        #expect(updated.ingredients[index].name == "ginger" && updated.ingredients[index].quantity == 0.875)
        #expect(updated.ingredients[index + 1].name == "garlic" && updated.ingredients[index + 1].quantity == 0.875)
        #expect(updated.ingredients[index].unit == "tbsp")
        #expect(!updated.ingredients.contains { $0.id == paste.id })
        #expect(updated.steps[4] == "Aromatics: Add ginger and garlic. Sauté 1–2 min until the raw smell goes.")
        for s in base.steps.indices where s != 4 { #expect(updated.steps[s] == base.steps[s]) }
        #expect(updated.servings == base.servings)
    }

    @Test func leaveItOutDropsTheListItem() throws {
        let base = try StepFixtures.pepperChicken()
        let leaves = try ingredient("curry leaves", in: base)
        let edits = RecipeSwap.edits(for: leaves.id, suggestion: nil, in: base)
        #expect(RecipeSwap.summary(of: edits, in: base) == "Leave out curry leaves")
        let updated = base.applying(edits)
        #expect(!updated.ingredients.contains { $0.id == leaves.id })
        #expect(updated.steps[3] == "Onions: Add onions, green chillies. Sauté 5–10 min until light golden.")
        // "Leave it out" from the table is the same as a skip.
        let leaveOut = SwapSuggestion(items: [], quality: .ok, note: "Leave it out")
        #expect(RecipeSwap.edits(for: leaves.id, suggestion: leaveOut, in: base) == edits)
    }

    @Test func ratioRescalesTheAmountInTheStepAndCollapsesRepeats() throws {
        let base = IngredientCatalog.shared.annotate(Recipe(
            title: "Test", servings: 2,
            ingredients: ["¼ cup soy sauce", "1 tbsp fish sauce", "1 tsp sugar"].map(IngredientLineParser.parse),
            steps: ["Whisk ¼ cup soy sauce, the fish sauce and the sugar.", "Season with soy sauce."]))
        let soy = try ingredient("soy sauce", in: base)
        let fish = SwapSuggestion(items: [.init(catalogID: "fish-sauce", name: "fish sauce", ratio: 0.5)], quality: .good, note: "")
        let updated = base.applying(RecipeSwap.edits(for: soy.id, suggestion: fish, in: base))
        #expect(updated.steps[0] == "Whisk ⅛ cup fish sauce and the sugar." || updated.steps[0] == "Whisk ⅛ cup fish sauce, the fish sauce and the sugar.")
        #expect(updated.steps[1] == "Season with fish sauce.")
        #expect(names(updated).contains("⅛ cup fish sauce"))
    }

    @Test func missingIngredientGivesNoEdits() throws {
        let base = try StepFixtures.pepperChicken()
        #expect(RecipeSwap.edits(for: UUID(), suggestion: nil, in: base).isEmpty)
    }

    /// "Just this time": a session holding the swap, at the servings shown, ready for cook mode.
    @Test func justThisTimeSessionAtTheServingsShown() throws {
        let base = try StepFixtures.pepperChicken()
        let paste = try ingredient("ginger garlic paste", in: base)
        let ginger = try #require(tableSwaps(for: paste).first)
        let servings = (base.servings ?? 4) * 2
        let planned = CookSession.planned(recipeID: UUID(), base: base, servings: servings)
        #expect(!planned.hasProgress)
        let (session, swap) = try #require(planned.settingSwap(of: paste.id, suggestion: ginger, consequence: ginger.note, base: base))
        #expect(session.isSwapsOnly && session.hasProgress)
        #expect(session.isResumable(for: base, at: .now))
        #expect(swap.replacements.map(\.displayText) == ["1 ¾ tbsp ginger", "1 ¾ tbsp garlic"])
        #expect(session.swap(for: paste.id)?.id == swap.id)

        // Cook mode replays it on the recipe at the session's servings.
        let working = CookSwapApplier.replay(session.swaps, on: session.scaledRecipe(base)).recipe
        #expect(working.steps[4] == "Aromatics: Add ginger and garlic. Sauté 1–2 min until the raw smell goes.")
        #expect(working.ingredients.map(\.displayText).contains("1 ¾ tbsp garlic"))

        // Choosing again for the same ingredient replaces the swap; removing it empties the session.
        let (again, skip) = try #require(session.settingSwap(of: paste.id, suggestion: nil, consequence: nil, base: base))
        #expect(again.swaps.count == 1 && again.swaps[0].isSkip && skip.isSkip)
        #expect(!again.removingSwap(skip.id).hasProgress)

        // Kept at the end of cooking ("I made this"): the edits are at the recipe's own servings.
        let kept = base.applying(swap.recipeEdits(in: base))
        #expect(kept.ingredients.contains { $0.name == "ginger" && $0.quantity == 0.875 })
    }

    @Test func servingsChangedBeforeCooking() throws {
        let base = try StepFixtures.pepperChicken()
        let paste = try ingredient("ginger garlic paste", in: base)
        let ginger = try #require(tableSwaps(for: paste).first)
        var (session, swap) = try #require(CookSession.planned(recipeID: UUID(), base: base, servings: base.servings)
            .settingSwap(of: paste.id, suggestion: ginger, consequence: nil, base: base))
        session.swaps[0].pantryKey = "ginger-garlic-paste"
        session.swaps[0].pantryBefore = "have"
        let doubled = session.rescaled(to: (base.servings ?? 4) * 2, base: base)
        #expect(doubled.servings == (base.servings ?? 4) * 2)
        #expect(doubled.swaps.count == 1)
        #expect(doubled.swaps[0].id == swap.id)
        #expect(doubled.swaps[0].pantryKey == "ginger-garlic-paste" && doubled.swaps[0].pantryBefore == "have")
        #expect(doubled.swaps[0].replacements.map(\.displayText) == ["1 ¾ tbsp ginger", "1 ¾ tbsp garlic"])
        swap = doubled.swaps[0]
        #expect(doubled.rescaled(to: doubled.servings, base: base) == doubled)
    }

    @Test func secondSwapIsWorkedOutOnTheSwappedRecipe() throws {
        let base = try StepFixtures.pepperChicken()
        let paste = try ingredient("ginger garlic paste", in: base)
        let leaves = try ingredient("curry leaves", in: base)
        let planned = CookSession.planned(recipeID: UUID(), base: base, servings: nil)
        let one = try #require(planned.settingSwap(of: paste.id, suggestion: tableSwaps(for: paste).first, consequence: nil, base: base)).session
        let two = try #require(one.settingSwap(of: leaves.id, suggestion: nil, consequence: nil, base: base)).session
        #expect(two.swaps.count == 2)
        let working = CookSwapApplier.replay(two.swaps, on: two.scaledRecipe(base)).recipe
        #expect(working.steps[3] == "Onions: Add onions, green chillies. Sauté 5–10 min until light golden.")
        #expect(working.steps[4] == "Aromatics: Add ginger and garlic. Sauté 1–2 min until the raw smell goes.")
        // A swapped-in ingredient can't be swapped again from the recipe page.
        let gingerID = try #require(two.swaps[0].replacements.first?.id)
        #expect(two.settingSwap(of: gingerID, suggestion: nil, consequence: nil, base: base) == nil)
    }
}
