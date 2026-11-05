import Foundation

/// Tidies the turns of a recording woven from separate tracks (MultitrackJob): a call's mic and call audio, or one
/// file per mic. Each track is transcribed on its own and the lines are merged by start time, so talk that overlaps
/// cut sentences in two around the other person's words, and left one-word turns ("Dana: The") where an engine split
/// a line at a pause. Pure Foundation, so mac/tools/test-meeting-names.sh checks it on Linux.
///
/// Two passes (research §4, steps 4 to 6, with Char's micro-segment rule):
/// 1. A fragment, one or two words with no sentence end, joins the same speaker's nearest line when it is within
///    `fragmentReach` seconds and only a line or two of someone else's sits between them. A backchannel ("yeah",
///    "mm-hmm", "right") isn't a fragment: it's a reply of its own, and pass 2 places it.
/// 2. A line that stops mid-sentence joins the same speaker's next line when they paused no more than `maxGap`
///    seconds and everything between was said before they went on: the other person's words (a "yeah", or
///    longer talk over them) move to after the joined line. The engines end lines at a sentence's end or a pause
///    (Engines.segments), so the turn now breaks where the sentence does, never inside it.
///
/// Nothing is dropped: a joined line holds both lines' words in order, its time spans both, and its word timings are
/// kept, so playback follows it. The engine's lines (`original`) join the same way, and Dictionary fixes move with
/// their words.
enum MeetingTurns {
    /// Words a line can have and still be a fragment.
    static let fragmentWords = 2
    /// Seconds between a fragment and the line it joins, at most.
    static let fragmentReach = 3.0
    /// Seconds a speaker can pause inside one sentence.
    static let maxGap = 2.0
    /// Other people's lines that can sit inside one cut sentence (or between a fragment and its line, less one).
    static let maxBetween = 4
    /// Words a joined line holds at most, so someone talking a long while without a full stop still reads in lines.
    static let maxJoinedWords = 80

    /// The engine's lines and the corrected ones, joined the same way. `originals` holds the engine's line for each
    /// corrected line's id.
    struct Result {
        var fixed: [Segment]
        var original: [Segment]
    }

    static func tidy(_ fixed: [Segment], originals: [UUID: Segment], corrections: inout [Correction]) -> Result {
        var lines = fixed.map { Line(seg: $0, orig: originals[$0.id] ?? $0) }
        foldFragments(&lines, corrections: &corrections)
        joinCutSentences(&lines, corrections: &corrections)
        return Result(fixed: lines.map(\.seg), original: lines.map(\.orig))
    }

    struct Line {
        var seg: Segment
        var orig: Segment
    }

    // MARK: Passes

    static func foldFragments(_ lines: inout [Line], corrections: inout [Correction]) {
        var i = 0
        while i < lines.count {
            let s = lines[i].seg
            guard let sp = s.speaker, isFragment(s.text), !isBackchannel(s.text) else { i += 1; continue }
            let next = lines.indices.dropFirst(i + 1).prefix(maxBetween).first { lines[$0].seg.speaker == sp }
            let prev = lines.indices.prefix(i).suffix(maxBetween).last { lines[$0].seg.speaker == sp }
            if let n = next, lines[n].seg.start - s.end <= fragmentReach {
                // It starts the sentence that follows ("The" + "page looks good.").
                lines[n] = joined(lines[i], lines[n], keep: lines[n].seg.id, corrections: &corrections)
                lines.remove(at: i)
            } else if let p = prev, s.start - lines[p].seg.end <= fragmentReach {
                lines[p] = joined(lines[p], lines[i], keep: lines[p].seg.id, corrections: &corrections)
                lines.remove(at: i)
                i = max(0, p)
            } else {
                i += 1
            }
        }
    }

    static func joinCutSentences(_ lines: inout [Line], corrections: inout [Correction]) {
        var i = 0
        while i < lines.count {
            let a = lines[i]
            guard let x = a.seg.speaker, !endsSentence(a.seg.text) else { i += 1; continue }
            var j = i + 1
            while j < lines.count, lines[j].seg.speaker != x, j - i <= maxBetween { j += 1 }
            guard j < lines.count, lines[j].seg.speaker == x else { i += 1; continue }
            let b = lines[j]
            // They went on after a short pause, and the others' words came before they did. Next to each other, the
            // two halves join too (a fragment folded away from between them).
            guard b.seg.start - a.seg.end <= maxGap, wordCount(a.seg.text) + wordCount(b.seg.text) <= maxJoinedWords,
                  (i + 1..<j).allSatisfy({ lines[$0].seg.start <= b.seg.start }) else { i += 1; continue }
            let between = Array(lines[(i + 1)..<j])
            lines[i] = joined(a, b, keep: a.seg.id, corrections: &corrections)
            lines.removeSubrange((i + 1)...j)
            lines.insert(contentsOf: between, at: i + 1)
            // Stay on the joined line: it may still stop mid-sentence and go on after the next interruption.
        }
    }

