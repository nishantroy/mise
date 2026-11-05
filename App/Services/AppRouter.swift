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
        while activeImport == nil, !queuedImports.isEmpty {
            let item = queuedImports.removeFirst()
            let request: ImportRequest
            switch item {
            case .url(let url): request = ImportRequest(url: url)
            case .text(_, let text): request = ImportRequest(sharedText: text)
            case .recipeFile(let id):
                // Its file is gone (e.g. cleared): drop the entry and move on.
                guard let data = PendingImports.recipeFileData(id: id) else {
                    onSharedImportFinished(item)
                    continue
                }
                request = ImportRequest(sharedRecipeData: data)
            }
            tab = .recipes
            presentedShared = item
            activeImport = request
        }
    }

    /// A `.mise` file opened in Mise (Messages, Mail, Files, AirDrop), cold launch or not. It
    /// goes through the App Group queue like the share extension's items, so it survives the
    /// app being killed mid-sheet; without an App Group it's shown straight away.
    func receiveRecipeFile(_ data: Data, showNow: Bool) {
        if PendingImports.appendRecipeFile(data) {
            if showNow { enqueue(PendingImports.pending()) }
        } else if activeImport == nil {
            tab = .recipes
            activeImport = ImportRequest(sharedRecipeData: data)
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
    /// A `.mise` file's bytes: the sheet previews the friend's recipe.
    var sharedRecipeData: Data?
}
