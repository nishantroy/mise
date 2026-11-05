import Foundation
import os
import SwiftData

/// Writes cooking-log entries with their photos, and deletes photos with whatever owns them.
@MainActor
enum CookLogging {
    private static let log = Logger(subsystem: "Mise", category: "CookLog")

    /// Logs a cook (counted in `timesCooked`). The photo is written first; if that fails the entry
    /// is still logged, without it. The caller saves the context.
    static func record(_ saved: SavedRecipe, photo: ProcessedCookPhoto?, rating: Int?, feedback: String,
                       servings: Int?, revisionID: UUID?, date: Date = .now, store: CookPhotoStore = .shared) {
        var name: String?
        if let photo {
            do {
                name = try store.write(photo)
            } catch {
                log.error("Couldn't write the cooking photo: \(error.localizedDescription, privacy: .public)")
            }
        }
        saved.recordCook(CookLogEntry(date: date, rating: rating, feedback: feedback,
                                      revisionID: revisionID, servings: servings, photo: name))
    }

    /// Before deleting a recipe: its photo files go too.
    static func deletePhotos(of saved: SavedRecipe, store: CookPhotoStore = .shared) {
        store.delete(saved.allPhotoNames)
    }

    static func deleteEntry(_ id: UUID, of saved: SavedRecipe, store: CookPhotoStore = .shared) {
        if let photo = saved.removeCookLogEntry(id: id) { store.delete(photo) }
    }

    static func deletePhoto(ofEntry id: UUID, of saved: SavedRecipe, store: CookPhotoStore = .shared) {
        if let photo = saved.removePhoto(fromEntry: id) { store.delete(photo) }
    }

    /// Settings → "Keep only the latest photo per recipe". Entries stay; older photos go, along
    /// with any file no entry refers to. Returns the number of photos deleted.
    @discardableResult
    static func keepLatestPhotos(in context: ModelContext, store: CookPhotoStore = .shared) -> Int {
        let recipes = (try? context.fetch(FetchDescriptor<SavedRecipe>())) ?? []
        var deleted = 0
        for saved in recipes {
            for entry in CookPhotoNaming.olderPhotos(saved.cookLog) {
                deletePhoto(ofEntry: entry.id, of: saved, store: store)
                deleted += 1
            }
        }
        try? context.save()
        let referenced = Set(recipes.flatMap(\.allPhotoNames))
        deleted += store.removeOrphans(referenced: referenced) / 2
        return deleted
    }
}
