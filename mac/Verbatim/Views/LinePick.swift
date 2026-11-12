import SwiftUI
import AppKit

// Clicks, highlights, and double-clicks on a transcript line (November 12, 2026). A click or a highlight moves the
// playhead to the word under it (the start of the highlight) without starting playback; a double-click opens the Fix
// box on that word; a highlighted phrase can be fixed from the line's menu or with Return. The rules are in
// Model/WordPick.swift; this file finds the word under the pointer from the text as SwiftUI laid it out.

/// The phrase last highlighted in a line, for "Correct …" in the line's menu and for Return. One for the window: a
/// click on any line clears it.
@MainActor @Observable
final class PhrasePick {
    static let shared = PhrasePick()
    private(set) var segment: UUID?
    private(set) var text = ""
    /// Where the phrase sits in its line, for the Fix box's arrow.
    @ObservationIgnored private(set) var rect: CGRect?
    /// Return was pressed: the line with this id opens Fix on the phrase, then clears it.
    var request: UUID?

    func set(_ segment: UUID, _ text: String, rect: CGRect?) {
        self.rect = rect
        if self.segment != segment { self.segment = segment }
        if self.text != text { self.text = text }
    }

    func clear() {
        rect = nil
        if segment != nil { segment = nil }
        if !text.isEmpty { text = "" }
    }
}

/// What the last click, highlight, and Fix on a line came to, for the self-test.
@MainActor
enum WordPickProbe {
    static var click: (line: Double, word: Int?, time: Double)?
    static var highlight: (line: Double, first: Int, last: Int)?
    static var fix: String?
    /// How the last press was read: "selection", "pointer", or "tap".
    static var path: String?
    static func reset() { click = nil; highlight = nil; fix = nil; path = nil }
}

/// A line's text as laid out, kept for the next click. A class in `@State`: setting it during a render changes
/// nothing a view observes.
@MainActor
final class LineLayoutBox {
    private var layout: Text.Layout?
    private var origin: CGPoint = .zero

    func set(_ found: (Text.Layout, CGPoint)?) {
        layout = found?.0
        origin = found?.1 ?? .zero
    }

    /// The place in the text (a UTF-16 offset) of the glyph nearest `point`, in the text view's own space. nil
    /// before the text is laid out.
    func offset(at point: CGPoint) -> Int? {
        guard let layout else { return nil }
        let p = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        var base: Text.Layout.CharacterIndex?
        var best: (distance: CGFloat, index: Text.Layout.CharacterIndex)?
        for line in layout {
            let lr = line.typographicBounds.rect
            let dy = p.y < lr.minY ? lr.minY - p.y : (p.y > lr.maxY ? p.y - lr.maxY : 0)
            for run in line {
                for glyph in run {
                    guard let ci = glyph.characterIndices.first else { continue }
                    if let b = base { if ci < b { base = ci } } else { base = ci }
                    let r = glyph.typographicBounds.rect
                    let dx = p.x < r.minX ? r.minX - p.x : (p.x > r.maxX ? p.x - r.maxX : 0)
                    // The row first, then the glyph along it.
                    let d = dy * 10_000 + dx
                    if let b = best { if d < b.distance { best = (d, ci) } } else { best = (d, ci) }
                }
            }
        }
        guard let best, let base else { return nil }
        return Int(base.distance(to: best.index))
    }

    /// The box around the text at `range` (UTF-16 offsets), on the first row it's on, in the text view's own space.
    func rect(of range: Range<Int>) -> CGRect? {
        guard let layout else { return nil }
        var base: Text.Layout.CharacterIndex?
        for line in layout { for run in line { for glyph in run {
            guard let ci = glyph.characterIndices.first else { continue }
            if let b = base { if ci < b { base = ci } } else { base = ci }
        } } }
        guard let base else { return nil }
        for line in layout {
            var box: CGRect?
            for run in line {
                for glyph in run {
                    guard let ci = glyph.characterIndices.first, range.contains(Int(base.distance(to: ci))) else { continue }
                    let r = glyph.typographicBounds.rect
                    box = box.map { $0.union(r) } ?? r
                }
            }
            if let box { return box.offsetBy(dx: origin.x, dy: origin.y) }
        }
        return nil
    }
}

/// A press on a line's text, as the window saw it (`LineClickHub`).
struct LineHit {
    /// Where the press went down and where the pointer was when it ended, in the text's own space (top-left).
    var down: CGPoint
    var up: CGPoint
    var clicks: Int
    /// What the system's text selection held once the press ended: its text, and the selected range (UTF-16).
    var selection: (text: String, range: NSRange)?
}

/// Sits behind a line's text and gives the window's click watcher the line's place. Takes no clicks itself.
final class LineProbeView: NSView {
    var handler: ((LineHit) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { LineClickHub.shared.add(self) } else { LineClickHub.shared.remove(self) }
    }
}

