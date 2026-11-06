import Foundation
import SwiftData

/// Keeps one row per identity after iCloud sync. CloudKit can't enforce `.unique`, and two
/// devices can each create a row before they've seen each other's: the same pantry ingredient,
/// a profile each, or (after restoring one phone from another's backup) the same recipe twice.
/// Run on foreground and after remote changes are imported. Last writer wins per record.
enum SyncDedupe {
    struct Result: Equatable {
        var pantry = 0
        var profiles = 0
        var recipes = 0
        var photos = 0
        var total: Int { pantry + profiles + recipes + photos }
    }

    /// Merges every kind of duplicate and saves when anything changed.
    @discardableResult
    static func run(in context: ModelContext) -> Result {
        var result = Result()
        result.pantry = mergePantry(in: context)
        let profiles = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        result.profiles = max(0, profiles.count - 1)
        mergeProfiles(profiles, in: context)
        result.recipes = mergeRecipes(in: context)
        result.photos = mergePhotos(in: context)
        if result.total > 0 { try? context.save() }
        return result
    }

    /// One entry per key: the most recently updated wins.
    static func mergePantry(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<PantryEntry>())) ?? []
        var removed = 0
        for group in Dictionary(grouping: all, by: \.key).values where group.count > 1 {
            let keep = group.max { $0.updatedAt < $1.updatedAt }
            for entry in group where entry !== keep {
                context.delete(entry)
                removed += 1
            }
        }
        return removed
    }

    /// One profile: preferences from the most recently changed, onboarding done if any says so.
    /// Returns the survivor (nil when there are none).
    @discardableResult
    static func mergeProfiles(_ profiles: [UserProfile], in context: ModelContext) -> UserProfile? {
        guard profiles.count > 1 else { return profiles.first }
        // Newest preferences; on a tie (profiles from before V3 both say distantPast) the one that
        // finished onboarding, since a blank one is a device that hadn't synced yet.
        let keep = profiles.max { a, b in
            a.updatedAt != b.updatedAt ? a.updatedAt < b.updatedAt : (!a.onboardingDone && b.onboardingDone)
        }!
        let onboarded = profiles.contains { $0.onboardingDone }
        for profile in profiles where profile !== keep { context.delete(profile) }
        if onboarded && !keep.onboardingDone { keep.onboardingDone = true }
        return keep
    }

    /// One recipe per `id` (only a restored backup makes these): the most recently edited wins,
    /// then the one cooked more.
    static func mergeRecipes(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<SavedRecipe>())) ?? []
        var removed = 0
        for group in Dictionary(grouping: all, by: \.id).values where group.count > 1 {
            let keep = group.max { a, b in
                a.updatedAt != b.updatedAt ? a.updatedAt < b.updatedAt : a.cookLog.count < b.cookLog.count
            }
            for recipe in group where recipe !== keep {
                context.delete(recipe)
                removed += 1
            }
        }
        return removed
    }

    /// One photo per name, preferring one whose data is there.
    static func mergePhotos(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<CookPhoto>()
        descriptor.propertiesToFetch = [\.name, \.byteCount]
        let all = (try? context.fetch(descriptor)) ?? []
        var removed = 0
        for group in Dictionary(grouping: all, by: \.name).values where group.count > 1 {
            let keep = group.max { $0.byteCount < $1.byteCount }
            for photo in group where photo !== keep {
                context.delete(photo)
                removed += 1
            }
        }
        return removed
    }
}
