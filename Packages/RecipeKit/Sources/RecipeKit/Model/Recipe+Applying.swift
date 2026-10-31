import Foundation

extension Recipe {
    /// Applies edits in order and returns the new recipe. Edits that reference missing
    /// ingredients or steps are skipped. Swaps also rewrite step text.
    public func applying(_ edits: [RecipeEdit], catalog: IngredientCatalog = .shared) -> Recipe {
        var recipe = self
        for edit in edits {
            switch edit {
            case let .replaceIngredient(id, replacements, reason):
                guard let index = recipe.ingredients.firstIndex(where: { $0.id == id }) else { continue }
                let old = recipe.ingredients[index]
                recipe.ingredients.replaceSubrange(index...index, with: replacements)
                // An amount change keeps the ingredient, so the steps already name it.
                if !replacements.isEmpty && reason != RecipeEdit.amountChangeReason {
                    let newName = replacements.map(\.name).joined(separator: " and ")
                    recipe.steps = recipe.steps.map {
                        StepRewriter.replace(catalog.aliases(for: old), with: newName, in: $0, catalog: catalog)
                    }
                }
            case let .scaleIngredient(id, factor):
                guard let index = recipe.ingredients.firstIndex(where: { $0.id == id }) else { continue }
                recipe.ingredients[index] = recipe.ingredients[index].scaled(by: factor)
            case let .removeIngredient(id):
                recipe.ingredients.removeAll { $0.id == id }
            case let .addIngredient(ingredient):
                recipe.ingredients.append(ingredient)
            case let .updateStep(index, text):
                if recipe.steps.indices.contains(index) {
                    recipe.steps[index] = text
                } else if index == recipe.steps.count {
                    recipe.steps.append(text)
                }
            case let .addNote(note):
                recipe.notes.append(note)
            case let .replaceIngredients(ids, replacements, _):
                let olds = recipe.ingredients.filter { ids.contains($0.id) }
                guard let index = recipe.ingredients.firstIndex(where: { ids.contains($0.id) }) else { continue }
                recipe.ingredients.removeAll { ids.contains($0.id) }
                recipe.ingredients.insert(contentsOf: replacements, at: min(index, recipe.ingredients.count))
                if !replacements.isEmpty {
                    let newName = replacements.map(\.name).joined(separator: " and ")
                    let names = olds.flatMap { catalog.aliases(for: $0) }
                    recipe.steps = recipe.steps.map {
                        StepRewriter.replace(names, with: newName, in: $0, catalog: catalog)
                    }
                }
            case let .replaceSteps(steps):
                recipe.steps = steps
            }
        }
        return recipe
    }
}

/// Whole-word, case-insensitive name replacement in step text, done in a single pass so a
/// new name that contains an old alias ("olive oil" for "oil") is never replaced again.
enum StepRewriter {
    static func replace(_ names: [String], with replacement: String, in text: String, catalog: IngredientCatalog) -> String {
        let targets = Set(names.flatMap { variants(of: $0) }.filter { $0.count >= 2 })
        guard !targets.isEmpty else { return text }

        // Longer names from other catalog entries that contain a target as whole words
        // ("dark soy sauce", "spring onions") are matched too, and left as they are.
        var protected: Set<String> = []
        for entry in catalog.entries {
            for raw in entry.names {
                for alias in variants(of: raw) where !targets.contains(alias) {
                    if targets.contains(where: { alias.count > $0.count && " \(alias) ".contains(" \($0) ") }) {
                        protected.insert(alias)
                    }
                }
            }
        }
        // One alternation, longest first, so each span of text is considered exactly once.
        let alternatives = (targets.union(protected)).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let pattern = "\\b(?:" + alternatives.map(Rx.escape).joined(separator: "|") + ")\\b"
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in Rx.re(pattern).matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let found = ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
            guard targets.contains(found.lowercased().collapsedWhitespace) else {
                out += found  // protected longer name
                continue
            }
            // Capitalise at the start of a sentence; otherwise use the name as written.
            let atSentenceStart = out.trimmed.isEmpty || Rx.test("[.!?:]\\s*$", out)
            out += atSentenceStart ? replacement.prefix(1).uppercased() + replacement.dropFirst() : replacement
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Lowercased name plus a simple plural or singular form ("onion" / "onions").
    static func variants(of name: String) -> [String] {
        let n = name.lowercased().collapsedWhitespace
        guard !n.isEmpty else { return [] }
        if n.hasSuffix("s") { return [n, String(n.dropLast())] }
        return [n, n + "s"]
    }
}
