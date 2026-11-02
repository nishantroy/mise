import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Size limits for cooking photos. A 12 MP iPhone photo (4032×3024, ~2–4 MB HEIC) becomes a
/// 1600×1200 HEIC of ~150–300 KB plus a 400×300 thumbnail of ~10–25 KB.
enum CookPhotoSizing {
    static let maxLongEdge = 1600
    static let thumbnailLongEdge = 400
    /// Tried in order until the photo fits `targetBytes` (the last one is kept regardless).
    static let qualities: [Double] = [0.7, 0.55, 0.4]
    static let thumbnailQuality = 0.6
    static let targetBytes = 300_000

    /// The size that fits within `maxLongEdge` on the long side, keeping the aspect ratio.
    /// Never upscales; each side is at least 1 px.
    static func fitting(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge else { return (width, height) }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let w = width >= height ? maxLongEdge : max(1, Int((Double(width) * scale).rounded()))
        let h = height > width ? maxLongEdge : max(1, Int((Double(height) * scale).rounded()))
        return (w, h)
    }
}

/// File names in the photo folder: "<uuid>.heic" and its thumbnail "<uuid>-thumb.heic"
/// (".jpg" when HEIC encoding isn't available).
enum CookPhotoNaming {
    static let thumbnailSuffix = "-thumb"

    static func photoName(id: UUID, fileExtension: String) -> String {
        "\(id.uuidString).\(fileExtension)"
    }

    static func thumbnailName(for photo: String) -> String {
        let url = URL(filePath: photo)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? stem + thumbnailSuffix : "\(stem)\(thumbnailSuffix).\(ext)"
    }

    static func isThumbnail(_ name: String) -> Bool {
        URL(filePath: name).deletingPathExtension().lastPathComponent.hasSuffix(thumbnailSuffix)
    }

    /// Files in the folder that no log entry refers to (photos and their thumbnails).
    static func orphans(in fileNames: [String], referenced: Set<String>) -> [String] {
        let keep = referenced.union(referenced.map(thumbnailName(for:)))
        return fileNames.filter { !keep.contains($0) && !$0.hasPrefix(".") }.sorted()
    }

    /// For "Keep only the latest photo per recipe": every photo but the newest, oldest first.
    static func olderPhotos(_ log: [CookLogEntry]) -> [CookLogEntry] {
        let withPhotos = log.filter { $0.photo != nil }.sorted { $0.date < $1.date }
        return Array(withPhotos.dropLast())
    }
}

/// A photo downscaled and re-encoded in memory, before it's written (on save).
struct ProcessedCookPhoto: Sendable, Equatable {
    var photo: Data
    var thumbnail: Data
    var fileExtension: String
    var pixelWidth: Int
    var pixelHeight: Int
}

enum CookPhotoProcessor {
    /// Downscales to `CookPhotoSizing.maxLongEdge` (orientation applied), encodes HEIC (JPEG if
    /// HEIC isn't available) at decreasing quality until it fits the byte target, and makes the
    /// thumbnail. Only pixels are written: EXIF, GPS and other metadata are dropped.
    static func process(_ data: Data, preferHEIC: Bool = true) -> ProcessedCookPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = downscaled(source, maxLongEdge: CookPhotoSizing.maxLongEdge) else { return nil }
        let heic = UTType.heic.identifier as CFString
        let type = preferHEIC && canEncode(heic) ? heic : UTType.jpeg.identifier as CFString
        let ext = type == heic ? "heic" : "jpg"

        var photo: Data?
        for quality in CookPhotoSizing.qualities {
            photo = encode(image, type: type, quality: quality)
            if let photo, photo.count <= CookPhotoSizing.targetBytes { break }
        }
        let thumbSize = CookPhotoSizing.fitting(width: image.width, height: image.height,
                                                maxLongEdge: CookPhotoSizing.thumbnailLongEdge)
        guard let photo, let small = resized(image, width: thumbSize.width, height: thumbSize.height),
              let thumbnail = encode(small, type: type, quality: CookPhotoSizing.thumbnailQuality) else { return nil }
        return ProcessedCookPhoto(photo: photo, thumbnail: thumbnail, fileExtension: ext,
                                  pixelWidth: image.width, pixelHeight: image.height)
    }

    /// Decodes at most `maxLongEdge` on the long side (ImageIO subsamples, so a 12 MP original is
    /// never fully decoded) and applies the EXIF orientation.
    static func downscaled(_ source: CGImageSource, maxLongEdge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func canEncode(_ type: CFString) -> Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(type as String)
    }

    static func encode(_ image: CGImage, type: CFString, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        // No source properties are copied, so nothing but the pixels (and colour profile) is kept.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Cooking photos as files in one folder. They're the owner's memories, so they're left in
/// backups; sizes are kept small instead.
struct CookPhotoStore: Sendable {
    let directory: URL

    func url(for name: String) -> URL { directory.appending(path: name, directoryHint: .notDirectory) }
    func thumbnailURL(for name: String) -> URL { url(for: CookPhotoNaming.thumbnailName(for: name)) }

    /// Writes the photo and its thumbnail; returns the photo's file name.
    func write(_ processed: ProcessedCookPhoto, id: UUID = UUID()) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = CookPhotoNaming.photoName(id: id, fileExtension: processed.fileExtension)
        try processed.photo.write(to: url(for: name), options: .atomic)
        try processed.thumbnail.write(to: thumbnailURL(for: name), options: .atomic)
        return name
    }

    /// Deletes a photo and its thumbnail (missing files are fine).
    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
        try? FileManager.default.removeItem(at: thumbnailURL(for: name))
    }

    func delete(_ names: some Sequence<String>) {
        for name in names { delete(name) }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func fileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    /// Photos (not counting thumbnails) and the bytes of every file in the folder.
    func usage() -> (photos: Int, bytes: Int64) {
        var photos = 0
        var bytes: Int64 = 0
        for name in fileNames() where !name.hasPrefix(".") {
            if !CookPhotoNaming.isThumbnail(name) { photos += 1 }
            let size = (try? url(for: name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += Int64(size)
        }
        return (photos, bytes)
    }

    /// Deletes files no log entry refers to (left by a crash between writing and saving).
    @discardableResult
    func removeOrphans(referenced: Set<String>) -> Int {
        let orphans = CookPhotoNaming.orphans(in: fileNames(), referenced: referenced)
        for name in orphans { try? FileManager.default.removeItem(at: url(for: name)) }
        return orphans.count
    }
}
