import Foundation

/// Something shared to Mise from another app: a web link, recipe text (e.g. from the
/// claude.ai app), or a `.mise` recipe file a friend sent.
enum PendingItem: Hashable, Sendable {
    case url(URL)
    case text(id: String, text: String)
    /// A `.mise` file copied into the App Group (`IncomingRecipeFiles`), by its id.
    case recipeFile(id: String)

    /// Stored form in the App Group list. URLs stay plain strings, exactly as builds before
    /// text sharing wrote them, so links queued by an older extension still drain. Builds
    /// before recipe files skip (and keep) entries they don't know.
    var storedValue: Any {
        switch self {
        case .url(let url): url.absoluteString
        case .text(let id, let text): ["type": "text", "id": id, "text": text]
        case .recipeFile(let id): ["type": "recipeFile", "id": id]
        }
    }

    init?(storedValue: Any) {
        if let string = storedValue as? String {
            guard let url = URL(string: string) else { return nil }
            self = .url(url)
        } else if let dict = storedValue as? [String: String], dict["type"] == "text",
                  let id = dict["id"], let text = dict["text"] {
            self = .text(id: id, text: text)
        } else if let dict = storedValue as? [String: String], dict["type"] == "recipeFile",
                  let id = dict["id"], IncomingRecipeFiles.isValidID(id) {
            self = .recipeFile(id: id)
        } else {
            return nil
        }
    }

    /// Same content (text items get a fresh id each time they're shared).
    func sameContent(as other: PendingItem) -> Bool {
        switch (self, other) {
        case let (.url(a), .url(b)): a == b
        case let (.text(_, a), .text(_, b)): a == b
        case let (.recipeFile(a), .recipeFile(b)): a == b
        default: false
        }
    }
}

/// `.mise` files waiting in the queue, as files in the App Group container (too big for
/// UserDefaults). Written by the share extension, or by the app when a file is opened in it.
enum IncomingRecipeFiles {
    /// Same as `SharedRecipeFile.maxFileBytes` (the extension doesn't link RecipeKit; a test
    /// keeps them equal). Larger files are refused before they're read.
    static let maxBytes = 1_000_000
    static let fileExtension = "mise"

    /// `<App Group>/IncomingRecipes`.
    static var directory: URL? {
        guard let groupID = PendingImports.groupID,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return container.appending(path: "IncomingRecipes", directoryHint: .isDirectory)
    }

    /// Ids are UUID strings we made; anything else (e.g. "../x") is never turned into a path.
    static func isValidID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    static func url(id: String, in directory: URL) -> URL {
        directory.appending(path: "\(id).\(fileExtension)", directoryHint: .notDirectory)
    }

    /// Writes the file's bytes; returns its id.
    static func save(_ data: Data, in directory: URL) throws -> String {
        guard data.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try data.write(to: url(id: id, in: directory), options: .atomic)
        return id
    }

    static func data(id: String, in directory: URL) -> Data? {
        guard isValidID(id) else { return nil }
        let file = url(id: id, in: directory)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else { return nil }
        return try? Data(contentsOf: file)
    }

    static func delete(id: String, in directory: URL) {
        guard isValidID(id) else { return }
        try? FileManager.default.removeItem(at: url(id: id, in: directory))
    }

    /// Reads a file opened in Mise (Messages, Mail, Files, AirDrop: iOS hands over a copy in
    /// Documents/Inbox, or a security-scoped URL), on a cold launch or while running. The size
    /// is checked before reading. A copy in our own Inbox is deleted once read.
    static func readOpened(_ url: URL, inboxDirectory: URL = URL.documentsDirectory.appending(path: "Inbox")) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        if isInside(url, directory: inboxDirectory) { try? FileManager.default.removeItem(at: url) }
        return data
    }

    static func isInside(_ file: URL, directory: URL) -> Bool {
        func path(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        }
        var dir = path(directory)
        if !dir.hasSuffix("/") { dir += "/" }
        return path(file).hasPrefix(dir)
    }
}

/// Items shared to Mise, queued in the App Group's UserDefaults by the share extension and
/// drained by the app when it becomes active. Compiled into both targets.
enum PendingImports {
    /// Unchanged from the URL-only queue, so existing entries are found.
    static let key = "pendingImportURLs"
    /// Shared text longer than this is cut (a recipe is far shorter; this keeps UserDefaults small).
    static let maxTextLength = 20_000

    /// From Info.plist (`AppGroupID = $(APP_GROUP_ID)`), so the same code works in both bundles.
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    static var defaults: UserDefaults? {
        groupID.flatMap { UserDefaults(suiteName: $0) }
    }

    static func append(_ url: URL) {
        append(.url(url))
    }

    static func appendText(_ text: String) {
        append(.text(id: UUID().uuidString, text: String(text.prefix(maxTextLength))))
    }

    /// Copies a `.mise` file's bytes into the App Group and queues it. False when there's no
    /// App Group (unprovisioned) or the file is too big.
    @discardableResult
    static func appendRecipeFile(_ data: Data) -> Bool {
        guard defaults != nil, let directory = IncomingRecipeFiles.directory,
              let id = try? IncomingRecipeFiles.save(data, in: directory) else { return false }
        append(.recipeFile(id: id))
        return true
    }

    /// A queued recipe file's bytes (nil when it's gone).
    static func recipeFileData(id: String) -> Data? {
        IncomingRecipeFiles.directory.flatMap { IncomingRecipeFiles.data(id: id, in: $0) }
    }

    static func append(_ item: PendingItem) {
        guard let defaults else { return }
        var list = defaults.array(forKey: key) ?? []
        if !list.contains(where: { PendingItem(storedValue: $0)?.sameContent(as: item) == true }) {
            list.append(item.storedValue)
        }
        defaults.set(list, forKey: key)
    }

    /// Queued items in order. Nothing is removed: the app calls `remove(_:)` once an item's
    /// sheet has been dealt with, so it survives the app being killed mid-sheet.
    static func pending() -> [PendingItem] {
        (defaults?.array(forKey: key) ?? []).compactMap(PendingItem.init(storedValue:))
    }

    /// Takes an item off the queue (and deletes a recipe file's copy).
    static func remove(_ item: PendingItem) {
        if case .recipeFile(let id) = item, let directory = IncomingRecipeFiles.directory {
            IncomingRecipeFiles.delete(id: id, in: directory)
        }
        guard let defaults else { return }
        let list = (defaults.array(forKey: key) ?? []).filter { PendingItem(storedValue: $0) != item }
        if list.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(list, forKey: key) }
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
        if let directory = IncomingRecipeFiles.directory { try? FileManager.default.removeItem(at: directory) }
    }
}
