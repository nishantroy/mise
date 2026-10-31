import Foundation
import Testing
@testable import RecipeKit

private func mongolianBeef() throws -> Recipe {
    try #require(RecipeImporter.parse(html: Fixture.html("woksoflife-shortcut-mongolian-ground-beef"), url: nil))
}

private func recipe(_ lines: [String], steps: [String]) -> Recipe {
    IngredientCatalog.shared.annotate(Recipe(title: "Test", ingredients: lines.map(IngredientLineParser.parse), steps: steps))
}

@Suite("Repeated names after a multi-replace")
struct CollapseRepeatsTests {
    @Test func collapsesJoinedRepeats() {
        let name = "ginger garlic paste"
        #expect(StepRewriter.collapseRepeats(of: name, in: "Fry the ginger garlic paste and ginger garlic paste.") == "Fry the ginger garlic paste.")
        #expect(StepRewriter.collapseRepeats(of: name, in: "Fry the ginger garlic paste and the ginger garlic paste.") == "Fry the ginger garlic paste.")
        #expect(StepRewriter.collapseRepeats(of: name, in: "Ginger garlic paste & ginger garlic paste go in.") == "Ginger garlic paste go in.")
        #expect(StepRewriter.collapseRepeats(of: name, in: "Add ginger garlic paste, ginger garlic paste, and ginger garlic paste, then stir.")
                == "Add ginger garlic paste, then stir.")
        // Not joined: left alone.
        #expect(StepRewriter.collapseRepeats(of: name, in: "Add the ginger garlic paste. Then more ginger garlic paste.")
                == "Add the ginger garlic paste. Then more ginger garlic paste.")
    }

    @Test func mongolianBeefWithTheSwapAndOriginalSteps() throws {
        let original = try mongolianBeef()
        let mine = try #require(RecipeImporter.parse(text: Fixture.text("mongolian-beef-my-version")))
        let diff = RecipeDiff.compare(current: original, mine: mine)
        // Apply everything except the user's own steps.
        let edits = diff.edits.filter { if case .replaceSteps = $0 { false } else { true } }
        let applied = original.applying(edits)
        for step in applied.steps {
            #expect(!step.lowercased().contains("ginger garlic paste and ginger garlic paste"), "\(step)")
            #expect(!step.lowercased().contains("ginger garlic paste, ginger garlic paste"), "\(step)")
        }
        #expect(applied.steps[4] == "Over medium-high heat, add the red chili peppers and cook for 1 minute. Add the ginger garlic paste, and fry for 30 seconds. Add the white parts of the scallions and the ginger garlic paste, and cook for another 30 seconds to a minute.")

        // A recipe whose step names both in one list.
        let both = recipe(["2 tsp ginger, minced", "3 cloves garlic, chopped"], steps: ["Add the ginger and garlic, and fry for 30 seconds."])
        let paste = IngredientLineParser.parse("1 ½ tbsp ginger garlic paste")
        let swapped = both.applying([.replaceIngredients(ids: both.ingredients.map(\.id), with: [paste], reason: nil)])
        #expect(swapped.steps == ["Add the ginger garlic paste, and fry for 30 seconds."])
    }
}

