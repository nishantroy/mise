import Foundation

/// Something shared to Mise from another app: a web link, or recipe text (e.g. from the
/// claude.ai app).
enum PendingItem: Hashable, Sendable {
    case url(URL)
    case text(id: String, text: String)

    /// Stored form in the App Group list. URLs stay plain strings, exactly as builds before
    /// text sharing wrote them, so links queued by an older extension still drain.
    var storedValue: Any {
        switch self {
        case .url(let url): url.absoluteString
        case .text(let id, let text): ["type": "text", "id": id, "text": text]
        }
    }

    init?(storedValue: Any) {
        if let string = storedValue as? String {
            guard let url = URL(string: string) else { return nil }
            self = .url(url)
        } else if let dict = storedValue as? [String: String], dict["type"] == "text",
                  let id = dict["id"], let text = dict["text"] {
            self = .text(id: id, text: text)
        } else {
            return nil
        }
    }

    /// Same content (text items get a fresh id each time they're shared).
    func sameContent(as other: PendingItem) -> Bool {
        switch (self, other) {
        case let (.url(a), .url(b)): a == b
        case let (.text(_, a), .text(_, b)): a == b
        default: false
        }
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

    static func remove(_ item: PendingItem) {
        guard let defaults else { return }
        let list = (defaults.array(forKey: key) ?? []).filter { PendingItem(storedValue: $0) != item }
        if list.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(list, forKey: key) }
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
