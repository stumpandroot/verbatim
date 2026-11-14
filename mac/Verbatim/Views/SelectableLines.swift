#if os(macOS)
import SwiftUI
import AppKit

/// The Original as one selectable text in the serif reading style (DESIGN.md §13), so you can select across lines and
/// copy with ⌘C. Times stay links that play from there; the playing passage keeps its wash and search (or find bar)
/// matches theirs. Turned on with "Select text"
/// in the Original tab; the line view (corrections, notes, Copy quote) comes back when you turn it off.
///
/// One text view, laid out once: the playing wash is painted over the lines that play without touching the text, so a
/// long meeting doesn't lay out again each time the playing line moves (as one SwiftUI `Text` did, for 1.5 s to 2.8 s
/// at 4,000 lines).
struct SelectableLines: View {
    @Environment(AppState.self) var app
    var clock: PlayerClock
    var isPlaying: Bool
    var transcript: Transcript
    var segments: [Segment]
    var textSize: CGFloat
    /// Passages under the playhead as of the last tick; only a change repaints the wash.
    @State private var playingIDs: Set<UUID> = []
    /// The whole text as last built, kept across renders.
    @State private var built = BuiltText()
    /// The find bar's query while it's open (Views/TranscriptFind.swift): it marks the lines instead of the search, as
    /// it does in the line view (SegmentLine).
    @Environment(\.pageFindQuery) private var findQuery

    static let seekScheme = "verbatim-seek"

    var body: some View {
        SelectableTextView(built: text(query: findQuery ?? app.search, minLength: findQuery == nil ? 2 : 1), playing: playingIDs) { s in
            app.player.seek(to: s)
            if !app.player.isPlaying { app.player.toggle() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("original-selectable")
        .onReceive(clock.$time) { now in sync(now) }
        .onChange(of: isPlaying) { _, _ in sync(clock.time) }
    }

    @MainActor private func sync(_ now: Double) {
        let ids = PlayingLines.ids(segments, at: now, isPlaying: isPlaying)
        if ids != playingIDs { playingIDs = ids }
    }

    /// Every line as "0:12  text", speaker names where the speaker changes, a blank line between speakers, matches in
    /// butter. Built again only when its words, names, query, or size change.
    private func text(query: String, minLength: Int) -> BuiltText {
        let key = contentKey(query: query, minLength: minLength)
        if built.key != key {
            built.build(segments, transcript: transcript, query: query, minLength: minLength, size: textSize, key: key)
        }
        return built
    }

    /// Everything the built text depends on: each line's id, time, speaker, and words, the speakers' names, the query,
    /// and the text size. Hashing it costs far less than building the text.
    private func contentKey(query: String, minLength: Int) -> Int {
        var h = Hasher()
        h.combine(query); h.combine(minLength); h.combine(textSize)
        h.combine(transcript.speakers.count)
        for sp in transcript.speakers { h.combine(sp.id); h.combine(sp.label) }
        h.combine(segments.count)
        for s in segments { h.combine(s.id); h.combine(s.start); h.combine(s.speaker); h.combine(s.text) }
        return h.finalize()
    }
}

/// SelectableLines' text, and where each line's words are in it (UTF-16, as the text view counts), so the wash goes on
/// the playing lines alone. A class kept in `@State`: building it during a render changes nothing a view observes.
@MainActor
final class BuiltText {
    private(set) var key: Int?
    private(set) var text = NSAttributedString()
    private(set) var lines: [UUID: [NSRange]] = [:]

    func build(_ segments: [Segment], transcript: Transcript, query: String, minLength: Int, size: CGFloat, key: Int) {
        let base = RefinedRules.TextRole.reading.size(mac: RefinedPlatform.mac)
        let spacing = RefinedRules.lineSpacing(.reading, mac: RefinedPlatform.mac) / base
        let para = NSMutableParagraphStyle()
        para.lineSpacing = size * CGFloat(spacing)
        let plain = NSFont.systemFont(ofSize: size)
        let serif = plain.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? plain
        let body: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: NSColor(Refined.ink), .paragraphStyle: para]
        let nameStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                        .foregroundColor: NSColor(Refined.dim), .paragraphStyle: para]
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        let butter = NSColor(Refined.badge(.butter)), onFill = NSColor(Refined.onFill)
        let q = query.trimmingCharacters(in: .whitespaces)
        let marks = q.count >= max(1, minLength)

        let out = NSMutableAttributedString()
        var places: [UUID: [NSRange]] = [:]
        let multi = transcript.speakers.count >= 2
        for (i, s) in segments.enumerated() {
            let changed = multi && s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
            if i > 0 { out.append(NSAttributedString(string: changed ? "\n\n" : "\n", attributes: body)) }
            if changed, let name = transcript.speakerName(s.speaker) {
                out.append(NSAttributedString(string: name + "\n", attributes: nameStyle))
            }
            var time = body
            time[.font] = timeFont
            time[.foregroundColor] = NSColor(Refined.mute)
            if let url = URL(string: "\(SelectableLines.seekScheme)://\(s.start)") { time[.link] = url }
            out.append(NSAttributedString(string: RefinedRules.time(s.start), attributes: time))
            out.append(NSAttributedString(string: "   ", attributes: body))
            let words = s.text as NSString
            let at = out.length
            out.append(NSAttributedString(string: s.text, attributes: body))
            places[s.id, default: []].append(NSRange(location: at, length: words.length))
            guard marks else { continue }
            var from = 0
            while from < words.length {
                let r = words.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: words.length - from))
                guard r.location != NSNotFound, r.length > 0 else { break }
                out.addAttributes([.backgroundColor: butter, .foregroundColor: onFill], range: NSRange(location: at + r.location, length: r.length))
                from = r.location + r.length
            }
        }
        text = out
        lines = places
        self.key = key
    }
}