@Suite("Step rewrites")
struct StepRewriteTests {
    @Test func requestsForAnAddNoStepMentionsAndAnAwkwardReplace() throws {
        let original = try mongolianBeef()
        let ginger = try #require(original.ingredients.first { $0.name == "ginger" })
        let garlic = try #require(original.ingredients.first { $0.name == "garlic" })
        let lime = IngredientLineParser.parse("1 tbsp lime juice")
        let edits: [RecipeEdit] = [
            .replaceIngredients(ids: [ginger.id, garlic.id], with: [IngredientLineParser.parse("1 ½ tbsp ginger garlic paste")], reason: nil),
            .addIngredient(lime),
            .addIngredient(IngredientLineParser.parse("1 tsp soy sauce")),  // already in the steps: no request
        ]
        let requests = StepRewrites.requests(recipe: original, edits: edits)
        #expect(requests.count == 2)
        #expect(requests[0].stepIndex == 4)
        #expect(requests[0].kind == .replaced(oldNames: ["ginger", "garlic"], newName: "ginger garlic paste"))
        #expect(requests[1].kind == .added(lime))
        #expect(requests[1].stepIndex == nil)

        // A good rewrite of step 5 for the replace.
        let good = "Over medium-high heat, add the red chili peppers and cook for 1 minute. Add the ginger garlic paste and the white parts of the scallions, and fry for 30 seconds to a minute."
        let proposal = try #require(StepRewrites.proposal(for: requests[0], stepNumber: 99, text: good, recipe: original, edits: edits))
        #expect(proposal.stepIndex == 4)
        #expect(proposal.dependsOn == [0])
        #expect(proposal.edit == .updateStep(index: 4, text: good))

        // The lime goes into the last step.
        let last = original.steps[5] + " Finish with the lime juice."
        let limeProposal = try #require(StepRewrites.proposal(for: requests[1], stepNumber: 6, text: last, recipe: original, edits: edits))
        #expect(limeProposal.stepIndex == 5)
        #expect(StepRewrites.proposal(for: requests[1], stepNumber: 7, text: last, recipe: original, edits: edits) == nil, "no step 7")
    }

    @Test func amountChangesAndSingleMentionsNeedNoRewrite() {
        let r = recipe(["2 tsp Shaoxing wine", "1 tbsp soy sauce"], steps: ["Add the Shaoxing wine and soy sauce."])
        let swap = RecipeEdit.replaceIngredient(id: r.ingredients[0].id, with: [IngredientLineParser.parse("2 tsp dry sherry")], reason: nil)
        #expect(StepRewrites.requests(recipe: r, edits: [swap]).isEmpty)
        let amount = RecipeEdit.replaceIngredient(id: r.ingredients[1].id, with: [IngredientLineParser.parse("2 tbsp soy sauce")], reason: RecipeEdit.amountChangeReason)
        #expect(StepRewrites.requests(recipe: r, edits: [amount]).isEmpty)
    }

    @Test func validation() {
        let original = "Simmer 2–3 minutes at 90°C, then add the ginger and garlic and 1 ½ tbsp water."
        let required = ["ginger garlic paste"]
        let removed = ["ginger", "garlic"]
        func check(_ text: String) -> String? {
            StepRewrites.validate(original: original, rewritten: text, required: required, removed: removed, masking: ["ginger garlic paste", "water"])
        }
        #expect(check("Simmer 2–3 minutes at 90°C, then add the ginger garlic paste and 1 ½ tbsp water.") != nil)
        #expect(check("Step 2: Simmer 2–3 minutes at 90°C, then add the ginger garlic paste and 1 ½ tbsp water.")
                == "Simmer 2–3 minutes at 90°C, then add the ginger garlic paste and 1 ½ tbsp water.")
        #expect(check("Simmer 3 minutes at 90°C, then add the ginger garlic paste and 1 ½ tbsp water.") == nil, "a number dropped")
        #expect(check("Simmer 2–3 minutes at 90 degrees, then add the ginger garlic paste and 1 ½ tbsp water.") == nil, "the temperature unit changed")
        #expect(check("Simmer 2–3 minutes at 90°C, then add 1 ½ tbsp water.") == nil, "the new ingredient is missing")
        #expect(check("Simmer 2–3 minutes at 90°C, then add the ginger garlic paste, extra garlic and 1 ½ tbsp water.") == nil, "an old name is back")
        #expect(check("Simmer 2–3 minutes at 90°C, then add the ginger garlic paste and 1 ½ tbsp water. " + String(repeating: "Stir well and keep stirring. ", count: 6)) == nil, "too long")
        #expect(check("Add the ginger garlic paste 2 3 90 1 ½") == nil, "too short")
        #expect(check(original) == nil, "unchanged")
        // Durations written as words still count.
        #expect(StepRewrites.validate(original: "Fry for a minute.", rewritten: "Fry the lime for a minute.", required: ["lime"], removed: []) != nil)
        #expect(StepRewrites.validate(original: "Fry for a minute.", rewritten: "Fry the lime briefly.", required: ["lime"], removed: []) == nil)
    }
}
