import Foundation

/// Where one correction sits in its passage: a UTF-16 range in the passage's corrected text, and the exact text the
/// engine had there. Undo puts `heard` back at that range and nowhere else, so a word that was already in the
/// passage (even one identical to the fix) is never touched.
struct CorrectionSpan: Codable, Equatable {
    var location: Int
    var length: Int
    var heard: String

    var range: NSRange { NSRange(location: location, length: length) }
    /// A span whose text was changed by a later, overlapping edit. Undo looks for the fix near where it was.
    var isStale: Bool { location < 0 }
}

/// One replacement in a passage's text: `range` in the text before the edit, and the length of what replaced it.
struct TextEdit {
    var range: NSRange
    var newLength: Int
    var delta: Int { newLength - range.length }
}

extension Correction {
    /// Moves this correction's spans to follow edits made elsewhere in the same passage. `edits` are in the
    /// coordinates of the text before them, sorted by location and not overlapping. A span an edit overlaps is
    /// marked stale.
    mutating func shift(by edits: [TextEdit]) {
        guard var list = spans, !edits.isEmpty else { return }
        for k in list.indices where !list[k].isStale {
            let r = list[k].range
            var delta = 0
            var hit = false
            for e in edits {
                if NSMaxRange(e.range) <= r.location { delta += e.delta }
                else if e.range.location >= NSMaxRange(r) { continue }
                else { hit = true }
            }
            list[k].location = hit ? -1 : r.location + delta
        }
        spans = list
    }
}

/// Exact, reversible corrections: every fix records where it went, and Undo restores exactly that.
enum CorrectionEdits {
    /// Ranges (UTF-16) of whole-word occurrences of `word` in `text`. Case-sensitive unless `ignoringCase`.
    static func wordRanges(of word: String, in text: String, ignoringCase: Bool = false) -> [NSRange] {
        guard !word.isEmpty else { return [] }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : []) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// Replaces `ranges` of `segments[i]` with `to`, records one correction holding a span per replacement, and
    /// shifts the spans of corrections already in that passage. Ranges that overlap, fall outside the text, or
    /// already read `to` are skipped. Returns the new correction, or nil when nothing changed.
    @discardableResult
    static func apply(_ ranges: [NSRange], in segments: inout [Segment], at i: Int, to: String, label from: String,
                      byDictionary: Bool, corrections: inout [Correction]) -> Correction? {
        guard segments.indices.contains(i) else { return nil }
        let text = segments[i].text
        let ns = text as NSString
        var chosen: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            guard r.location >= 0, r.length > 0, NSMaxRange(r) <= ns.length else { continue }
            if let last = chosen.last, NSMaxRange(last) > r.location { continue }
            if ns.substring(with: r) == to { continue }
            chosen.append(r)
        }
        guard !chosen.isEmpty else { return nil }
        let toLength = (to as NSString).length
        let out = NSMutableString(string: text)
        for r in chosen.reversed() { out.replaceCharacters(in: r, with: to) }
        var spans: [CorrectionSpan] = []
        var delta = 0
        for r in chosen {
            spans.append(CorrectionSpan(location: r.location + delta, length: toLength, heard: ns.substring(with: r)))
            delta += toLength - r.length
        }
        let edits = chosen.map { TextEdit(range: $0, newLength: toLength) }
        let sid = segments[i].id
        for j in corrections.indices where corrections[j].segmentId == sid { corrections[j].shift(by: edits) }
        segments[i].text = out as String
        let c = Correction(segmentId: sid, from: from, to: to, byDictionary: byDictionary, spans: spans)
        corrections.append(c)
        return c
    }

    /// The edits that undo `c` in `text`: each span's range back to what the engine heard. Spans moved by an
    /// overlapping edit look for the fix nearest to where it was. Corrections from builds before spans use the
    /// engine's own words for the passage (`original`) to find the right places.
    static func undoEdits(_ c: Correction, text: String, original: String?, onlyCorrection: Bool) -> [(range: NSRange, with: String)] {
        let ns = text as NSString
        if let spans = c.spans {
            var out: [(range: NSRange, with: String)] = []
            for s in spans {
                let r = s.range
                if !s.isStale, NSMaxRange(r) <= ns.length, ns.substring(with: r) == c.to {
                    out.append((r, s.heard))
                } else {
                    let taken = out.map(\.range)
                    let near = wordRanges(of: c.to, in: text)
                        .filter { cand in !taken.contains { NSIntersectionRange($0, cand).length > 0 } }
                        .min { abs($0.location - max(0, s.location)) < abs($1.location - max(0, s.location)) }
                    if let near { out.append((near, s.heard)) }
                }
            }
            return out
        }
        // Older corrections, which kept only the words. With nothing else changed in the passage, the engine's text
        // is the exact answer.
        if onlyCorrection, let original { return [(NSRange(location: 0, length: ns.length), original)] }
        let found = wordRanges(of: c.to, in: text)
        guard !found.isEmpty else { return [] }
        if let original {
            // Same number of words: put back the engine's word wherever the fix now stands and the engine said
            // something else.
            let cur = tokens(text), orig = tokens(original)
            if cur.count == orig.count, !c.to.contains(where: { $0.isWhitespace }) {
                var out: [(range: NSRange, with: String)] = []
                for (a, b) in zip(cur, orig) where a.core == c.to && b.core != c.to { out.append((a.coreRange, b.core)) }
                if !out.isEmpty { return out }
            }
            // The engine never said the fixed word: every occurrence came from this fix.
            if wordRanges(of: c.to, in: original).isEmpty { return found.map { ($0, c.from) } }
            // Otherwise only the last one, so words that were there before stay.
            return [(found[found.count - 1], c.from)]
        }
        return found.map { ($0, c.from) }
    }

    private struct Token { var core: String; var coreRange: NSRange }

    /// Whitespace-separated words, each with its letters and digits core (edge punctuation dropped).
    private static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        var loc = 0
        for piece in text.components(separatedBy: .whitespacesAndNewlines) {
            let len = (piece as NSString).length
            defer { loc += len + 1 }
            guard len > 0 else { continue }
            let core = piece.trimmingCharacters(in: edge)
            guard !core.isEmpty else { continue }
            let inner = (piece as NSString).range(of: core)
            out.append(Token(core: core, coreRange: NSRange(location: loc + inner.location, length: inner.length)))
        }
        return out
    }
}

