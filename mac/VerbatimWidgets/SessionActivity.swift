import Foundation
import ActivityKit
import AppIntents

/// The keyboard session's Live Activity (Dynamic Island and Lock Screen), which is also the recording ribbon's
/// face. Compiled into the app, which starts, updates, and ends it, and into the VerbatimWidgets extension, which
/// draws it. Never holds transcript text: only state, counts, and times (the Lock Screen is visible to anyone).
struct VerbatimSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// True while a dictation is being captured.
        var listening: Bool
        /// When the idle timeout ends the session; nil when it runs until you end it.
        var endsAt: Date?
        /// What the ribbon shows (`Ribbon.Phase`). Nil reads as ready or listening, from `listening`.
        var phase: Ribbon.Phase? = nil
        /// When the session started, for its age on the Lock Screen.
        var sessionStartedAt: Date? = nil
        /// When the running take started, so its timer counts on its own.
        var takeStartedAt: Date? = nil
        /// The microphone level, 0…1, updated about once a second while listening.
        var level: Double = 0
        /// Words in the last take (Copied · 42 words). A count, never the words.
        var words: Int = 0
        /// Takes so far this session.
        var takes: Int = 0
        /// A failure or end reason in Verbose's words ("Couldn't copy. Open Verbose to get your words.").
        var message: String? = nil

        init(listening: Bool, endsAt: Date?, phase: Ribbon.Phase? = nil, sessionStartedAt: Date? = nil, takeStartedAt: Date? = nil,
             level: Double = 0, words: Int = 0, takes: Int = 0, message: String? = nil) {
            self.listening = listening
            self.endsAt = endsAt
            self.phase = phase
            self.sessionStartedAt = sessionStartedAt
            self.takeStartedAt = takeStartedAt
            self.level = level
            self.words = words
            self.takes = takes
            self.message = message
        }

        /// The phase to draw.
        var shown: Ribbon.Phase { phase ?? (listening ? .listening : .ready) }
    }
}

/// Ends the session from the Live Activity's End session button.
///
/// A `LiveActivityIntent` runs in the app's process, so `perform` calls the session directly through
/// `SessionEndSignal.handler`. If iOS ever runs it in the widget's process, the command goes through the App Group
/// instead (`KeyboardBridge.sendCommand`), as the ribbon's do.
struct EndVerbatimSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End session"
    static var description = IntentDescription("Ends the Verbose keyboard session and turns off the microphone.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { SessionEndSignal.fire() }
        return .result()
    }
}

enum SessionEndSignal {
    /// The command's name in the App Group (`RibbonCommand.endSession`).
    static let command = "endSession"
    /// Set by the app's session; nil in the widget extension.
    @MainActor static var handler: (() -> Void)?

    @MainActor static func fire() {
        if let handler { handler(); return }
        KeyboardBridge.sendCommand(command)
    }
}