    // MARK: Joining

    /// `l` then `r` as one line with `keep`'s id: both texts in order, the time of both, both lines' word timings
    /// (none when either has none, rather than timings for only part of the text), and corrections in `r` moved to
    /// their place in the joined text.
    static func joined(_ l: Line, _ r: Line, keep: UUID, corrections: inout [Correction]) -> Line {
        func join(_ a: Segment, _ b: Segment) -> Segment {
            var s = a
            s.id = keep
            let at = a.text.trimmingCharacters(in: .whitespaces), bt = b.text.trimmingCharacters(in: .whitespaces)
            s.text = at.isEmpty ? bt : bt.isEmpty ? at : at + " " + bt
            s.start = min(a.start, b.start); s.end = max(a.end, b.end)
            if let aw = a.words, let bw = b.words { s.words = aw + bw } else { s.words = nil }
            return s
        }
        // Dictionary fixes in the right line now sit after the left line's text and a space.
        let leftText = l.seg.text.trimmingCharacters(in: .whitespaces)
        let shift = leftText.isEmpty ? 0 : (leftText as NSString).length + 1
        let leftLead = (l.seg.text as NSString).length - (l.seg.text.drop(while: { $0 == " " }) as Substring).utf16.count
        let rightLead = (r.seg.text as NSString).length - (r.seg.text.drop(while: { $0 == " " }) as Substring).utf16.count
        for k in corrections.indices {
            if corrections[k].segmentId == r.seg.id {
                corrections[k].segmentId = keep
                corrections[k].spans = corrections[k].spans?.map { sp in
                    var sp = sp
                    if !sp.isStale { sp.location += shift - rightLead }
                    return sp
                }
            } else if corrections[k].segmentId == l.seg.id {
                corrections[k].segmentId = keep
                corrections[k].spans = corrections[k].spans?.map { sp in
                    var sp = sp
                    if !sp.isStale { sp.location -= leftLead }
                    return sp
                }
            }
        }
        var line = Line(seg: join(l.seg, r.seg), orig: join(l.orig, r.orig))
        line.seg.speaker = l.seg.speaker ?? r.seg.speaker
        line.orig.speaker = line.seg.speaker
        return line
    }

    // MARK: Words

    /// Words with a letter or digit in them.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// The text ends a sentence: its last mark (past closing quotes and brackets) is ".", "?", "!", or "…".
    static func endsSentence(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespaces)
        while let l = t.last, "\"”’)]".contains(l) { t.removeLast() }
        guard let last = t.last else { return true }
        return ".?!…。！？".contains(last)
    }

    /// A short reply said over someone else ("yeah", "mm-hmm", "got it", "okay, right"): at most three words, every
    /// one of them a backchannel word, and not a question.
    static func isBackchannel(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.letters.union(CharacterSet(charactersIn: "-'’")).inverted) }
            .filter { !$0.isEmpty }
        return !words.isEmpty && words.count <= 3 && !text.contains("?") && words.allSatisfy { backchannelWords.contains($0) }
    }

    static let backchannelWords: Set<String> = [
        "yeah", "yes", "yep", "yup", "ya", "okay", "ok", "mm", "mhm", "mm-hmm", "mmhmm", "uh-huh", "uh", "um", "hmm", "right",
        "sure", "exactly", "totally", "true", "nice", "cool", "great", "wow", "oh", "ah", "gotcha", "got", "it", "i", "see",
        "absolutely", "definitely", "perfect", "awesome", "alright", "all", "sounds", "good", "for", "of", "course", "indeed",
        "no", "nope", "correct", "agreed", "fair", "interesting", "huh",
    ]

    /// One or two words that don't end a sentence: an engine's split at a pause, not a reply ("No." and "Got it."
    /// are replies and stay).
    static func isFragment(_ text: String) -> Bool {
        let n = wordCount(text)
        return n >= 1 && n <= fragmentWords && !endsSentence(text)
    }
}
