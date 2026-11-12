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
    static func reset() { click = nil; highlight = nil; fix = nil }
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
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in clicked(p) }
            // Beside the text's own selection, never instead of it.
            .simultaneousGesture(DragGesture(minimumDistance: 4).onEnded { v in highlighted(from: v.startLocation, to: v.location) },
                                 including: Self.highlightSeeks ? .all : .subviews)
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

    private func clicked(_ p: CGPoint) {
        let now = Date()
        let second = lastClick.map {
            WordPick.isDoubleClick(sinceLast: now.timeIntervalSince($0.at), distance: Double(hypot(p.x - $0.point.x, p.y - $0.point.y)),
                                   interval: NSEvent.doubleClickInterval)
        } ?? false
        lastClick = second ? nil : (now, p)
        let words = WordPick.words(segment.text)
        let w = word(at: p, in: words)
        if second {
            // The second click of a double-click: Fix on that word. The first already moved the playhead.
            guard editable, let w, let phrase = WordPick.phrase(w, w, words: words, text: segment.text) else { return }
            fix(phrase, box.rect(of: words[w].coreRange))
            return
        }
        select()
        PhrasePick.shared.clear()
        let t = seek(w, words)
        WordPickProbe.click = (segment.start, w, t)
    }

    private func highlighted(from a: CGPoint, to b: CGPoint) {
        let words = WordPick.words(segment.text)
        guard let i = word(at: a, in: words), let j = word(at: b, in: words) else { return }
        let first = min(i, j), last = max(i, j)
        lastClick = nil
        seek(first, words)
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
