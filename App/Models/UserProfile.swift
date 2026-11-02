import Foundation
import SwiftData
import RecipeKit

extension SchemaV2 {
    /// Single row holding the user's preferences.
    @Model
    final class UserProfile {
        /// JSON-encoded `UserPreferences`.
        var prefsData: Data
        var onboardingDone: Bool

        init(prefs: UserPreferences = UserPreferences(), onboardingDone: Bool = false) {
            prefsData = ModelCoding.encode(prefs)
            self.onboardingDone = onboardingDone
        }

        var prefs: UserPreferences {
            get { ModelCoding.decode(UserPreferences.self, from: prefsData) ?? UserPreferences() }
            set { prefsData = ModelCoding.encode(newValue) }
        }
    }
}

extension ModelContext {
    /// The single profile row, created if missing.
    func profile() -> UserProfile {
        if let existing = try? fetch(FetchDescriptor<UserProfile>()).first { return existing }
        let profile = UserProfile()
        insert(profile)
        return profile
    }
}
