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
/// them (Shaoxing wine → dry sherry). Matched ingredients whose amount differs as written become
/// a scale (same unit) or an amount change (different units, a size word "large" → "medium", or
/// a qualifier "scant"); a whole spice for a ground one (black pepper → black peppercorns) is a
/// replace by the user's line. Everything else is a remove or an add, and the user's steps
/// replace the old ones in one edit, unless they look like an ingredient list (then the old
/// steps stay and `stepsWarning` says why). Notes the recipe doesn't have yet become `addNote`
/// edits.
public struct RecipeDiff: Hashable, Sendable {
    /// In display order: replaces, removes, amount changes, adds, the steps, then new notes.
    public var edits: [RecipeEdit]
    public var pantryUpdates: [PantryUpdate]
    /// The user's title, when it differs from the current one (offered, off by default).
    public var title: String?
    /// The user's servings, when given and different.
    public var servings: Int?
    /// Set when the user's steps weren't proposed because they look like ingredient lines (a
    /// paste whose ingredient list ended up in the method).
    public var stepsWarning: String?

    /// Same-unit amounts closer than this (relative) are the same amount. The cook wrote what they
    /// used, so any real difference is offered: 2 → 1¾ tbsp is a change. (Was 15%, which hid
    /// most of a "90% of the original" version.)
    public static let scaleThreshold = 0.005
    /// Amounts in different units closer than this are the same amount converted (1 cup / 240 ml).
    public static let conversionThreshold = 0.03

    public init(edits: [RecipeEdit], pantryUpdates: [PantryUpdate], title: String?, servings: Int?,
                stepsWarning: String? = nil) {
        self.edits = edits
        self.pantryUpdates = pantryUpdates
        self.title = title
        self.servings = servings
        self.stepsWarning = stepsWarning
    }

    /// `servingsRange`: the paste said "3–4 servings" (`mine.servings` is 3); a recipe already
    /// within the range isn't offered a servings change.
    public static func compare(current: Recipe, mine: Recipe, pantry: PantrySnapshot = .empty,
                               servingsRange: ClosedRange<Int>? = nil,
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
        var stepsWarning: String?
        if !mine.steps.isEmpty && mine.steps != original.steps {
            if StepStyleParser.stepsLookLikeIngredients(mine.steps) {
                // Never replace a method with an ingredient list.
                let bare = mine.steps.filter(StepStyleParser.isBareIngredientLine)
                stepsWarning = "Kept the recipe's steps: \(bare.count) of your \(mine.steps.count) steps look like ingredients (“\(bare[0])”). Put your method under a “Steps” heading and compare again."
            } else {
                edits.append(.replaceSteps(mine.steps))
            }
        }
        // Notes in the user's version that the recipe doesn't already have (tips from the paste).
        let existingNotes = Set(original.notes.map { $0.collapsedWhitespace.lowercased() })
        var seenNotes: Set<String> = []
        for note in mine.notes {
            let key = note.collapsedWhitespace.lowercased()
            guard !key.isEmpty, !existingNotes.contains(key), seenNotes.insert(key).inserted else { continue }
            edits.append(.addNote(note.collapsedWhitespace))
        }

        // Title and servings: offered separately.
        let myTitle = mine.title.trimmed
        let title = (!myTitle.isEmpty && myTitle != "Untitled recipe" && myTitle.lowercased() != original.title.lowercased()) ? myTitle : nil
        var servings = (mine.servings != nil && mine.servings != original.servings) ? mine.servings : nil
        if let servingsRange, let current = original.servings, servingsRange.contains(current) { servings = nil }

        return RecipeDiff(edits: edits,
                          pantryUpdates: pantryUpdates(swappedOut: replaces.flatMap(\.olds), mine: mine, pantry: pantry, catalog: catalog),
                          title: title, servings: servings, stepsWarning: stepsWarning)
    }

    // MARK: Amounts

