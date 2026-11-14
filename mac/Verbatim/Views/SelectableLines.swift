#if os(macOS)
import SwiftUI
import AppKit

/// The Original as one selectable text in the serif reading style (DESIGN.md §13), so you can select across lines and
/// copy with ⌘C. Times stay links that play from there; the playing passage keeps its wash and search (or find bar)
/// matches theirs. Turned on with "Select text"
/// in the Original tab; the line view (corrections, notes, Copy quote) comes back when you turn it off.
///
/// One text view: the playing wash is painted over the lines that play without touching the text, so a long meeting
/// doesn't lay out again each time the playing line moves (as one SwiftUI `Text` did, for 1.5 s to 2.8 s at 4,000
/// lines). Matches are painted the same way, so typing in the find bar doesn't lay it out either. The text goes into
/// the view a stretch at a time between turns of the main thread, each stretch laid out as it arrives: a long meeting
/// grows from the top for a few seconds instead of holding the app (given all at once, AppKit laid the whole text out
/// the moment the view went on screen, 4 s at 4,000 lines).
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
    /// The text's height as laid out so far (SelectableTextView reports it).
    @State private var height: CGFloat = 0
    /// The find bar's query while it's open (Views/TranscriptFind.swift): it marks the lines instead of the search, as
    /// it does in the line view (SegmentLine).
    @Environment(\.pageFindQuery) private var findQuery

    static let seekScheme = "verbatim-seek"

    var body: some View {
        SelectableTextView(built: text(query: findQuery ?? app.search, minLength: findQuery == nil ? 2 : 1), playing: playingIDs,
                           onHeight: { h in if abs(h - height) > 0.5 { height = h } }) { s in
            app.player.seek(to: s)
            if !app.player.isPlaying { app.player.toggle() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(height, 1))
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
        let textKey = contentKey()
        var h = Hasher()
        h.combine(textKey); h.combine(query); h.combine(minLength)
        let key = h.finalize()
        if built.key != key {
            built.build(segments, transcript: transcript, query: query, minLength: minLength, size: textSize, key: key, textKey: textKey)
        }
        return built
    }

    /// Everything the text itself depends on: each line's id, time, speaker, and words, the speakers' names, and the
    /// text size (not the query: matches are painted over the text). Hashing it costs far less than building the text.
    private func contentKey() -> Int {
        var h = Hasher()
        h.combine(textSize)
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
    /// `key` covers the text and the query; `textKey` the text alone (the same text with new matches keeps it).
    private(set) var key: Int?
    private(set) var textKey: Int?
    private(set) var text = NSAttributedString()
    private(set) var lines: [UUID: [NSRange]] = [:]
    /// Where the query matches, by line; painted over the text (SelectableTextView), not part of it.
    private(set) var marks: [UUID: [NSRange]] = [:]

    func build(_ segments: [Segment], transcript: Transcript, query: String, minLength: Int, size: CGFloat, key: Int, textKey: Int) {
        let base = RefinedRules.TextRole.reading.size(mac: RefinedPlatform.mac)
        let spacing = RefinedRules.lineSpacing(.reading, mac: RefinedPlatform.mac) / base
        let para = NSMutableParagraphStyle()
        para.lineSpacing = size * CGFloat(spacing)
        let plain = NSFont.systemFont(ofSize: size)
        let serif = plain.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? plain
        let body: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: NSColor(Refined.ink), .paragraphStyle: para]
        let nameStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                        .foregroundColor: NSColor(Refined.dim), .paragraphStyle: para]
        var timeStyle = body
        timeStyle[.font] = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        timeStyle[.foregroundColor] = NSColor(Refined.mute)
        let began = Date()
        let q = query.trimmingCharacters(in: .whitespaces)
        let marks = q.count >= max(1, minLength)

        let out = NSMutableAttributedString()
        var places: [UUID: [NSRange]] = [:]
        var found: [UUID: [NSRange]] = [:]
        let multi = transcript.speakers.count >= 2
        for (i, s) in segments.enumerated() {
            let changed = multi && s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
            if i > 0 { out.append(NSAttributedString(string: changed ? "\n\n" : "\n", attributes: body)) }
            if changed, let name = transcript.speakerName(s.speaker) {
                out.append(NSAttributedString(string: name + "\n", attributes: nameStyle))
            }
            var time = timeStyle
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
                found[s.id, default: []].append(NSRange(location: at + r.location, length: r.length))
                from = r.location + r.length
            }
        }
        text = out
        lines = places
        self.marks = found
        self.key = key
        self.textKey = textKey
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        if ms >= 50 { Log.note("select text: built \(segments.count) lines in \(ms) ms") }
    }
}

