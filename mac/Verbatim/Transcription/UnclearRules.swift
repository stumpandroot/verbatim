import Foundation

// The noisy-recording rules from the lawnmower test (notes/audio/noise-report.md, October 2026): which stretches of
// a transcript are unclear, which of Whisper's segments are likely hallucinated, and which audio Whisper should hear
// at all. Pure functions over segments, words, and speech probabilities, so the Linux tests (mac/tools/test-unclear.sh)
// run them on synthetic data; SpeechMap.swift supplies the probabilities from Silero VAD on the device.

/// Speech probabilities from Silero VAD, one value per frame (FluidAudio: 4,096 samples at 16 kHz, 256 ms).
struct SpeechProbabilities: Equatable, Sendable {
    /// Seconds per value.
    var frame: Double
    var values: [Float]

    var duration: Double { Double(values.count) * frame }

    /// The highest probability over a time range (0 when the range holds no frame).
    func peak(from start: Double, to end: Double) -> Float {
        guard frame > 0, !values.isEmpty, end > start else { return 0 }
        let a = max(0, Int((start / frame).rounded(.down)))
        let b = min(values.count - 1, Int((end / frame).rounded(.up)) - 1)
        guard a <= b else { return 0 }
        return values[a...b].max() ?? 0
    }
}

/// One of Whisper's segments with the scores the hallucination rules read. Engines that don't score segments
/// leave the scores nil, and only the speech rule applies to them.
struct ScoredSegment {
    var segment: Segment
    var avgLogprob: Double? = nil
    var compressionRatio: Double? = nil
    var noSpeechProb: Double? = nil
}

enum UnclearRules {
    // MARK: Speech detection for Whisper's input (report: Recommendation 5)

    /// Speech starts at this probability.
    static let vadThreshold: Float = 0.35
    /// And ends once it stays under this one for `minSilence`. Never go below 0.25 for the threshold: at 0.15 the
    /// detector kept half of the lawn recording and let hallucinations back in.
    static let vadNegThreshold: Float = 0.2
    /// Kept on each side of a speech stretch.
    static let speechPad = 0.5
    /// A pause this long ends a stretch (the report's range is 1,000–2,000 ms).
    static let minSilence = 1.5
    /// Blips shorter than this aren't speech.
    static let minSpeech = 0.25

    // MARK: Unclear spans (report: Recommendation 6)

    /// Smoothed speech probability that counts as someone talking.
    static let speechHeard: Float = 0.4
    /// The smoothing window for that probability.
    static let smoothing = 0.5
    /// A talking stretch with nothing heard this long is unclear.
    static let minUnclear = 2.0
    /// A word at or over this counts as heard. Words without a confidence (Apple's engine) always count.
    static let heardWord = 0.4
    /// Words under this are shown as a best guess (the reading view's "(?)" style).
    static let lowConfidence = 0.35
    /// This many low-confidence words in a row make an unclear span.
    static let lowRun = 3
    /// Heard words cover a little either side of their timings, which Whisper smears.
    static let wordSlack = 0.2

    // MARK: Hallucinations

    /// Whisper's compression ratio over this is repeated text ("Thank you. Thank you. Thank you.").
    static let compressionLimit = 2.4
    /// No-speech probability over this with an average log probability under `logprobLimit` is text over silence.
    static let noSpeechLimit = 0.6
    static let logprobLimit = -1.0
    /// A short line whose speech probability never reaches this is text over no speech.
    static let silentPeak: Float = 0.2
    /// "Short": this many words or fewer. Longer lines over silence stay (speech detection can miss soft speech).
    static let shortLineWords = 6
    /// Whisper's segments split where its words pause this long (its segment times smear across pauses).
    static let splitGap = 4.0

    // MARK: Speech clips

