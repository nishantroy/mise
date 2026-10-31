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

@Generable
enum GeneratedCuisine {
    case indian, chinese, japanese, korean, thai, italian, mexican, middleEastern, french, american, other

    /// The label `CuisineGuesser.mapModelChoice` understands.
    var label: String {
        switch self {
        case .indian: "Indian"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .thai: "Thai"
        case .italian: "Italian"
        case .mexican: "Mexican"
        case .middleEastern: "Middle Eastern"
        case .french: "French"
        case .american: "American"
        case .other: "Other"
        }
    }
}

@Generable(description: "The cuisine a recipe belongs to.")
struct CuisineChoice {
    @Guide(description: "The best fit. Use other when none fits or it's unclear.")
    var cuisine: GeneratedCuisine
}

@Generable(description: "Minutes for work the recipe doesn't time.")
struct TimeGaps {
    @Guide(description: "Minutes to chop, measure and prepare the listed ingredients.", .range(0...90))
    var prepMinutes: Int
    @Guide(description: "Minutes for untimed work such as preheating the oven, boiling water, or cooking until golden. 0 if none.", .range(0...180))
    var untimedMinutes: Int
    @Guide(description: "One short sentence explaining the estimate.")
    var reason: String
}

@Generable(description: "The ingredients a recipe's steps mention, with their amounts.")
struct IngredientExtraction {
    @Guide(description: "One ingredient per line with its amount as the steps give it, e.g. \"1 tbsp soy sauce\" or \"a handful of cilantro\". Ingredients only, never instructions.", .maximumCount(40))
    var lines: [String]
}

@Generable
enum GeneratedPrepKind {
    case chopAndPrep, mixAhead, getOut
}

@Generable(description: "One line of a prep list.")
struct GeneratedPrepItem {
    @Guide(description: "A short instruction without any amounts, e.g. \"Thinly slice\" or \"Whisk together for the sauce\".")
    var action: String
    @Guide(description: "The ingredients this line covers, named exactly as listed.", .maximumCount(8))
    var ingredients: [String]
}

@Generable(description: "A group of prep lines.")
struct GeneratedPrepGroup {
    var kind: GeneratedPrepKind
    @Guide(.maximumCount(10))
    var items: [GeneratedPrepItem]
}

@Generable(description: "What to do before cooking: chop and prep, mix ahead, and get out the rest.")
struct GeneratedPrepPlan {
    @Guide(.maximumCount(3))
    var groups: [GeneratedPrepGroup]
}

@Generable(description: "One recipe step, rewritten.")
struct GeneratedStepRewrite {
    @Guide(description: "The number of the step you rewrote.")
    var stepNumber: Int
    @Guide(description: "The whole rewritten step.")
    var text: String
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

    /// Rules first; the model is asked only when they find no clear winner or a weak one.
    func guessCuisine(recipe: Recipe) async throws -> String? {
        let rules = CuisineGuesser().analyse(recipe)
        guard !rules.isStrong, SystemLanguageModel.default.isAvailable else { return rules.cuisine }
        let prompt = Self.cuisinePrompt(recipe: recipe)
        do {
            let choice = try await Self.withTimeout(Self.insightTimeout) {
                let session = LanguageModelSession(instructions: Self.cuisineInstructions)
                return try await session.respond(to: prompt, generating: CuisineChoice.self,
                                                 options: GenerationOptions(temperature: 0)).content
            }
            Self.debugLog("guessCuisine", prompt: prompt, output: "\(choice) (rules: \(rules.cuisine ?? "nil"), score \(rules.score))")
            return CuisineGuesser.mapModelChoice(choice.cuisine.label)
        } catch {
            Self.log.error("guessCuisine fell back to rules: \(String(describing: error), privacy: .public)")
            return rules.cuisine
        }
    }

    /// The rules extract durations and do the arithmetic; the model only fills in prep and
    /// untimed work. Any error or timeout gives the rules' estimate.
    func estimateTime(recipe: Recipe) async throws -> TimeEstimate {
        let estimator = TimeEstimator()
        guard SystemLanguageModel.default.isAvailable else { return estimator.estimate(recipe) }
        let prompt = Self.timePrompt(recipe: recipe, analysis: estimator.analyse(recipe))
        do {
            let gaps = try await Self.withTimeout(Self.insightTimeout) {
                let session = LanguageModelSession(instructions: Self.timeInstructions)
                return try await session.respond(to: prompt, generating: TimeGaps.self,
                                                 options: GenerationOptions(temperature: 0.2)).content
            }
            Self.debugLog("estimateTime", prompt: prompt, output: "\(gaps)")
            return estimator.estimate(recipe, gaps: TimeGapProposal(prepMinutes: gaps.prepMinutes,
                                                                    untimedMinutes: gaps.untimedMinutes,
                                                                    reason: gaps.reason))
        } catch {
            Self.log.error("estimateTime fell back to rules: \(String(describing: error), privacy: .public)")
            return estimator.estimate(recipe)
        }
    }

