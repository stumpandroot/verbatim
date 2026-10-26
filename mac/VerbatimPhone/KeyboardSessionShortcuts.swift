import Foundation
import AppIntents

/// Hands a session start from `StartKeyboardSessionIntent`, `DictateIntent`, `ActionButtonIntent`, or the Control
/// Center switch to the keyboard session. The intent can run before the session exists (a cold launch), so a start
/// that arrives early waits until `KeyboardSession` attaches.
enum SessionStartSignal {
    struct Start: Equatable {
        var source: KeyboardBridge.StartSource
        /// Also start a take as soon as the microphone is on (the Action button's first press).
        var take: Bool
    }

    @MainActor private static var handler: ((Start) -> Void)?
    @MainActor private static var pending: Start?

    /// Called once by `KeyboardSession`. A start that arrived first runs on the next turn of the main loop, once
    /// the app has finished setting up.
    @MainActor static func attach(_ h: @escaping (Start) -> Void) {
        handler = h
        guard let p = pending else { return }
        pending = nil
        DispatchQueue.main.async { h(p) }
    }

    @MainActor static func fire(_ source: KeyboardBridge.StartSource, take: Bool = false) {
        let s = Start(source: source, take: take)
        if let handler { handler(s) } else { pending = s }
    }
}

/// Hands Settings › Action button's choices that need Verbose in front (Record a voice note, Live captions, What's
/// playing, New thought) to the app once it is, and tries a voice note in place first (iOS 18 and later).
enum ActionButtonSignal {
    @MainActor private static var handler: ((Ribbon.ActionChoice) -> Void)?
    @MainActor private static var pending: Ribbon.ActionChoice?
    /// Set by `KeyboardSession` (`PhoneState.startVoiceNoteInPlace`); nil before the app has set up.
    @MainActor static var voiceNoteInPlace: (() -> Bool)?

    /// True when a voice note started in place with its Live Activity; false sends it through Verbose.
    @MainActor static func startVoiceNoteInPlace() -> Bool { voiceNoteInPlace?() ?? false }

    @MainActor static func attach(_ h: @escaping (Ribbon.ActionChoice) -> Void) {
        handler = h
        guard let p = pending else { return }
        pending = nil
        DispatchQueue.main.async { h(p) }
    }

    @MainActor static func fire(_ choice: Ribbon.ActionChoice) {
        if let handler { handler(choice) } else { pending = choice }
    }
}

/// Siri, Spotlight, the Shortcuts app, and the Action button (Settings › Action Button › Shortcut › Verbose).
struct VerbatimAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ActionButtonIntent(),
            phrases: [
                "\(.applicationName) action button",
                "Run the \(.applicationName) action",
            ],
            shortTitle: "Action button",
            systemImageName: "button.horizontal.top.press"   // brand: system surface
        )
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start a \(.applicationName) dictation",
                "Stop the \(.applicationName) dictation",
            ],
            shortTitle: "Dictate",
            systemImageName: "waveform"   // brand: system surface
        )
        AppShortcut(
            intent: StartKeyboardSessionIntent(),
            phrases: [
                "Start a \(.applicationName) session",
                "Start dictating with \(.applicationName)",
                "Start a \(.applicationName) keyboard session",
            ],
            shortTitle: "Start dictation session",
            systemImageName: "mic.fill"   // brand: system surface
        )
        // "New thought in Verbose": records in place, like the widgets, and works as soon as Verbose is installed.
        // Back Tap runs it through a shortcut made from it (Settings › Features › Thoughts). App Shortcuts take only
        // SF Symbol names, so this one can't use the exported Thoughts symbol.
        AppShortcut(
            intent: NewThoughtIntent(),
            phrases: [
                "New thought in \(.applicationName)",
                "Start a thought in \(.applicationName)",
                "Add a thought to \(.applicationName)",
            ],
            shortTitle: "New thought",
            systemImageName: "lightbulb"   // brand: system surface
        )
    }
}
