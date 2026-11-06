import Foundation
import SwiftData

/// Version 1 of the on-disk schema (the first release). Its models are frozen copies in
/// `SchemaV1Models.swift`. New versions get a new enum and a migration stage.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [SavedRecipe.self, PantryEntry.self, UserProfile.self] }
}

/// Version 2: `SavedRecipe.cookLogData` (the cooking log, JSON-encoded `[CookLogEntry]`).
/// Frozen copies in `SchemaV2Models.swift` (the 1.0 (2) TestFlight build).
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [SavedRecipe.self, PantryEntry.self, UserProfile.self] }
}

/// Version 3: iCloud sync. CloudKit's rules: every attribute optional or defaulted, no unique
/// constraints (pantry keys and the single profile are kept unique in code, `SyncDedupe`), no
/// required relationships. Adds `CookPhoto` (photos move from files into the store, so they
/// sync) and `UserProfile.updatedAt`. The live models (`SavedRecipe.swift`, `PantryEntry.swift`,
/// `UserProfile.swift`, `CookPhoto.swift`) belong here.
enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [SavedRecipe.self, PantryEntry.self, UserProfile.self, CookPhoto.self]
    }
}

/// Rules for a new version: freeze the previous version's stored properties in its own file
/// (no behaviour, never edited again), point the typealiases below at the new version, add a
/// stage, and extend `MigrationTests` with a store written by the previous release. Since V3 the
/// schema is also in CloudKit: only add optional/defaulted attributes and new models (CloudKit
/// can't rename or delete fields once deployed to production), and deploy the new schema in
/// CloudKit Console before shipping (NOTES.md, "iCloud sync").
enum MiseMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self] }
    /// V1 → V2 only adds an optional attribute; V2 → V3 adds defaults, an attribute with a
    /// default and an entity, and drops a unique constraint. Core Data infers both.
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
         .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self)]
    }
}

typealias SavedRecipe = SchemaV3.SavedRecipe
typealias PantryEntry = SchemaV3.PantryEntry
typealias UserProfile = SchemaV3.UserProfile
typealias CookPhoto = SchemaV3.CookPhoto

enum MiseStore {
    /// The app's CloudKit container (also in `App/Mise.entitlements`).
    static let cloudKitContainerID = "iCloud.com.nishantroy.mise"

    /// The current schema, opened through the migration plan (the app and the migration tests).
    /// `cloudKit` is `.none` unless the caller asks for sync: `.automatic` would pick up the
    /// entitlements' container, and tests and UI tests must never touch iCloud.
    static func container(url: URL, cloudKit: ModelConfiguration.CloudKitDatabase = .none) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: cloudKit)
        return try ModelContainer(for: schema, migrationPlan: MiseMigrationPlan.self, configurations: config)
    }

    static func inMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: MiseMigrationPlan.self, configurations: config)
    }
}

/// JSON coding shared by the models' computed accessors.
enum ModelCoding {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
