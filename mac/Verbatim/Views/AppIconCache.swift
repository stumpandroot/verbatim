import SwiftUI
import AppKit

/// App icons, looked up on a background queue once and then kept in memory. A cold Icon Services lookup can take
/// tens to hundreds of milliseconds, and these used to run in `body` (the first open of You looked up every app in
/// "Where you dictate" on the main thread). A lookup that finds nothing isn't remembered, so an app installed later
/// shows its icon the next time a view asks.
@MainActor
enum AppIconCache {
    enum Key: Hashable {
        /// By bundle ID. With `generic`, an app that can't be found gets the system's generic icon instead of none.
        case bundleID(String, generic: Bool = false)
        /// By app name, in the usual Applications folders (activity keeps names, not bundle IDs).
        case name(String)
    }

    private static var images: [Key: NSImage] = [:]
    private static var loading: [Key: Task<NSImage?, Never>] = [:]
    nonisolated static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                      "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    static func cached(_ key: Key) -> NSImage? { images[key] }

    /// The icon, looked up off the main thread the first time (one lookup per key at a time).
    static func load(_ key: Key) async -> NSImage? {
        if let hit = images[key] { return hit }
        let task: Task<NSImage?, Never>
        if let running = loading[key] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) { resolve(key) }
            loading[key] = task
        }
        let image = await task.value
        loading[key] = nil
        if let image { images[key] = image }
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
}

/// An app's icon from `AppIconCache`, sized by its frame. `placeholder` shows while it loads and when there's no
/// icon, in the same frame, so nothing moves when the icon arrives.
struct AppIcon<Placeholder: View>: View {
    var key: AppIconCache.Key?
    /// nil leaves SwiftUI's default.
    var interpolation: Image.Interpolation? = .high
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: (key: AppIconCache.Key, image: NSImage)?

    var body: some View {
        let image = key.flatMap { k in loaded?.key == k ? loaded?.image : AppIconCache.cached(k) }
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
        .task(id: key) {
            guard let key, AppIconCache.cached(key) == nil else { return }
            if let image = await AppIconCache.load(key) { loaded = (key, image) }
        }
    }
}
