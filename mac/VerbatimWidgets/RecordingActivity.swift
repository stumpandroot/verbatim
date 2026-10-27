import Foundation
import ActivityKit
import AppIntents

/// The iPhone recording's Live Activity (Lock Screen and Dynamic Island). Compiled into the app, which starts,
/// updates, and ends it (VerbatimPhone/RecordingPresence.swift), and into the VerbatimWidgets extension, which
/// draws it (RecordingLiveActivity.swift).
struct VerbatimRecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the timer reads 0:00 (the update's time minus `elapsed`), so the timer counts on its own while
        /// recording, with no updates from the app.
        var startDate: Date
        /// Seconds recorded at the update. The timer stops here while paused.
        var elapsed: TimeInterval
        var isPaused: Bool
        /// A short reason when the recording paused itself ("Paused for a call"); nil for your own pause.
        var pausedReason: String?
        /// Stopped and saved: shown for a few seconds before the activity ends.
        var saved: Bool
        /// The microphone level, 0 to 1, for the voice bars: about once a second for a thought, every two seconds for a
        /// voice note (its Lock Screen draws your voice too). nil from builds before voice notes sent it.
        var level: Double? = nil
        /// A thought only: the end of your words for the expanded Dynamic Island (`Ribbon.islandWords`), sent only with
        /// Settings › Thoughts › Show words in the Dynamic Island on. The Lock Screen never reads it.
        var words: String? = nil
        /// A thought only: when it was saved, for "Added to Thoughts · 9:41".
        var savedAt: Date? = nil
        /// Moments marked so far (Mark, in the expanded Island and on the Lock Screen; Model/Marks.swift). nil for none.
        var marks: Int? = nil
        /// Seconds into the recording of the last mark, for "Marked 4:12".
        var markedAt: TimeInterval? = nil
        /// True for the two seconds after a mark: the compact Island says "Marked 4:12 · 3 moments".
        var justMarked: Bool? = nil

        /// The state for a recording `elapsed` seconds in, at `now`. A saved recording reads as stopped (paused,
        /// no reason); a reason only shows while paused.
        static func make(elapsed: TimeInterval, isPaused: Bool, pausedReason: String?, saved: Bool = false, now: Date = Date()) -> ContentState {
            let e = elapsed.isFinite ? max(0, elapsed) : 0
            let paused = isPaused || saved
            return ContentState(startDate: now.addingTimeInterval(-e), elapsed: e, isPaused: paused,
                                pausedReason: paused && !saved ? pausedReason : nil, saved: saved)
        }

        /// A thought's state: a voice note's, plus the level and (only while recording, and only when asked for) the
        /// last words. Saved, it keeps neither and carries the time it was saved.
        static func thought(elapsed: TimeInterval, isPaused: Bool, pausedReason: String?, level: Double, words: String?,
                            saved: Bool = false, now: Date = Date()) -> ContentState {
            var s = make(elapsed: elapsed, isPaused: isPaused, pausedReason: pausedReason, saved: saved, now: now)
            s.level = saved || isPaused ? 0 : min(1, max(0, level.isFinite ? level : 0))
            s.words = saved ? nil : words
            s.savedAt = saved ? now : nil
            return s
        }

        /// The same state with the recording's marks.
        func marked(count: Int, lastAt: TimeInterval?, just: Bool) -> ContentState {
            var s = self
            s.marks = count > 0 ? count : nil
            s.markedAt = count > 0 ? lastAt : nil
            s.justMarked = count > 0 && just ? true : nil
            return s
        }

        var markCount: Int { marks ?? 0 }
        /// "Marked 4:12" while a mark is being confirmed; nil otherwise.
        var markedClock: String? {
            guard justMarked == true, let at = markedAt else { return nil }
            return VerbatimRecordingAttributes.clock(at)
        }
        /// "3 moments", "1 moment".
        var marksLabel: String { markCount == 1 ? "1 moment" : "\(markCount) moments" }

        /// The moment the timer stops at while paused or saved; nil while it runs.
        var pauseTime: Date? { isPaused ? startDate.addingTimeInterval(elapsed) : nil }

        /// The status line: "Recording", "Paused", a reason, or "Saved".
        var status: String {
            if saved { return savedAt != nil ? ThoughtRules.savedTitle : "Saved. Transcribing on this iPhone." }
            if isPaused { return pausedReason ?? "Paused" }
            return "Recording"
        }
    }

    /// "Voice note", "Live captions", or "New thought".
    var title: String
    /// A thought (nil or false for a voice note): drawn on paper with your voice, and "Added to Thoughts" when saved.
    var thought: Bool? = nil
    /// A thought's page, "Thoughts · Mon, Oct 26", for "Into Thoughts · Mon, Oct 26".
    var page: String? = nil

    var isThought: Bool { thought == true }

    /// "4:12" or "1:02:14" (the same as `Marks.clock`, which the widget extension doesn't compile).
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// A few words for the Lock Screen from the recorder's full pause reason. Nil for no reason.
    static func shortReason(_ full: String?) -> String? {
        guard let full, !full.isEmpty else { return nil }
        let s = full.lowercased()
        if s.contains("audio restarted") { return "Audio restarted. Tap Resume." }
        if s.contains("for a call") && s.contains("open verbose") { return "Paused for a call. Open Verbose." }
        if s.contains("another app") && s.contains("open verbose") { return "Paused for another app. Open Verbose." }
        if s.contains("call") || s.contains("another app") { return "Paused for a call" }
        if s.contains("can't save") { return "Can't save audio. Free up space." }
        if s.contains("microphone") { return "Microphone changed. Tap Resume." }
        return "Paused"
    }
}

