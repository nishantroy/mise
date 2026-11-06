import Foundation
import SwiftData
import SwiftUI
import RecipeKit
import os

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
    /// How the store was opened.
    enum Mode: Sendable, Equatable {
        /// Syncing with the iCloud private database (while the device is signed in).
        case cloud
        /// Local only: UI tests, or the CloudKit store couldn't load (the reason, for Settings).
        case local(reason: String?)
    }

    static func storeURL() -> URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: LaunchOptions.isUITesting ? "MiseUITest.store" : "Mise.store")
    }

    /// The app's store, opened once (the app and `CookPhotoStore.shared` share it).
    static let opened: (container: ModelContainer, mode: Mode) = open()

    private static func open() -> (container: ModelContainer, mode: Mode) {
        let url = storeURL()
        if LaunchOptions.resetData {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix))
            }
        }
        // UI tests never sync (their data must not reach anyone's iCloud).
        if LaunchOptions.isUITesting {
            return (openLocal(url), .local(reason: nil))
        }
        // Signed out of iCloud, the CloudKit store still opens and works locally; it starts
        // syncing when the device signs in. It only fails to load for a broken setup (missing
        // entitlement, a schema CloudKit rejects): then the same file is opened without sync
        // rather than crashing.
        #if DEBUG
        CloudSync.initializeDevelopmentSchemaIfNeeded()
        #endif
        do {
            let container = try MiseStore.container(url: url, cloudKit: .private(MiseStore.cloudKitContainerID))
            return (container, .cloud)
        } catch {
            Logger(subsystem: "Mise", category: "Sync")
                .error("CloudKit store failed to load, opening locally: \(String(describing: error), privacy: .public)")
            return (openLocal(url), .local(reason: error.localizedDescription))
        }
    }

    private static func openLocal(_ url: URL) -> ModelContainer {
        do {
            return try MiseStore.container(url: url, cloudKit: .none)
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
    /// Photos are in the store; this is the local file cache (Library/Caches/Photos; UI tests use
    /// their own folder, like their own store).
    static let shared = CookPhotoStore(container: Persistence.opened.container,
                                       directory: URL.cachesDirectory.appending(path: cacheFolder, directoryHint: .isDirectory))

    private static var cacheFolder: String { LaunchOptions.isUITesting ? "Photos-UITest" : "Photos" }

    /// Where photos were files before V3 (Application Support/Photos), imported on launch.
    static var legacyDirectory: URL {
        URL.applicationSupportDirectory.appending(path: cacheFolder, directoryHint: .isDirectory)
    }
}

extension EnvironmentValues {
    @Entry var recipeFetcher: any RecipeFetching = RecipeFetcher()
}
