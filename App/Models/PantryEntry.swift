import Foundation
import SwiftData
import RecipeKit

extension SchemaV1 {
    @Model
    final class PantryEntry {
        /// Catalog ID, or the normalised name for ingredients the catalog doesn't know.
        @Attribute(.unique) var key: String
        var displayName: String
        /// "have" or "missing".
        var status: String
        var updatedAt: Date

        init(key: String, displayName: String, status: PantryStatus, updatedAt: Date = Date()) {
            self.key = key
            self.displayName = displayName
            self.status = status.rawValue
            self.updatedAt = updatedAt
        }

        var pantryStatus: PantryStatus {
            get { PantryStatus(rawValue: status) ?? .have }
            set { status = newValue.rawValue }
        }
    }
}

enum PantryStatus: String, CaseIterable, Sendable {
    case have, missing
}

extension Array where Element == PantryEntry {
    var snapshot: PantrySnapshot {
        PantrySnapshot(have: Set(filter { $0.pantryStatus == .have }.map(\.key)),
                       missing: Set(filter { $0.pantryStatus == .missing }.map(\.key)))
    }
}

extension ModelContext {
    /// Inserts or updates the pantry entry for `key`.
    func setPantry(key: String, displayName: String, status: PantryStatus) {
        let descriptor = FetchDescriptor<PantryEntry>(predicate: #Predicate { $0.key == key })
        if let existing = try? fetch(descriptor).first {
            existing.pantryStatus = status
            existing.updatedAt = Date()
        } else {
            insert(PantryEntry(key: key, displayName: displayName, status: status))
        }
    }

    /// The status stored for `key`, if any.
    func pantryStatus(key: String) -> PantryStatus? {
        let descriptor = FetchDescriptor<PantryEntry>(predicate: #Predicate { $0.key == key })
        return (try? fetch(descriptor).first)?.pantryStatus
    }

    /// Deletes the pantry entry for `key` (undoing a change that created it).
    func removePantry(key: String) {
        let descriptor = FetchDescriptor<PantryEntry>(predicate: #Predicate { $0.key == key })
        for entry in (try? fetch(descriptor)) ?? [] { delete(entry) }
    }

    func pantrySnapshot() -> PantrySnapshot {
        ((try? fetch(FetchDescriptor<PantryEntry>())) ?? []).snapshot
    }
}
