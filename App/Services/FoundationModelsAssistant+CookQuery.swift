import Foundation
import FoundationModels
import os
import RecipeKit

// MARK: - "What can I cook?" query reading

@Generable
enum GeneratedCookStyle {
    case spicy, light, comforting, noodles, soup, rice, stirFry, curry

    var rawStyle: String {
        switch self {
        case .spicy: "spicy"
        case .light: "light"
        case .comforting: "comforting"
        case .noodles: "noodles"
        case .soup: "soup"
        case .rice: "rice"
        case .stirFry: "stirFry"
        case .curry: "curry"
        }
    }
}

@Generable(description: "What a home cook is asking for when they ask what to cook.")
struct GeneratedCookQuery {
    @Guide(description: "Ingredients they have or want to use, in their own words, e.g. \"chicken\", \"ground beef\". Empty if none.", .maximumCount(8))
    var ingredients: [String]
    @Guide(description: "Of those, the ones they want to use up because they're leftover or going off. Empty if none.", .maximumCount(4))
    var useUp: [String]
    @Guide(description: "Ingredients they don't want, e.g. \"pork\" for \"no pork\". Empty if none.", .maximumCount(6))
    var avoid: [String]
    @Guide(description: "The most minutes they said it may take, only if they gave a number. 0 otherwise.", .range(0...720))
    var maxMinutes: Int
    @Guide(description: "Cuisines they named. Empty if none.", .maximumCount(3))
    var cuisines: [GeneratedCuisine]
    @Guide(description: "Tastes or kinds of dish they asked for. Empty if none.", .maximumCount(4))
    var styles: [GeneratedCookStyle]
    @Guide(description: "How many people, only if they said. 0 otherwise.", .range(0...24))
    var servings: Int
    @Guide(description: "True only if they want to cook with what they already have, without shopping.")
    var pantryOnly: Bool
}

extension FoundationModelsAssistant {
    private static let cookQueryLog = Logger(subsystem: "Mise", category: "FoundationModels")

    /// A search, so it gets a shorter deadline than import-time calls.
    static let cookQueryTimeout: Duration = .seconds(8)

    /// The rules parse the question; the model's reading can only add grounded terms
    /// (`CookQueryMerge` validates it against the text). Any error or a timeout gives the rules.
    func parseCookQuery(text: String) async throws -> CookQuery {
        let rules = CookQueryParser().parse(text)
        guard SystemLanguageModel.default.isAvailable, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return rules }
        let prompt = "Question: \(String(text.prefix(600)))"
        do {
            let answer = try await Self.withTimeout(Self.cookQueryTimeout) {
                let session = LanguageModelSession(instructions: Self.cookQueryInstructions)
                return try await session.respond(to: prompt, generating: GeneratedCookQuery.self,
                                                 options: GenerationOptions(temperature: 0)).content
            }
            let proposal = ProposedCookQuery(ingredients: answer.ingredients, useUp: answer.useUp, avoid: answer.avoid,
                                             maxMinutes: answer.maxMinutes, cuisines: answer.cuisines.map(\.label),
                                             styles: answer.styles.map(\.rawStyle), servings: answer.servings,
                                             pantryOnly: answer.pantryOnly)
            let merged = CookQueryMerge.merge(proposal, rules: rules)
            #if DEBUG
            Self.cookQueryLog.debug("parseCookQuery prompt:\n\(prompt, privacy: .public)\noutput:\n\(String(describing: answer), privacy: .public)\nmerged: \(merged.summary, privacy: .public) (rules: \(rules.summary, privacy: .public))")
            #endif
            return merged
        } catch {
            Self.cookQueryLog.error("parseCookQuery fell back to rules: \(String(describing: error), privacy: .public)")
            return rules
        }
    }

    static let cookQueryInstructions = """
    You read a home cook's question about what to cook tonight, often dictated without punctuation, \
    and list what they asked for. Use only words from the question. \
    Ingredients they say they have or want go in ingredients; anything after "no", "without" or "don't want" goes in avoid. \
    Give minutes or servings only when the question says a number. Leave everything else empty.
    """
}
