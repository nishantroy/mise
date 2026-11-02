import Foundation
import SwiftData

/// Version 1 of the on-disk schema (the first release). Its models are frozen copies in
/// `SchemaV1Models.swift`. New versions get a new enum and a migration stage.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [SavedRecipe.self, PantryEntry.self, UserProfile.self] }
}

/// Version 2: `SavedRecipe.cookLogData` (the cooking log, JSON-encoded `[CookLogEntry]`).
/// The live models (`SavedRecipe.swift`, `PantryEntry.swift`, `UserProfile.swift`) belong here.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [SavedRecipe.self, PantryEntry.self, UserProfile.self] }
}

/// Rules for a new version: freeze the previous version's stored properties in its own file
/// (no behaviour, never edited again), point the typealiases below at the new version, add a
/// stage, and extend `MigrationTests` with a store written by the previous release.
enum MiseMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    /// V1 → V2 only adds an optional attribute, so Core Data infers it.
    static var stages: [MigrationStage] { [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)] }
}

typealias SavedRecipe = SchemaV2.SavedRecipe
typealias PantryEntry = SchemaV2.PantryEntry
typealias UserProfile = SchemaV2.UserProfile

enum MiseStore {
    /// The current schema, opened through the migration plan (the app and the migration tests).
    static func container(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let config = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, migrationPlan: MiseMigrationPlan.self, configurations: config)
    }

    static func inMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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
