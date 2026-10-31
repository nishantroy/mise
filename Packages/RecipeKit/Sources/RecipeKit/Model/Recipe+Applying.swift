import Foundation

extension Recipe {
    /// Applies edits in order and returns the new recipe. Edits that reference missing
    /// ingredients or steps are skipped. Swaps also rewrite step text.
    public func applying(_ edits: [RecipeEdit], catalog: IngredientCatalog = .shared) -> Recipe {
        var recipe = self
        for edit in edits {
            switch edit {
            case let .replaceIngredient(id, replacements, _):
                guard let index = recipe.ingredients.firstIndex(where: { $0.id == id }) else { continue }
                let old = recipe.ingredients[index]
                recipe.ingredients.replaceSubrange(index...index, with: replacements)
                if !replacements.isEmpty {
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
            }
        }
        return recipe
    }
}

/// Whole-word, case-insensitive name replacement in step text.
enum StepRewriter {
    static func replace(_ names: [String], with replacement: String, in text: String, catalog: IngredientCatalog) -> String {
        let targets = Array(Set(names.map { $0.lowercased().collapsedWhitespace }.filter { $0.count >= 2 }))
            .sorted { $0.count > $1.count }  // longer aliases first
        guard !targets.isEmpty else { return text }

        // Protect longer names that contain a target but aren't one ("dark soy sauce" when
        // swapping "soy sauce"), by masking them before replacing.
        let targetSet = Set(targets)
        var protected: [String] = []
        for (alias, _) in catalog.allAliases() where !targetSet.contains(alias) {
            if targets.contains(where: { alias.count > $0.count && " \(alias) ".contains(" \(IngredientCatalog.normalise($0)) ") }) {
                protected.append(alias)
            }
        }
        var s = text
        var masks: [(String, String)] = []
        for (i, p) in protected.enumerated() {
            let token = "\u{E000}\(i)\u{E001}"
            let pattern = "\\b\(Rx.escape(p))\\b"
            if Rx.test(pattern, s) {
                // Keep the original casing by capturing the match.
                for m in Rx.matches(pattern, in: s) { if let found = m[0] { masks.append((token, found)) } }
                s = Rx.replace(pattern, in: s, with: token)
            }
        }
        for target in targets {
            let pattern = "\\b\(Rx.escape(target))\\b"
            let matches = Rx.matches(pattern, in: s)
            guard !matches.isEmpty else { continue }
            let ns = s as NSString
            var out = ""
            var cursor = 0
            for m in Rx.re(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                // Capitalise at the start of a sentence; otherwise use the name as written.
                let atSentenceStart = out.trimmed.isEmpty || Rx.test("[.!?:]\\s*$", out)
                out += atSentenceStart ? replacement.prefix(1).uppercased() + replacement.dropFirst() : replacement
                cursor = m.range.location + m.range.length
            }
            out += ns.substring(from: cursor)
            s = out
        }
        // Unmask. Each token may have been used several times; restore with the first casing seen.
        var restored: [String: String] = [:]
        for (token, original) in masks where restored[token] == nil { restored[token] = original }
        for (token, original) in restored { s = s.replacingOccurrences(of: token, with: original) }
        return s
    }
}
