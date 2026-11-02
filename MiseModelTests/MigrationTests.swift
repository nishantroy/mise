import Foundation
import SwiftData
import Testing
import RecipeKit

/// The store on the owner's phone was written by SchemaV1. These open such stores with the
/// current schema and migration plan, as the app does on launch.
@Suite("Store migration")
struct MigrationTests {
    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MiseMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Mise.store")
    }

    /// A copy of `V1Sample.store`, written by the V1 release's own model code (main at 6804fd2;
    /// see NOTES.md): two recipes, a pantry entry and a profile.
    private func copyFixture() throws -> URL {
        let fixture = try #require(Bundle(for: BundleToken.self).url(forResource: "V1Sample", withExtension: "store",
                                                                    subdirectory: "Fixtures"))
        let url = try tempStoreURL()
        try FileManager.default.copyItem(at: fixture, to: url)
        return url
    }

    private func recipes(in context: ModelContext) throws -> [SavedRecipe] {
        try context.fetch(FetchDescriptor<SavedRecipe>(sortBy: [SortDescriptor(\.title)]))
    }

    @Test func v1StoreFromTheLastReleaseOpensWithEverythingKept() throws {
        let url = try copyFixture()
        do {
            let context = ModelContext(try MiseStore.container(url: url))
            let all = try recipes(in: context)
            #expect(all.map(\.title) == ["Chow Mein", "Mongolian Beef"])
            let beef = try #require(all.last)
            #expect(beef.timesCooked == 3)
            #expect(beef.rating == 1)
            #expect(beef.recipe.servings == 4)
            #expect(beef.recipe.ingredients.count == 3)
            #expect(beef.recipe.notes == ["Use less soy sauce"])
            #expect(beef.original.notes.isEmpty)
            #expect(beef.revisions.map(\.summary) == ["Imported", "Cooked it: Note added"])
            #expect(beef.createdAt == Date(timeIntervalSince1970: 1_780_000_000))
            // Nothing is backfilled: the log starts empty and the count stays.
            #expect(beef.cookLogData == nil)
            #expect(beef.cookLog.isEmpty)
            #expect(beef.latestPhoto == nil)

            let pantry = try context.fetch(FetchDescriptor<PantryEntry>())
            #expect(pantry.map(\.key) == ["shaoxing-wine"])
            #expect(pantry.first?.pantryStatus == .missing)
            let profile = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
            #expect(profile.onboardingDone)
            #expect(profile.prefs.spiceLevel == 2)

            // The migrated store takes log entries.
            beef.recordCook(CookLogEntry(date: Date(timeIntervalSince1970: 1_790_000_000), rating: 1,
                                         feedback: "Perfect", revisionID: beef.revisions.last?.id, servings: 2,
                                         photo: "A.heic"))
            try context.save()
        }
        // Reopen the (now V2) store: the entry and the count survived.
        let context = ModelContext(try MiseStore.container(url: url))
        let beef = try #require(try recipes(in: context).last)
        #expect(beef.timesCooked == 4)
        #expect(beef.cookLog.count == 1)
        #expect(beef.cookLog.first?.servings == 2)
        #expect(beef.latestPhoto == "A.heic")
        #expect(beef.revision(for: beef.cookLog[0])?.summary == "Cooked it: Note added")
    }

    /// The frozen V1 definitions describe the same store: one written with them migrates too.
    @Test func storeWrittenWithFrozenV1ModelsMigrates() throws {
        let url = try tempStoreURL()
        let recipe = Recipe(title: "Dal", steps: ["Simmer the lentils."])
        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(SchemaV1.SavedRecipe(title: "Dal", recipeData: ModelCoding.encode(recipe),
                                                originalData: ModelCoding.encode(recipe),
                                                revisionsData: ModelCoding.encode([RecipeRevision(summary: "Imported", edits: [])]),
                                                rating: -1, timesCooked: 2))
            context.insert(SchemaV1.PantryEntry(key: "lentils", displayName: "lentils", status: "have"))
            context.insert(SchemaV1.UserProfile(prefsData: ModelCoding.encode(UserPreferences()), onboardingDone: true))
            try context.save()
        }
        let context = ModelContext(try MiseStore.container(url: url))
        let dal = try #require(try recipes(in: context).first)
        #expect(dal.recipe.steps == ["Simmer the lentils."])
        #expect(dal.rating == -1)
        #expect(dal.timesCooked == 2)
        #expect(dal.cookLog.isEmpty)
        #expect(try context.fetch(FetchDescriptor<PantryEntry>()).first?.pantryStatus == .have)
        #expect(try context.fetch(FetchDescriptor<UserProfile>()).first?.onboardingDone == true)
    }
}

final class BundleToken {}
