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
/// lines). The layout itself runs in short slices between turns of the main thread, so opening a long meeting, typing
/// in the find bar, and resizing the window don't hold the app either; the first time, the text grows from the top.
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
        var timeStyle = body
        timeStyle[.font] = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        timeStyle[.foregroundColor] = NSColor(Refined.mute)
        let began = Date()
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
                out.addAttributes([.backgroundColor: butter, .foregroundColor: onFill], range: NSRange(location: at + r.location, length: r.length))
                from = r.location + r.length
            }
        }
        text = out
        lines = places
        self.key = key
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        if ms >= 50 { Log.note("select text: built \(segments.count) lines in \(ms) ms") }
    }
}

/// The text view under SelectableLines: read-only, selectable, as wide as it's given and as tall as its text (the
/// transcript's scroll view scrolls it). The playing wash is a temporary attribute, which repaints those lines without
/// laying the text out again; it leaves search matches in their butter.
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
        // The width is set by hand (Coordinator.layOut): tracking the view would make the container zero wide before
        // SwiftUI places the view, and anything that asked for layout then would break the text one glyph to a line.
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
            c.layOut(v)
        }
        c.onSeek = onSeek
        c.onHeight = onHeight
        apply(to: v, c)
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.onHeight = onHeight
        apply(to: v, context.coordinator)
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

    private func apply(to v: NSTextView, _ c: Coordinator) {
        guard let layout = v.layoutManager else { return }
        if c.key != built.key {
            let began = Date()
            v.textStorage?.setAttributedString(built.text)
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            if ms >= 50 { Log.note("select text: set \(built.text.length) characters in \(ms) ms") }
            c.key = built.key
            c.washed = []
        }
        c.layOut(v)
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSeek: (Double) -> Void = { _ in }
        var onHeight: (CGFloat) -> Void = { _ in }
        /// The built text now in the view, and the lines that carry the wash.
        var key: Int?
        var washed: Set<UUID> = []
        var washedKey: Int?
        /// The text and width the layout is running for (or ran for), and whether a whole layout has finished once.
        var laidKey: Int?
        var laidWidth: CGFloat = 0
        var measured = false
        var task: Task<Void, Never>?
        /// When the view was made, for the log line on how long SwiftUI took to give it a width.
        let made = Date()

        /// Lays the text out in slices of about 20 ms with the main thread free between them, then reports the height.
        /// The first time, the height is reported as it grows, so the text appears from the top; after that (a new
        /// width, or new words or matches) the old height stays until the new one is known, which keeps your place.
        func layOut(_ v: NSTextView) {
            let width = v.frame.width
            guard width >= 1, key != laidKey || abs(width - laidWidth) > 0.5 else { return }
            guard let layout = v.layoutManager, let container = v.textContainer, let storage = v.textStorage else { return }
            if laidKey == nil {
                let ms = Int(Date().timeIntervalSince(made) * 1000)
                if ms >= 100 { Log.note("select text: first width \(Int(width)) after \(ms) ms") }
            }
            laidKey = key
            laidWidth = width
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            task?.cancel()
            let total = storage.length
            let growing = !measured
            let began = Date()
            task = Task { @MainActor [weak self] in
                var at = 0
                var reported = Date.distantPast
                while at < total {
                    let slice = Date()
                    while at < total, Date().timeIntervalSince(slice) < 0.02 {
                        let n = min(4_000, total - at)
                        layout.ensureLayout(forCharacterRange: NSRange(location: at, length: n))
                        at += n
                    }
                    if growing, at < total, Date().timeIntervalSince(reported) > 0.12 {
                        reported = Date()
                        self?.onHeight(ceil(layout.usedRect(for: container).height))
                    }
                    try? await Task.sleep(nanoseconds: 4_000_000)
                    if Task.isCancelled || storage.length != total { return }
                }
                layout.ensureLayout(for: container)
                self?.measured = true
                self?.onHeight(ceil(layout.usedRect(for: container).height))
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                if ms >= 100 { Log.note("select text: laid out \(total) characters in \(ms) ms at width \(Int(width))") }
            }
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
