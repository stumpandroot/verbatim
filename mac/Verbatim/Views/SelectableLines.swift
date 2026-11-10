import SwiftUI

/// The Original as one selectable text in the serif reading style (DESIGN.md §13), so you can select across lines and
/// copy with ⌘C. Times stay links that play from there; the playing passage keeps its wash and search (or find bar)
/// matches theirs. Turned on with "Select text"
/// in the Original tab; the line view (corrections, notes, Copy quote) comes back when you turn it off.
struct SelectableLines: View {
    @Environment(AppState.self) var app
    var clock: PlayerClock
    var isPlaying: Bool
    var transcript: Transcript
    var segments: [Segment]
    var textSize: CGFloat
    /// Passages under the playhead as of the last tick; only a change re-renders the text.
    @State private var playingIDs: Set<UUID> = []
    /// The whole text as last built, kept across renders: a change of the playing line rewashes only the lines that
    /// play, instead of rebuilding and searching every line again.
    @State private var built = BuiltText()
    /// The find bar's query while it's open (Views/TranscriptFind.swift): it marks the lines instead of the search, as
    /// it does in the line view (SegmentLine).
    @Environment(\.pageFindQuery) private var findQuery

    static let seekScheme = "verbatim-seek"

    var body: some View {
        Text(attributed(query: findQuery ?? app.search, minLength: findQuery == nil ? 2 : 1))
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

    /// Every line as "0:12  text", speaker names where the speaker changes, a blank line between speakers, matches in
    /// butter; the playing lines take the playing wash under their matches.
    private func attributed(query: String, minLength: Int) -> AttributedString {
        let key = contentKey(query: query, minLength: minLength)
        if built.key != key { built.build(segments, transcript: transcript, query: query, minLength: minLength, key: key) }
        guard !playingIDs.isEmpty else { return built.text }
        var out = built.text
        for id in playingIDs {
            for line in built.lines[id] ?? [] {
                // Offsets, not indexes, so each lookup is into the text as it stands; the same words go back washed.
                let lo = out.unicodeScalars.index(out.startIndex, offsetBy: line.start)
                let hi = out.unicodeScalars.index(lo, offsetBy: line.text.unicodeScalars.count)
                guard String(out[lo..<hi].characters) == line.text else { continue }
                var washed = AttributedString(line.text)
                washed.backgroundColor = Refined.playing
                out.replaceSubrange(lo..<hi, with: ReadingHighlight.marked(washed, query: query, minLength: minLength))
            }
        }
        return out
    }

    /// Everything the built text depends on besides the playing lines: each line's id, time, speaker, and words, the
    /// speakers' names, and the query. Hashing it costs far less than building the text.
    private func contentKey(query: String, minLength: Int) -> Int {
        var h = Hasher()
        h.combine(query); h.combine(minLength)
        h.combine(transcript.speakers.count)
        for sp in transcript.speakers { h.combine(sp.id); h.combine(sp.label) }
        h.combine(segments.count)
        for s in segments { h.combine(s.id); h.combine(s.start); h.combine(s.speaker); h.combine(s.text) }
        return h.finalize()
    }
}

/// SelectableLines' text without the playing wash, and where each line's words start in it (in Unicode scalars), so
/// the wash goes on the playing lines alone. A class kept in `@State`: building it during a render changes nothing a
/// view observes.
@MainActor
private final class BuiltText {
    struct Line {
        let start: Int
        let text: String
    }
    private(set) var key: Int?
    private(set) var text = AttributedString()
    private(set) var lines: [UUID: [Line]] = [:]

    func build(_ segments: [Segment], transcript: Transcript, query: String, minLength: Int, key: Int) {
        var out = AttributedString()
        var places: [UUID: [Line]] = [:]
        var at = 0
        func append(_ piece: AttributedString, _ plain: String) { out += piece; at += plain.unicodeScalars.count }
        let multi = transcript.speakers.count >= 2
        for (i, s) in segments.enumerated() {
            let changed = multi && s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
            if i > 0 { let gap = changed ? "\n\n" : "\n"; append(AttributedString(gap), gap) }
            if changed, let name = transcript.speakerName(s.speaker) {
                var n = AttributedString(name + "\n")
                n.font = .system(size: 13, weight: .semibold)
                n.foregroundColor = Refined.dim
                append(n, name + "\n")
            }
            let time = RefinedRules.time(s.start)
            var tc = AttributedString(time)
            tc.font = .system(size: 12.5).monospacedDigit()
            tc.foregroundColor = Refined.mute
            tc.link = URL(string: "\(SelectableLines.seekScheme)://\(s.start)")
            append(tc, time)
            append(AttributedString("   "), "   ")
            places[s.id, default: []].append(Line(start: at, text: s.text))
            append(ReadingHighlight.marked(AttributedString(s.text), query: query, minLength: minLength), s.text)
        }
        text = out
        lines = places
        self.key = key
    }
}