extension Transcript {
    /// A correction made by hand: every whole-word `from` in the passage becomes `to`, recorded so Undo restores
    /// exactly those words.
    mutating func correct(segment sid: UUID, from: String, to: String) {
        guard let i = segments.firstIndex(where: { $0.id == sid }) else { return }
        var ranges = CorrectionEdits.wordRanges(of: from, in: segments[i].text)
        if ranges.isEmpty {
            // Not a whole word (part of a longer one): the first place it appears.
            let r = (segments[i].text as NSString).range(of: from)
            if r.location != NSNotFound { ranges = [r] }
        }
        CorrectionEdits.apply(ranges, in: &segments, at: i, to: to, label: from, byDictionary: false, corrections: &corrections)
    }

    /// Undoes one correction exactly: what the engine heard goes back where the fix was, other corrections in the
    /// passage move with the text, and the correction leaves the list.
    mutating func undo(_ c: Correction) {
        let current = corrections.first { $0.id == c.id } ?? c
        defer { corrections.removeAll { $0.id == c.id } }
        guard let i = segments.firstIndex(where: { $0.id == current.segmentId }) else { return }
        let sid = segments[i].id
        let text = segments[i].text
        let engine = original.first { $0.id == sid }?.text
        let alone = !corrections.contains { $0.segmentId == sid && $0.id != current.id }
        let edits = CorrectionEdits.undoEdits(current, text: text, original: engine, onlyCorrection: alone)
            .sorted { $0.range.location < $1.range.location }
        guard !edits.isEmpty else { return }
        var kept: [(range: NSRange, with: String)] = []
        for e in edits where kept.last.map({ NSMaxRange($0.range) <= e.range.location }) ?? true { kept.append(e) }
        let out = NSMutableString(string: text)
        for e in kept.reversed() { out.replaceCharacters(in: e.range, with: e.with) }
        let shifts = kept.map { TextEdit(range: $0.range, newLength: ($0.with as NSString).length) }
        for j in corrections.indices where corrections[j].segmentId == sid && corrections[j].id != current.id { corrections[j].shift(by: shifts) }
        segments[i].text = out as String
    }

    /// The engine's lines for the given lines (same ids), for "Show engine words". Speakers follow the shown lines,
    /// since naming and moving speakers isn't a change to the words. Lines the engine has no record of show as
    /// they are.
    func engineLines(for shown: [Segment]) -> [Segment] {
        guard !original.isEmpty else { return shown }
        let byId = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return shown.map { s in
            guard var e = byId[s.id] else { return s }
            e.speaker = s.speaker
            return e
        }
    }

    /// True when the engine's words are stored for this transcript.
    var hasEngineWords: Bool { !original.isEmpty }
}
