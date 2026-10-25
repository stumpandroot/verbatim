import SwiftUI

// The app's look: the illustrated Verbose style (paper, color panels, line art, grain, serif titles, ink edges) or
// Native (a stock Apple app with a persimmon accent). Stored per device, never synced. On iPhone it lives in the App
// Group, so the keyboard follows the app's choice. Settings › Appearance (iPhone) and Settings › General (Mac) change
// it; onboarding offers both. Views read `@Environment(\.look)`; shared kit components switch on it, so most screens
// change without edits of their own.

enum AppLook: String, CaseIterable, Identifiable, Sendable {
    case verbose, native
    var id: String { rawValue }
    var label: String {
        switch self {
        case .verbose: return "Verbose style"
        case .native: return "Native"
        }
    }

    static let key = "appearance.look"
    /// iPhone and the keyboard share the App Group; the Mac uses its own defaults.
    static var store: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: "group.co.stumpandroot.verbatim.ios") ?? .standard
        #else
        return .standard
        #endif
    }
    /// New installs start in Verbose style.
    static var current: AppLook {
        get { (store.string(forKey: key)).flatMap(AppLook.init(rawValue:)) ?? .verbose }
        set { store.set(newValue.rawValue, forKey: key) }
    }
}

private struct LookKey: EnvironmentKey {
    static let defaultValue: AppLook = .verbose
}

extension EnvironmentValues {
    /// The chosen look. Injected at each window root (and in panels and the keyboard) by `lookRoot()`.
    var look: AppLook {
        get { self[LookKey.self] }
        set { self[LookKey.self] = newValue }
    }
}

/// Reads the stored look and hands it to everything below; updates live when Settings changes it.
struct LookRoot: ViewModifier {
    @AppStorage(AppLook.key, store: AppLook.store) private var raw = AppLook.verbose.rawValue
    func body(content: Content) -> some View {
        content.environment(\.look, AppLook(rawValue: raw) ?? .verbose)
    }
}

extension View {
    /// Apply once at each window root, next to `limitMotionRoot()`.
    func lookRoot() -> some View { modifier(LookRoot()) }
}
