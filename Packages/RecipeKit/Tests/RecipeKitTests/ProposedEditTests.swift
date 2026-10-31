import Foundation
import Testing
@testable import RecipeKit

@Suite("Assistant edit mapping")
struct ProposedEditTests {
    let recipe = IngredientCatalog.shared.annotate(Recipe(title: "Larb", ingredients: [
        "500 g ground pork", "2 tbsp fish sauce", "1 tbsp lime juice", "Salt to taste", "1 bunch mint",
    ].map(IngredientLineParser.parse)))

    func id(_ name: String) -> UUID { recipe.ingredients.first { $0.name == name }!.id }

    @Test func mapsEachKind() {
        let proposals: [ProposedEdit] = [
            .init(kind: .scale, ingredient: "fish sauce", factor: 1.25),
            .init(kind: .add, replacement: "1 lime, cut into wedges"),
            .init(kind: .replace, ingredient: "pork", replacement: "chicken mince"),
            .init(kind: .remove, ingredient: "mint"),
            .init(kind: .note, text: "Finish with lime just before serving"),
        ]
        let edits = ProposedEdit.map(proposals, in: recipe)
        #expect(edits.count == 5)
        #expect(edits[0] == .scaleIngredient(id: id("fish sauce"), factor: 1.25))
        guard case .addIngredient(let lime) = edits[1] else { Issue.record("add"); return }
        #expect(lime.name == "lime")
        guard case .replaceIngredient(let target, let with, _) = edits[2] else { Issue.record("replace"); return }
        #expect(target == id("ground pork"))
        #expect(with.first?.quantity == 500)
        #expect(edits[3] == .removeIngredient(id: id("mint")))
        #expect(edits[4] == .addNote("Finish with lime just before serving"))
    }

    @Test func dropsWhatDoesNotMap() {
        let proposals: [ProposedEdit] = [
            .init(kind: .scale, ingredient: "saffron", factor: 0.5),       // not in recipe
            .init(kind: .remove, ingredient: ""),                         // empty
            .init(kind: .scale, ingredient: "fish sauce", factor: 1.0),   // no-op
            .init(kind: .scale, ingredient: "fish sauce", factor: 40),    // absurd
            .init(kind: .note, text: "  "),
            .init(kind: .replace, ingredient: "mint", replacement: "mint"),
        ]
        #expect(ProposedEdit.map(proposals, in: recipe).isEmpty)
    }

    @Test func scalingSaltToTasteBecomesNote() {
        #expect(ProposedEdit(kind: .scale, ingredient: "salt", factor: 0.5).map(in: recipe) == .addNote("Use less salt than last time"))
    }

    @Test func addingExistingMeansMore() {
        #expect(ProposedEdit(kind: .add, replacement: "fish sauce").map(in: recipe) == .scaleIngredient(id: id("fish sauce"), factor: 1.25))
    }

    @Test func addWithSplitAmountAndName() {
        guard case .addIngredient(let ing) = ProposedEdit(kind: .add, ingredient: "lime", replacement: "1 tbsp").map(in: recipe) else {
            Issue.record("expected add"); return
        }
        #expect(ing.name == "lime")
        #expect(ing.quantity == 1)
        #expect(ing.unit == "tbsp")
        #expect(ProposedEdit(kind: .add, replacement: "1 tbsp").map(in: recipe) == nil)
    }

    @Test func oneEditPerIngredient() {
        let edits = ProposedEdit.map([
            .init(kind: .scale, ingredient: "fish sauce", factor: 1.25),
            .init(kind: .scale, ingredient: "fish sauce", factor: 1.5),
        ], in: recipe)
        #expect(edits.count == 1)
    }
}