/// The text view under SelectableLines: read-only, selectable, as wide as it's given and as tall as its text (the
/// transcript's scroll view scrolls it). The playing wash and the matches are temporary attributes, which repaint those
/// lines without laying the text out again.
private struct SelectableTextView: NSViewRepresentable {
    var built: BuiltText
    var playing: Set<UUID>
    var onHeight: (CGFloat) -> Void
    var onSeek: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, set up by hand: temporary attributes, and layout asked for a stretch at a time.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        // The width is set by hand (Coordinator.setWidth), so the container is never zero wide before SwiftUI places
        // the view.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let v = WidthWatchingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), textContainer: container)
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
        let c = context.coordinator
        v.onWidth = { [weak v, weak c] _ in
            guard let v, let c else { return }
            c.setWidth(v)
        }
        c.onSeek = onSeek
        c.onHeight = onHeight
        c.show(built, playing: playing, in: v)
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.onHeight = onHeight
        context.coordinator.show(built, playing: playing, in: v)
    }

    /// The width SwiftUI offers and the height it already has (the frame around this view carries the measured
    /// height), so sizing never asks the text view to lay anything out.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 600
        let h = proposal.height ?? 1
        return CGSize(width: w.isFinite ? w : 600, height: h.isFinite ? h : 1)
    }

    static func dismantleNSView(_ v: NSTextView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSeek: (Double) -> Void = { _ in }
        var onHeight: (CGFloat) -> Void = { _ in }
        /// The text in the view (or on its way in), and where its lines and matches are.
        private var textKey: Int?
        private var key: Int?
        private var lines: [UUID: [NSRange]] = [:]
        private var marks: [UUID: [NSRange]] = [:]
        private var playing: Set<UUID> = []
        /// What's painted: the key its matches were painted for, and the lines that carry the wash.
        private var paintedKey: Int?
        private var washed: Set<UUID> = []
        /// True while the text is still going into the view.
        private var filling = false
        private var width: CGFloat = 600
        var task: Task<Void, Never>?

        /// About 20 ms of layout at 4,000 lines an hour of meeting.
        private static let stretch = 1_500

        func show(_ built: BuiltText, playing: Set<UUID>, in v: NSTextView) {
            self.playing = playing
            lines = built.lines
            marks = built.marks
            key = built.key
            if textKey != built.textKey {
                textKey = built.textKey
                fill(v, with: built.text)
            }
            paint(v)
        }

        /// Puts the text into the view a stretch at a time (whole paragraphs), laying each out as it arrives, with the
        /// main thread free between slices of about 20 ms. The height is reported as it grows. The text view never
        /// holds text it hasn't laid out, so nothing AppKit asks of it can lay the whole meeting out in one go.
        private func fill(_ v: NSTextView, with text: NSAttributedString) {
            guard let layout = v.layoutManager, let container = v.textContainer, let storage = v.textStorage else { return }
            task?.cancel()
            filling = true
            storage.setAttributedString(NSAttributedString())
            paintedKey = nil
            washed = []
            let mine = textKey
            let whole = text.string as NSString
            let total = whole.length
            let began = Date()
            task = Task { @MainActor [weak self, weak v] in
                var at = 0
                var reported = Date()
                while at < total {
                    let slice = Date()
                    while at < total, Date().timeIntervalSince(slice) < 0.02 {
                        let para = whole.paragraphRange(for: NSRange(location: at, length: min(Coordinator.stretch, total - at)))
                        let piece = NSRange(location: at, length: NSMaxRange(para) - at)
                        storage.append(text.attributedSubstring(from: piece))
                        layout.ensureLayout(forCharacterRange: piece)
                        at = NSMaxRange(piece)
                    }
                    if at < total, Date().timeIntervalSince(reported) > 0.12 {
                        reported = Date()
                        self?.onHeight(ceil(layout.usedRect(for: container).height))
                    }
                    try? await Task.sleep(nanoseconds: 4_000_000)
                    guard !Task.isCancelled, let self, self.textKey == mine else { return }
                }
                guard let self, let v else { return }
                self.filling = false
                self.onHeight(ceil(layout.usedRect(for: container).height))
                // The wash and the matches for lines that weren't in the view yet.
                self.paintedKey = nil
                self.paint(v)
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                if ms >= 100 { Log.note("select text: filled \(total) characters in \(ms) ms") }
            }
        }

        /// A new width: the lines break again. Laid out in slices, then the new height; until then the old height
        /// stays, which keeps your place. While the text is still going in, the fill lays it out at the new width.
        func setWidth(_ v: NSTextView) {
            let w = v.frame.width
            guard w >= 1, abs(w - width) > 0.5 else { return }
            guard let layout = v.layoutManager, let container = v.textContainer, let storage = v.textStorage else { return }
            width = w
            container.size = NSSize(width: w, height: .greatestFiniteMagnitude)
            guard !filling else { return }
            task?.cancel()
            let total = storage.length
            let mine = textKey
            task = Task { @MainActor [weak self] in
                var at = 0
                while at < total {
                    let slice = Date()
                    while at < total, Date().timeIntervalSince(slice) < 0.02 {
                        let n = min(Coordinator.stretch, total - at)
                        layout.ensureLayout(forCharacterRange: NSRange(location: at, length: n))
                        at += n
                    }
                    try? await Task.sleep(nanoseconds: 4_000_000)
                    guard !Task.isCancelled, let self, self.textKey == mine, storage.length == total else { return }
                }
                self?.onHeight(ceil(layout.usedRect(for: container).height))
            }
        }

        /// Paints the matches (butter) and the playing wash as temporary attributes: no layout. New matches repaint
        /// everything; a new playing line repaints the lines that changed. Lines not in the view yet are left for the
        /// end of the fill.
        private func paint(_ v: NSTextView) {
            guard let layout = v.layoutManager, let length = v.textStorage?.length, length > 0 else { return }
            let wash = NSColor(Refined.playing)
            let butter = NSColor(Refined.badge(.butter)), onFill = NSColor(Refined.onFill)
            func clear(_ id: UUID) {
                for r in lines[id] ?? [] where NSMaxRange(r) <= length {
                    layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
                    layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
                }
            }
            func mark(_ id: UUID) {
                for r in marks[id] ?? [] where NSMaxRange(r) <= length {
                    layout.addTemporaryAttributes([.backgroundColor: butter, .foregroundColor: onFill], forCharacterRange: r)
                }
            }
            func washLine(_ id: UUID) {
                for r in lines[id] ?? [] where NSMaxRange(r) <= length {
                    layout.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: r)
                }
                mark(id)
            }
            if paintedKey != key {
                let all = NSRange(location: 0, length: length)
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
                for id in marks.keys { mark(id) }
                for id in playing { washLine(id) }
                paintedKey = key
            } else if washed != playing {
                for id in washed.subtracting(playing) { clear(id); mark(id) }
                for id in playing.subtracting(washed) { washLine(id) }
            }
            washed = playing
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == SelectableLines.seekScheme, let s = Double(url.host ?? "") else { return false }
            onSeek(s)
            return true
        }
    }
}

/// Tells SelectableTextView when its width changes, which is when the lines have to be laid out again.
private final class WidthWatchingTextView: NSTextView {
    var onWidth: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = -1

    /// No size of its own: SwiftUI sets the frame, and asking must never force a layout.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - lastWidth) > 0.5 else { return }
        lastWidth = newSize.width
        onWidth?(newSize.width)
    }
}
#endif
