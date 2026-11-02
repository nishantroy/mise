import Foundation
import Testing
@testable import RecipeKit

/// "I made this" feedback about steps (time, heat, cover, skip, method, order).
enum StepFixtures {
    /// The owner's saved Pepper Chicken: their pasted version (ingredients and the 10 labelled steps).
    static func pepperChicken() throws -> Recipe {
        try #require(RecipeImporter.parse(text: Fixture.text("pepper-chicken-my-version")))
    }

    static func html(_ name: String) throws -> Recipe {
        try #require(RecipeImporter.parse(html: Fixture.html(name), url: nil))
    }

    static func recipe(_ name: String) throws -> Recipe {
        name == "pepper-chicken" ? try pepperChicken() : try html(name)
    }
}

@Suite("Step feedback")
struct StepFeedbackTests {
    static let ownerSentence = "I only cooked the chicken for 5 minutes on a high flame and then 5 minutes on low flame"

    @Test func ownersPepperChickenSentenceRewritesStep7Only() throws {
        let recipe = try StepFixtures.pepperChicken()
        #expect(recipe.steps.count == 10)
        #expect(recipe.steps[6] == "Chicken: Add chicken and coat well. Cover and cook on low 25–35 min until tender (boneless: ~15–20 min). No water needed.")
        let analysis = FeedbackParser().analyse(Self.ownerSentence, recipe: recipe)
        #expect(analysis.edits == [.updateStep(index: 6, text:
            "Chicken: Add chicken and coat well. Cook on high 5 min, then cover and cook on low 5 min until tender. No water needed.")])
        #expect(analysis.otherFeedback.isEmpty, "nothing left for the ingredient model")
        let applied = recipe.applying(analysis.edits)
        #expect(applied.ingredients == recipe.ingredients)
        #expect(applied.notes == recipe.notes)
        for i in recipe.steps.indices where i != 6 { #expect(applied.steps[i] == recipe.steps[i]) }

        // The proposal the UI shows: before/after with the reason, and the changed span.
        let change = try #require(analysis.stepChanges.first)
        let proposal = try #require(analysis.stepChanges.proposal(for: analysis.edits[0], in: recipe))
        #expect(proposal.fromFeedback && proposal.reason == change.clause && proposal.oldText == recipe.steps[6])
        let diff = StepTextDiff(old: proposal.oldText, new: proposal.newText)
        #expect(diff.prefix == "Chicken: Add chicken and coat well. ")
        #expect(diff.removed == "Cover and cook on low 25–35 min until tender (boneless: ~15–20 min). ")
        #expect(diff.added == "Cook on high 5 min, then cover and cook on low 5 min until tender. ")
        #expect(diff.suffix == "No water needed.")
        #expect(diff.compact(context: 3).prefix == "…and coat well. ")
    }

    @Test func ownersSentenceSplitAcrossSentencesAndCommas() throws {
        let recipe = try StepFixtures.pepperChicken()
        let expected = "Chicken: Add chicken and coat well. Cook on high 5 min, then cover and cook on low 5 min until tender. No water needed."
        for text in ["Cooked the chicken 5 min on high, then 5 min on low",
                     "Cooked the chicken for 5 minutes on high heat. Then 5 minutes on low."] {
            #expect(FeedbackParser.edits(from: text, recipe: recipe) == [.updateStep(index: 6, text: expected)], "\(text)")
        }
    }

    enum Expect: CustomStringConvertible {
        case rewrite(step: Int, text: String)
        case remove(step: Int)
        /// A note tied to the step; `model` = offered to the model for a rewrite.
        case note(step: Int, text: String, model: Bool)
        /// Not a step change: the generic note the parser always made.
        case generic(String)

        var description: String {
            switch self {
            case let .rewrite(step, _): "rewrite step \(step)"
            case let .remove(step): "remove step \(step)"
            case let .note(step, _, _): "note on step \(step)"
            case let .generic(note): "note \(note)"
            }
        }
    }

    static let cases: [(fixture: String, feedback: String, expect: Expect)] = [
        // Shorter, with "instead of".
        ("wikibooks-kung-pao-chicken", "Stir fried the chicken 6 minutes instead of 4",
         .rewrite(step: 7, text: "Add chicken mixture to wok and stir fry for about 6 minutes (until chicken is cooked through).")),
        ("pepper-chicken", "the chicken only needed 15 minutes instead of 30",
         .rewrite(step: 7, text: "Chicken: Add chicken and coat well. Cover and cook on low 15 min until tender. No water needed.")),
        // Longer: a range moves by the extra time; alternative times are kept.
        ("pepper-chicken", "the chicken needed 10 more minutes",
         .rewrite(step: 7, text: "Chicken: Add chicken and coat well. Cover and cook on low 35–45 min until tender (boneless: ~15–20 min). No water needed.")),
        ("woksoflife-red-braised-pork-belly", "the pork belly needed 30 more minutes to get tender",
         .rewrite(step: 3, text: "Next, add the Shaoxing wine, light soy sauce, dark soy sauce, cinnamon, star anise, bay leaves, dried chili peppers and water, and stir until everything is covered. Cover the wok and bring the mixture to a simmer over medium low heat for 1 hour 30 minutes, checking the pork now and then so the liquid doesn't cook away.")),
        ("recipetineats-chow-mein", "I stir fried the chicken for 3 minutes",
         .rewrite(step: 7, text: "Add chicken and stir fry until lightly browned outside but still raw in the middle - about 3 minutes.")),
        ("woksoflife-shortcut-mongolian-ground-beef", "marinated the beef 10 minutes less",
         .rewrite(step: 1, text: "Combine the ground beef, Shaoxing wine, soy sauce and baking soda in a medium bowl. Leave the beef to marinate for 10 minutes while you prep the other ingredients. (Or if making ahead, cover and refrigerate overnight.)")),
        // Only the sentence about the named ingredient changes.
        ("woksoflife-shortcut-mongolian-ground-beef", "fried the ginger for a minute",
         .rewrite(step: 5, text: "Over medium-high heat, add the red chili peppers and cook for 1 minute. Add the ginger, and fry for 1 minute. Add the white parts of the scallions and the garlic, and cook for another 30 seconds to a minute.")),
        // Heat.
        ("wikibooks-kung-pao-chicken", "cooked the vegetables on high heat",
         .rewrite(step: 8, text: "Add vegetables to wok and stir fry on high for about 2–3 minutes.")),
        ("indianhealthyrecipes-chicken-curry", "fried the chicken on high heat",
         .rewrite(step: 7, text: "Add chicken and coriander leaves. Fry on a high heat until the chicken is no longer pink. This takes around 3 mins.")),
        ("pepper-chicken", "sautéed the onions for 15 minutes on medium",
         .rewrite(step: 4, text: "Onions: Add onions, curry leaves, green chillies. Sauté on medium 15 min until light golden.")),
        // Cover.
        ("pepper-chicken", "cooked the chicken uncovered",
         .rewrite(step: 7, text: "Chicken: Add chicken and coat well. Cook uncovered on low 25–35 min until tender (boneless: ~15–20 min). No water needed.")),
        // Skipped steps: removed when nothing is lost, else a note on the step.
        ("woksoflife-red-braised-pork-belly", "skipped blanching the pork belly", .remove(step: 1)),
        ("pepper-chicken", "I skipped the dry out step", .remove(step: 8)),
        ("wikibooks-kung-pao-chicken", "didn't have time to marinate the chicken",
         .note(step: 2, text: "Step 2: Didn't have time to marinate the chicken", model: true)),
        // Oven instead of the stove: the long cook, for the model or a note.
        ("woksoflife-red-braised-pork-belly", "braised the pork in the oven at 160°C",
         .note(step: 3, text: "Step 3: Braised the pork in the oven at 160°C", model: true)),
        ("pepper-chicken", "did the chicken in the oven at 200°C",
         .note(step: 7, text: "Step 7 (Chicken): Did the chicken in the oven at 200°C", model: true)),
        // Order.
        ("pepper-chicken", "added the onions before the spices",
         .note(step: 4, text: "Step 4 (Onions): Added the onions before the spices", model: true)),
        ("recipetineats-chow-mein", "I added the garlic later",
         .note(step: 6, text: "Step 6: I added the garlic later", model: true)),
        // Ambiguous: the step is clear, the change isn't (no time for the high phase).
        ("pepper-chicken", "Cooked the chicken on high. Then 5 min on low.",
         .note(step: 7, text: "Step 7 (Chicken): Cooked the chicken on high, then 5 min on low", model: true)),
        // Step number.
        ("recipetineats-chow-mein", "step 9 needed 2 minutes",
         .rewrite(step: 9, text: "Tip in the noodles, Sauce and water. Stir fry for 2 minutes, tossing the whole time.")),
        // No step stands out: the generic note, as before.
        ("woksoflife-red-braised-pork-belly", "needed 10 more minutes", .generic("Needed about 10 more minutes than written")),
    ]

    @Test(arguments: cases.indices)
    func phrasing(_ i: Int) throws {
        let c = Self.cases[i]
        let recipe = try StepFixtures.recipe(c.fixture)
        let analysis = FeedbackParser().analyse(c.feedback, recipe: recipe)
        switch c.expect {
        case let .rewrite(step, text):
            #expect(analysis.edits == [.updateStep(index: step - 1, text: text)], "\(c.feedback): \(analysis.edits)")
        case let .remove(step):
            #expect(analysis.edits == [.removeStep(index: step - 1)], "\(c.feedback): \(analysis.edits)")
            #expect(recipe.applying(analysis.edits).steps.count == recipe.steps.count - 1)
        case let .note(step, text, model):
            #expect(analysis.edits == [.addNote(text)], "\(c.feedback): \(analysis.edits)")
            #expect(analysis.stepChanges.map(\.stepIndex) == [step - 1])
            #expect(analysis.stepChanges.first?.wantsModel == model)
            #expect(analysis.stepChanges.stepIndex(forNote: .addNote(text)) == step - 1)
        case let .generic(note):
            #expect(analysis.edits == [.addNote(note)], "\(c.feedback): \(analysis.edits)")
            #expect(analysis.stepChanges.isEmpty)
        }
    }

    @Test func ingredientFeedbackIsUntouchedAndStepEditsComeLast() throws {
        let recipe = try StepFixtures.pepperChicken()
        let e = FeedbackParser.edits(from: "too salty. skipped the cilantro, and I only cooked the chicken for 15 minutes", recipe: recipe)
        #expect(e.count == 3, "\(e)")
        #expect(e.last == .updateStep(index: 6, text: "Chicken: Add chicken and coat well. Cover and cook on low 15 min until tender. No water needed."))
        #expect(e.contains(.removeIngredient(id: recipe.ingredients.first { $0.name == "Cilantro" }!.id)))
        // "Skipped the cilantro" is an ingredient, not a step.
        #expect(!e.contains { if case .removeStep = $0 { true } else { false } })
        let analysis = FeedbackParser().analyse("too salty. skipped the cilantro, and I only cooked the chicken for 15 minutes", recipe: recipe)
        #expect(analysis.otherFeedback == "too salty. skipped the cilantro")
    }

    @Test func removalsApplyLastSoIndicesReferToTheSavedSteps() {
        let r = Recipe(title: "T", steps: ["a", "b", "c", "d"])
        let applied = r.applying([.removeStep(index: 0), .updateStep(index: 2, text: "C"), .removeStep(index: 3)])
        #expect(applied.steps == ["b", "C"])
        #expect(RecipeEdit.removeStep(index: 0).summary(in: r) == "Remove step 1")
        // Codable: a new case that old revisions never contain.
        let data = try! JSONEncoder().encode([RecipeEdit.removeStep(index: 2)])
        #expect(try! JSONDecoder().decode([RecipeEdit].self, from: data) == [.removeStep(index: 2)])
    }

    @Test func stepEditsRefreshTheTimeEstimate() throws {
        var recipe = try StepFixtures.pepperChicken()
        recipe.timeEstimate = TimeEstimator().estimate(recipe)
        let before = try #require(recipe.timeEstimate)
        let edited = recipe.applying(FeedbackParser.edits(from: Self.ownerSentence, recipe: recipe))
        #expect(edited.timeEstimate?.fits(edited) == false, "a step edit makes the stored estimate stale")
        let refreshed = try #require(edited.refreshingStaleTimeEstimate().timeEstimate)
        #expect(refreshed.fits(edited))
        #expect(refreshed.totalMinutes < before.totalMinutes, "\(before.totalMinutes) → \(refreshed.totalMinutes)")
    }
}

