import Foundation

/// A pantry change implied by the user's version of a recipe, offered as a toggle (never applied
/// silently): ingredients they swapped out become "missing", specialty ones they used become "have".
public struct PantryUpdate: Hashable, Sendable, Identifiable {
    public enum Status: String, Hashable, Sendable { case have, missing }

    /// Catalog ID, or the normalised name (`IngredientCatalog.pantryKey`).
    public var key: String
    public var displayName: String
    public var status: Status

    public init(key: String, displayName: String, status: Status) {
        self.key = key
        self.displayName = displayName
        self.status = status
    }

    public var id: String { key }

    /// "Pantry: Shaoxing wine → don't have".
    public var summary: String {
        let name = displayName.prefix(1).uppercased() + displayName.dropFirst()
        return "Pantry: \(name) → \(status == .have ? "have" : "don't have")"
    }
}

/// Turns (current recipe, the user's own version) into reviewable edits.
///
/// Ingredients are matched by catalog ID, then by normalised name. Of what's left, a removed
/// ingredient and an added one become a single replace when a catalog entry stands in for
/// several (`replaces`: ginger + garlic → ginger garlic paste) or when the swaps table pairs
/// them (Shaoxing wine → dry sherry). Matched ingredients whose amount differs by at least
/// `scaleThreshold` become a scale (same unit) or an amount change (different units). Everything
/// else is a remove or an add, and the user's steps replace the old ones in one edit.
public struct RecipeDiff: Hashable, Sendable {
    /// In display order: replaces, removes, amount changes, adds, then the steps.
    public var edits: [RecipeEdit]
    public var pantryUpdates: [PantryUpdate]
    /// The user's title, when it differs from the current one (offered, off by default).
    public var title: String?
    /// The user's servings, when given and different.
    public var servings: Int?

    /// Amount differences smaller than this (relative) are ignored: 15%.
    public static let scaleThreshold = 0.15

    public init(edits: [RecipeEdit], pantryUpdates: [PantryUpdate], title: String?, servings: Int?) {
        self.edits = edits
        self.pantryUpdates = pantryUpdates
        self.title = title
        self.servings = servings
    }

    public static func compare(current: Recipe, mine: Recipe, pantry: PantrySnapshot = .empty,
                               catalog: IngredientCatalog = .shared) -> RecipeDiff {
        let original = annotateMissing(current, catalog: catalog)
        let mine = annotateMissing(mine, catalog: catalog)
        var leftOriginal = original.ingredients
        var leftMine = mine.ingredients
        var matched: [(old: Ingredient, new: Ingredient)] = []

        func take(_ ing: Ingredient, from list: inout [Ingredient]) {
            list.removeAll { $0.id == ing.id }
        }

        // 1. Same catalog ID; with several candidates (soy sauce in the marinade and the sauce),
        //    the closest amount wins.
        for m in mine.ingredients {
            guard let id = m.catalogID else { continue }
            let candidates = leftOriginal.filter { $0.catalogID == id }
            guard let best = candidates.min(by: { amountDistance($0, m) < amountDistance($1, m) }) else { continue }
            matched.append((best, m))
            take(best, from: &leftOriginal)
            take(m, from: &leftMine)
        }
        // 2. Same normalised name (ingredients the catalog doesn't know).
        for m in leftMine {
            let name = IngredientCatalog.normalisedName(m.name)
            let candidates = leftOriginal.filter { IngredientCatalog.normalisedName($0.name) == name }
            guard let best = candidates.min(by: { amountDistance($0, m) < amountDistance($1, m) }) else { continue }
            matched.append((best, m))
            take(best, from: &leftOriginal)
            take(m, from: &leftMine)
        }

        var replaces: [(edit: RecipeEdit, olds: [Ingredient])] = []
        // 3. One added entry that stands in for several removed ones.
        for m in leftMine {
            guard let id = m.catalogID, let stands = catalog.entry(id: id)?.replaces, !stands.isEmpty else { continue }
            let olds = leftOriginal.filter { $0.catalogID.map(stands.contains) ?? false }
            guard !olds.isEmpty else { continue }
            let reason = "Your version uses \(m.name)"
            let edit: RecipeEdit = olds.count == 1
                ? .replaceIngredient(id: olds[0].id, with: [m], reason: reason)
                : .replaceIngredients(ids: olds.map(\.id), with: [m], reason: reason)
            replaces.append((edit, olds))
            olds.forEach { take($0, from: &leftOriginal) }
            take(m, from: &leftMine)
        }
        // 4. Pairs from the swaps table, best quality first; then the table read backwards.
        for o in leftOriginal {
            guard let oid = o.catalogID else { continue }
            let options = catalog.swaps(for: oid).filter { $0.use.count == 1 }.sorted { $0.quality.score > $1.quality.score }
            var partner = options.lazy.compactMap { opt in leftMine.first { $0.catalogID == opt.use[0].id } }.first
            if partner == nil {
                partner = leftMine.first { m in
                    m.catalogID.map { catalog.swaps(for: $0).contains { $0.use.count == 1 && $0.use[0].id == oid } } ?? false
                }
            }
            guard let m = partner else { continue }
            replaces.append((.replaceIngredient(id: o.id, with: [m], reason: "Your version uses \(m.name)"), [o]))
            take(o, from: &leftOriginal)
            take(m, from: &leftMine)
        }

        // 5. Amounts of matched ingredients.
        var amountEdits: [RecipeEdit] = []
        for (old, new) in matched {
            if let edit = amountEdit(old: old, new: new) { amountEdits.append(edit) }
        }

        let removes = leftOriginal.map { RecipeEdit.removeIngredient(id: $0.id) }
        let adds = leftMine.map { RecipeEdit.addIngredient($0) }
        var edits = replaces.map(\.edit) + removes + amountEdits.sorted(by: { order($0, in: original) < order($1, in: original) }) + adds
        if !mine.steps.isEmpty && mine.steps != original.steps {
            edits.append(.replaceSteps(mine.steps))
        }

        // Title and servings: offered separately.
        let myTitle = mine.title.trimmed
        let title = (!myTitle.isEmpty && myTitle != "Untitled recipe" && myTitle.lowercased() != original.title.lowercased()) ? myTitle : nil
        let servings = (mine.servings != nil && mine.servings != original.servings) ? mine.servings : nil

        return RecipeDiff(edits: edits,
                          pantryUpdates: pantryUpdates(swappedOut: replaces.flatMap(\.olds), mine: mine, pantry: pantry, catalog: catalog),
                          title: title, servings: servings)
    }

