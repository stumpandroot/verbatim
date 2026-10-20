import Foundation
import ActivityKit
import AppIntents

/// The keyboard session's Live Activity (Dynamic Island and Lock Screen). Compiled into the app, which starts,
/// updates, and ends it, and into the VerbatimWidgets extension, which draws it.
struct VerbatimSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// True while a dictation is being captured.
        var listening: Bool
        /// When the idle timeout ends the session; nil when it runs until you end it.
        var endsAt: Date?
    }
}

/// Ends the session from the Live Activity's End session button.
///
/// A `LiveActivityIntent` runs in the app's process, so `perform` calls the session directly through
/// `SessionEndSignal.handler`. It also posts a Darwin notification, which reaches the app even if iOS ever runs
/// the intent in the widget's process. Neither path needs the widget to be in the App Group.
struct EndVerbatimSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End session"
    static var description = IntentDescription("Ends the Verbatim keyboard session and turns off the microphone.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { SessionEndSignal.fire() }
        return .result()
    }
}

enum SessionEndSignal {
    /// Posted when the Live Activity's End session button is tapped.
    static let note = "co.stumpandroot.verbatim.session.end"
    /// Set by the app's session; nil in the widget extension.
    @MainActor static var handler: (() -> Void)?

    @MainActor static func fire() {
        if let handler { handler(); return }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(note as CFString), nil, nil, true)
    }
}
