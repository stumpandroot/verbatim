import Foundation

// Long recordings in sections: where each section starts and ends, and how neighboring sections' words are joined.
// Pure Swift (Foundation only), so mac/tools/longfile-tests runs it on Linux. The audio reading, engines, and
// checkpoints that use it are in SectionedTranscription.swift.

/// One recognized word with its time span in seconds, as a section engine returns it.
struct SectionWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double

    var center: Double { (start + end) / 2 }
}

/// Where the sections of a recording fall, in samples. Neighboring sections overlap by `overlap`, so a word cut at
/// one section's edge is heard whole by the next. The last section may run up to `slack` past `window` instead of
/// leaving a short tail section with almost no context.
struct SectionPlan: Equatable, Sendable {
    var sampleRate = 16_000
    /// About 5 minutes per section: about 19 MB of 16 kHz float samples, whatever the recording's length.
    var window = 300 * 16_000
    var overlap = 2 * 16_000
    var slack = 30 * 16_000
    /// How far back from a section's end to look for a quiet moment to end it on.
    var search = 10 * 16_000

    /// Parakeet: 5-minute sections.
    static let parakeet = SectionPlan()
    /// Apple's on-device recognizer: 1-minute sections, the length it handles reliably in one request.
    static let apple = SectionPlan(window: 60 * 16_000, overlap: 2 * 16_000, slack: 10 * 16_000, search: 5 * 16_000)

    /// Recordings this long or shorter fit in one section.
    var singleSectionLimit: Int { window + slack }

    /// The section after the one that ended at `previousEnd` (nil for the first), or nil when the recording is done.
    /// Its end is where reading stops; `quietCut` can end it earlier.
    func next(after previousEnd: Int?, total: Int) -> Range<Int>? {
        guard total > 0 else { return nil }
        let start: Int
        if let end = previousEnd {
            guard end < total else { return nil }
            start = max(0, end - overlap)
        } else {
            start = 0
        }
        let end = total - start <= window + slack ? total : start + window
        return start..<end
    }

    /// Every section, with no quiet cuts.
    func windows(total: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var end: Int? = nil
        while let r = next(after: end, total: total) {
            out.append(r)
            end = r.upperBound
            if r.upperBound >= total { break }
        }
        return out
    }

    /// About how many sections a recording of `total` samples takes.
    func estimatedCount(total: Int) -> Int { max(1, windows(total: total).count) }

    /// Where to end a section that isn't the last: the middle of the quietest 300 ms in its final `search` samples,
    /// when that stretch is clearly quieter than the rest of the tail (under 30% of its median loudness). Nil when
    /// there's no such pause; the section then ends where reading stopped and the overlap covers the seam.
    func quietCut(in samples: [Float]) -> Int? {
        let frame = max(1, sampleRate / 50)          // 20 ms
        let run = 15                                 // 300 ms
        let tailStart = max(0, samples.count - search)
        let frames = (samples.count - tailStart) / frame
        guard frames >= run * 2 else { return nil }
        var energy = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var acc: Float = 0
            let base = tailStart + f * frame
            for i in base..<(base + frame) { acc += samples[i] * samples[i] }
            energy[f] = (acc / Float(frame)).squareRoot()
        }
        guard let best = Self.quietestRun(energy, length: run) else { return nil }
        let sorted = energy.sorted()
        let median = sorted[sorted.count / 2]
        let mean = energy[best..<(best + run)].reduce(0, +) / Float(run)
        guard median > 0.000_1 ? mean <= median * 0.3 : true else { return nil }
        return tailStart + (best + run / 2) * frame
    }

    /// The start of the `length` frames with the lowest total energy (the latest one on a tie).
    static func quietestRun(_ energy: [Float], length: Int) -> Int? {
        guard length > 0, energy.count >= length else { return nil }
        var sum = energy[0..<length].reduce(0, +)
        var best = 0, bestSum = sum
        for i in 1...(energy.count - length) {
            sum += energy[i + length - 1] - energy[i - 1]
            if sum <= bestSum { bestSum = sum; best = i }
        }
        return best
    }
}

/// Joins neighboring sections' words. In the overlap, a word both sections heard is kept once, from the section
/// where it sits farther from the edge; a word only one section heard is kept when it's on that section's side of
/// the overlap's middle (where that section is the more reliable one).
enum SectionStitcher {
    /// Shifts a section's words (relative to the section's start) to the recording's time.
    static func offset(_ words: [SectionWord], by seconds: Double) -> [SectionWord] {
        words.map { SectionWord(text: $0.text, start: $0.start + seconds, end: $0.end + seconds) }
    }

    /// `earlier` is everything so far; `later` is the next section's words, already offset. The sections overlap
    /// from `overlapStart` (the later section's start) to `overlapEnd` (the earlier section's end), in seconds.
    static func stitch(_ earlier: [SectionWord], _ later: [SectionWord], overlapStart a: Double, overlapEnd b: Double) -> [SectionWord] {
        guard !earlier.isEmpty else { return later }
        guard !later.isEmpty else { return earlier }
        guard b > a else {
            // No overlap: keep each side's words on its side of the seam.
            return earlier.filter { $0.center < a } + later.filter { $0.center >= a }
        }
        let mid = (a + b) / 2
        let keepEarlier = earlier.filter { $0.center < a }
        let earlierOverlap = earlier.filter { $0.center >= a }
        let laterOverlap = later.filter { $0.center <= b }
        let keepLater = later.filter { $0.center > b }
        var merged: [SectionWord] = []
        var i = 0, j = 0
        while i < earlierOverlap.count || j < laterOverlap.count {
            if i < earlierOverlap.count, j < laterOverlap.count {
                let l = earlierOverlap[i], r = laterOverlap[j]
                if same(l, r) {
                    // Distance from the edge each section had: the earlier one's end, the later one's start.
                    merged.append(b - l.center >= r.center - a ? l : r)
                    i += 1; j += 1
                } else if l.center <= r.center {
                    if l.center < mid { merged.append(l) }
                    i += 1
                } else {
                    if r.center >= mid { merged.append(r) }
                    j += 1
                }
            } else if i < earlierOverlap.count {
                if earlierOverlap[i].center < mid { merged.append(earlierOverlap[i]) }
                i += 1
            } else {
                if laterOverlap[j].center >= mid { merged.append(laterOverlap[j]) }
                j += 1
            }
        }
        return keepEarlier + merged + keepLater
    }

    /// Two sections' versions of the same spoken word: mostly the same time span, nearly the same middle, or the
    /// same text close by. A word cut at an edge ("some" for "something") still overlaps the whole one.
    static func same(_ l: SectionWord, _ r: SectionWord) -> Bool {
        let shared = min(l.end, r.end) - max(l.start, r.start)
        let shorter = max(0.01, min(l.end - l.start, r.end - r.start))
        if shared >= 0.5 * shorter { return true }
        let apart = abs(l.center - r.center)
        if apart <= 0.15 { return true }
        return apart <= 0.5 && normalized(l.text) == normalized(r.text)
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }
}
