import Foundation
import RecipeKit

/// One "I made this": when, how it went, and an optional photo. Stored as JSON on
/// `SavedRecipe.cookLogData`, oldest first (like the revisions).
struct CookLogEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    /// -1 or 1 as rated that time; nil when not rated.
    var rating: Int?
    /// The feedback as typed (quick chips and text); empty when there was none.
    var feedback: String
    /// The revision saved with this cook ("Cooked it: …"), so the changes aren't copied here.
    var revisionID: UUID?
    var servings: Int?
    /// File name in the photo store (`CookPhotoStore`); the thumbnail's name is derived from it.
    var photo: String?

    init(id: UUID = UUID(), date: Date = Date(), rating: Int? = nil, feedback: String = "",
         revisionID: UUID? = nil, servings: Int? = nil, photo: String? = nil) {
        self.id = id
        self.date = date
        self.rating = rating
        self.feedback = feedback
        self.revisionID = revisionID
        self.servings = servings
        self.photo = photo
    }
}

extension SchemaV2.SavedRecipe {
    /// Oldest first. Empty for recipes saved before the log existed (nothing is backfilled).
    var cookLog: [CookLogEntry] {
        get { cookLogData.flatMap { ModelCoding.decode([CookLogEntry].self, from: $0) } ?? [] }
        set { cookLogData = newValue.isEmpty ? nil : ModelCoding.encode(newValue) }
    }

    /// Logs a cook and counts it, so `timesCooked` moves with the log.
    func recordCook(_ entry: CookLogEntry) {
        var log = cookLog
        log.append(entry)
        log.sort { $0.date < $1.date }
        cookLog = log
        timesCooked += 1
    }

    /// Removes an entry (and uncounts it). Returns its photo's file name for the caller to delete.
    @discardableResult
    func removeCookLogEntry(id: UUID) -> String? {
        var log = cookLog
        guard let index = log.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = log.remove(at: index)
        cookLog = log
        timesCooked = max(0, timesCooked - 1)
        return removed.photo
    }

    /// Clears an entry's photo, keeping the entry. Returns the file name for the caller to delete.
    @discardableResult
    func removePhoto(fromEntry id: UUID) -> String? {
        var log = cookLog
        guard let index = log.firstIndex(where: { $0.id == id }), let photo = log[index].photo else { return nil }
        log[index].photo = nil
        cookLog = log
        return photo
    }

    /// The most recent cooking photo, shown instead of the web image.
    var latestPhoto: String? { cookLog.last(where: { $0.photo != nil })?.photo }

    /// Every photo file this recipe's cooking log refers to.
    var photoNames: [String] { cookLog.compactMap(\.photo) }

    /// The log's photos plus the names a shared photo (from a `.mise` file) may have: for
    /// deleting the recipe, and for keeping those files when orphans are cleaned up.
    var allPhotoNames: [String] { photoNames + CookPhotoNaming.sharedPhotoCandidates(recipeID: id) }

    /// The photo for cards and the detail header: the latest cooking photo, else the photo a
    /// friend shared with the recipe.
    func displayPhotoURL(in store: CookPhotoStore) -> URL? {
        if let latest = latestPhoto { return store.url(for: latest) }
        return store.sharedPhoto(recipeID: id).map(store.url(for:))
    }

    /// The revision saved with an entry.
    func revision(for entry: CookLogEntry) -> RecipeRevision? {
        guard let id = entry.revisionID else { return nil }
        return revisions.first { $0.id == id }
    }
}
