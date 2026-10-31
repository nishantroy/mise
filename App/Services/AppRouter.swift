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
    /// Shared items waiting for their turn in the import sheet.
    private(set) var queuedImports: [PendingItem] = []
    /// The shared item whose sheet is showing; removed from the App Group queue when it closes.
    private(set) var presentedShared: PendingItem?
    /// Called with a shared item once its sheet has closed (saved or cancelled).
    var onSharedImportFinished: (PendingItem) -> Void = { _ in }

    func startImport(url: URL? = nil) {
        activeImport = ImportRequest(url: url)
    }

    /// Queue items from the share extension (ignoring ones already queued or showing);
    /// shows the first straight away.
    func enqueue(_ items: [PendingItem]) {
        for item in items where item != presentedShared && !queuedImports.contains(item) {
            queuedImports.append(item)
        }
        showNextQueuedImportIfIdle()
    }

    /// Called when the import sheet closes.
    func importSheetDismissed() {
        if let item = presentedShared {
            presentedShared = nil
            onSharedImportFinished(item)
        }
        showNextQueuedImportIfIdle()
    }

    private func showNextQueuedImportIfIdle() {
        guard activeImport == nil, !queuedImports.isEmpty else { return }
        tab = .recipes
        let item = queuedImports.removeFirst()
        presentedShared = item
        switch item {
        case .url(let url): activeImport = ImportRequest(url: url)
        case .text(_, let text): activeImport = ImportRequest(sharedText: text)
        }
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
    /// Text shared from another app: the sheet asks whether it's a new recipe or "my version".
    var sharedText: String?
}
