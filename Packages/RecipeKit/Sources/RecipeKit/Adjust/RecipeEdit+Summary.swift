import Foundation

extension RecipeEdit {
    /// One-line, human summary, e.g. "Swapped Shaoxing wine for dry sherry".
    public func summary(in recipe: Recipe) -> String {
        switch self {
        case let .replaceIngredient(id, replacements, _):
            let old = recipe.ingredient(id: id)?.name ?? "an ingredient"
            if replacements.isEmpty { return "Leave out \(old)" }
            return "Swapped \(old) for \(replacements.map(\.name).joined(separator: " and "))"
        case let .scaleIngredient(id, factor):
            guard let ing = recipe.ingredient(id: id) else { return "Change an ingredient amount" }
            let lead: String
            if factor <= 0.5 + 1e-9 { lead = "Half the" }
            else if factor < 1 { lead = "Less" }
            else if factor >= 2 - 1e-9 { lead = "Double the" }
            else { lead = "More" }
            var text = "\(lead) \(ing.name)"
            if let q = ing.quantity {
                let unit = ing.unit.map { " " + Units.display($0, quantity: q) } ?? ""
                let newUnit = ing.unit.map { " " + Units.display($0, quantity: q * factor) } ?? ""
                text += ": \(QuantityFormatter.string(from: q, unit: ing.unit))\(unit) → \(QuantityFormatter.string(from: q * factor, unit: ing.unit))\(newUnit)"
            }
            return text
        case let .removeIngredient(id):
            return "Leave out \(recipe.ingredient(id: id)?.name ?? "an ingredient")"
        case let .addIngredient(ing):
            return "Add \(ing.displayText)"
        case let .updateStep(index, text):
            return "Step \(index + 1): \(text)"
        case let .addNote(note):
            return "Note: \(note)"
        }
    }
}

extension Array where Element == RecipeEdit {
    /// Summary of several edits for a revision entry.
    public func summary(in recipe: Recipe) -> String {
        guard !isEmpty else { return "No changes" }
        return map { $0.summary(in: recipe) }.joined(separator: "; ")
    }
}
