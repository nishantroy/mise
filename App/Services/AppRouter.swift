import Foundation
import Observation

/// App-wide navigation state: the Recipes stack and pending import requests.
@MainActor
@Observable
final class AppRouter {
    /// Recipes tab navigation path (saved recipe IDs).
    var recipePath: [UUID] = []
    /// Selected tab.
    var tab: AppTab = .recipes
    /// The import sheet currently shown, if any.
    var activeImport: ImportRequest?
    /// Shared URLs waiting for their turn in the import sheet.
    private(set) var queuedImports: [URL] = []

    func startImport(url: URL? = nil) {
        activeImport = ImportRequest(url: url)
    }

    /// Queue URLs from the share extension; shows the first straight away.
    func enqueue(_ urls: [URL]) {
        queuedImports += urls
        showNextQueuedImportIfIdle()
    }

    /// Called when the import sheet closes.
    func importSheetDismissed() {
        showNextQueuedImportIfIdle()
    }

    private func showNextQueuedImportIfIdle() {
        guard activeImport == nil, !queuedImports.isEmpty else { return }
        tab = .recipes
        activeImport = ImportRequest(url: queuedImports.removeFirst())
    }

    func open(recipeID: UUID) {
        tab = .recipes
        recipePath = [recipeID]
    }
}

enum AppTab: Hashable {
    case recipes, pantry, settings
}

struct ImportRequest: Identifiable, Hashable {
    let id = UUID()
    var url: URL?
}
