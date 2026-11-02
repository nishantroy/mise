import Foundation

extension RecipeEdit {
    /// One-line, human summary, e.g. "Swapped Shaoxing wine for dry sherry".
    public func summary(in recipe: Recipe) -> String {
        switch self {
        case let .replaceIngredient(id, replacements, reason):
            let oldIngredient = recipe.ingredient(id: id)
            let old = oldIngredient?.name ?? "an ingredient"
            if replacements.isEmpty { return "Leave out \(old)" }
            if reason == RecipeEdit.amountChangeReason, replacements.count == 1, let oldIngredient {
                // "Change onions: 2 large → 2 medium (~270 g)", "Change turmeric: 1 tsp → scant 1 tsp".
                let new = replacements[0]
                let from = RecipeDiff.amountText(oldIngredient) ?? "some"
                var to = RecipeDiff.amountText(new) ?? "some"
                if let measure = RecipeDiff.measureNote(new), RecipeDiff.measureNote(oldIngredient) != measure {
                    to += " (\(measure))"
                }
                return "Change \(RecipeDiff.nameWithoutSize(oldIngredient.name)): \(from) → \(to)"
            }
            if reason == RecipeEdit.versionLineReason, replacements.count == 1, let oldIngredient {
                let from = Self.amount(oldIngredient).map { " (\($0))" } ?? ""
                return "Change \(old)\(from) to \(replacements[0].displayText)"
            }
            return "Swapped \(old) for \(replacements.map(\.name).joined(separator: " and "))"
        case let .replaceIngredients(ids, replacements, _):
            let olds = ids.compactMap { recipe.ingredient(id: $0)?.name }
            let old = olds.isEmpty ? "some ingredients" : Self.list(olds)
            if replacements.isEmpty { return "Leave out \(old)" }
            return "Swapped \(old) for \(replacements.map(\.name).joined(separator: " and "))"
        case let .scaleIngredient(id, factor):
            guard let ing = recipe.ingredient(id: id) else { return "Change an ingredient amount" }
            let lead: String
            if abs(factor - 0.5) < 0.02 { lead = "Half the" }
            else if factor < 1 { lead = "Less" }
            else if abs(factor - 2) < 0.02 { lead = "Double the" }
            else { lead = "More" }
            var text = "\(lead) \(ing.name)"
            if let q = ing.quantity {
                let unit = ing.unit.map { " " + Units.display($0, quantity: q) } ?? ""
                let newUnit = ing.unit.map { " " + Units.display($0, quantity: q * factor) } ?? ""
                text += ": \(QuantityFormatter.string(from: q, unit: ing.unit))\(unit) → \(QuantityFormatter.string(from: q * factor, unit: ing.unit))\(newUnit)"
            }
            return text
        case let .removeIngredient(id):
            guard let ing = recipe.ingredient(id: id) else { return "Leave out an ingredient" }
            // Two lines with the same name (marinade and sauce): say which one.
            let duplicated = recipe.ingredients.contains {
                $0.id != id && $0.name.lowercased() == ing.name.lowercased()
            }
            if duplicated, let amount = Self.amount(ing) { return "Leave out \(ing.name) (\(amount))" }
            return "Leave out \(ing.name)"
        case let .addIngredient(ing):
            // "Add ½ tsp cumin seeds (for tempering, optional)": the note says why it's a second line.
            if let note = ing.note, !note.isEmpty, note.count <= 40 { return "Add \(ing.displayText) (\(note))" }
            return "Add \(ing.displayText)"
        case let .updateStep(index, text):
            return "Step \(index + 1): \(text)"
        case let .addNote(note):
            return "Note: \(note)"
        case let .replaceSteps(steps):
            return "Use your steps (\(steps.count) \(steps.count == 1 ? "step" : "steps"))"
        case let .removeStep(index):
            let label = recipe.steps.indices.contains(index) ? StepFeedbackParser.label(of: recipe.steps[index]) : nil
            return "Remove step \(index + 1)\(label.map { " (\($0))" } ?? "")"
        }
    }

    /// "¼ cup", "3", or nil without a quantity.
    static func amount(_ ing: Ingredient) -> String? {
        guard let q = ing.quantity else { return nil }
        let unit = ing.unit.map { " " + Units.display($0, quantity: q) } ?? ""
        return QuantityFormatter.string(from: q, unit: ing.unit) + unit
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

extension Array where Element == RecipeEdit {
    /// Summary of several edits for a revision entry.
    public func summary(in recipe: Recipe) -> String {
        guard !isEmpty else { return "No changes" }
        return map { $0.summary(in: recipe) }.joined(separator: "; ")
    }
}