    /// Ingredients for a recipe written as steps only. The model proposes lines; RecipeKit
    /// (`ModelIngredientLines`) drops anything the steps don't mention and falls back to the
    /// rules when the model's list is too thin. Steps are never changed. Errors → the rules.
    func extractIngredients(steps: [String], title: String) async throws -> [Ingredient] {
        let rules = try await RuleBasedAssistant().extractIngredients(steps: steps, title: title)
        guard SystemLanguageModel.default.isAvailable else { return rules }
        let prompt = Self.extractionPrompt(steps: steps, title: title)
        do {
            let plan = try await Self.withTimeout(Self.insightTimeout) {
                let session = LanguageModelSession(instructions: Self.extractionInstructions)
                return try await session.respond(to: prompt, generating: IngredientExtraction.self,
                                                 options: GenerationOptions(temperature: 0)).content
            }
            Self.debugLog("extractIngredients", prompt: prompt, output: "\(plan)")
            return ModelIngredientLines.choose(model: ModelIngredientLines.map(plan.lines, steps: steps), rules: rules)
        } catch {
            Self.log.error("extractIngredients fell back to rules: \(String(describing: error), privacy: .public)")
            return rules
        }
    }

    /// The rules' plan, refined by the model: it groups chopping, mixing and getting things out;
    /// the rules keep "Start early" (it comes from step times). `PrepPlanner.map` validates the
    /// answer; anything invalid, any error or a timeout gives the rules' plan.
    func planPrep(recipe: Recipe) async throws -> PrepPlan {
        let planner = PrepPlanner()
        let rules = planner.plan(for: recipe)
        guard SystemLanguageModel.default.isAvailable, !recipe.ingredients.isEmpty else { return rules }
        let prompt = Self.prepPrompt(recipe: recipe)
        do {
            let plan = try await Self.withTimeout(Self.insightTimeout) {
                let session = LanguageModelSession(instructions: Self.prepInstructions)
                return try await session.respond(to: prompt, generating: GeneratedPrepPlan.self,
                                                 options: GenerationOptions(temperature: 0.2)).content
            }
            Self.debugLog("planPrep", prompt: prompt, output: "\(plan)")
            let proposal = plan.groups.map { group in
                ProposedPrepGroup(kind: group.kind.prepKind,
                                  items: group.items.map { ProposedPrepItem(action: $0.action, ingredients: $0.ingredients) })
            }
            guard let mapped = planner.map(proposal, recipe: recipe, rules: rules) else {
                Self.log.info("planPrep: model plan failed validation, using rules")
                return rules
            }
            return mapped
        } catch {
            Self.log.error("planPrep fell back to rules: \(String(describing: error), privacy: .public)")
            return rules
        }
    }

    static let prepInstructions = """
    You write a home cook's prep list (mise en place) for a recipe. \
    Group the listed ingredients into: chopAndPrep (things to cut, grate, toast or grind), \
    mixAhead (sauces or mixtures combined before cooking starts), and getOut (everything else). \
    Each line is a short instruction without amounts plus the ingredients it covers, named exactly as listed. \
    Use every ingredient once.
    """

    static func prepPrompt(recipe: Recipe) -> String {
        let ingredients = recipe.ingredients.prefix(30)
            .map { "- \($0.name)\($0.note.map { " (\($0))" } ?? "")" }.joined(separator: "\n")
        let steps = recipe.steps.prefix(10).enumerated()
            .map { "\($0.offset + 1). \(String($0.element.prefix(140)))" }.joined(separator: "\n")
        return """
        Recipe: \(recipe.title)
        Ingredients:
        \(ingredients)
        Steps:
        \(steps)
        """
    }

