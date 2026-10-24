import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Shared by the Mac and iPhone apps: link thumbnails and note stills from `Paths.thumbs`.

#if os(macOS)
typealias ThumbPlatformImage = NSImage
#else
typealias ThumbPlatformImage = UIImage
#endif

/// A still from `Paths.thumbs`, read and scaled down off the main thread once, then kept in memory (`ThumbCache`).
/// A plain track shows while it loads; `missing` shows when there's no readable file. (Reading the file in `body`
/// decoded every thumbnail on the main thread on every render.)
struct ThumbImage<Missing: View>: View {
    var file: String
    /// The longest side to decode, in pixels: about twice (Mac) or three times (iPhone) the largest size it's
    /// drawn at.
    var maxPixel: Int
    @ViewBuilder var missing: () -> Missing
    @State private var loaded: ThumbPlatformImage?
    @State private var failed = false

    var body: some View {
        let image = loaded ?? ThumbCache.cached(file, maxPixel: maxPixel)
        ZStack {
            if let image {
                Rectangle().fill(Ink.track)
                    .overlay { Self.picture(image).resizable().aspectRatio(contentMode: .fill) }
                    .clipped()
            } else if failed {
                missing()
            } else {
                Rectangle().fill(Ink.track)
            }
        }
        .task(id: file) {
            guard ThumbCache.cached(file, maxPixel: maxPixel) == nil else { return }
            if let img = await ThumbCache.load(file, maxPixel: maxPixel) { loaded = img; failed = false } else { failed = true }
        }
    }

    private static func picture(_ image: ThumbPlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

/// Decoded stills by file and size, downsampled with ImageIO on a background task (`CGImage`, so the Mac and the
/// iPhone share it). Missing files aren't remembered, so a still that arrives later (iCloud) shows the next time
/// its view appears.
@MainActor
enum ThumbCache {
    private static let images: NSCache<NSString, ThumbPlatformImage> = {
        let c = NSCache<NSString, ThumbPlatformImage>()
        c.countLimit = 400
        return c
    }()

    private static func key(_ file: String, _ maxPixel: Int) -> NSString { "\(file)@\(maxPixel)" as NSString }

    static func cached(_ file: String, maxPixel: Int) -> ThumbPlatformImage? { images.object(forKey: key(file, maxPixel)) }

    static func load(_ file: String, maxPixel: Int) async -> ThumbPlatformImage? {
        if let hit = cached(file, maxPixel: maxPixel) { return hit }
        let interval = Perf.signposter.beginInterval("ThumbCache.load")
        defer { Perf.signposter.endInterval("ThumbCache.load", interval) }
        let thumbs = Paths.thumbs
        let cg: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let url = LibraryFile.url(file, in: thumbs, field: "thumbnail"),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }.value
        guard let cg else { return nil }
        #if os(macOS)
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        let image = UIImage(cgImage: cg)
        #endif
        images.setObject(image, forKey: key(file, maxPixel))
        return image
    }
}
