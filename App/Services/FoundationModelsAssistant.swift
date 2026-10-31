import Foundation
import FoundationModels
import os
import RecipeKit

// MARK: - Generable output types

@Generable
enum GeneratedEditKind {
    case replace, scale, remove, add, note
}

@Generable(description: "One change to the recipe.")
struct GeneratedEdit {
    @Guide(description: "The kind of change.")
    var kind: GeneratedEditKind
    @Guide(description: "Name of the existing recipe ingredient this changes, exactly as listed. Empty for add and note.")
    var ingredient: String
    @Guide(description: "For replace or add: the new ingredient, e.g. \"chicken thighs\" or \"1 tbsp lime juice\". Otherwise empty.")
    var replacement: String
    @Guide(description: "For scale: multiplier, e.g. 0.75 for less or 1.25 for more. Otherwise 1.0.", .range(0.25...3.0))
    var factor: Double
    @Guide(description: "For note: one short sentence for next time. Otherwise empty.")
    var text: String
}

@Generable(description: "Changes to make to the saved recipe based on the cook's feedback.")
struct EditPlan {
    @Guide(description: "Only changes the feedback supports. Empty if nothing should change.", .maximumCount(6))
    var edits: [GeneratedEdit]
}

@Generable
enum GeneratedSwapQuality {
    case great, good, ok
}

@Generable(description: "A substitute for a missing ingredient.")
struct GeneratedSwap {
    @Guide(description: "Ingredient names to use instead, usually one, e.g. [\"dry sherry\"]. Empty means leave it out.", .maximumCount(2))
    var ingredients: [String]
    @Guide(description: "How close the result will be.")
    var quality: GeneratedSwapQuality
    @Guide(description: "A short tip, under 12 words.")
    var note: String
}

@Generable
struct SwapPlan {
    @Guide(description: "Best substitutes first.", .maximumCount(3))
    var swaps: [GeneratedSwap]
}

// MARK: - Assistant

/// On-device model assistant. Uses the rules as hints and falls back to them silently on any error.
struct FoundationModelsAssistant: RecipeAssistant {
    private static let log = Logger(subsystem: "Mise", category: "FoundationModels")
    private let rules = RuleBasedAssistant()

    var displayName: String { "Apple Intelligence" }

    func proposeEdits(recipe: Recipe, feedback: String, prefs: UserPreferences) async throws -> [RecipeEdit] {
        let hints = (try? await rules.proposeEdits(recipe: recipe, feedback: feedback, prefs: prefs)) ?? []
        guard SystemLanguageModel.default.isAvailable else { return hints }
        let prompt = Self.editPrompt(recipe: recipe, feedback: feedback, hints: hints)
        do {
            let session = LanguageModelSession(instructions: Self.editInstructions)
            let response = try await session.respond(to: prompt, generating: EditPlan.self,
                                                     options: GenerationOptions(temperature: 0.2))
            Self.debugLog("proposeEdits", prompt: prompt, output: "\(response.content)")
            let proposals = response.content.edits.map { e in
                ProposedEdit(kind: ProposedEdit.Kind(e.kind), ingredient: e.ingredient, replacement: e.replacement,
                             factor: e.factor, text: e.text)
            }
            let edits = ProposedEdit.map(proposals, in: recipe)
            return edits.isEmpty ? hints : edits
        } catch {
            Self.log.error("proposeEdits fell back to rules: \(String(describing: error), privacy: .public)")
            return hints
        }
    }

    func suggestSwaps(for ingredient: Ingredient, in recipe: Recipe,
                      pantry: PantrySnapshot, prefs: UserPreferences) async throws -> [SwapSuggestion] {
        // The bundled table first; the model only fills gaps.
        let table = (try? await rules.suggestSwaps(for: ingredient, in: recipe, pantry: pantry, prefs: prefs)) ?? []
        guard table.isEmpty, SystemLanguageModel.default.isAvailable else { return table }
        let prompt = Self.swapPrompt(ingredient: ingredient, recipe: recipe, pantry: pantry, prefs: prefs)
        do {
            let session = LanguageModelSession(instructions: Self.swapInstructions)
            let response = try await session.respond(to: prompt, generating: SwapPlan.self,
                                                     options: GenerationOptions(temperature: 0.3))
            Self.debugLog("suggestSwaps", prompt: prompt, output: "\(response.content)")
            return Self.mapSwaps(response.content, pantry: pantry, prefs: prefs)
        } catch {
            Self.log.error("suggestSwaps fell back to rules: \(String(describing: error), privacy: .public)")
            return table
        }
    }

