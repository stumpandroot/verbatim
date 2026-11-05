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
                Rectangle().fill(Refined.track)
                    .overlay { Self.picture(image).resizable().aspectRatio(contentMode: .fill) }
                    .clipped()
            } else if failed {
                missing()
            } else {
                Rectangle().fill(Refined.track)
            }
        }
        .task(id: file) {
            guard ThumbCache.cached(file, maxPixel: maxPixel) == nil else { return }
            if let img = await ThumbCache.load(file, maxPixel: maxPixel) { loaded = img; failed = false } else { failed = true }
        }
    }

    private static func picture(_ image: ThumbPlatformImage) -> Image {
        #if os(macOS)
        return Image(nsImage: image)
        #else
        return Image(uiImage: image)
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

/// A still in the transcript's margin (VideoStill: an imported video's, or a call's shared screen; mockup "Verbose Video
/// Stills", option B): drawn at the still's shape, a tall one `tallWidth` across. A click or tap opens the stills viewer
/// on it (DESIGN.md §6.9, Stills viewer). On the Mac, a small play button appears on the thumbnail's corner on hover or
/// keyboard focus and plays from its moment; Play from here is also in its context menu and VoiceOver's actions.
/// Shared by the Mac and the iPhone.
struct VideoStillThumb: View {
    var still: VideoStill
    var tallWidth: CGFloat
    /// The still's place among the transcript's stills, for VoiceOver ("Still at 12:04, 3 of 9").
    var index: Int = 0
    var count: Int = 1
    /// Opens the viewer on this still.
    var open: () -> Void
    /// Plays from the still's moment (the Mac's hover button); nil leaves it out.
    var play: (() -> Void)? = nil
    #if os(macOS)
    @State private var hover = false
    @FocusState private var playFocused: Bool
    #endif

    var body: some View {
        let size = VideoStill.size(aspect: still.aspect, tallWidth: Double(tallWidth))
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let thumb = Button(action: open) {
            ThumbImage(file: still.file, maxPixel: Int(max(size.width, size.height) * 3)) { Rectangle().fill(Refined.track) }
                .frame(width: CGFloat(size.width), height: CGFloat(size.height))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Refined.separator, lineWidth: 0.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(StillViewerRules.spokenLabel(at: still.at, index: index, count: count))
        .accessibilityHint("Opens the still.")
        .accessibilityActions {
            if let play { Button("Play from here", action: play) }
        }
        #if os(macOS)
        thumb
            .help("Open the still at \(StillViewerRules.caption(still.at))")
            .contextMenu {
                Button("Open Still", action: open)
                if let play { Button("Play from Here", action: play) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let play { playButton(play) }
            }
            .onHover { hover = $0 }
        #else
        thumb
        #endif
    }

    #if os(macOS)
    /// The corner's play button: a small card-colored disc with the play glyph, shown while the pointer is over the
    /// thumbnail or the button has keyboard focus (it stays in the key view loop when hidden).
    private func playButton(_ play: @escaping () -> Void) -> some View {
        let shown = hover || playFocused
        return Button(action: play) {
            IconGlyph(art: .iconPlay, size: 10, color: Refined.ink)
                .frame(width: 20, height: 20)
                .background(Refined.card, in: Circle())
                .overlay(Circle().strokeBorder(Refined.separator, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($playFocused)
        .padding(3)
        .opacity(shown ? 1 : 0)
        .animation(Motion.touch, value: shown)
        .help("Play from \(StillViewerRules.caption(still.at))")
        .accessibilityLabel("Play from \(StillViewerRules.caption(still.at))")
    }
    #endif

    /// The margin a transcript's stills need: the widest still, or nil when it has none (no margin at all).
    static func margin(_ stills: [VideoStill]?, tallWidth: CGFloat) -> CGFloat? {
        guard let stills, !stills.isEmpty else { return nil }
        return CGFloat(stills.map { VideoStill.size(aspect: $0.aspect, tallWidth: Double(tallWidth)).width }.max() ?? Double(tallWidth))
    }
}