/// The text view under SelectableLines: read-only, selectable, as tall as its text at the width it's given (the
/// transcript's scroll view scrolls it). The playing wash is a temporary attribute, which repaints those lines without
/// laying the text out again; it leaves search matches in their butter.
private struct SelectableTextView: NSViewRepresentable {
    var built: BuiltText
    var playing: Set<UUID>
    var onSeek: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, set up by hand: temporary attributes and one full layout for the height.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let v = NSTextView(frame: .zero, textContainer: container)
        v.isEditable = false
        v.isSelectable = true
        v.isRichText = true
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.isAutomaticLinkDetectionEnabled = false
        v.linkTextAttributes = [.foregroundColor: NSColor(Refined.mute), .cursor: NSCursor.pointingHand]
        v.delegate = context.coordinator
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.onSeek = onSeek
        apply(to: v, context.coordinator)
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        context.coordinator.onSeek = onSeek
        apply(to: v, context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: NSTextView, context: Context) -> CGSize? {
        let c = context.coordinator
        var w = proposal.width ?? c.width ?? 600
        if !w.isFinite || w < 1 { w = c.width ?? 600 }
        guard let layout = v.layoutManager, let container = v.textContainer else { return CGSize(width: w, height: 0) }
        if c.width != w || c.sizedKey != c.key {
            container.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            c.height = ceil(layout.usedRect(for: container).height)
            c.width = w
            c.sizedKey = c.key
        }
        return CGSize(width: w, height: c.height)
    }

    private func apply(to v: NSTextView, _ c: Coordinator) {
        guard let layout = v.layoutManager else { return }
        if c.key != built.key {
            v.textStorage?.setAttributedString(built.text)
            c.key = built.key
            c.washed = []
            v.invalidateIntrinsicContentSize()
        }
        guard c.washed != playing || c.washedKey != c.key else { return }
        let length = v.textStorage?.length ?? 0
        for id in c.washed {
            for r in built.lines[id] ?? [] where NSMaxRange(r) <= length { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
        }
        let wash = NSColor(Refined.playing)
        for id in playing {
            for r in built.lines[id] ?? [] where NSMaxRange(r) <= length {
                // Around the matches: a temporary attribute would paint over their butter.
                v.textStorage?.enumerateAttribute(.backgroundColor, in: r) { value, part, _ in
                    if value == nil { layout.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: part) }
                }
            }
        }
        c.washed = playing
        c.washedKey = c.key
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSeek: (Double) -> Void = { _ in }
        /// The built text now in the view, and the lines that carry the wash.
        var key: Int?
        var washed: Set<UUID> = []
        var washedKey: Int?
        /// The last measured size: the height of `sizedKey`'s text at `width`.
        var width: CGFloat?
        var height: CGFloat = 0
        var sizedKey: Int?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == SelectableLines.seekScheme, let s = Double(url.host ?? "") else { return false }
            onSeek(s)
            return true
        }
    }
}
#endif
