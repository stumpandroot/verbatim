import Foundation

/// A click, a highlight, or a double-click on a transcript line, as pure rules (November 12, 2026): which word sits at
/// a place in the line's text, when that word was said, and the word or phrase a fix starts from. The Mac's line view
/// (Views/SegmentLine.swift) turns a pointer position into a place in the text and asks here; nothing here draws.
enum WordPick {
    /// A whitespace-separated word of a line: where it sits in the text (UTF-16 offsets, as the text layout counts)
    /// and its letters without the punctuation around it ("first," gives "first").
    struct Word: Equatable {
        var range: Range<Int>
        var text: String
        var core: String
        /// Where `core` sits in the text.
        var coreRange: Range<Int>
    }

    /// The line's words in order. Split as the playing-word highlight splits them (`PlaybackSync.wordRanges`), so a
    /// word's place here is its place there.
    static func words(_ text: String) -> [Word] {
        var out: [Word] = []
        var start: String.Index? = nil
        func close(_ s: String.Index, _ e: String.Index) {
            let piece = String(text[s..<e])
            let lo = text.utf16.distance(from: text.startIndex, to: s)
            let hi = text.utf16.distance(from: text.startIndex, to: e)
            let core = piece.trimmingCharacters(in: .punctuationCharacters)
            var coreRange = lo..<hi
            if !core.isEmpty, let r = piece.range(of: core) {
                let a = piece.utf16.distance(from: piece.startIndex, to: r.lowerBound)
                coreRange = (lo + a)..<(lo + a + core.utf16.count)
            }
            out.append(Word(range: lo..<hi, text: piece, core: core, coreRange: coreRange))
        }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                if let s = start { close(s, i); start = nil }
            } else if start == nil {
                start = i
            }
            i = text.index(after: i)
        }
        if let s = start { close(s, text.endIndex) }
        return out
    }

    /// The word at a place in the text: the one that holds it, or the nearest when the place is a space or past the
    /// end. nil only when the line has no words.
    static func index(at offset: Int, in words: [Word]) -> Int? {
        guard !words.isEmpty else { return nil }
        if let i = words.firstIndex(where: { $0.range.contains(offset) }) { return i }
        func gap(_ w: Word) -> Int { offset < w.range.lowerBound ? w.range.lowerBound - offset : offset - (w.range.upperBound - 1) }
        return words.indices.min { gap(words[$0]) < gap(words[$1]) }
    }

    /// When word `i` was said. `timed` holds each word's start where the line's word timings are fresh (nil where a
    /// word has none); without one, the moment is read off the word's place between the line's start and end. Kept
    /// inside the line, and inside the recording when its length is known.
    static func time(word i: Int, words: [Word], timed: [Double?], lineStart: Double, lineEnd: Double, duration: Double) -> Double {
        let start = lineStart.isFinite ? max(0, lineStart) : 0
        let end = lineEnd.isFinite && lineEnd > start ? lineEnd : start
        var t = start
        if words.indices.contains(i) {
            if i < timed.count, let known = timed[i], known.isFinite {
                t = known
            } else if i > 0, let total = words.last?.range.upperBound, total > 0 {
                t = start + (end - start) * Double(words[i].range.lowerBound) / Double(total)
            }
        }
        t = min(max(t, start), max(start, end))
        return duration > 0 ? min(t, max(0, duration - 0.05)) : t
    }

    /// The words from `first` through `last` as one phrase to fix: the text between them as shown, without the
    /// punctuation at either end. nil when there's nothing but punctuation.
    static func phrase(_ first: Int, _ last: Int, words: [Word], text: String) -> String? {
        let a = min(first, last), b = max(first, last)
        guard words.indices.contains(a), words.indices.contains(b) else { return nil }
        guard let lo = (a...b).first(where: { !words[$0].core.isEmpty }),
              let hi = (a...b).last(where: { !words[$0].core.isEmpty }) else { return nil }
        let u = text.utf16
        guard let s = u.index(u.startIndex, offsetBy: words[lo].coreRange.lowerBound, limitedBy: u.endIndex),
              let e = u.index(u.startIndex, offsetBy: words[hi].coreRange.upperBound, limitedBy: u.endIndex), s < e,
              let out = String(u[s..<e]) else { return nil }
        return out
    }

    /// Two clicks make a double-click when the second lands soon after the first and close to it.
    static func isDoubleClick(sinceLast seconds: Double, distance: Double, interval: Double) -> Bool {
        seconds >= 0 && seconds <= interval && distance <= 6
    }
}
