import SwiftUI
import AppKit

// The Mac's appearance helpers that every window shares: the Increase Contrast setting the tokens read, the type
// roles for surfaces that draw outside the main window (the Ribbon, the notch, the floating button), and the soft
// scroll edge under the toolbar's glass.

/// Increase Contrast, read once and again only when it changes (it was asked on every color resolve).
enum ContrastSetting {
    static var increased: Bool {
        _ = watcher
        lock.lock(); defer { lock.unlock() }
        return value
    }
    private static let lock = NSLock()
    private static var value = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private static let watcher: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil) { _ in
            let v = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            lock.lock(); value = v; lock.unlock()
        }
}

/// The serif and mono roles for the dictation surfaces (the Ribbon, the notch, the floating button), which draw in
/// their own panels.
enum SurfaceFont {
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced).monospacedDigit() }
}

extension View {
    /// The soft scroll edge effect on these edges (macOS 26), so text that scrolls under the toolbar's glass or beside
    /// the player bar fades instead of colliding with it (DESIGN.md §13; review M-05, M-29). Earlier systems draw no
    /// glass there, so nothing changes.
    @ViewBuilder func softScrollEdges(_ edges: Edge.Set) -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: edges) } else { self }
    }

    /// The Mac sidebar's surface (DESIGN.md §16). macOS 26 and later float the sidebar as the system's glass panel,
    /// inset from the window's edges over the page's paper, so Verbose draws nothing under it: an opaque fill turned
    /// the panel into a flat block. Earlier systems draw a plain sidebar, which keeps the paper-gray `side` token.
    @ViewBuilder func macSidebarSurface() -> some View {
        if #available(macOS 26, *) { self } else { background(Refined.side.ignoresSafeArea()) }
    }
}
