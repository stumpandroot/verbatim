import Foundation

// The Native look's pure rules on iPhone (DESIGN.md §13.3; mockup "Verbose Native Redesign", October 27, 2026), kept
// free of SwiftUI so mac/tools/test-native-phone.sh checks them on Linux: the recorder's clock and ruler, the colors of
// Settings' squares (system colors, never red, which means recording), and This week's bars.

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

    // MARK: Settings squares

    /// The system colors Settings' squares use, as Apple's Settings app does. Red isn't one of them: red means
    /// recording in Verbose, and destructive rows are gray with a red title.
    enum Square: String, CaseIterable {
        case blue, indigo, purple, pink, orange, yellow, green, mint, teal, cyan, brown, gray
    }

    /// A row's square, from its SF Symbol. Apple's own meanings where one exists (blue for Appearance, the Action
    /// button, and Privacy; gray for Keyboard and General-style rows); the rest spread across the system colors so a
    /// long list scans. Anything not listed is gray.
    static func square(for symbol: String) -> Square {
        switch symbol {
        // Personalization and preferences
        case "circle.lefthalf.filled": return .blue          // Appearance
        case "house", "square.grid.2x2": return .indigo      // Customize Home, Widgets and controls
        case "dock.rectangle": return .cyan                  // Tab bar
        case "person", "person.crop.circle": return .gray    // About me, Your name
        case "waveform": return .purple                      // Your voice
        case "book.closed": return .orange                   // Dictionary
        case "globe": return .blue                           // Detect the language
        case "tortoise": return .teal                        // Limit animation
        case "hand.tap": return .pink                        // Haptics
        // Recording and transcription
        case "chart.line.uptrend.xyaxis": return .green      // Quality
        case "person.2": return .orange                      // Speakers
        case "text.quote": return .yellow                    // Summaries
        case "sparkles": return .purple                      // Name and sort recordings
        case "text.bubble": return .green                    // Show words while you record
        case "square.stack.3d.up": return .gray              // More transcription options
        // Dictation and keyboard
        case "keyboard": return .gray                        // Keyboard
        case "button.horizontal.top.press": return .blue     // Action button
        case "wand.and.stars": return .indigo                // Cleanup
        case "arrow.uturn.backward": return .teal            // Spoken corrections
        case "text.badge.plus": return .orange               // Snippets
        case "cloud": return .cyan                           // Cloud cleanup
        // Sync and storage
        case "hand.raised", "lock.shield", "lock": return .blue   // Privacy
        case "icloud", "icloud.slash": return .cyan          // iCloud sync
        case "square.and.arrow.down": return .green          // Export everything
        case "trash": return .gray                           // Delete all data (a red title, a gray square)
        // Support, features, and the rest
        case "square.and.arrow.up": return .blue             // Share Verbose
        case "lightbulb": return .yellow                     // Thoughts
        case "doc.text": return .indigo                      // Templates
        case "questionmark.bubble": return .teal             // Ask
        case "envelope", "bubble.left": return .green        // Feedback
        case "star": return .yellow                          // Rate
        case "info.circle", "sparkles.rectangle.stack", "newspaper": return .gray  // About, What's new
        case "mic", "mic.fill": return .orange               // Microphone
        case "bookmark": return .blue                        // Moments
        case "switch.2": return .indigo                      // Controls
        case "record.circle": return .orange                 // Record (red stays with the record disc itself)
        case "play.rectangle", "play.circle": return .pink   // Videos, playback
        case "bolt.circle": return .yellow                   // Shortcuts
        case "tag", "pencil", "square.and.pencil": return .orange
        case "stethoscope", "checkmark", "plus.square.on.square", "arrow.triangle.2.circlepath": return .green
        case "speaker.wave.1", "bell": return .pink
        case "doc.on.clipboard": return .teal
        case "calendar": return .orange
        case "arrow.up.forward.app", "plus": return .blue
        case "server.rack", "eye.slash", "doc.plaintext", "clock": return .gray
        default: return .gray
        }
    }

    // MARK: This week

    /// Home's This week cell: "1,414 words" over "20 recordings · 25 min saved".
    static func weekDetail(recordings: Int, saved: String) -> String {
        "\(recordings == 1 ? "1 recording" : "\(recordings) recordings") · \(saved) saved"
    }
}
