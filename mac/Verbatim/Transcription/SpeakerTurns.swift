import Foundation

/// Puts the diarizer's speaker turns onto transcript lines, word by word, for the Mac and the iPhone.
///
/// The diarizer's turn boundaries and the transcriber's lines don't line up: a line can hold the end of one
/// speaker's sentence and the start of the next speaker's, and a boundary often lands a word or two off
/// ("…for them legally as / Speaker 2: well."). So each word takes the speaker whose turn it falls in, then every
/// speaker change moves to the nearest sentence boundary (terminal punctuation) within `windowWords` words and
/// `windowSeconds` seconds:
/// - When the sentence the change falls inside ends within the window, that sentence stays with the speaker
///   before the change ("What would your response be?" is the host's, not the start of the guest's answer).
/// - Otherwise, when the sentence started within the window, the change moves back to its start.
/// - Text never moves across a pause longer than the window, and a change with no boundary in reach stays put.
/// Lines whose words change speaker are then split there; lines without word timings take the speaker who talks
/// for most of their span, as before. Pure Foundation, so mac/tools/test-speakers.sh runs it on Linux.
enum SpeakerTurns {
    typealias Turn = (speaker: String, start: Double, end: Double)

    static let windowSeconds = 1.5
    static let windowWords = 4

    /// Labels `segments` with speaker ids ("S1", "S2", … in order of appearance) from the diarizer's `turns`, and
    /// returns the diarizer labels in that order (`order[0]` became "S1").
    ///
    /// With `split`, a line whose words change speaker is cut where they do. `parallel` (the engine's original
    /// lines, matched to `segments` by index) gets the same labels and cuts; a line is only cut when its text is
    /// made of its words, both copies match, and its id isn't in `keepWhole` (lines with corrections). Nothing is
    /// cut, and `parallel` is left alone, when the two don't pair up.
    @discardableResult
    static func assign(_ turns: [Turn], to segments: inout [Segment], parallel: inout [Segment]?, split: Bool,
                       keepWhole: Set<UUID> = []) -> [String] {
        let paired = parallel.map { $0.count == segments.count } ?? false
        let split = split && (parallel == nil || paired)
        let partner = paired ? parallel! : []
        // Every word in time order, with where it came from.
        var words: [WordSpan] = []
        var owner: [(segment: Int, index: Int)] = []
        for (i, s) in segments.enumerated() {
            for (k, w) in (s.words ?? []).enumerated() { words.append(w); owner.append((i, k)) }
        }
        let labels = snapped(words, raw: rawLabels(words, turns: turns))
        var perSegment: [[String?]] = segments.map { Array(repeating: nil, count: $0.words?.count ?? 0) }
        for (n, o) in owner.enumerated() { perSegment[o.segment][o.index] = labels[n] }

        var outSegments: [Segment] = []
        var outParallel: [Segment] = []
        var order: [String] = []
        func id(_ label: String?) -> String? {
            guard let label else { return nil }
            if !order.contains(label) { order.append(label) }
            return "S\(order.firstIndex(of: label)! + 1)"
        }
        for (i, s) in segments.enumerated() {
            let wl = perSegment[i]
            let runs = runsOf(wl)
            let separator = joiner(s)
            let partnerOK = !paired || (partner[i].text == s.text && partner[i].id == s.id)
            if split, runs.count > 1, let separator, partnerOK, !keepWhole.contains(s.id), let ws = s.words {
                for (k, run) in runs.enumerated() {
                    let sub = Array(ws[run.range])
                    let label = id(run.label)
                    var piece = s
                    if k > 0 { piece.id = UUID() }
                    piece.start = k == 0 ? s.start : sub.first!.start
                    piece.end = k == runs.count - 1 ? s.end : sub.last!.end
                    piece.text = sub.map(\.text).joined(separator: separator)
                    piece.words = sub
                    if let label { piece.speaker = label }
                    outSegments.append(piece)
                    if paired {
                        var p = partner[i]
                        p.id = piece.id; p.start = piece.start; p.end = piece.end; p.text = piece.text; p.words = sub
                        if let label { p.speaker = label }
                        outParallel.append(p)
                    }
                }
                continue
            }
            var s = s
            let label: String?
            if !wl.isEmpty, wl.contains(where: { $0 != nil }) {
                label = majority(wl, words: s.words ?? [])
            } else {
                label = mostOverlap(s.start, s.end, turns)
            }
            if let l = id(label) { s.speaker = l }
            outSegments.append(s)
            if paired {
                var p = partner[i]
                if let l = id(label) { p.speaker = l }
                outParallel.append(p)
            }
        }
        segments = outSegments
        if paired { parallel = outParallel }
        return order
    }

    // MARK: Words

