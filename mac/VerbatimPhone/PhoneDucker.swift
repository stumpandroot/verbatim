import SwiftUI
import AVFoundation

/// Settings › Keyboard › Lower other audio while Verbatim listens. On unless you turn it off. Same key as the Mac.
enum PhoneLowerAudio {
    static let key = "audio.lowerOthers"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Settings › Keyboard: the switch for `PhoneLowerAudio`.
struct PhoneLowerAudioRow: View {
    @AppStorage(PhoneLowerAudio.key) private var on = true
    var body: some View {
        SettingsToggleRow(icon: "speaker.wave.1", tint: Ink.persimmonTint, art: .iconLowerAudio, title: "Lower other audio while Verbose listens",
                          subtitle: "Other sound drops to a whisper so it doesn't reach the microphone.", isOn: $on)
            .cardSurface(radius: Radius.row)
    }
}

/// Lowers other apps' audio during a keyboard dictation and brings it back between dictations.
///
/// A keyboard session keeps the microphone open with `.mixWithOthers`, so music and podcasts keep playing while
/// it's on. During a dictation the session's options add `.duckOthers`; when the dictation ends they drop it again.
/// The category and mode stay the same (`.playAndRecord`, `.spokenAudio`), so the running capture engine isn't
/// torn down: only the options change, followed by `setActive(true)` on the already active session. If iOS ever
/// stops the engine for it, `SessionCapture` sees the category change with the engine stopped and rebuilds through
/// its existing path (its log says "route change (category change)").
///
/// iOS sets how far other audio drops (the system duck level); an app can't ask for a precise 10%.
///
/// Voice notes and Live captions don't need this: `Recorder` uses a session that doesn't mix, so other audio
/// stops entirely while they record, which keeps more sound out of the microphone than ducking would.
@MainActor
enum PhoneDucker {
    private static var ducking = false

    /// Called when a keyboard dictation starts (true) and ends (false). Returns quickly; never stops the capture.
    static func set(_ listening: Bool) {
        let want = listening && PhoneLowerAudio.isOn
        guard want != ducking else { return }
        let s = AVAudioSession.sharedInstance()
        // Only the keyboard session's own category: never change a session that isn't recording.
        guard s.category == .playAndRecord else { ducking = false; return }
        var options = s.categoryOptions
        if want { options.insert(.duckOthers) } else { options.remove(.duckOthers) }
        do {
            try RecordingRoute.setCategory(s, mode: s.mode, options: options)
            try s.setActive(true)
            ducking = want
            Log.note("keyboard session: other audio \(want ? "lowered" : "back to full volume")")
        } catch {
            Log.note("keyboard session: couldn't \(want ? "lower" : "restore") other audio: \(error.localizedDescription)")
        }
    }
}
