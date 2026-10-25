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
    /// iPhone and the keyboard share the App Group; the Mac uses its own defaults. One instance for the process, so
    /// every `@AppStorage` reading the look observes the same object the look is written through.
    static let store: UserDefaults = {
        #if os(iOS)
        return UserDefaults(suiteName: "group.co.stumpandroot.verbatim.ios") ?? .standard
        #else
        return .standard
        #endif
    }()
    /// New installs start in Verbose style. Setting it also tells every `lookRoot()` at once (`LookOverride.stored`).
    static var current: AppLook {
        get { (store.string(forKey: key)).flatMap(AppLook.init(rawValue:)) ?? .verbose }
        set {
            store.set(newValue.rawValue, forKey: key)
            LookOverride.storedChanged(newValue)
        }
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

/// The look a switch is applying (LookSwitch.swift in the apps), set in the same moment as the stored value so every
/// root changes in one update, before the stored value's change notification reaches them. Nil the rest of the time.
final class LookOverride: ObservableObject {
    static let shared = LookOverride()
    @Published var look: AppLook?
    /// The stored look, published the moment `AppLook.current` is set. Roots read this rather than their
    /// `@AppStorage` alone: after build 208 stopped the App structs re-rendering on every state change, iPhone roots
    /// were left on the old look once a switch cleared `look`, because the App Group's change notice hadn't reached
    /// them (Home stayed in Verbose style after switching to Native).
    @Published private(set) var stored: AppLook = AppLook.current

    /// Called by `AppLook.current`'s setter; publishes on the main thread.
    static func storedChanged(_ look: AppLook) {
        if Thread.isMainThread { shared.set(look) } else { DispatchQueue.main.async { shared.set(look) } }
    }
    fileprivate func set(_ look: AppLook) { if stored != look { stored = look } }
}

/// Reads the stored look and hands it to everything below; updates live when Settings changes it.
struct LookRoot: ViewModifier {
    @AppStorage(AppLook.key, store: AppLook.store) private var raw = AppLook.verbose.rawValue
    @ObservedObject private var override = LookOverride.shared
    func body(content: Content) -> some View {
        content.environment(\.look, override.look ?? override.stored)
            // A write that didn't go through `AppLook.current` (the self-test restoring the stored value) still lands.
            .onChange(of: raw) { _, new in override.set(AppLook(rawValue: new) ?? .verbose) }
    }
}

extension View {
    /// Apply once at each window root, next to `limitMotionRoot()`.
    func lookRoot() -> some View { modifier(LookRoot()) }
}
