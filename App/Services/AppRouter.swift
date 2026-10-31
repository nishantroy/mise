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
    /// The shared URL whose sheet is showing; removed from the App Group queue when it closes.
    private(set) var presentedSharedURL: URL?
    /// Called with a shared URL once its sheet has closed (saved or cancelled).
    var onSharedImportFinished: (URL) -> Void = { _ in }

    func startImport(url: URL? = nil) {
        activeImport = ImportRequest(url: url)
    }

    /// Queue URLs from the share extension (ignoring ones already queued or showing);
    /// shows the first straight away.
    func enqueue(_ urls: [URL]) {
        for url in urls where url != presentedSharedURL && !queuedImports.contains(url) {
            queuedImports.append(url)
        }
        showNextQueuedImportIfIdle()
    }

    /// Called when the import sheet closes.
    func importSheetDismissed() {
        if let url = presentedSharedURL {
            presentedSharedURL = nil
            onSharedImportFinished(url)
        }
        showNextQueuedImportIfIdle()
    }

    private func showNextQueuedImportIfIdle() {
        guard activeImport == nil, !queuedImports.isEmpty else { return }
        tab = .recipes
        let url = queuedImports.removeFirst()
        presentedSharedURL = url
        activeImport = ImportRequest(url: url)
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