    /// Single-step rewrites for what `StepRewrites.requests` finds (at most two). Each answer is
    /// validated in RecipeKit and dropped if it fails; errors drop it too.
    func proposeStepRewrites(recipe: Recipe, edits: [RecipeEdit], feedback: String) async throws -> [StepRewriteProposal] {
        let requests = StepRewrites.requests(recipe: recipe, edits: edits)
        guard !requests.isEmpty, SystemLanguageModel.default.isAvailable else { return [] }
        let after = recipe.applying(edits)
        var out: [StepRewriteProposal] = []
        for request in requests {
            let prompt = Self.rewritePrompt(request, after: after, feedback: feedback)
            do {
                let answer = try await Self.withTimeout(Self.insightTimeout) {
                    let session = LanguageModelSession(instructions: Self.rewriteInstructions)
                    return try await session.respond(to: prompt, generating: GeneratedStepRewrite.self,
                                                     options: GenerationOptions(temperature: 0.2)).content
                }
                let proposal = StepRewrites.proposal(for: request, stepNumber: answer.stepNumber, text: answer.text,
                                                     recipe: recipe, edits: edits)
                Self.debugLog("rewriteStep", prompt: prompt, output: "\(answer) → \(proposal == nil ? "rejected" : "kept")")
                if let proposal, !out.contains(where: { $0.stepIndex == proposal.stepIndex }) { out.append(proposal) }
            } catch {
                Self.log.error("rewriteStep dropped: \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }

    static let rewriteInstructions = """
    You fix one step of a home cook's recipe so it reads naturally after an ingredient change. \
    Rewrite only that one step. Keep every number, time and temperature exactly as written. \
    Keep it about as long as the original and don't add new instructions.
    """

    static func rewritePrompt(_ request: StepRewriteRequest, after: Recipe, feedback: String) -> String {
        switch request.kind {
        case let .added(ingredient):
            let steps = after.steps.prefix(12).enumerated()
                .map { "\($0.offset + 1). \(String($0.element.prefix(200)))" }.joined(separator: "\n")
            return """
            Steps:
            \(steps)

            New ingredient: \(ingredient.displayText)
            Cook's feedback: \(feedback.isEmpty ? "(none)" : feedback)
            Pick the one step where the new ingredient is used and rewrite that step so it mentions \(ingredient.name).
            """
        case let .replaced(oldNames, newName):
            let index = request.stepIndex ?? 0
            return """
            Step \(index + 1): \(after.steps.indices.contains(index) ? after.steps[index] : "")

            This step was changed to use \(newName) instead of \(oldNames.joined(separator: " and ")), so it now repeats \(newName).
            Rewrite it so \(newName) is mentioned once, and don't mention \(oldNames.joined(separator: " or ")).
            """
        }
    }

    static let extractionInstructions = """
    You list the ingredients of a home cook's recipe. The amounts are written inside the steps. \
    Give each ingredient once, with its amount and unit exactly as the steps say. \
    Put alternatives in the same line ("soy sauce or tamari"). Don't list equipment, times or temperatures, \
    and never rewrite the steps.
    """

    static func extractionPrompt(steps: [String], title: String) -> String {
        let text = steps.prefix(20).enumerated()
            .map { "\($0.offset + 1). \(String($0.element.prefix(300)))" }.joined(separator: "\n")
        return """
        Recipe: \(title)
        Steps:
        \(text)
        """
    }

    /// Import waits for these calls, so they get a deadline.
    static let insightTimeout: Duration = .seconds(12)

    struct TimeoutError: Error {}

    static func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimeoutError() }
            return first
        }
    }

    // MARK: Prompts (kept short: the on-device context window is small)

    static let cuisineInstructions = """
    You classify a recipe's cuisine from its title and ingredients. \
    Pick one of the listed cuisines, or other when none clearly fits.
    """

    static let timeInstructions = """
    You estimate how long a home cook really needs for a recipe. \
    Times written in the steps are already counted; never count them again. \
    Give only the minutes the recipe leaves out: prep (chopping, measuring) for the listed ingredients, \
    and untimed work such as preheating the oven, boiling water, or cooking until golden or soft. \
    Be realistic for a home cook, not optimistic.
    """

    static func cuisinePrompt(recipe: Recipe) -> String {
        let names = recipe.ingredients.prefix(25).map(\.name).joined(separator: ", ")
        return """
        Recipe: \(recipe.title)
        Ingredients: \(names)
        """
    }

    static func timePrompt(recipe: Recipe, analysis: TimeAnalysis) -> String {
        let names = recipe.ingredients.prefix(30).map(\.name).joined(separator: ", ")
        let steps = recipe.steps.prefix(12).enumerated()
            .map { "\($0.offset + 1). \(String($0.element.prefix(140)))" }.joined(separator: "\n")
        let hints = analysis.hintLines
        return """
        Recipe: \(recipe.title)
        Ingredients (\(recipe.ingredients.count)): \(names)
        Steps:
        \(steps)
        Already timed in the steps:
        \(hints.isEmpty ? "(nothing)" : hints.map { "- \($0)" }.joined(separator: "\n"))
        """
    }


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

extension GeneratedPrepKind {
    var prepKind: PrepGroupKind {
        switch self {
        case .chopAndPrep: .chopAndPrep
        case .mixAhead: .mixAhead
        case .getOut: .getOut
        }
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
