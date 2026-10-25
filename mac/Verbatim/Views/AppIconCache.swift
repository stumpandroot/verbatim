import SwiftUI
import AppKit

/// App icons, looked up on a background queue once and then kept in memory. A cold Icon Services lookup can take
/// tens to hundreds of milliseconds, and these used to run in `body` (the first open of You looked up every app in
/// "Where you dictate" on the main thread). A lookup that finds nothing isn't remembered, so an app installed later
/// shows its icon the next time a view asks.
///
/// Each icon is kept per appearance as a bitmap, rendered off the main thread: an Icon Services image draws each
/// appearance's representation lazily, on the main thread, the first time it's drawn, which is why dark Dictations
/// and dark You settled hundreds of milliseconds late.
@MainActor
enum AppIconCache {
    enum Key: Hashable {
        /// By bundle ID. With `generic`, an app that can't be found gets the system's generic icon instead of none.
        case bundleID(String, generic: Bool = false)
        /// By app name, in the usual Applications folders (activity keeps names, not bundle IDs).
        case name(String)
    }

    /// An icon in one appearance.
    struct Variant: Hashable { var key: Key; var dark: Bool }

    private static var images: [Variant: NSImage] = [:]
    private static var loading: [Variant: Task<NSImage?, Never>] = [:]
    nonisolated static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                      "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    /// Bitmaps are this many pixels square: sharp up to 48 pt on a Retina display.
    nonisolated static let pixels = 96

    static func cached(_ key: Key, dark: Bool) -> NSImage? { images[Variant(key: key, dark: dark)] }

    /// The icon, looked up and rendered off the main thread the first time (one job per icon and appearance at a time).
    static func load(_ key: Key, dark: Bool) async -> NSImage? {
        let v = Variant(key: key, dark: dark)
        if let hit = images[v] { return hit }
        let task: Task<NSImage?, Never>
        if let running = loading[v] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) { AppIconCache.resolve(key).map { AppIconCache.bitmap($0, dark: dark) } }
            loading[v] = task
        }
        let image = await task.value
        loading[v] = nil
        if let image { images[v] = image }
        return image
    }

    nonisolated private static func resolve(_ key: Key) -> NSImage? {
        let interval = Perf.signposter.beginInterval("AppIconCache.resolve")
        defer { Perf.signposter.endInterval("AppIconCache.resolve", interval) }
        switch key {
        case .bundleID(let id, let generic):
            if !id.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return generic ? NSWorkspace.shared.icon(forFile: "") : nil
        case .name(let name):
            guard !name.isEmpty else { return nil }
            for folder in folders {
                let path = folder + "/" + name + ".app"
                if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
            }
            return nil
        }
    }

    /// `image` drawn once in light or dark into a bitmap, so drawing it later is a plain copy.
    nonisolated static func bitmap(_ image: NSImage, dark: Bool) -> NSImage {
        let side = pixels
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let draw = { image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1) }
        if let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: side / 2, height: side / 2)
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }
}

/// An app's icon from `AppIconCache`, sized by its frame, in the view's appearance. `placeholder` shows while it
/// loads and when there's no icon, in the same frame, so nothing moves when the icon arrives.
struct AppIcon<Placeholder: View>: View {
    var key: AppIconCache.Key?
    /// nil leaves SwiftUI's default.
    var interpolation: Image.Interpolation? = .high
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: (variant: AppIconCache.Variant, image: NSImage)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let image = key.flatMap { k in loaded?.variant == AppIconCache.Variant(key: k, dark: dark) ? loaded?.image : AppIconCache.cached(k, dark: dark) }
        ZStack {
            if let image {
                if let interpolation {
                    Image(nsImage: image).resizable().interpolation(interpolation)
                } else {
                    Image(nsImage: image).resizable()
                }
            } else {
                placeholder()
            }
        }
        .task(id: key.map { AppIconCache.Variant(key: $0, dark: dark) }) {
            guard let key, AppIconCache.cached(key, dark: dark) == nil else { return }
            if let image = await AppIconCache.load(key, dark: dark) { loaded = (AppIconCache.Variant(key: key, dark: dark), image) }
        }
    }
}
