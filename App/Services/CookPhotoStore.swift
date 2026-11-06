import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import SwiftData

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

    /// "X-thumb.heic" → "X.heic".
    static func photoName(forThumbnail thumbnail: String) -> String {
        let url = URL(filePath: thumbnail)
        let stem = String(url.deletingPathExtension().lastPathComponent.dropLast(thumbnailSuffix.count))
        let ext = url.pathExtension
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// A photo that came with a shared recipe (`.mise` file): "shared-<recipe uuid>.heic". Not a
    /// cooking-log entry (the receiver didn't cook it); found by the recipe's ID, so the recipe
    /// needs no property for it. Shown until the receiver logs a photo of their own.
    static let sharedPrefix = "shared-"

    /// The recipe ID in a shared photo's name.
    static func sharedRecipeID(_ name: String) -> UUID? {
        guard name.hasPrefix(sharedPrefix) else { return nil }
        let stem = URL(filePath: name).deletingPathExtension().lastPathComponent
        return UUID(uuidString: String(stem.dropFirst(sharedPrefix.count)))
    }

    static func sharedPhotoName(recipeID: UUID, fileExtension: String) -> String {
        "\(sharedPrefix)\(recipeID.uuidString).\(fileExtension)"
    }

    /// Every name a recipe's shared photo can have (HEIC, or JPEG where HEIC can't be encoded).
    static func sharedPhotoCandidates(recipeID: UUID) -> [String] {
        ["heic", "jpg"].map { sharedPhotoName(recipeID: recipeID, fileExtension: $0) }
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

    /// A thumbnail derived from a stored photo (thumbnails aren't synced; each device makes its
    /// own). Same type as the photo when it can be encoded, else JPEG.
    static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = downscaled(source, maxLongEdge: CookPhotoSizing.thumbnailLongEdge) else { return nil }
        let sourceType = CGImageSourceGetType(source) ?? (UTType.jpeg.identifier as CFString)
        let type = canEncode(sourceType) ? sourceType : UTType.jpeg.identifier as CFString
        return encode(image, type: type, quality: CookPhotoSizing.thumbnailQuality)
    }
}

/// Cooking photos (and photos that came with shared recipes). Since V3 the photo itself lives in
/// the store as a `CookPhoto` (so it syncs with iCloud); `directory` is a local cache of files,
/// the photo plus a derived thumbnail, filled on demand for display and sharing. The cache is
/// regenerable (Library/Caches), so the system may clear it.
///
/// Each call uses its own `ModelContext` and saves straight away, like the files it replaced:
/// a photo is stored before the log entry that names it is saved.
struct CookPhotoStore: Sendable {
    let container: ModelContainer
    /// The file cache.
    let directory: URL

    /// Posted when photos may have appeared (legacy files imported, a sync arrived), so
    /// `LocalPhoto` retries a photo it couldn't load.
    static let photosChanged = Notification.Name("CookPhotoStore.photosChanged")

    /// Where the cached file for `name` goes. It may not exist yet: `ensureCached` fills it.
    func url(for name: String) -> URL { directory.appending(path: name, directoryHint: .notDirectory) }
    func thumbnailURL(for name: String) -> URL { url(for: CookPhotoNaming.thumbnailName(for: name)) }

    // MARK: Writing

    /// Stores a cooking photo; returns its name for the log entry. The cache gets both files.
    func write(_ processed: ProcessedCookPhoto, id: UUID = UUID(), recipeID: UUID? = nil) throws -> String {
        let name = CookPhotoNaming.photoName(id: id, fileExtension: processed.fileExtension)
        try store(processed, name: name, recipeID: recipeID, replacing: [])
        return name
    }