    /// Each word's speaker: the turn it overlaps most, else the nearest turn within the window, else nil.
    static func rawLabels(_ words: [WordSpan], turns: [Turn]) -> [String?] {
        words.map { w in
            if let best = mostOverlap(w.start, max(w.end, w.start + 0.01), turns) { return best }
            let mid = (w.start + w.end) / 2
            var nearest: (label: String, distance: Double)?
            for t in turns {
                let d = mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0)
                if d <= windowSeconds, nearest == nil || d < nearest!.distance { nearest = (t.speaker, d) }
            }
            return nearest?.label
        }
    }

    /// The labels with each speaker change moved to a sentence boundary (see the type's notes). Words the diarizer
    /// left unlabeled take the speaker before them (or after, at the start).
    static func snapped(_ words: [WordSpan], raw: [String?]) -> [String?] {
        var m = raw
        // Fill the gaps first, so changes are only between real labels.
        var last: String?
        for i in m.indices { if let l = m[i] { last = l } else { m[i] = last } }
        if let first = m.firstIndex(where: { $0 != nil }) { for i in 0..<first { m[i] = m[first] } }
        let n = words.count
        guard n > 1 else { return m }
        var i = 1
        while i < n {
            guard m[i] != m[i - 1] else { i += 1; continue }
            let target = snapTarget(words, m, at: i)
            if target < i {
                for k in target..<i { m[k] = m[i] }
            } else if target > i {
                let previous = m[i - 1]
                for k in i..<target { m[k] = previous }
            }
            i = max(i, target) + 1
        }
        return m
    }

    /// Where the change at word `i` (the first word of the new speaker) should be.
    private static func snapTarget(_ w: [WordSpan], _ m: [String?], at i: Int) -> Int {
        if endsSentence(w[i - 1].text) { return i }
        // The runs on either side: text only moves within them.
        var prevStart = i - 1
        while prevStart > 0, m[prevStart - 1] == m[i - 1] { prevStart -= 1 }
        var nextEnd = i
        while nextEnd < w.count, m[nextEnd] == m[i] { nextEnd += 1 }

        // Forward: the rest of the sentence goes to the speaker before the change.
        var f = i
        while f < w.count, !endsSentence(w[f].text) { f += 1 }
        if f < w.count {
            let end = f + 1
            if end - i <= windowWords, end <= nextEnd, w[f].end - w[i].start <= windowSeconds, noLongPause(w, from: i - 1, to: f) {
                return end
            }
        }
        // Back: the start of the sentence goes to the speaker after it.
        var b = i - 1
        while b > 0, !endsSentence(w[b - 1].text) { b -= 1 }
        if i - b <= windowWords, b >= prevStart, w[i].start - w[b].start <= windowSeconds, noLongPause(w, from: b, to: i) {
            return b
        }
        return i
    }

    /// No pause longer than the window between any two neighbouring words from `from` to `to` (inclusive).
    private static func noLongPause(_ w: [WordSpan], from: Int, to: Int) -> Bool {
        guard from < to else { return true }
        for k in from..<to where w[k + 1].start - w[k].end > windowSeconds { return false }
        return true
    }

    private static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "st.", "vs.", "jr.", "sr."]

    /// Whether a word ends a sentence: ., !, ?, or …, before any closing quote or bracket. Not "Mr." or "Dr.".
    static func endsSentence(_ word: String) -> Bool {
        var t = Substring(word.trimmingCharacters(in: .whitespaces))
        while let c = t.last, "\"'”’)]}»".contains(c) { t = t.dropLast() }
        guard let c = t.last, ".!?…。！？".contains(c) else { return false }
        return !abbreviations.contains(t.lowercased())
    }

    // MARK: Lines

    private struct Run { var label: String?; var range: Range<Int> }

    private static func runsOf(_ labels: [String?]) -> [Run] {
        var out: [Run] = []
        for (k, l) in labels.enumerated() {
            if let lastRun = out.last, lastRun.label == l { out[out.count - 1].range = lastRun.range.lowerBound..<(k + 1) }
            else { out.append(Run(label: l, range: k..<(k + 1))) }
        }
        return out
    }

    /// How a line's words make its text (" ", or "" for languages written without spaces). Nil when they don't.
    private static func joiner(_ s: Segment) -> String? {
        guard let ws = s.words, !ws.isEmpty else { return nil }
        let texts = ws.map(\.text)
        if texts.joined(separator: " ") == s.text { return " " }
        if texts.joined() == s.text { return "" }
        return nil
    }

    /// The label held for most of a line's spoken time (by word, in order of first appearance on ties).
    private static func majority(_ labels: [String?], words: [WordSpan]) -> String? {
        var time: [String: Double] = [:]
        var first: [String] = []
        for (k, l) in labels.enumerated() {
            guard let l else { continue }
            if time[l] == nil { first.append(l) }
            let d = k < words.count ? max(0.01, words[k].end - words[k].start) : 0.01
            time[l, default: 0] += d
        }
        return first.max { (time[$0] ?? 0) < (time[$1] ?? 0) }
    }

    /// The speaker who talks for most of `start`…`end`.
    private static func mostOverlap(_ start: Double, _ end: Double, _ turns: [Turn]) -> String? {
        var overlap: [String: Double] = [:]
        var first: [String] = []
        for t in turns {
            let o = min(end, t.end) - max(start, t.start)
            if o > 0 {
                if overlap[t.speaker] == nil { first.append(t.speaker) }
                overlap[t.speaker, default: 0] += o
            }
        }
        return first.max { (overlap[$0] ?? 0) < (overlap[$1] ?? 0) }
    }
}
