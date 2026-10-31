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

    /// "35 min · Chinese". Uses the stated time, or the estimate as "~45 min" when the page
    /// gave none; a guessed cuisine reads "Chinese (guess)".
    static func metadata(_ recipe: Recipe) -> String {
        [time(recipe), cuisine(recipe)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "35 min", or "~45 min" for an estimate.
    static func time(_ recipe: Recipe) -> String? {
        guard let t = recipe.displayTime else { return nil }
        return t.isEstimate ? "~" + duration(t.minutes) : duration(t.minutes)
    }

    static func cuisine(_ recipe: Recipe) -> String? {
        guard let c = recipe.cuisine?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        return recipe.cuisineIsGuess ? "\(c) (guess)" : c
    }

    /// The detail screen's realistic-time line, or nil when there's nothing to add to the stated time:
    /// "Realistically ~55 min (30 min marinating) · recipe says 15 min", or, with no stated time,
    /// "Estimated ~1 hr 5 min (30 min marinating)". Shown only when the estimate is meaningfully
    /// longer than the stated time (`Recipe.timeMismatch`) or there is no stated time.
    static func realisticTime(_ recipe: Recipe) -> String? {
        guard let e = recipe.timeEstimate else { return nil }
        let realistic: String
        if e.isOvernight {
            realistic = "overnight + ~\(duration(max(5, e.activeMinutes)))"
        } else {
            realistic = "~\(duration(e.totalMinutes))"
        }
        var waiting = ""
        if let label = e.passiveLabel, e.passiveMinutes > 0 {
            waiting = e.isOvernight ? " (\(label == "overnight" ? "waiting" : label))" : " (\(duration(e.passiveMinutes)) \(label))"
        }
        if let stated = recipe.totalMinutes, stated > 0 {
            guard recipe.timeMismatch else { return nil }
            return "Realistically \(realistic)\(waiting) · recipe says \(duration(stated))"
        }
        return "Estimated \(realistic)\(waiting)"
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
