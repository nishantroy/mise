import Foundation

/// A step a model may reword after a proposed edit: an added ingredient no step mentions, or a
/// step a swap left awkward ("Add the ginger garlic paste, … the scallions and the ginger garlic paste").
public struct StepRewriteRequest: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The model picks the one step where the new ingredient goes.
        case added(Ingredient)
        /// The step at `stepIndex` reads awkwardly after replacing `oldNames` with `newName`.
        case replaced(oldNames: [String], newName: String)
    }

    public var kind: Kind
    /// The edit (index into the proposed edits) that causes it.
    public var editIndex: Int
    /// The step to reword; nil for `.added` (the model chooses).
    public var stepIndex: Int?
    /// At least one of these must appear in the new text.
    public var required: [String]
    /// None of these may appear in the new text.
    public var removed: [String]
}

/// A validated rewrite of one step, offered as an extra (unticked) toggle.
public struct StepRewriteProposal: Hashable, Sendable {
    public var stepIndex: Int
    public var oldText: String
    public var newText: String
    /// Edits (indices into the proposed edits) the new text relies on. If any is unticked, the
    /// rewrite must be left out too.
    public var dependsOn: [Int]

    public var edit: RecipeEdit { .updateStep(index: stepIndex, text: newText) }

    public init(stepIndex: Int, oldText: String, newText: String, dependsOn: [Int]) {
        self.stepIndex = stepIndex
        self.oldText = oldText
        self.newText = newText
        self.dependsOn = dependsOn
    }
}

/// Finding steps worth rewording and validating a model's rewrite. Only ever one step per
/// request, never whole recipes, and never the user's own pasted steps.
public enum StepRewrites {
    public static let maxRequests = 2
    public static let maxLength = 600

    /// Steps worth rewording after `edits` are applied (at most `maxRequests`, one per edit):
    /// - an added ingredient that no step mentions (the model picks the step);
    /// - a replace (not an amount change) whose new name now appears twice in one step.
    public static func requests(recipe: Recipe, edits: [RecipeEdit], catalog: IngredientCatalog = .shared) -> [StepRewriteRequest] {
        guard !recipe.steps.isEmpty else { return [] }
        let after = recipe.applying(edits, catalog: catalog)
        let links = StepIngredientLinker(catalog: catalog).links(for: after)
        var out: [StepRewriteRequest] = []
        for (i, edit) in edits.enumerated() where out.count < maxRequests {
            switch edit {
            case let .addIngredient(ing):
                guard links.unmentioned.contains(ing.id) else { continue }
                out.append(StepRewriteRequest(kind: .added(ing), editIndex: i, stepIndex: nil,
                                              required: names(for: ing, catalog: catalog), removed: []))
            case let .replaceIngredient(id, with, reason):
                guard !with.isEmpty, reason != RecipeEdit.amountChangeReason, let old = recipe.ingredient(id: id) else { continue }
                if let request = replaced([old], with: with, editIndex: i, recipe: recipe, after: after, catalog: catalog) { out.append(request) }
            case let .replaceIngredients(ids, with, _):
                let olds = ids.compactMap(recipe.ingredient(id:))
                guard !with.isEmpty, !olds.isEmpty else { continue }
                if let request = replaced(olds, with: with, editIndex: i, recipe: recipe, after: after, catalog: catalog) { out.append(request) }
            default:
                continue
            }
        }
        return out
    }

    static func replaced(_ olds: [Ingredient], with: [Ingredient], editIndex: Int, recipe: Recipe, after: Recipe,
                         catalog: IngredientCatalog) -> StepRewriteRequest? {
        let newName = with.map(\.name).joined(separator: " and ")
        for s in after.steps.indices where s < recipe.steps.count && after.steps[s] != recipe.steps[s] {
            guard occurrences(of: newName, in: after.steps[s]) >= 2 else { continue }
            let removed = olds.flatMap { catalog.aliases(for: $0) }
            return StepRewriteRequest(kind: .replaced(oldNames: olds.map(\.name), newName: newName), editIndex: editIndex,
                                      stepIndex: s, required: [newName], removed: removed)
        }
        return nil
    }

