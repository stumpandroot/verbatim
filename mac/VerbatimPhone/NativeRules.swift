import Foundation

// The Native look's pure rules on iPhone (DESIGN.md §13.3; mockup "Verbose Native Redesign", October 27, 2026), kept
// free of SwiftUI so mac/tools/test-native-phone.sh checks them on Linux: the recorder's clock and ruler, and This
// week's bars. Settings' squares moved to the refined look (`RefinedRules.settingsHue`).

enum NativeRules {
    // MARK: Recorder

    /// The recorder's clock, as Voice Memos shows it: minutes, seconds, and hundredths ("02:18.41"), with hours once
    /// there are any ("1:02:18.41"). Never negative.
    static func recorderClock(_ t: Double) -> String {
        let total = max(0, t)
        let hundredths = Int((total * 100).rounded(.down)) % 100
        let s = Int(total.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, sec, hundredths) }
        return String(format: "%02d:%02d.%02d", m, sec, hundredths)
    }

    /// The ruler's second marks over the recorder's waveform: each whole second from `window` seconds before
    /// `elapsed` up to it, with its distance back from the playhead as a fraction of the window (0 at the playhead, 1 at
    /// the left edge). Seconds before the recording started are left out.
    static func rulerTicks(elapsed: Double, window: Double) -> [(second: Int, back: Double)] {
        guard window > 0, elapsed >= 0 else { return [] }
        let first = max(0, Int((elapsed - window).rounded(.up)))
        let last = Int(elapsed.rounded(.down))
        guard first <= last else { return [] }
        return (first...last).map { s in (s, (elapsed - Double(s)) / window) }
    }

    /// "2:11": a ruler label or a moment's time, minutes and seconds.
    static func shortClock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "3 moments", "1 moment".
    static func momentsLabel(_ n: Int) -> String { n == 1 ? "1 moment" : "\(n) moments" }

    // MARK: This week

    /// Home's This week cell: "1,414 words" over "20 recordings · 25 min saved".
    static func weekDetail(recordings: Int, saved: String) -> String {
        "\(recordings == 1 ? "1 recording" : "\(recordings) recordings") · \(saved) saved"
    }
}