    // MARK: Prompts (kept short: the on-device context window is small)

    static let editInstructions = """
    You update a home cook's saved recipe after they cooked it. \
    Read their feedback and propose small, concrete changes using only these kinds: \
    replace (swap one listed ingredient for another), scale (change a listed ingredient's amount by a factor), \
    remove (drop a listed ingredient), add (a new ingredient), note (a short tip for next time). \
    Use ingredient names exactly as listed. Don't invent changes the feedback doesn't support. \
    Suggested changes from a simple rule engine are included; keep the good ones, fix wrong ones, and add what they missed.
    """

    static let swapInstructions = """
    You suggest substitutes for one ingredient a home cook doesn't have. \
    Prefer things from their pantry. Respect their diet and things they avoid. Keep tips short.
    """

    static func editPrompt(recipe: Recipe, feedback: String, hints: [RecipeEdit]) -> String {
        let ingredients = recipe.ingredients.prefix(30).map { "- \($0.displayText)" }.joined(separator: "\n")
        let steps = recipe.steps.prefix(10).enumerated()
            .map { "\($0.offset + 1). \(String($0.element.prefix(160)))" }.joined(separator: "\n")
        let hintText = hints.isEmpty ? "(none)" : hints.map { "- \($0.summary(in: recipe))" }.joined(separator: "\n")
        return """
        Recipe: \(recipe.title)
        Ingredients:
        \(ingredients)
        Steps:
        \(steps)

        Cook's feedback: \(feedback)

        Rule engine suggestions:
        \(hintText)
        """
    }

    static func swapPrompt(ingredient: Ingredient, recipe: Recipe, pantry: PantrySnapshot, prefs: UserPreferences) -> String {
        let catalog = IngredientCatalog.shared
        let have = pantry.have.sorted().prefix(30).map { catalog.displayName(for: $0) }.joined(separator: ", ")
        let missing = pantry.missing.sorted().prefix(20).map { catalog.displayName(for: $0) }.joined(separator: ", ")
        let avoid = prefs.avoid.map(\.rawValue).sorted().joined(separator: ", ")
        return """
        Missing ingredient: \(ingredient.displayText)
        Recipe: \(recipe.title)
        Diet: \(prefs.diet.rawValue)\(avoid.isEmpty ? "" : ". Avoids: \(avoid)")\(prefs.dislikes.isEmpty ? "" : ". Dislikes: \(prefs.dislikes.joined(separator: ", "))")
        In their pantry: \(have.isEmpty ? "unknown" : have)
        They don't have: \(missing.isEmpty ? "unknown" : missing)
        Suggest up to 3 substitutes.
        """
    }

    static func mapSwaps(_ plan: SwapPlan, pantry: PantrySnapshot, prefs: UserPreferences) -> [SwapSuggestion] {
        let catalog = IngredientCatalog.shared
        let engine = SwapEngine(catalog: catalog)
        var out: [SwapSuggestion] = []
        for swap in plan.swaps {
            var items: [SwapSuggestion.Item] = []
            var allowed = true
            for name in swap.ingredients where !name.trimmingCharacters(in: .whitespaces).isEmpty {
                let entry = catalog.match(name)
                if let entry {
                    if pantry.missing.contains(entry.id) || !engine.conflictReasons(tags: entry.tags, prefs: prefs).isEmpty { allowed = false }
                    items.append(.init(catalogID: entry.id, name: entry.displayName))
                } else {
                    items.append(.init(catalogID: nil, name: name.lowercased()))
                }
            }
            guard allowed else { continue }
            let fromPantry = !items.isEmpty && items.allSatisfy { $0.catalogID.map(pantry.have.contains) ?? false }
            let quality: SwapQuality = switch swap.quality { case .great: .great; case .good: .good; case .ok: .ok }
            let suggestion = SwapSuggestion(items: items, quality: quality, note: swap.note, fromPantry: fromPantry,
                                            score: quality.score + (fromPantry ? 3 : 0))
            if !out.contains(where: { $0.id == suggestion.id }) { out.append(suggestion) }
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(3))
    }

    private static func debugLog(_ label: String, prompt: String, output: String) {
        #if DEBUG
        log.debug("\(label, privacy: .public) prompt:\n\(prompt, privacy: .public)\noutput:\n\(output, privacy: .public)")
        #endif
    }
}

extension ProposedEdit.Kind {
    init(_ kind: GeneratedEditKind) {
        switch kind {
        case .replace: self = .replace
        case .scale: self = .scale
        case .remove: self = .remove
        case .add: self = .add
        case .note: self = .note
        }
    }
}
