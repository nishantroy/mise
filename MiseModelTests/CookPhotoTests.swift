import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Cooking photos")
struct CookPhotoTests {
    // MARK: Sizing

    @Test(arguments: [
        (4032, 3024, 1600, 1600, 1200),   // 12 MP landscape
        (3024, 4032, 1600, 1200, 1600),   // 12 MP portrait
        (8064, 6048, 1600, 1600, 1200),   // 48 MP
        (1000, 800, 1600, 1000, 800),     // smaller: never upscaled
        (1600, 1600, 1600, 1600, 1600),   // exactly the limit
        (5000, 5000, 400, 400, 400),      // square thumbnail
        (20000, 10, 1600, 1600, 1),       // panorama: at least 1 px
        (1600, 1200, 400, 400, 300),      // thumbnail of a downscaled photo
    ])
    func fitting(width: Int, height: Int, limit: Int, expectedWidth: Int, expectedHeight: Int) {
        let size = CookPhotoSizing.fitting(width: width, height: height, maxLongEdge: limit)
        #expect(size.width == expectedWidth)
        #expect(size.height == expectedHeight)
    }

    @Test func fittingAnEmptySize() {
        #expect(CookPhotoSizing.fitting(width: 0, height: 100, maxLongEdge: 1600) == (0, 0))
    }

    // MARK: Naming

    @Test func names() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let name = CookPhotoNaming.photoName(id: id, fileExtension: "heic")
        #expect(name == "6F9619FF-8B86-D011-B42D-00C04FC964FF.heic")
        #expect(CookPhotoNaming.thumbnailName(for: name) == "6F9619FF-8B86-D011-B42D-00C04FC964FF-thumb.heic")
        #expect(CookPhotoNaming.thumbnailName(for: "A.jpg") == "A-thumb.jpg")
        #expect(CookPhotoNaming.isThumbnail("A-thumb.heic"))
        #expect(!CookPhotoNaming.isThumbnail("A.heic"))
    }

    @Test func orphansAreUnreferencedPhotosAndThumbnails() {
        let files = ["A.heic", "A-thumb.heic", "B.heic", "B-thumb.heic", "C-thumb.jpg", ".DS_Store"]
        #expect(CookPhotoNaming.orphans(in: files, referenced: ["A.heic"]) == ["B-thumb.heic", "B.heic", "C-thumb.jpg"])
        #expect(CookPhotoNaming.orphans(in: files, referenced: ["A.heic", "B.heic", "C.jpg"]).isEmpty)
    }

    // MARK: Store

    @Test func storeWritesCountsAndCleansUp() throws {
        let store = CookPhotoStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "MisePhotos-\(UUID().uuidString)", directoryHint: .isDirectory))
        defer { store.deleteAll() }
        #expect(store.usage().photos == 0)
        let processed = ProcessedCookPhoto(photo: Data(count: 1000), thumbnail: Data(count: 100),
                                           fileExtension: "heic", pixelWidth: 1, pixelHeight: 1)
        let a = try store.write(processed)
        let b = try store.write(processed)
        #expect(Set(store.fileNames()) == [a, b, CookPhotoNaming.thumbnailName(for: a), CookPhotoNaming.thumbnailName(for: b)])
        #expect(store.usage().photos == 2)
        #expect(store.usage().bytes == 2200)

        #expect(store.removeOrphans(referenced: [a]) == 2)
        #expect(store.usage().photos == 1)
        store.delete(a)
        #expect(store.fileNames().isEmpty)
        store.delete("missing.heic")   // fine

        _ = try store.write(processed)
        store.deleteAll()
        #expect(store.usage().photos == 0)
    }

    // MARK: Processing a 12 MP photo

    /// A stand-in for a 12 MP iPhone photo: a lit plate of food (gradients, overlapping shapes)
    /// with sensor grain, written as HEIC at camera quality with GPS and EXIF orientation.
    static func cameraPhoto(orientation: Int = 1, grain: Int = 6) throws -> Data {
        let width = 4032, height = 3024
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.55, green: 0.42, blue: 0.3, alpha: 1),
                                                               CGColor(red: 0.2, green: 0.15, blue: 0.12, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1))
        context.fillEllipse(in: CGRect(x: 700, y: 300, width: 2600, height: 2400))
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        for _ in 0..<400 {   // noodles, greens, sauce
            context.setFillColor(CGColor(red: 0.5 + next() * 0.5, green: 0.2 + next() * 0.6, blue: next() * 0.4, alpha: 0.85))
            let x = 1000 + next() * 2000, y = 600 + next() * 1800
            context.fillEllipse(in: CGRect(x: x, y: y, width: 40 + next() * 260, height: 20 + next() * 120))
        }
        if grain > 0, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            for i in 0..<(width * height) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int(seed >> 59) % (2 * grain + 1) - grain
                for c in 0..<3 {
                    let p = i * 4 + c
                    pixels[p] = UInt8(clamping: Int(pixels[p]) + noise)
                }
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "iPhone 15 Pro back camera"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func twelveMegapixelPhotoIsDownscaledSmallAndStripped() throws {
        let input = try Self.cameraPhoto()
        #expect(try properties(input)[kCGImagePropertyGPSDictionary] != nil)

        let processed = try #require(CookPhotoProcessor.process(input))
        print("12 MP stand-in: input \(input.count) B → photo \(processed.photo.count) B (\(processed.pixelWidth)×\(processed.pixelHeight) \(processed.fileExtension)), thumbnail \(processed.thumbnail.count) B")
        #expect(processed.fileExtension == "heic")
        #expect(processed.pixelWidth == 1600 && processed.pixelHeight == 1200)
        #expect(processed.photo.count <= CookPhotoSizing.targetBytes)
        #expect(processed.thumbnail.count < 40_000)

        for data in [processed.photo, processed.thumbnail] {
            let props = try properties(data)
            #expect(props[kCGImagePropertyGPSDictionary] == nil)
            #expect((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] == nil)
            #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        }
        let thumb = try properties(processed.thumbnail)
        #expect(thumb[kCGImagePropertyPixelWidth] as? Int == 400)
        #expect(thumb[kCGImagePropertyPixelHeight] as? Int == 300)
    }

    @Test func portraitOrientationIsAppliedToThePixels() throws {
        let processed = try #require(CookPhotoProcessor.process(try Self.cameraPhoto(orientation: 6, grain: 0)))
        #expect(processed.pixelWidth == 1200 && processed.pixelHeight == 1600)
        print("12 MP stand-in, no grain: photo \(processed.photo.count) B, thumbnail \(processed.thumbnail.count) B")
    }

    @Test func jpegFallback() throws {
        let processed = try #require(CookPhotoProcessor.process(try Self.cameraPhoto(), preferHEIC: false))
        #expect(processed.fileExtension == "jpg")
        #expect(processed.pixelWidth == 1600)
        print("12 MP stand-in as JPEG: photo \(processed.photo.count) B, thumbnail \(processed.thumbnail.count) B")
    }

    @Test func notAnImage() {
        #expect(CookPhotoProcessor.process(Data("hello".utf8)) == nil)
    }
}
