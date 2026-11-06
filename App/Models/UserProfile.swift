import Foundation
import SwiftData
import RecipeKit

extension SchemaV3 {
    /// Single row holding the user's preferences. With iCloud sync two devices can each create
    /// one before they've seen each other's; `ModelContext.profile()` and `SyncDedupe` merge them.
    @Model
    final class UserProfile {
        /// JSON-encoded `UserPreferences`.
        var prefsData: Data = Data()
        var onboardingDone: Bool = false
        /// When `prefs` last changed, so the newest preferences win a merge. Added in V3; profiles
        /// from earlier versions start at `distantPast`.
        var updatedAt: Date = Date.distantPast

        /// `updatedAt` defaults to `distantPast`: a blank profile made on a new device before the
        /// synced one arrives must not win the merge with its default preferences.
        init(prefs: UserPreferences = UserPreferences(), onboardingDone: Bool = false,
             updatedAt: Date = Date.distantPast) {
            prefsData = ModelCoding.encode(prefs)
            self.onboardingDone = onboardingDone
            self.updatedAt = updatedAt
        }

        var prefs: UserPreferences {
            get { ModelCoding.decode(UserPreferences.self, from: prefsData) ?? UserPreferences() }
            set {
                prefsData = ModelCoding.encode(newValue)
                updatedAt = Date()
            }
        }
    }
}

extension ModelContext {
    /// The single profile row, created if missing. Duplicates (from another device) are merged.
    func profile() -> UserProfile {
        let all = (try? fetch(FetchDescriptor<UserProfile>())) ?? []
        if let merged = SyncDedupe.mergeProfiles(all, in: self) { return merged }
        let profile = UserProfile()
        insert(profile)
        return profile
    }
}
