import Foundation
import SwiftData
import Testing
import RecipeKit

@Suite("Cooking log")
@MainActor
struct CookLogTests {
    let container: ModelContainer
    let saved: SavedRecipe

    init() throws {
        container = try MiseStore.inMemory()
        saved = SavedRecipe(original: Recipe(title: "Chow Mein", steps: ["Boil the noodles."]))
        container.mainContext.insert(saved)
    }

    @Test func recordingKeepsTheLogInDateOrderAndCountsTheCook() {
        saved.timesCooked = 5   // cooked before the log existed: not backfilled, just counted on
        saved.recordCook(CookLogEntry(date: Date(timeIntervalSince1970: 200), photo: "B.heic"))
        saved.recordCook(CookLogEntry(date: Date(timeIntervalSince1970: 100), photo: "A.heic"))
        saved.recordCook(CookLogEntry(date: Date(timeIntervalSince1970: 300)))
        #expect(saved.timesCooked == 8)
        #expect(saved.cookLog.map(\.date.timeIntervalSince1970) == [100, 200, 300])
        #expect(saved.latestPhoto == "B.heic")
        #expect(saved.photoNames == ["A.heic", "B.heic"])
    }

    @Test func removingAnEntryUncountsItAndHandsBackItsPhoto() {
        let entry = CookLogEntry(photo: "A.heic")
        saved.recordCook(entry)
        #expect(saved.removeCookLogEntry(id: UUID()) == nil)
        #expect(saved.removeCookLogEntry(id: entry.id) == "A.heic")
        #expect(saved.timesCooked == 0)
        #expect(saved.cookLog.isEmpty)
        #expect(saved.cookLogData == nil)
        #expect(saved.removeCookLogEntry(id: entry.id) == nil)
        #expect(saved.timesCooked == 0)
    }

    @Test func removingAPhotoKeepsTheEntry() {
        let entry = CookLogEntry(rating: 1, feedback: "Too salty", photo: "A.heic")
        saved.recordCook(entry)
        #expect(saved.removePhoto(fromEntry: entry.id) == "A.heic")
        #expect(saved.cookLog.first?.photo == nil)
        #expect(saved.cookLog.first?.feedback == "Too salty")
        #expect(saved.timesCooked == 1)
        #expect(saved.latestPhoto == nil)
        #expect(saved.removePhoto(fromEntry: entry.id) == nil)
    }

    @Test func entriesLinkToTheirRevision() {
        saved.apply([.addNote("Less salt")], summary: "Cooked it: Note added")
        let entry = CookLogEntry(revisionID: saved.revisions.last?.id)
        saved.recordCook(entry)
        #expect(saved.revision(for: entry)?.summary == "Cooked it: Note added")
        #expect(saved.revision(for: CookLogEntry()) == nil)
    }

    @Test func olderPhotosAreEveryPhotoButTheNewest() {
        let log = [
            CookLogEntry(date: Date(timeIntervalSince1970: 300), photo: "C.heic"),
            CookLogEntry(date: Date(timeIntervalSince1970: 100), photo: "A.heic"),
            CookLogEntry(date: Date(timeIntervalSince1970: 400)),
            CookLogEntry(date: Date(timeIntervalSince1970: 200), photo: "B.heic"),
        ]
        #expect(CookPhotoNaming.olderPhotos(log).compactMap(\.photo) == ["A.heic", "B.heic"])
        #expect(CookPhotoNaming.olderPhotos([CookLogEntry(photo: "A.heic")]).isEmpty)
        #expect(CookPhotoNaming.olderPhotos([]).isEmpty)
    }
}
