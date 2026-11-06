import Foundation
import SwiftData

extension SchemaV3 {
    /// A cooking photo, or the photo that came with a shared recipe, stored in the database so it
    /// syncs with iCloud (`.externalStorage` data becomes a CloudKit asset). Added in V3; before,
    /// photos were files in Application Support/Photos (`CookPhotoStore.importLegacyFiles`).
    ///
    /// Found by `name`, the same string a `CookLogEntry.photo` holds ("<uuid>.heic") or
    /// "shared-<recipe uuid>.heic", so the cooking log's JSON didn't change. No relationship to
    /// `SavedRecipe`: log entries live inside the recipe's JSON, so they can't point at a model,
    /// and records arrive from iCloud in any order, so nothing may depend on both ends being here.
    /// Thumbnails aren't stored: each device derives and caches its own.
    @Model
    final class CookPhoto {
        var name: String = ""
        /// The recipe it belongs to, for clean-up. Nil for files whose recipe couldn't be found.
        var recipeID: UUID?
        var createdAt: Date = Date.distantPast
        /// `data.count`, so Settings can total the size without loading every photo.
        var byteCount: Int = 0
        /// HEIC (or JPEG), ≤ ~300 KB, metadata already stripped (`CookPhotoProcessor`).
        @Attribute(.externalStorage) var data: Data?

        init(name: String, recipeID: UUID?, data: Data, createdAt: Date = Date()) {
            self.name = name
            self.recipeID = recipeID
            self.data = data
            self.byteCount = data.count
            self.createdAt = createdAt
        }
    }
}
