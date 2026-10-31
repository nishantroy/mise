import Foundation
import Observation
import RecipeKit

/// Chooses which `RecipeAssistant` the app uses.
@MainActor
@Observable
final class AssistantProvider {
    private static let forceRulesKey = "forceRulesAssistant"

    /// Settings toggle: always use the built-in rules.
    var forceRules: Bool {
        didSet { UserDefaults.standard.set(forceRules, forKey: Self.forceRulesKey) }
    }

    init() {
        forceRules = LaunchOptions.forceRules || UserDefaults.standard.bool(forKey: Self.forceRulesKey)
    }

    var assistant: any RecipeAssistant { RuleBasedAssistant() }
}
