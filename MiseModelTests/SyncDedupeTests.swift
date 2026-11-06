import Foundation
import SwiftData
import Testing
import RecipeKit

/// Rows iCloud can duplicate (CloudKit has no unique constraints): what two devices end up with
/// after syncing, merged by `SyncDedupe` and the context helpers.
@Suite("Sync duplicates")
@MainActor
struct SyncDedupeTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try MiseStore.inMemory()
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func pantryKeepsTheNewestEntryPerKey() throws {
        context.insert(PantryEntry(key: "garlic", displayName: "garlic", status: .have, updatedAt: date(100)))
        context.insert(PantryEntry(key: "garlic", displayName: "Garlic", status: .missing, updatedAt: date(200)))
        context.insert(PantryEntry(key: "ginger", displayName: "ginger", status: .have, updatedAt: date(50)))
        try context.save()

        // Before the pass, readers already see one entry per key, the newest.
        let entries = try context.fetch(FetchDescriptor<PantryEntry>())
        #expect(entries.newestPerKey.count == 2)
        #expect(entries.snapshot.missing == ["garlic"])
        #expect(entries.snapshot.have == ["ginger"])
        #expect(context.pantryStatus(key: "garlic") == .missing)

        #expect(SyncDedupe.run(in: context).pantry == 1)
        let left = try context.fetch(FetchDescriptor<PantryEntry>(sortBy: [SortDescriptor(\.key)]))
        #expect(left.map(\.key) == ["garlic", "ginger"])
        #expect(left.first?.displayName == "Garlic")
        #expect(SyncDedupe.run(in: context).total == 0)
    }

    @Test func settingThePantryMergesDuplicates() throws {
        context.insert(PantryEntry(key: "garlic", displayName: "garlic", status: .have, updatedAt: date(100)))
        context.insert(PantryEntry(key: "garlic", displayName: "garlic", status: .have, updatedAt: date(200)))
        context.setPantry(key: "garlic", displayName: "garlic", status: .missing)
        try context.save()
        let left = try context.fetch(FetchDescriptor<PantryEntry>())
        #expect(left.count == 1)
        #expect(left.first?.pantryStatus == .missing)
        context.removePantry(key: "garlic")
        #expect(try context.fetchCount(FetchDescriptor<PantryEntry>()) == 0)
    }

    /// Reinstall or a second device: a blank profile was made before the synced one arrived.
    @Test func profilesMergeToOneKeepingOnboardingAndTheNewestPrefs() throws {
        let blank = UserProfile()   // a new device, before sync: default prefs, distantPast
        let migrated = UserProfile(prefs: UserPreferences(spiceLevel: 4), onboardingDone: true)   // from V2: distantPast
        context.insert(blank)
        context.insert(migrated)
        try context.save()
        let merged = context.profile()
        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 1)
        #expect(merged.onboardingDone)
        #expect(merged.prefs.spiceLevel == 4)
    }

    @Test func newerPrefsWinAndOnboardingIsKeptFromEither() throws {
        let older = UserProfile(prefs: UserPreferences(spiceLevel: 1), onboardingDone: true, updatedAt: date(100))
        let newer = UserProfile(prefs: UserPreferences(spiceLevel: 3), onboardingDone: false, updatedAt: date(200))
        context.insert(older)
        context.insert(newer)
        try context.save()
        #expect(SyncDedupe.run(in: context).profiles == 1)
        let left = try context.fetch(FetchDescriptor<UserProfile>())
        #expect(left.count == 1)
        #expect(left.first?.prefs.spiceLevel == 3)
        #expect(left.first?.onboardingDone == true)
    }

    @Test func changingPrefsStampsTheProfile() {
        let profile = context.profile()
        #expect(profile.updatedAt == .distantPast)
        profile.prefs = UserPreferences(spiceLevel: 0)
        #expect(profile.updatedAt > Date().addingTimeInterval(-60))
    }

    /// Only a restored backup shares recipe IDs; the more recently edited copy wins. Recipes
    /// created separately on two devices are two recipes.
    @Test func recipesWithTheSameIDMergeAndOthersStay() throws {
        let recipe = Recipe(title: "Dal", steps: ["Simmer."])
        let a = SavedRecipe(original: recipe, now: date(100))
        let b = SavedRecipe(original: recipe, now: date(100))
        b.id = a.id
        b.updatedAt = date(300)
        b.recordCook(CookLogEntry(feedback: "on the iPad"))
        let separate = SavedRecipe(original: recipe, now: date(100))
        for item in [a, b, separate] { context.insert(item) }
        try context.save()

        #expect(SyncDedupe.run(in: context).recipes == 1)
        let left = try context.fetch(FetchDescriptor<SavedRecipe>())
        #expect(left.count == 2)
        #expect(left.first { $0.id == a.id }?.cookLog.map(\.feedback) == ["on the iPad"])
    }

    @Test func photosKeepOnePerName() throws {
        context.insert(CookPhoto(name: "A.heic", recipeID: nil, data: Data(count: 10)))
        context.insert(CookPhoto(name: "A.heic", recipeID: nil, data: Data(count: 10)))
        context.insert(CookPhoto(name: "B.heic", recipeID: nil, data: Data(count: 10)))
        try context.save()
        #expect(SyncDedupe.run(in: context).photos == 1)
        #expect(try context.fetch(FetchDescriptor<CookPhoto>()).map(\.name).sorted() == ["A.heic", "B.heic"])
    }
}
