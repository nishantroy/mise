import Foundation
import FoundationModels
import Observation
import RecipeKit

/// Chooses which `RecipeAssistant` the app uses: the on-device model when it's available and
/// the user hasn't turned it off, otherwise the built-in rules. A cloud model would be one more
/// conforming type here.
@MainActor
@Observable
final class AssistantProvider {
    private static let forceRulesKey = "forceRulesAssistant"

    /// Settings toggle: always use the built-in rules.
    var forceRules: Bool {
        didSet { UserDefaults.standard.set(forceRules, forKey: Self.forceRulesKey) }
    }

    /// Bumped to re-read model availability (e.g. when the app becomes active).
    private var refreshToken = 0

    init() {
        if LaunchOptions.resetData { UserDefaults.standard.removeObject(forKey: Self.forceRulesKey) }
        forceRules = LaunchOptions.forceRules || UserDefaults.standard.bool(forKey: Self.forceRulesKey)
    }

    func refresh() { refreshToken += 1 }

    var modelAvailability: SystemLanguageModel.Availability {
        _ = refreshToken
        return SystemLanguageModel.default.availability
    }

    var usesModel: Bool { !forceRules && modelAvailability == .available }

    var assistant: any RecipeAssistant {
        usesModel ? FoundationModelsAssistant() : RuleBasedAssistant()
    }

    /// Why the active assistant was chosen, for Settings.
    var statusDetail: String {
        if forceRules {
            return modelAvailability == .available
                ? "You've chosen the built-in rules. Apple Intelligence is available."
                : "You've chosen the built-in rules."
        }
        switch modelAvailability {
        case .available:
            return "Using the on-device model. Nothing leaves this iPhone."
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence, so Mise uses its built-in rules."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in Settings, so Mise uses its built-in rules."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Mise uses its built-in rules until it's ready."
        case .unavailable:
            return "The on-device model isn't available, so Mise uses its built-in rules."
        }
    }
}
