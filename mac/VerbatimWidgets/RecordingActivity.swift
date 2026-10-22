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

        /// The state for a recording `elapsed` seconds in, at `now`. A saved recording reads as stopped (paused,
        /// no reason); a reason only shows while paused.
        static func make(elapsed: TimeInterval, isPaused: Bool, pausedReason: String?, saved: Bool = false, now: Date = Date()) -> ContentState {
            let e = elapsed.isFinite ? max(0, elapsed) : 0
            let paused = isPaused || saved
            return ContentState(startDate: now.addingTimeInterval(-e), elapsed: e, isPaused: paused,
                                pausedReason: paused && !saved ? pausedReason : nil, saved: saved)
        }

        /// The moment the timer stops at while paused or saved; nil while it runs.
        var pauseTime: Date? { isPaused ? startDate.addingTimeInterval(elapsed) : nil }

        /// The status line: "Recording", "Paused", a reason, or "Saved".
        var status: String {
            if saved { return "Saved. Transcribing on this iPhone." }
            if isPaused { return pausedReason ?? "Paused" }
            return "Recording"
        }
    }

    /// "Voice note" or "Live captions".
    var title: String

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

enum RecordingControl {
    enum Command { case togglePause, stop }
    /// Set by the app (RecordingPresence); nil in the widget extension. Returns false when no recording runs.
    @MainActor static var handler: ((Command) -> Bool)?

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
