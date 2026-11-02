import SwiftUI
import UIKit
import ImageIO

/// A cooking photo from disk, decoded off the main thread at no more than `maxPixelSize` on the
/// long side (cards and the header use the 1600 px photo; strips use the 400 px thumbnail).
struct LocalPhoto<Placeholder: View>: View {
    let url: URL
    var maxPixelSize: Int = 1200
    @ViewBuilder var placeholder: Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) { image = await LocalPhotoCache.shared.image(at: url, maxPixelSize: maxPixelSize) }
    }
}

/// Decoded photos by path and size. `NSCache` is thread-safe and drops entries under memory pressure.
final class LocalPhotoCache: @unchecked Sendable {
    static let shared = LocalPhotoCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 60 }

    func image(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = "\(url.path(percentEncoded: false))@\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CookPhotoProcessor.downscaled(source, maxLongEdge: maxPixelSize) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