    // MARK: Amounts

    /// Scale (same unit) or amount change (different units) when the amounts differ enough.
    static func amountEdit(old: Ingredient, new: Ingredient) -> RecipeEdit? {
        guard let qo = old.quantity, let qn = new.quantity, qo > 0, qn > 0 else { return nil }
        if old.unit == new.unit {
            let factor = qn / qo
            return abs(factor - 1) >= scaleThreshold ? .scaleIngredient(id: old.id, factor: factor) : nil
        }
        if let bo = baseAmount(qo, old.unit), let bn = baseAmount(qn, new.unit), bo.kind == bn.kind {
            guard abs(bn.value / bo.value - 1) >= scaleThreshold else { return nil }
        }
        // Different units: keep the ingredient (name, note, catalog ID), take the user's amount.
        var changed = old
        changed.quantity = qn
        changed.unit = new.unit
        changed.raw = changed.displayText
        return .replaceIngredient(id: old.id, with: [changed], reason: RecipeEdit.amountChangeReason)
    }

    /// Volume in teaspoons or weight in grams.
    static func baseAmount(_ quantity: Double, _ unit: String?) -> (value: Double, kind: Int)? {
        let volume: [String: Double] = ["tsp": 1, "tbsp": 3, "cup": 48, "ml": 0.2029, "l": 202.9, "fl oz": 6]
        let weight: [String: Double] = ["g": 1, "kg": 1000, "oz": 28.35, "lb": 453.6]
        guard let unit else { return nil }
        if let f = volume[unit] { return (quantity * f, 0) }
        if let f = weight[unit] { return (quantity * f, 1) }
        return nil
    }

    /// How different two amounts are (log ratio); unknown or incomparable amounts sort last.
    static func amountDistance(_ a: Ingredient, _ b: Ingredient) -> Double {
        guard let qa = a.quantity, let qb = b.quantity, qa > 0, qb > 0 else { return 50 }
        if a.unit == b.unit { return abs(log(qa / qb)) }
        if let ba = baseAmount(qa, a.unit), let bb = baseAmount(qb, b.unit), ba.kind == bb.kind {
            return abs(log(ba.value / bb.value))
        }
        return 20
    }

    static func order(_ edit: RecipeEdit, in recipe: Recipe) -> Int {
        guard let id = edit.targetID else { return Int.max }
        return recipe.ingredients.firstIndex { $0.id == id } ?? Int.max
    }

    // MARK: Pantry

    /// Swapped-out specialty or rare ingredients → missing (unless the user's version still uses
    /// them); specialty or rare ingredients in the user's version, and any currently marked
    /// missing → have. Staples and common items are left alone either way: swapping fresh ginger
    /// and garlic for a paste doesn't mean they're out of garlic. Changes the pantry already
    /// reflects are left out.
    static func pantryUpdates(swappedOut: [Ingredient], mine: Recipe, pantry: PantrySnapshot,
                              catalog: IngredientCatalog) -> [PantryUpdate] {
        let mineKeys = Set(mine.ingredients.map(catalog.pantryKey))
        var out: [PantryUpdate] = []
        var seen: Set<String> = []
        func isSpecialty(_ key: String) -> Bool {
            let commonness = catalog.entry(id: key)?.commonness
            return commonness == .specialty || commonness == .rare
        }
        for old in swappedOut {
            let key = catalog.pantryKey(for: old)
            guard isSpecialty(key), !mineKeys.contains(key), !pantry.missing.contains(key), !pantry.have.contains(key),
                  seen.insert(key).inserted else { continue }
            out.append(PantryUpdate(key: key, displayName: old.name, status: .missing))
        }
        for ing in mine.ingredients {
            let key = catalog.pantryKey(for: ing)
            guard isSpecialty(key) || pantry.missing.contains(key), !pantry.have.contains(key), seen.insert(key).inserted else { continue }
            out.append(PantryUpdate(key: key, displayName: ing.name, status: .have))
        }
        return out
    }

    static func annotateMissing(_ recipe: Recipe, catalog: IngredientCatalog) -> Recipe {
        var copy = recipe
        copy.ingredients = recipe.ingredients.map { $0.catalogID == nil ? catalog.annotate($0) : $0 }
        return copy
    }
}