    /// The stretches Whisper should transcribe: Silero-style hysteresis (start at `vadThreshold`, end after
    /// `minSilence` under `vadNegThreshold`), blips dropped, padded by `speechPad`, overlaps merged.
    static func speechClips(_ p: SpeechProbabilities) -> [ClosedRange<Double>] {
        guard p.frame > 0 else { return [] }
        var raw: [(Double, Double)] = []
        var inSpeech = false
        var start = 0.0
        var quietSince: Double? = nil
        for (i, v) in p.values.enumerated() {
            let t = Double(i) * p.frame
            if !inSpeech {
                if v >= vadThreshold { inSpeech = true; start = t; quietSince = nil }
                continue
            }
            if v < vadNegThreshold {
                let q = quietSince ?? t
                quietSince = q
                if t + p.frame - q >= minSilence { raw.append((start, q)); inSpeech = false; quietSince = nil }
            } else if v >= vadThreshold {
                quietSince = nil
            }
        }
        if inSpeech { raw.append((start, quietSince ?? p.duration)) }
        var out: [ClosedRange<Double>] = []
        for (a, b) in raw where b - a >= minSpeech {
            let lo = max(0, a - speechPad), hi = min(p.duration, b + speechPad)
            if let last = out.last, lo <= last.upperBound { out[out.count - 1] = last.lowerBound...max(last.upperBound, hi) }
            else { out.append(lo...hi) }
        }
        return out
    }

