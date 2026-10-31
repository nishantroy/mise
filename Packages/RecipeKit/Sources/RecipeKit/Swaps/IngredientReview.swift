import Foundation

/// A resolved swap: what to use instead, how good it is, and whether it comes from the pantry.
public struct SwapSuggestion: Codable, Hashable, Sendable, Identifiable {
    public struct Item: Codable, Hashable, Sendable {
        public var catalogID: String?
        public var name: String
        public var ratio: Double?
        public var amount: String?

        public init(catalogID: String?, name: String, ratio: Double? = 1, amount: String? = nil) {
            self.catalogID = catalogID
            self.name = name
            self.ratio = amount == nil ? ratio : nil
            self.amount = amount
        }
    }

    public var items: [Item]
    public var quality: SwapQuality
    public var note: String
    public var fromPantry: Bool
    public var score: Int

    public init(items: [Item], quality: SwapQuality, note: String, fromPantry: Bool = false, score: Int = 0) {
        self.items = items
        self.quality = quality
        self.note = note
        self.fromPantry = fromPantry
        self.score = score
    }

    public var id: String { items.isEmpty ? "leave-out" : items.map { $0.catalogID ?? $0.name }.joined(separator: "+") }
    public var isLeaveOut: Bool { items.isEmpty }

    /// "Dry sherry", "Milk + lemon juice", "Leave it out".
    public var title: String {
        guard !items.isEmpty else { return "Leave it out" }
        let joined = items.map(\.name).joined(separator: " + ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// New ingredient lines for this swap: quantity × ratio in the same unit, or the amount as a note.
    public func replacementIngredients(for original: Ingredient) -> [Ingredient] {
        items.map { item in
            if let amount = item.amount {
                return Ingredient(raw: "\(item.name) (\(amount))", quantity: nil, unit: nil, name: item.name,
                                  note: amount, catalogID: item.catalogID)
            }
            let q = original.quantity.map { $0 * (item.ratio ?? 1) }
            var ing = Ingredient(raw: "", quantity: q, unit: q == nil ? nil : original.unit, name: item.name,
                                 note: nil, catalogID: item.catalogID)
            ing.raw = ing.displayText
            return ing
        }
    }

    /// The recipe edit that applies this swap.
    public func edit(for original: Ingredient) -> RecipeEdit {
        if isLeaveOut { return .removeIngredient(id: original.id) }
        return .replaceIngredient(id: original.id, with: replacementIngredients(for: original),
                                  reason: "Swapped \(original.name) for \(items.map(\.name).joined(separator: " and "))")
    }
}

/// Why an ingredient needs the user's attention before saving.
public enum ReviewKind: Hashable, Sendable {
    /// Conflicts with the user's diet or avoid list. Reasons are human-readable.
    case conflict([String])
    /// Matches one of the user's dislikes.
    case dislike(String)
    /// The pantry says they don't have it.
    case missing
    /// Specialty or rare and not yet known to the pantry: ask "Do you have X?".
    case askHave
    /// Spicy and the user prefers mild food; suggest a smaller amount.
    case tooSpicy
}

public struct ReviewItem: Identifiable, Hashable, Sendable {
    public var ingredient: Ingredient
    public var kind: ReviewKind
    public var swaps: [SwapSuggestion]
    /// Pantry key to record Yes/No answers under.
    public var pantryKey: String
    /// Suggested multiplier (0.5 for spicy ingredients when the user likes mild food).
    public var suggestedScale: Double?

    public var id: UUID { ingredient.id }

    public init(ingredient: Ingredient, kind: ReviewKind, swaps: [SwapSuggestion], pantryKey: String, suggestedScale: Double? = nil) {
        self.ingredient = ingredient
        self.kind = kind
        self.swaps = swaps
        self.pantryKey = pantryKey
        self.suggestedScale = suggestedScale
    }

    /// Short headline for the card.
    public var headline: String {
        switch kind {
        case .conflict(let reasons): reasons.joined(separator: " · ")
        case .dislike(let what): "You don't like \(what)"
        case .missing: "Not in your pantry"
        case .askHave: "Do you have \(ingredient.name)?"
        case .tooSpicy: "You prefer milder food"
        }
    }
}
