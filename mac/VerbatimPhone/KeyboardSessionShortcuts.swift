import Foundation
import AppIntents

/// Hands a session start from `StartKeyboardSessionIntent` (Control Center, the Action button, Shortcuts) to the
/// keyboard session. The intent can run before the session exists (a cold launch), so a start that arrives early
/// waits until `KeyboardSession` attaches.
enum SessionStartSignal {
    @MainActor private static var handler: ((KeyboardBridge.StartSource) -> Void)?
    @MainActor private static var pending: KeyboardBridge.StartSource?

    /// Called once by `KeyboardSession`. A start that arrived first runs on the next turn of the main loop, once
    /// the app has finished setting up.
    @MainActor static func attach(_ h: @escaping (KeyboardBridge.StartSource) -> Void) {
        handler = h
        guard let p = pending else { return }
        pending = nil
        DispatchQueue.main.async { h(p) }
    }

    @MainActor static func fire(_ source: KeyboardBridge.StartSource) {
        if let handler { handler(source) } else { pending = source }
    }
}

/// Siri, Spotlight, the Shortcuts app, and the Action button (Settings › Action Button › Shortcut › Verbatim).
struct VerbatimAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartKeyboardSessionIntent(),
            phrases: [
                "Start a \(.applicationName) session",
                "Start dictating with \(.applicationName)",
                "Start a \(.applicationName) keyboard session",
            ],
            shortTitle: "Start dictation session",
            systemImageName: "mic.fill"
        )
    }
}