    /// Validates a model's rewrite and returns the proposal, or nil if any check fails.
    /// `stepNumber` is 1-based (what the model saw); for `.replaced` the request's step is used.
    public static func proposal(for request: StepRewriteRequest, stepNumber: Int, text: String, recipe: Recipe,
                                edits: [RecipeEdit], catalog: IngredientCatalog = .shared) -> StepRewriteProposal? {
        let after = recipe.applying(edits, catalog: catalog)
        let s = request.stepIndex ?? (stepNumber - 1)
        guard after.steps.indices.contains(s), s < recipe.steps.count else { return nil }
        let original = after.steps[s]
        // Other ingredients' names (and the new one) are masked before checking removed names,
        // so "ginger garlic paste" doesn't count as "garlic".
        let masking = after.ingredients.map(\.name) + request.required
        guard let valid = validate(original: original, rewritten: text, required: request.required,
                                   removed: request.removed, masking: masking) else { return nil }
        var depends = [request.editIndex]
        for (j, edit) in edits.enumerated() where j != request.editIndex {
            if recipe.applying([edit], catalog: catalog).steps[s] != recipe.steps[s] { depends.append(j) }
        }
        return StepRewriteProposal(stepIndex: s, oldText: original, newText: valid, dependsOn: depends.sorted())
    }

    /// The rewritten step, tidied, or nil when it fails a check:
    /// - not empty, one paragraph, different from the original;
    /// - length between half the original and 1.5× + 60 characters (and at most 600);
    /// - every number, duration and temperature in the original is still there;
    /// - one of `required` appears (whole word, plural allowed);
    /// - none of `removed` appears once `masking` names are blanked out.
    public static func validate(original: String, rewritten: String, required: [String], removed: [String],
                                masking: [String] = []) -> String? {
        var text = rewritten.collapsedWhitespace
        text = Rx.replace("^(?:step\\s*\\d+\\s*[:.)-]\\s*|\\d+\\s*[.)]\\s+)", in: text, with: "")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        text = text.trimmed
        guard !text.isEmpty, !rewritten.contains("\n\n"), text != original.collapsedWhitespace else { return nil }
        let length = text.count, base = original.collapsedWhitespace.count
        guard length <= min(maxLength, Int(Double(base) * 1.5) + 60), length >= base / 2 else { return nil }

        let numbers = Set(numberTokens(text))
        guard numberTokens(original).allSatisfy(numbers.contains) else { return nil }
        let newDurations = TimeEstimator.durations(in: text).map(\.minutes)
        for d in TimeEstimator.durations(in: original).map(\.minutes) where !newDurations.contains(where: { abs($0 - d) < 0.01 }) {
            return nil
        }
        let newTemps = Set(temperatureTokens(text))
        guard temperatureTokens(original).allSatisfy(newTemps.contains) else { return nil }

        guard required.isEmpty || required.contains(where: { occurrences(of: $0, in: text) > 0 }) else { return nil }
        var masked = text
        for name in masking.sorted(by: { $0.count > $1.count }) where !removed.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            masked = Rx.replace(namePattern(name), in: masked, with: " ")
        }
        guard !removed.contains(where: { occurrences(of: $0, in: masked) > 0 }) else { return nil }
        return text
    }

    // MARK: Helpers

    static func names(for ingredient: Ingredient, catalog: IngredientCatalog) -> [String] {
        var names = [ingredient.name]
        if let entry = ingredient.catalogID.flatMap(catalog.entry(id:)) ?? catalog.match(ingredient.name) {
            names += entry.names
        }
        return names
    }

    /// Whole-word, case-insensitive, plural allowed.
    static func namePattern(_ name: String) -> String {
        let words = name.trimmed.split(whereSeparator: \.isWhitespace).map { Rx.escape(String($0)) }
        return "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?:s|es)?(?![\\p{L}\\p{N}])"
    }

    static func occurrences(of name: String, in text: String) -> Int {
        guard !name.trimmed.isEmpty else { return 0 }
        return Rx.matches(namePattern(name), in: text).count
    }

    /// "2", "1.5", "1/2", "½" tokens. "1 1/2" gives "1" and "1/2".
    static func numberTokens(_ text: String) -> [String] {
        Rx.matches("\\d+(?:[.,/]\\d+)?|[½¼¾⅓⅔⅛]", in: text).compactMap { $0[0] }
    }

    /// "200°C", "400 °F", "180 degrees" → "200c", "400f", "180".
    static func temperatureTokens(_ text: String) -> [String] {
        Rx.matches("(\\d+)\\s*(?:°\\s*([cf])?|degrees?\\s*([cf])?\\b)", in: text).compactMap { m in
            guard let n = m[1] else { return nil }
            return n + ((m[2] ?? m[3])?.lowercased() ?? "")
        }
    }
}
