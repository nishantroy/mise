import Foundation
import SwiftData
import RecipeKit

extension SchemaV3 {
    @Model
    final class PantryEntry {
        /// Catalog ID, or the normalised name for ingredients the catalog doesn't know.
        /// Not `.unique` since V3 (CloudKit can't enforce it): one entry per key is kept in code,
        /// newest `updatedAt` winning (`setPantry`, `SyncDedupe`).
        var key: String = ""
        var displayName: String = ""
        /// "have" or "missing".
        var status: String = PantryStatus.have.rawValue
        var updatedAt: Date = Date.distantPast

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
        let entries = newestPerKey
        return PantrySnapshot(have: Set(entries.filter { $0.pantryStatus == .have }.map(\.key)),
                              missing: Set(entries.filter { $0.pantryStatus == .missing }.map(\.key)))
    }

    /// One entry per key, the most recently updated (duplicates can arrive from another device
    /// before the dedupe pass removes them).
    var newestPerKey: [PantryEntry] {
        Dictionary(grouping: self, by: \.key).values.compactMap { $0.max { $0.updatedAt < $1.updatedAt } }
    }
}

extension ModelContext {
    /// Inserts or updates the pantry entry for `key`.
    func setPantry(key: String, displayName: String, status: PantryStatus) {
        let descriptor = FetchDescriptor<PantryEntry>(predicate: #Predicate { $0.key == key },
                                                      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let matches = (try? fetch(descriptor)) ?? []
        if let existing = matches.first {
            existing.pantryStatus = status
            existing.updatedAt = Date()
            // Copies synced from another device: one entry per key.
            for duplicate in matches.dropFirst() { delete(duplicate) }
        } else {
            insert(PantryEntry(key: key, displayName: displayName, status: status))
        }
    }

    /// The status stored for `key`, if any.
    func pantryStatus(key: String) -> PantryStatus? {
        let descriptor = FetchDescriptor<PantryEntry>(predicate: #Predicate { $0.key == key },
                                                      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
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
