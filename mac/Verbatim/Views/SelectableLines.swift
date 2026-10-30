import SwiftUI

/// The Original as one selectable text in the serif reading style (DESIGN.md §13), so you can select across lines and
/// copy with ⌘C. Times stay links that play from there; the playing passage keeps its wash and search matches theirs. Turned on with "Select text"
/// in the Original tab; the line view (corrections, notes, Copy quote) comes back when you turn it off.
struct SelectableLines: View {
    @EnvironmentObject var app: AppState
    var clock: PlayerClock
    var isPlaying: Bool
    var transcript: Transcript
    var segments: [Segment]
    var textSize: CGFloat
    /// Passages under the playhead as of the last tick; only a change re-renders the text.
    @State private var playingIDs: Set<UUID> = []

    static let seekScheme = "verbatim-seek"

    var body: some View {
        Text(attributed())
            .readingStyle(size: textSize)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.seekScheme, let s = Double(url.host ?? "") else { return .systemAction }
                app.player.seek(to: s)
                if !app.player.isPlaying { app.player.toggle() }
                return .handled
            })
            .accessibilityIdentifier("original-selectable")
            .onReceive(clock.$time) { now in sync(now) }
            .onChange(of: isPlaying) { _, _ in sync(clock.time) }
    }

    @MainActor private func sync(_ now: Double) {
        let ids = PlayingLines.ids(segments, at: now, isPlaying: isPlaying)
        if ids != playingIDs { playingIDs = ids }
    }

    /// Every line as "0:12  text", speaker names where the speaker changes, a blank line between speakers.
    private func attributed() -> AttributedString {
        var out = AttributedString()
        let multi = transcript.speakers.count >= 2
        for (i, s) in segments.enumerated() {
            let changed = multi && s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
            if i > 0 { out += AttributedString(changed ? "\n\n" : "\n") }
            if changed, let name = transcript.speakerName(s.speaker) {
                var n = AttributedString(name + "\n")
                n.font = .system(size: 13, weight: .semibold)
                n.foregroundColor = Refined.dim
                out += n
            }
            var tc = AttributedString(RefinedRules.time(s.start))
            tc.font = .system(size: 12.5).monospacedDigit()
            tc.foregroundColor = Refined.mute
            tc.link = URL(string: "\(Self.seekScheme)://\(s.start)")
            out += tc
            out += AttributedString("   ")
            var line = AttributedString(s.text)
            if playingIDs.contains(s.id) { line.backgroundColor = Refined.playing }
            out += ReadingHighlight.marked(line, query: app.search)
        }
        return out
    }
}
