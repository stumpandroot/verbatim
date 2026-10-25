import Foundation
import ActivityKit
import AppIntents

/// The keyboard session's Live Activity (Dynamic Island and Lock Screen), which is also the recording ribbon's
/// face. Compiled into the app, which starts, updates, and ends it, and into the VerbatimWidgets extension, which
/// draws it.
///
/// What the content state may hold (the Island and the Lock Screen share it, and anyone can read a Lock Screen):
/// - Always: state, counts, times, a failure message in Verbose's words, and the name of the app the words go to
///   ("Messages"; nil in App Store builds and when the app isn't known, which reads as the Verbose keyboard).
/// - `liveWords`, the only transcript text: the last `Ribbon.islandWordsLimit` (about 80) characters of the words
///   so far, and only while a take is listening with Settings › Keyboard › Show words in the Dynamic Island on
///   (off by default). The app clears it when the take stops. Only the expanded Dynamic Island draws it; the Lock
///   Screen view never reads it, so the Lock Screen never shows words.
/// The whole state stays far under ActivityKit's 4 KB cap (`Ribbon.contentStateLimit`), and the app updates it
/// about once a second while listening, as ActivityKit expects of local updates.
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
        /// The app the words go to ("Messages"), for "Into Messages"; nil reads as the Verbose keyboard.
        var target: String? = nil
        /// The expanded Island's words line while listening, with Show words in the Dynamic Island on; nil
        /// otherwise. Never drawn on the Lock Screen (see above).
        var liveWords: String? = nil
        /// True while a take listens before the speech model is ready (the first dictation): "Getting ready".
        /// A state only, never words. Optional, so a state encoded without it still decodes.
        var gettingReady: Bool? = nil

        init(listening: Bool, endsAt: Date?, phase: Ribbon.Phase? = nil, sessionStartedAt: Date? = nil, takeStartedAt: Date? = nil,
             level: Double = 0, words: Int = 0, takes: Int = 0, message: String? = nil, target: String? = nil, liveWords: String? = nil,
             gettingReady: Bool? = nil) {
            self.listening = listening
            self.endsAt = endsAt
            self.phase = phase
            self.sessionStartedAt = sessionStartedAt
            self.takeStartedAt = takeStartedAt
            self.level = level
            self.words = words
            self.takes = takes
            self.message = message
            self.target = target
            self.liveWords = liveWords
            self.gettingReady = gettingReady
        }

        /// The phase to draw.
        var shown: Ribbon.Phase { phase ?? (listening ? .listening : .ready) }

        /// Listening before the speech model is ready.
        var warming: Bool { shown == .listening && gettingReady == true }
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
