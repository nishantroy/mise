import Foundation

/// URLs shared from Safari, queued in the App Group's UserDefaults by the share extension
/// and drained by the app when it becomes active. Compiled into both targets.
enum PendingImports {
    static let key = "pendingImportURLs"

    /// From Info.plist (`AppGroupID = $(APP_GROUP_ID)`), so the same code works in both bundles.
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    static var defaults: UserDefaults? {
        groupID.flatMap { UserDefaults(suiteName: $0) }
    }

    static func append(_ url: URL) {
        guard let defaults else { return }
        var list = defaults.stringArray(forKey: key) ?? []
        if !list.contains(url.absoluteString) { list.append(url.absoluteString) }
        defaults.set(list, forKey: key)
    }

    /// Returns queued URLs in order and empties the queue.
    static func drain() -> [URL] {
        guard let defaults, let list = defaults.stringArray(forKey: key), !list.isEmpty else { return [] }
        defaults.removeObject(forKey: key)
        return list.compactMap(URL.init(string:))
    }
}