struct LineProbe: NSViewRepresentable {
    var handler: (LineHit) -> Void
    func makeNSView(context: Context) -> LineProbeView { let v = LineProbeView(); v.handler = handler; return v }
    func updateNSView(_ v: LineProbeView, context: Context) { v.handler = handler }
}

/// Selectable text on the Mac is covered by the system's own selection view, which takes every press, so a SwiftUI
/// gesture on the text never fires (the self-test of November 12, 2026). This watches the window's presses instead,
/// lets each one through untouched, and tells the line under it once the press has ended, with what got selected.
@MainActor
final class LineClickHub {
    static let shared = LineClickHub()
    private let probes = NSHashTable<LineProbeView>.weakObjects()
    private var monitor: Any?
    /// Presses seen on a line, for the self-test.
    private(set) var seen = 0

    func add(_ v: LineProbeView) {
        probes.add(v)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { e in
            MainActor.assumeIsolated { LineClickHub.shared.saw(e) ? nil : e }
        }
    }

    func remove(_ v: LineProbeView) { probes.remove(v) }

    /// True when the event is used up here (only Return on a highlighted phrase).
    @discardableResult
    func saw(_ e: NSEvent) -> Bool {
        if e.type == .keyDown { return returnPressed(e) }
        guard e.type == .leftMouseDown, let window = e.window, let content = window.contentView else { return false }
        let at = e.locationInWindow
        // The view the press goes to: the selection view over one line's text, and nothing bigger (a sheet, the
        // stills viewer, the page itself).
        guard let hit = (content.superview ?? content).hitTest(at) else { return false }
        let hitRect = hit.convert(hit.bounds, to: nil)
        guard let probe = probes.allObjects.first(where: {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                && $0.convert($0.bounds, to: nil).insetBy(dx: -6, dy: -6).contains(hitRect) && $0.convert($0.bounds, to: nil).contains(at)
        }) else { return false }
        seen += 1
        let down = Self.local(at, in: probe)
        let clicks = e.clickCount
        // The selection view follows the press in a loop of its own; this runs when that loop is over.
        RunLoop.main.perform(inModes: [.default]) { [weak probe, weak hit, weak window] in
            MainActor.assumeIsolated {
                guard let probe, let window, probe.window === window else { return }
                let up = Self.local(window.mouseLocationOutsideOfEventStream, in: probe)
                let tv = (hit as? NSTextView) ?? (window.firstResponder as? NSTextView)
                let near = tv.map { $0.window === window && $0.convert($0.bounds, to: nil).intersects(probe.convert(probe.bounds, to: nil)) } ?? false
                let selection = near ? tv.map { (text: $0.string, range: $0.selectedRange()) } : nil
                probe.handler?(LineHit(down: down, up: up, clicks: clicks, selection: selection))
            }
        }
        return false
    }

    /// Return, with a phrase highlighted and the selection (not a field you type in) holding the keys: Fix on it.
    private func returnPressed(_ e: NSEvent) -> Bool {
        guard e.keyCode == 36, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let segment = PhrasePick.shared.segment, !PhrasePick.shared.text.isEmpty,
              let tv = e.window?.firstResponder as? NSTextView, !tv.isEditable else { return false }
        PhrasePick.shared.request = segment
        return true
    }

    private static func local(_ windowPoint: CGPoint, in v: NSView) -> CGPoint {
        let p = v.convert(windowPoint, from: nil)
        return v.isFlipped ? p : CGPoint(x: p.x, y: v.bounds.height - p.y)
    }
}

/// A transcript line's text, taking clicks and highlights (see the top of this file). `fix` opens the line's Fix box
/// on a word or phrase, with the box around it in the text's own space.
struct LinePick: ViewModifier {
    @Environment(AppState.self) var app
    var segment: Segment
    var editable: Bool
    var select: () -> Void
    var fix: (_ phrase: String, _ at: CGRect?) -> Void
    @State private var box = LineLayoutBox()
    @State private var lastClick: (at: Date, point: CGPoint)?