    /// The share of the recording the clips cover (0…1), for the log.
    static func coverage(_ clips: [ClosedRange<Double>], duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, clips.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } / duration)
    }

    // MARK: Unclear spans

    /// Speech probabilities averaged over `window` seconds, centered.
    static func smoothed(_ p: SpeechProbabilities, window: Double = smoothing) -> [Float] {
        guard p.frame > 0, !p.values.isEmpty else { return [] }
        let k = max(1, Int((window / p.frame).rounded()))
        let back = (k - 1) / 2, ahead = k / 2
        var prefix = [Float](repeating: 0, count: p.values.count + 1)
        for (i, v) in p.values.enumerated() { prefix[i + 1] = prefix[i] + v }
        return p.values.indices.map { i in
            let a = max(0, i - back), b = min(p.values.count - 1, i + ahead)
            return (prefix[b + 1] - prefix[a]) / Float(b - a + 1)
        }
    }

    /// Where the transcript is unclear, by either rule:
    /// 1. Speech (smoothed probability at or over `speechHeard`) for `minUnclear` seconds or more with no word heard
    ///    (no word at `heardWord` or over).
    /// 2. `lowRun` or more words in a row under `lowConfidence`.
    /// Overlapping spans merge; a merged span is `.noWords` when either part was. Sorted by start.
    static func unclearSpans(words: [WordSpan], speech: SpeechProbabilities?) -> [UnclearSpan] {
        let sorted = words.sorted { $0.start < $1.start }
        var spans: [UnclearSpan] = []
        if let p = speech, p.frame > 0, !p.values.isEmpty {
            let s = smoothed(p)
            var heard = [Bool](repeating: false, count: s.count)
            for w in sorted where (w.confidence ?? 1) >= heardWord {
                let a = max(0, Int(((w.start - wordSlack) / p.frame).rounded(.down)))
                let b = min(s.count - 1, Int(((w.end + wordSlack) / p.frame).rounded(.up)) - 1)
                if a <= b { for i in a...b { heard[i] = true } }
            }
            var runStart: Int? = nil
            func close(_ end: Int) {
                guard let a = runStart else { return }
                if Double(end - a) * p.frame >= minUnclear - 1e-9 {
                    spans.append(UnclearSpan(start: Double(a) * p.frame, end: Double(end) * p.frame, reason: .noWords))
                }
                runStart = nil
            }
            for i in s.indices {
                if s[i] >= speechHeard && !heard[i] { if runStart == nil { runStart = i } } else { close(i) }
            }
            close(s.count)
        }
        var run: [WordSpan] = []
        func closeRun() {
            if run.count >= lowRun, let f = run.first, let l = run.last { spans.append(UnclearSpan(start: f.start, end: l.end, reason: .lowConfidence)) }
            run = []
        }
        for w in sorted {
            guard let c = w.confidence, c < lowConfidence else { closeRun(); continue }
            if let last = run.last, w.start - last.end > splitGap { closeRun() }
            run.append(w)
        }
        closeRun()
        return merged(spans)
    }

    static func merged(_ spans: [UnclearSpan]) -> [UnclearSpan] {
        var out: [UnclearSpan] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1].end = max(last.end, s.end)
                if s.reason == .noWords { out[out.count - 1].reason = .noWords }
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: Hallucinations

    /// Why a segment is dropped, or nil to keep it.
    enum Drop: String { case repeated, noSpeech, overSilence }

    static func drop(_ s: ScoredSegment, speech: SpeechProbabilities?) -> Drop? {
        if let cr = s.compressionRatio, cr > compressionLimit { return .repeated }
        if let ns = s.noSpeechProb, let lp = s.avgLogprob, ns > noSpeechLimit, lp < logprobLimit { return .noSpeech }
        if let p = speech, wordCount(s.segment.text) <= shortLineWords,
           p.peak(from: s.segment.start - 0.25, to: s.segment.end + 0.25) < silentPeak { return .overSilence }
        return nil
    }

    /// The segments to keep: likely hallucinations dropped, the rest split where their words pause `splitGap` or more.
    static func clean(_ segments: [ScoredSegment], speech: SpeechProbabilities?) -> (kept: [Segment], dropped: [Drop: Int]) {
        var kept: [Segment] = []
        var dropped: [Drop: Int] = [:]
        for s in segments {
            if let why = drop(s, speech: speech) { dropped[why, default: 0] += 1; continue }
            kept.append(contentsOf: splitAtGaps(s.segment))
        }
        return (kept, dropped)
    }

    /// Splits a segment where its words pause `gap` seconds or more. Unchanged without word timings or long pauses.
    static func splitAtGaps(_ s: Segment, gap: Double = splitGap) -> [Segment] {
        guard let words = s.words, words.count > 1 else { return [s] }
        var groups: [[WordSpan]] = [[words[0]]]
        for w in words.dropFirst() {
            if let prev = groups[groups.count - 1].last, w.start - prev.end > gap { groups.append([w]) } else { groups[groups.count - 1].append(w) }
        }
        guard groups.count > 1 else { return [s] }
        return groups.enumerated().map { i, g in
            var seg = Segment(start: g.first!.start, end: g.last!.end, text: g.map(\.text).joined(separator: " "), words: g, speaker: s.speaker)
            if i == 0 { seg.id = s.id }
            return seg
        }
    }

    // MARK: Reading view

    /// Which of a line's timed words are low-confidence (indices into `words`): the reading view underlines them
    /// with a quiet dotted line, as a best guess. Exports leave them as they are.
    static func lowWords(_ s: Segment) -> Set<Int> {
        guard let words = s.words else { return [] }
        return Set(words.indices.filter { (words[$0].confidence ?? 1) < lowConfidence })
    }

    /// "unclear 2:10", the chip's words; exports write "[unclear 2:10]".
    static func label(_ seconds: Double) -> String { "unclear " + clock(seconds) }

    /// "2:10", or "1:02:14" past an hour.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The chips to show between lines: each `.noWords` span, placed before the first shown line that starts at or
    /// after it (`Int.max` places it after the last line). Low-confidence runs show as styled words instead.
    static func placements(_ spans: [UnclearSpan], lineStarts: [Double]) -> [(span: UnclearSpan, before: Int)] {
        spans.filter { $0.reason == .noWords }.map { sp in
            (sp, lineStarts.firstIndex { $0 >= sp.start - 0.05 } ?? Int.max)
        }
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}
