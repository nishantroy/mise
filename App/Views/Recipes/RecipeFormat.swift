import Foundation
import RecipeKit

/// Display helpers for recipe metadata.
enum RecipeFormat {
    /// "1 hr 45 min", "35 min".
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) hr"
        default: return "\(h) hr \(m) min"
        }
    }

    /// "35 min · Chinese".
    static func metadata(_ recipe: Recipe) -> String {
        var parts: [String] = []
        if let t = recipe.totalMinutes { parts.append(duration(t)) }
        if let c = recipe.cuisine, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    /// Quantity and unit for an ingredient row ("1 ½ cups"), or nil.
    static func amount(_ ingredient: Ingredient) -> String? {
        guard let q = ingredient.quantity else { return nil }
        let qty = QuantityFormatter.string(from: q, unit: ingredient.unit)
        guard let unit = ingredient.unit else { return qty }
        return "\(qty) \(Units.display(unit, quantity: q))"
    }

    static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