    /// Off (`defaults write … transcript.highlightSeeks -bool NO`), a highlight no longer moves the playhead; clicks
    /// and double-clicks still do their part.
    static var highlightSeeks: Bool { UserDefaults.standard.object(forKey: "transcript.highlightSeeks") as? Bool ?? true }

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geo in
                    let _ = box.set(layouts.first.map { ($0.layout, geo[$0.origin]) })
                    Color.clear
                }
            }
            // Presses on the text itself: the system's selection view takes them, so the window's watcher reports them.
            .background(LineProbe { hit in pressed(hit) })
            // Presses beside the text (the rest of the row's width), which no selection view covers.
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in tapped(p) }
    }

    private func word(at p: CGPoint, in words: [WordPick.Word]) -> Int? {
        box.offset(at: p).flatMap { WordPick.index(at: $0, in: words) }
    }

    /// Moves the playhead to the word (the line's start when the word isn't known). Playback stays as it was.
    @discardableResult
    private func seek(_ word: Int?, _ words: [WordPick.Word]) -> Double {
        let timed: [Double?] = PlaybackSync.timingIndex(segment).map { i in
            guard let i, let w = segment.words, w.indices.contains(i) else { return nil }
            return w[i].start
        }
        let t = WordPick.time(word: word ?? 0, words: words, timed: timed, lineStart: segment.start, lineEnd: segment.end,
                              duration: app.player.duration)
        // A hair inside the word, so the playhead reads as on it and not on the one before.
        app.player.seek(to: word == nil ? t : t + 0.01)
        return t
    }

    /// A press on the text has ended. What the system selected says what it was: nothing selected is a click, a
    /// range is a highlight, and a second click is a double-click. Without a selection to read, the pointer's
    /// places say it.
    private func pressed(_ hit: LineHit) {
        guard hit.clicks <= 2 else { return }
        let words = WordPick.words(segment.text)
        if let sel = hit.selection, sel.text == segment.text, sel.range.location != NSNotFound {
            WordPickProbe.path = "selection"
            let first = WordPick.index(at: sel.range.location, in: words)
            if hit.clicks == 2 { fixWord(first, words) }
            else if sel.range.length > 0, let first, let last = WordPick.index(at: sel.range.location + sel.range.length - 1, in: words) {
                highlighted(first, last, words)
            } else { clicked(first, words) }
            return
        }
        WordPickProbe.path = "pointer"
        if hit.clicks == 2 { fixWord(word(at: hit.down, in: words), words) }
        else if hypot(hit.up.x - hit.down.x, hit.up.y - hit.down.y) > 4, let i = word(at: hit.down, in: words), let j = word(at: hit.up, in: words) {
            highlighted(min(i, j), max(i, j), words)
        } else { clicked(word(at: hit.down, in: words), words) }
    }

    /// A click beside the text. The second of two close clicks is a double-click.
    private func tapped(_ p: CGPoint) {
        let now = Date()
        let second = lastClick.map {
            WordPick.isDoubleClick(sinceLast: now.timeIntervalSince($0.at), distance: Double(hypot(p.x - $0.point.x, p.y - $0.point.y)),
                                   interval: NSEvent.doubleClickInterval)
        } ?? false
        lastClick = second ? nil : (now, p)
        let words = WordPick.words(segment.text)
        WordPickProbe.path = "tap"
        if second { fixWord(word(at: p, in: words), words) } else { clicked(word(at: p, in: words), words) }
    }

    private func clicked(_ w: Int?, _ words: [WordPick.Word]) {
        select()
        PhrasePick.shared.clear()
        let t = seek(w, words)
        WordPickProbe.click = (segment.start, w, t)
    }

    /// The second click of a double-click: Fix on that word. The first already moved the playhead.
    private func fixWord(_ w: Int?, _ words: [WordPick.Word]) {
        guard editable, let w, let phrase = WordPick.phrase(w, w, words: words, text: segment.text) else { return }
        fix(phrase, box.rect(of: words[w].coreRange))
    }

    private func highlighted(_ first: Int, _ last: Int, _ words: [WordPick.Word]) {
        lastClick = nil
        if Self.highlightSeeks { seek(first, words) }
        WordPickProbe.highlight = (segment.start, first, last)
        if editable, let phrase = WordPick.phrase(first, last, words: words, text: segment.text) {
            PhrasePick.shared.set(segment.id, phrase, rect: box.rect(of: words[first].coreRange))
        } else {
            PhrasePick.shared.clear()
        }
    }
}

extension View {
    /// See `LinePick`.
    func linePick(segment: Segment, editable: Bool, select: @escaping () -> Void,
                  fix: @escaping (_ phrase: String, _ at: CGRect?) -> Void) -> some View {
        modifier(LinePick(segment: segment, editable: editable, select: select, fix: fix))
    }
}

/// "Correct “the phrase”…" at the top of a line's menu while a phrase is highlighted in that line. A view of its own,
/// so only menus read the phrase.
struct PickedPhraseItem: View {
    var segment: UUID
    var editable: Bool
    var pick: (_ phrase: String, _ at: CGRect?) -> Void

    var body: some View {
        let picked = PhrasePick.shared
        if editable, picked.segment == segment, !picked.text.isEmpty {
            Button("Correct “\(Self.label(picked.text))”…") { pick(picked.text, picked.rect) }
            Divider()
        }
    }

    /// The phrase for the menu, cut short when long.
    static func label(_ phrase: String) -> String {
        phrase.count > 40 ? String(phrase.prefix(38)) + "…" : phrase
    }
}
