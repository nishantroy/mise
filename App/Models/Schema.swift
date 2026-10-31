import Foundation
import SwiftData

/// Version 1 of the on-disk schema. New versions get a new enum and a migration stage.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [SavedRecipe.self, PantryEntry.self, UserProfile.self] }
}

enum MiseMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias SavedRecipe = SchemaV1.SavedRecipe
typealias PantryEntry = SchemaV1.PantryEntry
typealias UserProfile = SchemaV1.UserProfile

/// JSON coding shared by the models' computed accessors.
enum ModelCoding {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
