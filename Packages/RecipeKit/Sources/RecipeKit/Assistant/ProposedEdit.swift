import Foundation

/// A loosely-typed edit as a language model (or any other assistant) describes it, using
/// ingredient names rather than IDs. `map` turns it into a `RecipeEdit` or drops it.
public struct ProposedEdit: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case replace, scale, remove, add, note
    }

    public var kind: Kind
    public var ingredient: String
    public var replacement: String
    public var factor: Double
    public var text: String

    public init(kind: Kind, ingredient: String = "", replacement: String = "", factor: Double = 1, text: String = "") {
        self.kind = kind
        self.ingredient = ingredient
        self.replacement = replacement
        self.factor = factor
        self.text = text
    }

    /// Maps names back to recipe ingredients with the same matcher the rules use.
    /// Returns nil for anything that doesn't map (unknown ingredient, empty text, no-op factor).
    public func map(in recipe: Recipe, kind feedbackKind: FeedbackKind = .cooked, catalog: IngredientCatalog = .shared) -> RecipeEdit? {
        let parser = FeedbackParser(catalog: catalog, kind: feedbackKind)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .replace:
            guard let original = parser.findIngredient(ingredient, in: recipe) else { return nil }
            return parser.replace(original, with: replacement)
        case .scale:
            guard let original = parser.findIngredient(ingredient, in: recipe),
                  factor.isFinite, factor > 0.1, factor < 4, abs(factor - 1) > 0.01 else { return nil }
            return parser.scale(original, factor: factor)
        case .remove:
            guard let original = parser.findIngredient(ingredient, in: recipe) else { return nil }
            return .removeIngredient(id: original.id)
        case .add:
            // Models sometimes split "1 tbsp lime juice" into replacement "1 tbsp" + ingredient "lime juice".
            let rep = replacement.trimmingCharacters(in: .whitespaces)
            let ing = ingredient.trimmingCharacters(in: .whitespaces)
            var source = rep.isEmpty ? ing : rep
            if !rep.isEmpty, !ing.isEmpty, !rep.lowercased().contains(ing.lowercased()) {
                source = "\(rep) \(ing)"
            }
            guard !source.isEmpty else { return nil }
            let parsedName = IngredientLineParser.parse(source).name
            // Reject bare amounts ("1 tbsp") that name no ingredient.
            guard Units.canonical(for: parsedName) == nil, parsedName.rangeOfCharacter(from: .letters) != nil else { return nil }
            // "Add" of something already in the recipe means "more of it".
            if parser.findIngredient(source, in: recipe) != nil,
               let existing = parser.findIngredient(source, in: recipe),
               IngredientCatalog.normalise(existing.name) == IngredientCatalog.normalise(IngredientLineParser.parse(source).name) {
                return parser.scale(existing, factor: 1.25)
            }
            return parser.newIngredient(source).map { .addIngredient($0) }
        case .note:
            guard !trimmedText.isEmpty else { return nil }
            return .addNote(trimmedText)
        }
    }

    /// Maps a list, dropping unmappable and duplicate edits (and duplicate targets).
    public static func map(_ proposals: [ProposedEdit], in recipe: Recipe, kind: FeedbackKind = .cooked,
                           catalog: IngredientCatalog = .shared) -> [RecipeEdit] {
        var out: [RecipeEdit] = []
        var touched: Set<UUID> = []
        for p in proposals {
            guard let edit = p.map(in: recipe, kind: kind, catalog: catalog), !out.contains(edit) else { continue }
            if let id = edit.targetID {
                guard !touched.contains(id) else { continue }
                touched.insert(id)
            }
            out.append(edit)
        }
        return out
    }
}

extension RecipeEdit {
    /// The ingredient an edit changes, if any (the first, for a multi-replace).
    public var targetID: UUID? { targetIDs.first }

    /// Every existing ingredient an edit changes.
    public var targetIDs: [UUID] {
        switch self {
        case .replaceIngredient(let id, _, _), .scaleIngredient(let id, _), .removeIngredient(let id): [id]
        case .replaceIngredients(let ids, _, _): ids
        default: []
        }
    }
}