    /// Stores the photo that came with a shared recipe (see `CookPhotoNaming.sharedPrefix`),
    /// replacing an earlier one.
    @discardableResult
    func writeShared(_ processed: ProcessedCookPhoto, recipeID: UUID) throws -> String {
        let name = CookPhotoNaming.sharedPhotoName(recipeID: recipeID, fileExtension: processed.fileExtension)
        try store(processed, name: name, recipeID: recipeID,
                  replacing: CookPhotoNaming.sharedPhotoCandidates(recipeID: recipeID))
        return name
    }

    private func store(_ processed: ProcessedCookPhoto, name: String, recipeID: UUID?, replacing: [String]) throws {
        let context = ModelContext(container)
        for old in rows(named: replacing, in: context) { context.delete(old) }
        context.insert(CookPhoto(name: name, recipeID: recipeID, data: processed.photo))
        try context.save()
        for old in replacing { removeCached(old) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? processed.photo.write(to: url(for: name), options: .atomic)
        try? processed.thumbnail.write(to: thumbnailURL(for: name), options: .atomic)
    }

    // MARK: Reading

    /// The shared photo's name, if this recipe has one (cached, or in the store).
    func sharedPhoto(recipeID: UUID) -> String? {
        let candidates = CookPhotoNaming.sharedPhotoCandidates(recipeID: recipeID)
        if let cached = candidates.first(where: { fileExists(url(for: $0)) }) { return cached }
        return rows(named: candidates, in: ModelContext(container)).first?.name
    }

    /// The photo's bytes, from the store.
    func data(for name: String) -> Data? {
        rows(named: [name], in: ModelContext(container)).first { $0.data != nil }?.data
    }

    /// Makes sure the cached file at `fileURL` (a photo or its thumbnail, from `url(for:)` or
    /// `thumbnailURL(for:)`) exists, writing it from the store. False when the photo isn't
    /// stored (deleted, or not synced to this device yet).
    @discardableResult
    func ensureCached(_ fileURL: URL) -> Bool {
        if fileExists(fileURL) { return true }
        let fileName = fileURL.lastPathComponent
        let isThumbnail = CookPhotoNaming.isThumbnail(fileName)
        let name = isThumbnail ? CookPhotoNaming.photoName(forThumbnail: fileName) : fileName
        let photoURL = url(for: name)
        let photo: Data
        if let cached = try? Data(contentsOf: photoURL) {
            photo = cached
        } else {
            guard let stored = data(for: name) else { return false }
            photo = stored
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard (try? stored.write(to: photoURL, options: .atomic)) != nil else { return false }
        }
        guard isThumbnail else { return true }
        guard let thumbnail = CookPhotoProcessor.thumbnail(from: photo) else { return false }
        return (try? thumbnail.write(to: fileURL, options: .atomic)) != nil
    }

    /// Names of every stored photo.
    func photoNames() -> [String] {
        let all = (try? ModelContext(container).fetch(FetchDescriptor<CookPhoto>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return all.map(\.name)
    }

    /// Stored photos and their bytes (thumbnails aren't stored).
    func usage() -> (photos: Int, bytes: Int64) {
        let all = (try? ModelContext(container).fetch(FetchDescriptor<CookPhoto>())) ?? []
        return (Set(all.map(\.name)).count, all.reduce(0) { $0 + Int64($1.byteCount) })
    }

    // MARK: Deleting

    /// Deletes a photo (and its cached files). Missing photos are fine.
    func delete(_ name: String) { delete([name]) }

    func delete(_ names: some Sequence<String>) {
        let names = Array(names)
        guard !names.isEmpty else { return }
        let context = ModelContext(container)
        for row in rows(named: names, in: context) { context.delete(row) }
        try? context.save()
        for name in names { removeCached(name) }
    }

    /// Every photo and the cache.
    func deleteAll() {
        let context = ModelContext(container)
        for row in (try? context.fetch(FetchDescriptor<CookPhoto>())) ?? [] { context.delete(row) }
        try? context.save()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Deletes photos nothing refers to. Only those older than `minimumAge`: with iCloud a photo
    /// can arrive before the recipe change that refers to it. Cached files of photos that are
    /// gone go too. Returns the number of photos deleted.
    @discardableResult
    func removeOrphans(referenced: Set<String>, minimumAge: TimeInterval = 3600, now: Date = Date()) -> Int {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<CookPhoto>())) ?? []
        let cutoff = now.addingTimeInterval(-minimumAge)
        let orphans = all.filter { !referenced.contains($0.name) && $0.createdAt <= cutoff }
        let kept = Set(all.map(\.name)).subtracting(orphans.map(\.name))
        for row in orphans { context.delete(row) }
        if !orphans.isEmpty { try? context.save() }
        for file in CookPhotoNaming.orphans(in: cachedFileNames(), referenced: kept) {
            try? FileManager.default.removeItem(at: url(for: file))
        }
        return orphans.count
    }

    // MARK: Files from before V3

    /// Moves photos from the pre-V3 folder (Application Support/Photos) into the store.
    /// Idempotent: a photo already stored isn't stored twice. Files are kept until the save that
    /// stores them succeeds, then moved into the cache (so they show straight away); the folder
    /// goes once empty. Unreadable files stay where they are. Saves in batches to bound memory.
    /// Returns the number of photos stored.
    @discardableResult
    func importLegacyFiles(from legacy: URL, batchSize: Int = 20) throws -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: legacy.path(percentEncoded: false)) else { return 0 }
        let photos = files.filter { !$0.hasPrefix(".") && !CookPhotoNaming.isThumbnail($0) }.sorted()

        var owners: [String: UUID] = [:]
        for recipe in (try? ModelContext(container).fetch(FetchDescriptor<SavedRecipe>())) ?? [] {
            for name in recipe.photoNames { owners[name] = recipe.id }
        }
        var stored = Set(photoNames())

        var imported = 0
        var start = 0
        while start < photos.count {
            let batch = photos[start..<min(start + batchSize, photos.count)]
            start += batchSize
            let context = ModelContext(container)
            var done: [String] = []
            for name in batch {
                if stored.contains(name) {
                    done.append(name)
                    continue
                }
                let fileURL = legacy.appending(path: name, directoryHint: .notDirectory)
                guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { continue }
                let created = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let recipeID = owners[name] ?? CookPhotoNaming.sharedRecipeID(name)
                context.insert(CookPhoto(name: name, recipeID: recipeID, data: data, createdAt: created))
                done.append(name)
                imported += 1
            }
            try context.save()
            stored.formUnion(done)
            // Stored: the files become the cache.
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in done {
                for file in [name, CookPhotoNaming.thumbnailName(for: name)] {
                    let from = legacy.appending(path: file, directoryHint: .notDirectory)
                    guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
                    let to = url(for: file)
                    try? fm.removeItem(at: to)
                    if (try? fm.moveItem(at: from, to: to)) == nil { try? fm.removeItem(at: from) }
                }
            }
        }
        // Thumbnails whose photo is gone, then the folder once nothing else is left.
        let left = ((try? fm.contentsOfDirectory(atPath: legacy.path(percentEncoded: false))) ?? [])
        for file in left where CookPhotoNaming.isThumbnail(file)
            && !left.contains(CookPhotoNaming.photoName(forThumbnail: file)) {
            try? fm.removeItem(at: legacy.appending(path: file, directoryHint: .notDirectory))
        }
        let remaining = ((try? fm.contentsOfDirectory(atPath: legacy.path(percentEncoded: false))) ?? [])
            .filter { !$0.hasPrefix(".") }
        if remaining.isEmpty { try? fm.removeItem(at: legacy) }
        return imported
    }

    // MARK: Helpers

    private func rows(named names: [String], in context: ModelContext) -> [CookPhoto] {
        guard !names.isEmpty else { return [] }
        let descriptor = FetchDescriptor<CookPhoto>(predicate: #Predicate { names.contains($0.name) })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func removeCached(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
        try? FileManager.default.removeItem(at: thumbnailURL(for: name))
    }

    func cachedFileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

