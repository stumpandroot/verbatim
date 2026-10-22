import SwiftUI

/// The Original as one selectable text, so you can select across lines and copy with ⌘C. Timecodes stay links that
/// play from there; the playing passage keeps its tint and search matches keep theirs. Turned on with "Select text"
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
            .font(.system(size: textSize)).lineSpacing(textSize * 0.3).foregroundStyle(Ink.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
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
        let ids = TranscriptLines.playing(segments, at: now, isPlaying: isPlaying)
        if ids != playingIDs { playingIDs = ids }
    }

    /// Every line as "00:12  text", speaker names where the speaker changes, a blank line between speakers.
    private func attributed() -> AttributedString {
        var out = AttributedString()
        let multi = transcript.speakers.count >= 2
        let q = app.search.trimmingCharacters(in: .whitespaces)
        for (i, s) in segments.enumerated() {
            let changed = multi && s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
            if i > 0 { out += AttributedString(changed ? "\n\n" : "\n") }
            if changed, let name = transcript.speakerName(s.speaker) {
                var n = AttributedString(name + "\n")
                n.font = .system(size: 13, weight: .semibold)
                n.foregroundColor = Ink.dim
                out += n
            }
            var tc = AttributedString(s.start.timecode)
            tc.font = .system(size: 11.5, design: .monospaced)
            tc.foregroundColor = Ink.mute
            tc.link = URL(string: "\(Self.seekScheme)://\(s.start)")
            out += tc
            out += AttributedString("   ")
            var line = AttributedString(s.text)
            if playingIDs.contains(s.id) { line.backgroundColor = Ink.irisTint }
            if q.count >= 2 {
                var from = line.startIndex
                while from < line.endIndex, let r = line[from...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                    line[r].backgroundColor = Ink.coral.opacity(0.28)
                    from = r.upperBound
                }
            }
            out += line
        }
        return out
    }
}
