import Foundation
import SwiftData
import SwiftUI
import RecipeKit

/// Launch-time configuration, including the hooks UI tests use.
enum LaunchOptions {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// UI tests: use a separate store file and stubbed network.
    static var isUITesting: Bool { arguments.contains("-uiTesting") }
    /// Delete the store before opening it (fresh-install behaviour).
    static var resetData: Bool { arguments.contains("-resetData") }
    /// Force the rules assistant regardless of model availability (UI tests).
    static var forceRules: Bool { arguments.contains("-forceRules") }

    /// `MISE_STUB_PAGES`: JSON object mapping URL strings to HTML, served by `StubRecipeFetcher`.
    static var stubPages: [String: String]? {
        guard let json = environment["MISE_STUB_PAGES"], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// `-enqueueImport <url>`: append a URL to the share queue at launch, as the extension would.
    static var enqueueImport: URL? {
        guard let i = arguments.firstIndex(of: "-enqueueImport"), i + 1 < arguments.count else { return nil }
        return URL(string: arguments[i + 1])
    }

    /// `-enqueueTextBase64 <base64 UTF-8>`: append shared text to the queue at launch, as the
    /// extension would. Base64 because multi-line launch arguments don't survive intact.
    static var enqueueText: String? {
        guard let i = arguments.firstIndex(of: "-enqueueTextBase64"), i + 1 < arguments.count,
              let data = Data(base64Encoded: arguments[i + 1]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum Persistence {
    static func storeURL() -> URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: LaunchOptions.isUITesting ? "MiseUITest.store" : "Mise.store")
    }

    @MainActor
    static func makeContainer() -> ModelContainer {
        let url = storeURL()
        if LaunchOptions.resetData {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix))
            }
        }
        do {
            return try MiseStore.container(url: url)
        } catch {
            fatalError("Could not open the recipe store: \(error)")
        }
    }

    /// In-memory container for previews.
    @MainActor
    static func inMemory() -> ModelContainer {
        try! MiseStore.inMemory()
    }
}

extension CookPhotoStore {
    /// Cooking photos live in Application Support/Photos (backed up with the app's data; UI tests
    /// use their own folder, like their own store).
    static let shared = CookPhotoStore(directory: URL.applicationSupportDirectory
        .appending(path: LaunchOptions.isUITesting ? "Photos-UITest" : "Photos", directoryHint: .isDirectory))
}

extension EnvironmentValues {
    @Entry var recipeFetcher: any RecipeFetching = RecipeFetcher()
}