/// Pause or Resume from the Live Activity. A `LiveActivityIntent` runs in the app's process, so `perform` calls
/// the running recorder through `RecordingControl.handler`. With no recording running (the app was closed),
/// it does nothing and leftover recording activities are ended.
struct ToggleRecordingPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume recording"
    static var description = IntentDescription("Pauses or resumes the Verbose recording.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { RecordingControl.fire(.togglePause) }
        return .result()
    }
}

/// Stop from the Live Activity: the recording stops and is saved and transcribed, as Stop & transcribe does.
struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop recording"
    static var description = IntentDescription("Stops the Verbose recording, saves it, and transcribes it.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { RecordingControl.fire(.stop) }
        return .result()
    }
}

/// Mark from the expanded Dynamic Island or the Lock Screen: saves the recording's current time as a moment, without
/// opening Verbose or unlocking (mockup "Library features", section 3a). `source` says which ("island" or "lockScreen",
/// `MarkSource`), for "Moment 4:12 · from the Lock Screen" in the transcript.
struct MarkMomentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark a moment"
    static var description = IntentDescription("Marks a moment in the Verbose recording at the current time.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Where", default: "island")
    var source: String

    init() {}
    init(source: String) { self.source = source }

    func perform() async throws -> some IntentResult {
        let from = source
        await MainActor.run { RecordingControl.fire(.mark(from)) }
        return .result()
    }
}

enum RecordingControl {
    enum Command { case togglePause, stop, mark(String) }
    /// Set by the app (RecordingPresence); nil in the widget extension. Returns false when no recording runs.
    @MainActor static var handler: ((Command) -> Bool)?

    /// Marks a moment in the running recording (the Action button's Record or mark). False when nothing records, and
    /// nothing else happens then.
    @MainActor static func mark(_ source: String) -> Bool { handler?(.mark(source)) ?? false }

    @MainActor static func fire(_ command: Command) {
        if let handler, handler(command) { return }
        #if !VERBATIM_WIDGETS
        // Nothing is recording (Verbatim was closed mid-recording, and launch recovery keeps the audio): the
        // activity is out of date, so it goes.
        for a in Activity<VerbatimRecordingAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        #endif
    }
}
