import Foundation
import Testing
import RecipeKit

/// Receiving a `.mise` file: reading the opened file (the `onOpenURL` path, cold launch or
/// not), the App Group queue entry, the shared photo, and what's saved.
@Suite("Shared recipes")
struct SharedRecipeTests {
    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MiseShared-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let recipe = Recipe(title: "Pepper Chicken", sourceURL: URL(string: "https://example.com/pc"), servings: 4,
                               ingredients: [Ingredient(raw: "2 tbsp oil", quantity: 2, unit: "tbsp", name: "oil")],
                               steps: ["Fry the chicken."], notes: ["More pepper."])

    @Test func limitsMatchTheFormat() {
        #expect(IncomingRecipeFiles.maxBytes == SharedRecipeFile.maxFileBytes)
        #expect(IncomingRecipeFiles.fileExtension == SharedRecipeFile.fileExtension)
    }

    // MARK: Opening a file (onOpenURL)

    @Test func openedFileInOurInboxIsReadAndRemoved() throws {
        let documents = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let inbox = documents.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let data = try SharedRecipeFile(recipe: Self.recipe).fileData()
        let file = inbox.appending(path: "Pepper Chicken.mise")
        try data.write(to: file)

        let read = try IncomingRecipeFiles.readOpened(file, inboxDirectory: inbox)
        #expect(read == data)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(try SharedRecipeFile.read(read).recipe.title == "Pepper Chicken")
    }

    @Test func openedFileElsewhereIsLeftAlone() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Pepper Chicken.mise")
        try Data("{}".utf8).write(to: file)
        _ = try IncomingRecipeFiles.readOpened(file, inboxDirectory: dir.appending(path: "Inbox"))
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func oversizedOpenedFileIsRefusedUnread() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Big.mise")
        try Data(count: IncomingRecipeFiles.maxBytes + 1).write(to: file)
        #expect(throws: CocoaError.self) { try IncomingRecipeFiles.readOpened(file, inboxDirectory: dir) }
    }

    @Test func missingOpenedFileThrows() {
        #expect(throws: (any Error).self) {
            try IncomingRecipeFiles.readOpened(URL(filePath: "/nonexistent/x.mise"), inboxDirectory: URL(filePath: "/nonexistent"))
        }
    }

    // MARK: Queue

    @Test func queuedFileSavesReadsAndDeletes() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("recipe".utf8)
        let id = try IncomingRecipeFiles.save(data, in: dir)
        #expect(IncomingRecipeFiles.data(id: id, in: dir) == data)
        IncomingRecipeFiles.delete(id: id, in: dir)
        #expect(IncomingRecipeFiles.data(id: id, in: dir) == nil)
        #expect(throws: CocoaError.self) { try IncomingRecipeFiles.save(Data(count: IncomingRecipeFiles.maxBytes + 1), in: dir) }
    }

    @Test func queueEntryRoundTripsAndRejectsPaths() {
        let id = UUID().uuidString
        let item = PendingItem.recipeFile(id: id)
        #expect(PendingItem(storedValue: item.storedValue) == item)
        #expect(PendingItem(storedValue: ["type": "recipeFile", "id": "../../etc/passwd"]) == nil)
        #expect(IncomingRecipeFiles.data(id: "../x", in: FileManager.default.temporaryDirectory) == nil)
        // Older entries still read.
        #expect(PendingItem(storedValue: "https://example.com") == .url(URL(string: "https://example.com")!))
        #expect(PendingItem(storedValue: ["type": "text", "id": "1", "text": "hi"]) == .text(id: "1", text: "hi"))
    }

    // MARK: Shared photo

    @Test func sharedPhotoIsTheCardImageUntilACookPhotoIsLogged() throws {
        let store = try CookPhotoTests.makeStore()
        defer { store.deleteAll() }
        let saved = SavedRecipe(original: Self.recipe, revisions: [RecipeRevision(summary: "Shared with you", edits: [])])
        #expect(saved.displayPhotoURL(in: store) == nil)

        let processed = ProcessedCookPhoto(photo: Data(count: 500), thumbnail: Data(count: 50), fileExtension: "heic",
                                           pixelWidth: 1, pixelHeight: 1)
        let name = try store.writeShared(processed, recipeID: saved.id)
        #expect(name == "shared-\(saved.id.uuidString).heic")
        #expect(saved.displayPhotoURL(in: store) == store.url(for: name))
        // Not a cook: nothing logged or counted.
        #expect(saved.cookLog.isEmpty)
        #expect(saved.timesCooked == 0)

        // Orphan clean-up keeps it (and its thumbnail) while the recipe refers to it.
        #expect(store.removeOrphans(referenced: Set(saved.allPhotoNames), now: Date().addingTimeInterval(7200)) == 0)
        #expect(store.usage().photos == 1)

        saved.recordCook(CookLogEntry(photo: "mine.heic"))
        #expect(saved.displayPhotoURL(in: store) == store.url(for: "mine.heic"))

        // Deleting the recipe deletes it (CookLogging.deletePhotos uses allPhotoNames).
        store.delete(saved.allPhotoNames)
        #expect(store.photoNames().isEmpty)
        #expect(store.cachedFileNames().isEmpty)
    }

    @Test func receivedCookPhotoFitsAndIsReEncodedOnReceive() throws {
        // The sender's stored photo (≤ 300 KB HEIC) goes in as is.
        let processed = try #require(CookPhotoProcessor.process(try CookPhotoTests.cameraPhoto()))
        let file = SharedRecipeFile(recipe: Self.recipe, photo: .init(data: processed.photo, type: "public.heic"))
        let data = try file.fileData()
        let plain = try SharedRecipeFile(recipe: Self.recipe).fileData()
        print("Shared file: \(plain.count) B without a photo, \(data.count) B with a \(processed.photo.count) B photo")
        #expect(data.count <= SharedRecipeFile.maxFileBytes)

        // The receiver runs it through the same processor (metadata stripped, thumbnail made).
        let received = try #require(try SharedRecipeFile.read(data).photo)
        let again = try #require(CookPhotoProcessor.process(received.data))
        #expect(again.pixelWidth == 1600)
        #expect(again.photo.count <= CookPhotoSizing.targetBytes)
    }

    // MARK: Saved recipe

    @Test func originalIsTheFriendsVersion() {
        var friends = Self.recipe
        friends.notes = ["Friend's tip"]
        let saved = SavedRecipe(original: friends, revisions: [RecipeRevision(summary: "Shared with you", edits: [])])
        saved.apply([.addNote("Mine")])
        #expect(saved.recipe.notes == ["Friend's tip", "Mine"])
        saved.resetToOriginal()
        #expect(saved.recipe.notes == ["Friend's tip"])
        #expect(saved.revisions.map(\.summary).first == "Shared with you")
    }
}
