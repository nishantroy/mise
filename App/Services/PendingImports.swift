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

    /// Queued URLs in order. Nothing is removed: the app calls `remove(_:)` once a URL's import
    /// sheet has been dealt with, so a URL survives the app being killed mid-sheet.
    static func pending() -> [URL] {
        (defaults?.stringArray(forKey: key) ?? []).compactMap(URL.init(string:))
    }

    static func remove(_ url: URL) {
        guard let defaults else { return }
        let list = (defaults.stringArray(forKey: key) ?? []).filter { $0 != url.absoluteString }
        if list.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(list, forKey: key) }
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
