import Foundation
import SwiftData
import CoreData
import Testing
import RecipeKit

/// Stores on testers' phones were written by SchemaV1 (1.0 (1)) or SchemaV2 (1.0 (2)). These open
/// such stores with the current schema (V3) and migration plan, as the app does on launch (with
/// iCloud off: `MiseStore.container` defaults to `cloudKit: .none`).
@Suite("Store migration")
struct MigrationTests {
    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MiseMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Mise.store")
    }

    /// A copy of `V1Sample.store`, written by the V1 release's own model code (main at 6804fd2;
    /// see NOTES.md): two recipes, a pantry entry and a profile.
    private func copyFixture(_ name: String = "V1Sample") throws -> URL {
        let fixture = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "store",
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

    // MARK: V2 (1.0 (2), the TestFlight build) → V3

    static let beefID = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
    static let dalID = UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!
    static let beefPhoto = "A0000000-0000-0000-0000-000000000001.heic"

    /// `V2Sample.store` was written by the 1.0 (2) model files, unmodified (main at afba3f0,
    /// generator in `Fixtures/MakeV2Fixture.swift.txt`): every field is checked after migration.
    @Test func v2StoreFromTestFlightOpensWithEverythingKept() throws {
        let url = try copyFixture("V2Sample")
        do {
            let context = ModelContext(try MiseStore.container(url: url))
            let all = try recipes(in: context)
            #expect(all.map(\.title) == ["Mongolian Beef", "Shared Dal"])

            let beef = all[0]
            #expect(beef.id == Self.beefID)
            #expect(beef.createdAt == Date(timeIntervalSince1970: 1_780_000_000))
            #expect(beef.updatedAt == Date(timeIntervalSince1970: 1_781_000_000))
            #expect(beef.rating == 1)
            #expect(beef.timesCooked == 4)
            #expect(beef.recipe.title == "Mongolian Beef")
            #expect(beef.recipe.servings == 4)
            #expect(beef.recipe.cuisine == "Chinese")
            #expect(beef.recipe.sourceURL == URL(string: "https://example.com/beef"))
            #expect(beef.recipe.ingredients.map(\.raw) == ["500 g flank steak", "3 tbsp soy sauce"])
            #expect(beef.recipe.steps == ["Slice the beef.", "Fry it hot."])
            #expect(beef.recipe.notes == ["Use less soy sauce"])
            #expect(beef.original.notes.isEmpty)
            #expect(beef.revisions.map(\.summary) == ["Imported", "Cooked it: Note added"])
            let log = beef.cookLog
            #expect(log.count == 2)
            #expect(log[0].id == UUID(uuidString: "C0000000-0000-0000-0000-000000000001"))
            #expect(log[0].date == Date(timeIntervalSince1970: 1_781_000_000))
            #expect(log[0].rating == 1)
            #expect(log[0].feedback == "Great, less salty")
            #expect(log[0].servings == 2)
            #expect(log[0].photo == Self.beefPhoto)
            #expect(beef.revision(for: log[0])?.summary == "Cooked it: Note added")
            #expect(log[1].photo == nil && log[1].rating == nil && log[1].feedback.isEmpty)
            #expect(beef.latestPhoto == Self.beefPhoto)

            let dal = all[1]
            #expect(dal.id == Self.dalID)
            #expect(dal.rating == -1)
            #expect(dal.timesCooked == 0)
            #expect(dal.cookLogData == nil)
            #expect(dal.recipe.steps == ["Simmer the lentils."])
            #expect(dal.revisions.map(\.summary) == ["Shared with you"])

            let pantry = try context.fetch(FetchDescriptor<PantryEntry>(sortBy: [SortDescriptor(\.key)]))
            #expect(pantry.map(\.key) == ["garlic", "shaoxing-wine"])
            #expect(pantry.map(\.displayName) == ["garlic", "Shaoxing wine"])
            #expect(pantry.map(\.pantryStatus) == [.have, .missing])
            #expect(pantry.map(\.updatedAt) == [Date(timeIntervalSince1970: 1_781_600_000),
                                                 Date(timeIntervalSince1970: 1_781_500_000)])

            let profiles = try context.fetch(FetchDescriptor<UserProfile>())
            #expect(profiles.count == 1)
            let profile = try #require(profiles.first)
            #expect(profile.onboardingDone)
            #expect(profile.updatedAt == .distantPast)   // added in V3
            #expect(profile.prefs == UserPreferences(diet: .pescatarian, avoid: [.pork], dislikes: ["cilantro"],
                                                     spiceLevel: 3, cuisines: ["Chinese", "Indian"],
                                                     weeknightMinutes: 45, servings: 3))
            #expect(try context.fetch(FetchDescriptor<CookPhoto>()).isEmpty)

            // The migrated store takes V3 writes: a pantry change and a photo.
            context.setPantry(key: "garlic", displayName: "garlic", status: .missing)
            context.insert(CookPhoto(name: "new.heic", recipeID: beef.id, data: Data(count: 10)))
            try context.save()
        }
        let context = ModelContext(try MiseStore.container(url: url))
        #expect(context.pantryStatus(key: "garlic") == .missing)
        #expect(try context.fetch(FetchDescriptor<CookPhoto>()).map(\.name) == ["new.heic"])
        #expect(try recipes(in: context).first?.cookLog.count == 2)
    }

    /// First launch of V3 on the owner's phone: the photo files move into the store, are found
    /// by name, and the folder goes. Running it again changes nothing.
    @Test func v2PhotoFilesMoveIntoTheStore() throws {
        let url = try copyFixture("V2Sample")
        let container = try MiseStore.container(url: url)
        let root = url.deletingLastPathComponent()
        let legacy = root.appending(path: "Photos", directoryHint: .isDirectory)
        let cache = root.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let processed = try #require(CookPhotoProcessor.process(try CookPhotoTests.cameraPhoto(grain: 0)))
        let shared = CookPhotoNaming.sharedPhotoName(recipeID: Self.dalID, fileExtension: "heic")
        for name in [Self.beefPhoto, shared, "orphan.heic"] {
            try processed.photo.write(to: legacy.appending(path: name))
            try processed.thumbnail.write(to: legacy.appending(path: CookPhotoNaming.thumbnailName(for: name)))
        }
        try Data().write(to: legacy.appending(path: "gone-thumb.heic"))   // a thumbnail without its photo

        let store = CookPhotoStore(container: container, directory: cache)
        #expect(try store.importLegacyFiles(from: legacy, batchSize: 2) == 3)
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))

        let photos = try ModelContext(container).fetch(FetchDescriptor<CookPhoto>(sortBy: [SortDescriptor(\.name)]))
        #expect(photos.map(\.name) == [Self.beefPhoto, "orphan.heic", shared])
        #expect(photos.map(\.recipeID) == [Self.beefID, nil, Self.dalID])
        #expect(photos.allSatisfy { $0.data == processed.photo && $0.byteCount == processed.photo.count })
        // The files became the cache, thumbnails included.
        #expect(Set(store.cachedFileNames()).isSuperset(of: [Self.beefPhoto, CookPhotoNaming.thumbnailName(for: Self.beefPhoto)]))
        let all = try recipes(in: ModelContext(container))
        #expect(all.first?.displayPhotoURL(in: store) == store.url(for: Self.beefPhoto))
        #expect(all.last?.displayPhotoURL(in: store) == store.url(for: shared))

        // Idempotent: nothing left to import, nothing stored twice.
        #expect(try store.importLegacyFiles(from: legacy) == 0)
        // A crash after the save but before the files moved: they're recognised, not duplicated.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try processed.photo.write(to: legacy.appending(path: Self.beefPhoto))
        #expect(try store.importLegacyFiles(from: legacy) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<CookPhoto>()) == 3)
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
    }

    /// The frozen V2 definitions describe the same store as the release: one written with them
    /// migrates too.
    @Test func storeWrittenWithFrozenV2ModelsMigrates() throws {
        let url = try tempStoreURL()
        let recipe = Recipe(title: "Dal", steps: ["Simmer the lentils."])
        let log = [CookLogEntry(feedback: "Good", photo: "P.heic")]
        do {
            let schema = Schema(versionedSchema: SchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(SchemaV2.SavedRecipe(title: "Dal", recipeData: ModelCoding.encode(recipe),
                                                originalData: ModelCoding.encode(recipe),
                                                revisionsData: ModelCoding.encode([RecipeRevision(summary: "Imported", edits: [])]),
                                                rating: 1, timesCooked: 1, cookLogData: ModelCoding.encode(log)))
            context.insert(SchemaV2.PantryEntry(key: "lentils", displayName: "lentils", status: "missing"))
            context.insert(SchemaV2.UserProfile(prefsData: ModelCoding.encode(UserPreferences(spiceLevel: 4)), onboardingDone: true))
            try context.save()
        }
        let context = ModelContext(try MiseStore.container(url: url))
        let dal = try #require(try recipes(in: context).first)
        #expect(dal.recipe.steps == ["Simmer the lentils."])
        #expect(dal.timesCooked == 1)
        #expect(dal.cookLog.map(\.feedback) == ["Good"])
        #expect(dal.latestPhoto == "P.heic")
        #expect(try context.fetch(FetchDescriptor<PantryEntry>()).first?.pantryStatus == .missing)
        #expect(try context.fetch(FetchDescriptor<UserProfile>()).first?.prefs.spiceLevel == 4)
    }

    // MARK: CloudKit's rules

    /// What NSPersistentCloudKitContainer checks when it loads (it refuses the store otherwise,
    /// and the app would fall back to local): no unique constraints, every attribute optional or
    /// defaulted, every relationship optional with an inverse.
    @Test func v3ModelMeetsCloudKitRequirements() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: SchemaV3.models))
        #expect(Set(model.entities.compactMap(\.name)) == ["SavedRecipe", "PantryEntry", "UserProfile", "CookPhoto"])
        for entity in model.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name ?? "") has a unique constraint")
            for attribute in entity.attributesByName.values {
                #expect(attribute.isOptional || attribute.defaultValue != nil,
                        "\(entity.name ?? "").\(attribute.name) needs a default")
            }
            for relationship in entity.relationshipsByName.values {
                #expect(relationship.isOptional && relationship.inverseRelationship != nil)
            }
        }
        let data = try #require(model.entitiesByName["CookPhoto"]?.attributesByName["data"])
        #expect(data.allowsExternalBinaryDataStorage)
    }
}

final class BundleToken {}