@Suite("Step rewrites from feedback (model output)")
struct FeedbackRewriteValidationTests {
    static let step = "Chicken: Add chicken and coat well. Cover and cook on low 25–35 min until tender (boneless: ~15–20 min). No water needed."

    @Test func requestsOnlyForNotesTheModelShouldTry() throws {
        let recipe = try StepFixtures.pepperChicken()
        let feedback = "did the chicken in the oven at 200°C. skipped the dry out step"
        let edits = FeedbackParser.edits(from: feedback, recipe: recipe)
        #expect(edits == [.addNote("Step 7 (Chicken): Did the chicken in the oven at 200°C"), .removeStep(index: 7)])
        let requests = StepRewrites.feedbackRequests(recipe: recipe, edits: edits, feedback: feedback)
        #expect(requests.count == 1)
        #expect(requests[0].kind == .feedback(clause: "Did the chicken in the oven at 200°C"))
        #expect(requests[0].stepIndex == 6 && requests[0].editIndex == 0)

        let good = "Chicken: Add chicken and coat well. Cover and cook in the oven at 200°C for 25–35 min until tender. No water needed."
        let proposal = try #require(StepRewrites.feedbackProposal(for: requests[0], text: good, recipe: recipe))
        #expect(proposal.fromFeedback && proposal.replacesEdit == 0 && proposal.stepIndex == 6)
        #expect(proposal.edit == .updateStep(index: 6, text: good))
        // The rules' answer for the owner's sentence needs no model.
        #expect(StepRewrites.feedbackRequests(recipe: recipe, edits: FeedbackParser.edits(from: StepFeedbackTests.ownerSentence, recipe: recipe),
                                              feedback: StepFeedbackTests.ownerSentence).isEmpty)
    }

    @Test func acceptsNumbersFromTheStepOrTheFeedback() {
        let feedback = "I only cooked the chicken for five minutes on high and then 5 minutes on low"
        let text = "Cook on high 5 min, then cover and cook on low 5 min until tender. No water needed."
        // The label is put back.
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten: text, feedback: feedback)
                == "Chicken: " + text)
    }

    @Test func rejectsInventedNumbers() {
        let feedback = "cooked the chicken 5 minutes on high then 5 on low"
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten:
            "Chicken: Add chicken and coat well. Cook on high 5 min, then cover and cook on low 12 min until tender.", feedback: feedback) == nil)
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten:
            "Chicken: Add chicken and coat well. Cook on high 5 min, then on low 5 min at 180°C until tender.", feedback: feedback) == nil,
                "a temperature nobody wrote")
    }

    @Test func rejectsDroppedTemperatures() {
        let original = "Roast at 220°C for 25 minutes until golden, turning once."
        #expect(StepRewrites.validateFeedbackRewrite(original: original, rewritten: "Roast for 35 minutes until golden, turning once.",
                                                     feedback: "roasted it for 35 minutes") == nil)
        #expect(StepRewrites.validateFeedbackRewrite(original: original, rewritten: "Roast at 220°C for 35 minutes until golden, turning once.",
                                                     feedback: "roasted it for 35 minutes") != nil)
        // A new temperature from the feedback may replace it.
        #expect(StepRewrites.validateFeedbackRewrite(original: original, rewritten: "Roast at 200°C for 25 minutes until golden, turning once.",
                                                     feedback: "roasted it at 200°C") != nil)
    }

    @Test func rejectsInventedIngredientsAndBadShapes() {
        let feedback = "did the chicken in the oven at 200°C"
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten:
            "Chicken: Add chicken and coat well. Cover and bake at 200°C until tender. Finish with butter.", feedback: feedback) == nil,
                "butter isn't in the step or the feedback")
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten: "Bake.", feedback: feedback) == nil, "too short")
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten: Self.step, feedback: feedback) == nil, "unchanged")
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten: "1 lb chicken", feedback: feedback) == nil)
        #expect(StepRewrites.validateFeedbackRewrite(original: Self.step, rewritten:
            "Chicken: Add chicken and coat well.\n\nBake at 200°C until tender.", feedback: feedback) == nil, "two paragraphs")
    }
}