    /// Scale (same unit) or amount change (different units, size or qualifier) when the amounts
    /// differ as written; the user's line when it's the whole form of a ground spice or the reverse.
    static func amountEdit(old: Ingredient, new: Ingredient) -> RecipeEdit? {
        if isWholeForm(old.name) != isWholeForm(new.name) {
            var line = new
            line.catalogID = new.catalogID ?? old.catalogID
            return .replaceIngredient(id: old.id, with: [line], reason: RecipeEdit.versionLineReason)
        }
        guard let qo = old.quantity, let qn = new.quantity, qo > 0, qn > 0 else { return nil }
        let newSize = sizeWord(new.name)
        let sizeChanged = newSize != nil && newSize != sizeWord(old.name)
        let qualifierChanged = qualifier(old) != qualifier(new)
        if old.unit == new.unit {
            let factor = qn / qo
            let differs = abs(factor - 1) > scaleThreshold
            if !sizeChanged && !qualifierChanged { return differs ? .scaleIngredient(id: old.id, factor: factor) : nil }
        } else if let bo = baseAmount(qo, old.unit), let bn = baseAmount(qn, new.unit), bo.kind == bn.kind,
                  abs(bn.value / bo.value - 1) < conversionThreshold, !sizeChanged, !qualifierChanged {
            return nil
        }
        // Keep the ingredient (name, note, catalog ID); take the user's amount, size, qualifier and
        // any alternative measure they gave ("1 lb (450 g)").
        var changed = old
        changed.quantity = qn
        changed.unit = new.unit
        if sizeChanged, let newSize {
            changed.name = sizeWord(old.name) != nil ? newSize + " " + nameWithoutSize(old.name) : newSize + " " + old.name
        }
        var notes = noteSegments(old).filter { $0.lowercased() != qualifier(old) && $0 != measureNote(old) }
        if let measure = measureNote(new) ?? measureNote(old) { notes.insert(measure, at: 0) }
        if let q = qualifier(new) { notes.insert(q, at: 0) }
        changed.note = notes.isEmpty ? nil : notes.joined(separator: ", ")
        changed.raw = changed.displayText
        return .replaceIngredient(id: old.id, with: [changed], reason: RecipeEdit.amountChangeReason)
    }

    // MARK: Amount wording

    static let sizeWords: Set<String> = ["small", "medium", "large", "big", "extra-large", "jumbo"]
    static let qualifiers: Set<String> = ["scant", "heaped", "heaping", "generous", "rounded", "level"]

    /// "large" in "large onions".
    static func sizeWord(_ name: String) -> String? {
        guard let first = name.split(separator: " ").first.map({ $0.lowercased() }), sizeWords.contains(first) else { return nil }
        return first
    }

    /// "large onions" → "onions".
    public static func nameWithoutSize(_ name: String) -> String {
        sizeWord(name) == nil ? name : name.split(separator: " ").dropFirst().joined(separator: " ")
    }

    static func noteSegments(_ ing: Ingredient) -> [String] {
        (ing.note ?? "").split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    /// "scant": the first note segment, where `IngredientLineParser` puts it.
    static func qualifier(_ ing: Ingredient) -> String? {
        noteSegments(ing).first.flatMap { qualifiers.contains($0.lowercased()) ? $0.lowercased() : nil }
    }

    /// An alternative measure in the note: "450 g", "~270 g".
    public static func measureNote(_ ing: Ingredient) -> String? {
        noteSegments(ing).first { Rx.test("^~?\\d+(?:\\.\\d+)?\\s*(?:g|kg|ml|l|oz|lb)$", $0) }
    }

    /// The amount as the cook would say it: "scant 1 tsp", "2 large", "0.5 kg".
    public static func amountText(_ ing: Ingredient) -> String? {
        guard let q = ing.quantity else { return nil }
        var parts: [String] = []
        if let qualifier = qualifier(ing) { parts.append(qualifier) }
        parts.append(QuantityFormatter.string(from: q, unit: ing.unit))
        if let unit = ing.unit { parts.append(Units.display(unit, quantity: q)) }
        if let size = sizeWord(ing.name) { parts.append(size) }
        return parts.joined(separator: " ")
    }

    /// Peppercorns, cumin seeds, whole cloves: measured differently from the ground spice.
    static func isWholeForm(_ name: String) -> Bool {
        Rx.test("\\b(?:peppercorns?|seeds?|whole|pods?)\\b", name)
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
