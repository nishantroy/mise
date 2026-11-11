import Foundation
import ImageIO
import LinkPresentation
import UIKit
import UniformTypeIdentifiers
import RecipeKit

/// Sending a recipe to a friend: a `.mise` file, or the recipe as plain text through Copy.
///
/// UIActivityViewController with two items rather than `ShareLink` + one `Transferable`, so each
/// destination gets what suits it: Copy gets only the recipe text; Messages, Mail and the like get
/// the file plus one line with a link to get Mise; AirDrop and Save to Files get only the file.
@MainActor
enum RecipeSharing {
    /// The photo is re-encoded until it fits this (the format accepts up to
    /// `SharedRecipeFile.maxPhotoBytes`).
    nonisolated static let photoTargetBytes = 300_000
    nonisolated static let photoLongEdge = 1200

    /// Where a friend without Mise goes to get it: the public TestFlight invite for now, the App
    /// Store page once Mise is published. While nil, Messages and Mail get the file alone.
    // TODO: set to the public TestFlight link (App Store Connect → TestFlight → external group).
    nonisolated static let getMiseURL: URL? = nil

    /// The line sent with the file to Messages, Mail and the like; nil without a link.
    nonisolated static func inviteLine(title: String) -> String? {
        guard let url = getMiseURL else { return nil }
        return "Open “\(title)” in Mise. Don't have it? Get Mise: \(url.absoluteString)"
    }

    /// The photo that would be shared: the latest cooking photo, else one a friend shared.
    /// The cached file, written from the store if needed; nil if the photo isn't on this device.
    static func photoURL(for saved: SavedRecipe, store: CookPhotoStore = .shared) -> URL? {
        guard let url = saved.displayPhotoURL(in: store), store.ensureCached(url) else { return nil }
        return url
    }

    /// Writes "<Title>.mise" into a fresh temporary folder and returns its URL.
    static func makeFile(for saved: SavedRecipe, includePhoto: Bool, store: CookPhotoStore = .shared) throws -> URL {
        let photo = includePhoto ? photoURL(for: saved, store: store).flatMap(sharePhoto(at:)) : nil
        let file = SharedRecipeFile(recipe: saved.recipe, original: saved.original, photo: photo)
        let data = try file.fileData()
        let root = FileManager.default.temporaryDirectory.appending(path: "SharedRecipes", directoryHint: .isDirectory)
        // Files from earlier shares have been handed over by now.
        try? FileManager.default.removeItem(at: root)
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: SharedRecipeFile.fileName(for: saved.title), directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The stored photo as is when it's small enough (they're ≤ 300 KB HEIC already, usually),
    /// otherwise downscaled to 1200 px and re-encoded. Nil if it can't be read.
    nonisolated static func sharePhoto(at url: URL) -> SharedRecipeFile.Photo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .heic
        if data.count <= photoTargetBytes, [UTType.heic, .jpeg].contains(type) {
            return SharedRecipeFile.Photo(data: data, type: type.identifier)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CookPhotoProcessor.downscaled(source, maxLongEdge: photoLongEdge) else { return nil }
        let heic = CookPhotoProcessor.canEncode(UTType.heic.identifier as CFString)
        let encodeType = (heic ? UTType.heic : .jpeg)
        for quality in [0.6, 0.45, 0.3] {
            if let encoded = CookPhotoProcessor.encode(image, type: encodeType.identifier as CFString, quality: quality),
               encoded.count <= photoTargetBytes {
                return SharedRecipeFile.Photo(data: encoded, type: encodeType.identifier)
            }
        }
        return nil
    }

    /// Presents the share sheet over whatever is on screen.
    static func present(file: URL, recipe: Recipe, photoURL: URL?) {
        let image = photoURL.flatMap { url -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CookPhotoProcessor.downscaled(source, maxLongEdge: 300) else { return nil }
            return UIImage(cgImage: cg)
        }
        let items: [Any] = [
            RecipeFileItem(url: file, title: recipe.title, image: image),
            RecipeTextItem(recipeText: SharedRecipeFile.plainText(for: recipe),
                           inviteLine: inviteLine(title: recipe.title)),
        ]
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.excludedActivityTypes = [.assignToContact, .addToReadingList, .openInIBooks, .postToFacebook,
                                            .postToTwitter, .postToWeibo, .postToVimeo, .postToFlickr, .postToTencentWeibo]
        // The file isn't deleted on completion (an AirDrop may still be reading it); the next
        // share clears the folder, and the system clears tmp.
        guard let presenter = topViewController() else { return }
        controller.popoverPresentationController?.sourceView = presenter.view
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// The `.mise` file. Not for Copy (that gets the text).
final class RecipeFileItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let image: UIImage?

    init(url: URL, title: String, image: UIImage?) {
        self.url = url
        self.title = title
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        activityType == .copyToPasteboard ? nil : url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        SharedRecipeFile.typeIdentifier
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    /// The share sheet's header: the recipe's title and photo.
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let image { metadata.imageProvider = NSItemProvider(object: image) }
        return metadata
    }
}

/// The text beside the file. Copy gets the whole recipe as text (the file isn't copied); Messages,
/// Mail and the like get one line with a link to get Mise, not the whole recipe; AirDrop and
/// Save to Files get nothing (the receiver would get a stray text file or note).
final class RecipeTextItem: NSObject, UIActivityItemSource {
    let recipeText: String
    let inviteLine: String?
    static let fileOnly: Set<String> = [
        UIActivity.ActivityType.airDrop.rawValue,
        "com.apple.DocumentManagerUICore.SaveToFiles",
        "com.apple.CloudDocsUI.AddToiCloudDrive",
    ]

    init(recipeText: String, inviteLine: String?) {
        self.recipeText = recipeText
        self.inviteLine = inviteLine
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { "" }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        guard let activityType else { return inviteLine }
        if activityType == .copyToPasteboard { return recipeText }
        return Self.fileOnly.contains(activityType.rawValue) ? nil : inviteLine
    }
}
