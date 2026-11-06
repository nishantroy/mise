import Foundation

/// "Find a substitute" on the recipe page: the same swap as cook mode's "Out of something?",
/// either kept in the saved recipe ("Update the recipe") or set up in a cook session for the
/// next cook ("Just this time").
public enum RecipeSwap {
    /// The edits that make swapping `ingredientID` for `suggestion` (nil or "Leave it out": a
    /// skip) part of `base`, the saved, unscaled recipe: amounts at the recipe's own servings and
    /// steps as cook mode would show them (renamed, an amount before the name rescaled for a
    /// ratio, "X and X" collapsed; a skip drops a plain list item). Empty when `base` doesn't
    /// have the ingredient.
    public static func edits(for ingredientID: UUID, suggestion: SwapSuggestion?, in base: Recipe,
                             catalog: IngredientCatalog = .shared) -> [RecipeEdit] {
        guard let ingredient = base.ingredient(id: ingredientID) else { return [] }
        return CookSwap.make(original: ingredient, suggestion: suggestion).recipeEdits(in: base, catalog: catalog)
    }

    /// The revision line: "Swapped ginger garlic paste for ginger and garlic", "Leave out sherry".
    public static func summary(of edits: [RecipeEdit], in base: Recipe) -> String {
        edits.first?.summary(in: base) ?? "No changes"
    }
}

extension CookSession {
    /// A session holding swaps chosen ahead of cooking ("Just this time" on the recipe page) and
    /// nothing else: still on the prep list, nothing ticked or timed.
    public var isSwapsOnly: Bool { page == 0 && checkedPrep.isEmpty && timers.isEmpty && !swaps.isEmpty }

    /// A new session for `base` (the saved recipe) at `servings`, with no swaps yet.
    public static func planned(recipeID: UUID, base: Recipe, servings: Int?, now: Date = .now) -> CookSession {
        CookSession(recipeID: recipeID, fingerprint: PrepPlanner.fingerprint(base), servings: servings ?? base.servings,
                    startedAt: now, updatedAt: now)
    }

    /// The swap of the saved recipe's ingredient `ingredientID` in this session, if any.
    public func swap(for ingredientID: UUID) -> CookSwap? {
        swaps.first { $0.original.id == ingredientID }
    }

    /// `base` (saved, unscaled) as this session cooks it: scaled to the session's servings.
    public func scaledRecipe(_ base: Recipe) -> Recipe {
        servings.map(base.scaled(to:)) ?? base
    }

    /// The session with the saved recipe's ingredient `ingredientID` swapped (or skipped, for a
    /// nil suggestion), replacing any earlier swap of it. Amounts are at the session's servings,
    /// worked out on the recipe as the session shows it (its other swaps applied). Returns nil
    /// when the ingredient isn't one of `base`'s lines. The swap's pantry fields are left for the caller.
    public func settingSwap(of ingredientID: UUID, suggestion: SwapSuggestion?, consequence: String?,
                            base: Recipe, catalog: IngredientCatalog = .shared, now: Date = .now) -> (session: CookSession, swap: CookSwap)? {
        // Only the saved recipe's own lines: an ingredient that came from a swap isn't swapped again.
        guard base.ingredient(id: ingredientID) != nil else { return nil }
        var copy = self
        copy.swaps.removeAll { $0.original.id == ingredientID }
        let shown = CookSwapApplier.replay(copy.swaps, on: scaledRecipe(base), catalog: catalog).recipe
        guard let ingredient = shown.ingredient(id: ingredientID) else { return nil }
        let swap = CookSwap.make(original: ingredient, suggestion: suggestion, consequence: consequence)
        copy.swaps.append(swap)
        copy.updatedAt = now
        return (copy, swap)
    }

    /// The session without the swap `id`.
    public func removingSwap(_ id: UUID, now: Date = .now) -> CookSession {
        var copy = self
        copy.swaps.removeAll { $0.id == id }
        copy.updatedAt = now
        return copy
    }

    /// The session at other servings, each swap's amounts worked out again from `base` (the swap,
    /// its note and pantry fields are kept). For a swaps-only session whose servings were changed
    /// on the recipe page before cooking; a swap whose ingredient is gone is dropped.
    public func rescaled(to newServings: Int?, base: Recipe, catalog: IngredientCatalog = .shared, now: Date = .now) -> CookSession {
        let target = newServings ?? base.servings
        guard target != servings else { return self }
        var copy = self
        copy.servings = target
        copy.swaps = []
        copy.plan = nil
        for old in swaps {
            guard let next = copy.settingSwap(of: old.original.id, suggestion: old.suggestion, consequence: old.consequence,
                                              base: base, catalog: catalog, now: now) else { continue }
            var swap = next.swap
            swap.id = old.id
            swap.pantryKey = old.pantryKey
            swap.pantryBefore = old.pantryBefore
            copy.swaps = Array(next.session.swaps.dropLast()) + [swap]
        }
        copy.updatedAt = now
        return copy
    }
}
