import Foundation

/// A segment from one track of a multi-track recording, with its times already on the shared timeline.
struct TrackSegment {
    var track: Int
    var segment: Segment
}

/// The pure parts of multi-track transcription: speaker names from file names, lining tracks up by sound,
/// dropping mic bleed, and weaving the tracks into one list. No audio or file access, so the harness in
/// mac/tools/multitrack-tests runs them on Linux.
enum MultitrackMath {
    /// Envelope frames per second (10 ms hops).
    static let frameRate: Double = 100
    /// How much of each track the automatic line-up compares (the first five minutes).
    static let alignWindow: Double = 300
    /// The furthest apart two tracks can start and still be found.
    static let maxAlignLag: Double = 30

    // MARK: Speaker names

    /// "Tim_MV7.wav" → "Tim", "02 - Ana (SM7B).wav" → "Ana", "Track 3.wav" → "Track 3". Empty when nothing fits.
    static func speakerName(fromFile name: String) -> String {
        var stem = name
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex, stem.distance(from: dot, to: stem.endIndex) <= 6 {
            stem = String(stem[..<dot])
        }
        let seps = CharacterSet(charactersIn: "_-–—.,()[]{}+ ")
        let tokens = stem.components(separatedBy: seps).filter { !$0.isEmpty }
        let words = tokens.filter { !$0.allSatisfy(\.isNumber) }
        guard let first = words.first else { return tokens.isEmpty ? "" : "Track " + tokens[0] }
        let generic: Set<String> = ["track", "audio", "mic", "microphone", "channel", "ch", "input", "in", "tr", "rec", "recording", "zoom", "tascam"]
        if generic.contains(first.lowercased()) {
            return tokens.prefix(2).joined(separator: " ").capitalizedFirst
        }
        return first.capitalizedFirst
    }

    // MARK: Lining up

    /// RMS envelope (linear, 0…1) of mono samples, one value per `hop` samples.
    static func envelope(_ samples: [Float], hop: Int) -> [Float] {
        guard hop > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / hop + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + hop)
            var acc: Float = 0
            for j in i..<end { acc += samples[j] * samples[j] }
            out.append((acc / Float(end - i)).squareRoot())
            i = end
        }
        return out
    }

    /// Sound activity, mean 0 and standard deviation 1: how far each frame rises above the track's noise floor,
    /// in dB, capped at 15 dB. The cap makes a speaker's own voice and their voice bleeding into another mic look
    /// alike, so two mics compare by when there's sound at all, not by who is loud.
    static func activity(_ env: [Float]) -> [Float] {
        guard !env.isEmpty else { return [] }
        let db = env.map { max(-100, 20 * log10(max($0, 1e-6))) }
        let floor = db.sorted()[db.count / 10]
        let act = db.map { min(1, max(0, ($0 - floor - 3) / 12)) }
        return zNormalize(act)
    }

    /// Averages every `factor` frames.
    static func decimate(_ v: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return v }
        var out: [Float] = []
        var i = 0
        while i < v.count {
            let end = min(v.count, i + factor)
            var s: Float = 0
            for j in i..<end { s += v[j] }
            out.append(s / Float(end - i))
            i = end
        }
        return out
    }

    /// Mean of a[t] · b[t − lag] over the frames both cover, or nil when they share fewer than `minOverlap`.
    static func correlation(_ a: [Float], _ b: [Float], lag: Int, minOverlap: Int) -> Float? {
        let lo = max(0, lag), hi = min(a.count, b.count + lag)
        guard hi - lo >= max(1, minOverlap) else { return nil }
        var s: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for t in lo..<hi { s += pa[t] * pb[t - lag] }
            }
        }
        return s / Float(hi - lo)
    }

    struct Alignment: Equatable {
        /// Seconds this track starts after the reference (negative: before).
        var offset: Double
        /// Peak normalized correlation, about −1…1. Low means the tracks share too little sound to line up.
        var confidence: Double
    }

    /// Where `track` sits against `reference`, from their RMS envelopes (`frameRate` frames per second): the lag
    /// whose sound activity matches best, found coarsely at a tenth of the rate, then refined. Mic bleed is
    /// what makes this work; fully isolated mics share no sound and come back with low confidence.
    static func estimateOffset(reference: [Float], track: [Float], frameRate: Double = frameRate,
                               maxLag: Double = maxAlignLag, window: Double = alignWindow) -> Alignment {
        let n = Int(window * frameRate)
        let a = activity(Array(reference.prefix(n))), b = activity(Array(track.prefix(n)))
        guard a.count > 10, b.count > 10 else { return Alignment(offset: 0, confidence: 0) }
        let factor = max(1, Int(frameRate / 10))
        let ca = zNormalize(decimate(a, by: factor)), cb = zNormalize(decimate(b, by: factor))
        let coarseMax = Int(maxLag * frameRate) / factor
        let coarseMin = max(2, min(ca.count, cb.count) / 3)
        var best = 0, bestV = -Float.infinity
        for lag in -coarseMax...coarseMax {
            guard let v = correlation(ca, cb, lag: lag, minOverlap: coarseMin), v > bestV else { continue }
            bestV = v; best = lag
        }
        guard bestV > -Float.infinity else { return Alignment(offset: 0, confidence: 0) }
        let center = best * factor
        let fineMin = max(2, min(a.count, b.count) / 3)
        var fine = center, fineV = -Float.infinity
        for lag in (center - 2 * factor)...(center + 2 * factor) {
            guard let v = correlation(a, b, lag: lag, minOverlap: fineMin), v > fineV else { continue }
            fineV = v; fine = lag
        }
        if fineV == -Float.infinity { fine = center; fineV = bestV }
        return Alignment(offset: Double(fine) / frameRate, confidence: Double(fineV))
    }

    private static func zNormalize(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let mean = v.reduce(0, +) / Float(v.count)
        var s: Float = 0
        for x in v { s += (x - mean) * (x - mean) }
        let sd = (s / Float(v.count)).squareRoot()
        guard sd > 1e-4 else { return [Float](repeating: 0, count: v.count) }
        return v.map { ($0 - mean) / sd }
    }

    /// Below this, the automatic line-up isn't trusted and the track starts with the first one.
    static let minAlignConfidence = 0.2

    /// Offsets against track 1 for every track (track 1 is 0). Weak matches fall back to 0.
    static func offsets(envelopes: [[Float]], frameRate: Double = frameRate) -> [Double] {
        guard let ref = envelopes.first else { return [] }
        return envelopes.enumerated().map { i, env in
            guard i > 0 else { return 0 }
            let a = estimateOffset(reference: ref, track: env, frameRate: frameRate)
            return a.confidence >= minAlignConfidence ? a.offset : 0
        }
    }

    /// Offsets against track 1 moved so the earliest track starts at 0: where each track begins on the shared
    /// timeline (and in the mixed audio).
    static func timeline(_ offsets: [Double]) -> [Double] {
        let shift = -(offsets.min() ?? 0)
        return offsets.map { $0 + shift }
    }

    /// "starts 0.4 s later", "starts 12 s earlier", "starts 1:05 later"; nil when it's within 50 ms.
    static func offsetText(_ offset: Double) -> String? {
        let a = abs(offset)
        guard a >= 0.05 else { return nil }
        let amount: String
        if a < 10 { amount = String(format: "%.1f s", a) }
        else if a < 60 { amount = "\(Int(a.rounded())) s" }
        else { let s = Int(a.rounded()); amount = String(format: "%d:%02d", s / 60, s % 60) }
        return "starts \(amount) \(offset > 0 ? "later" : "earlier")"
    }

    // MARK: Placing and merging

    /// One track's segments moved onto the shared timeline and given the track's speaker ("S1" for track 1).
    static func place(_ segments: [Segment], track: Int, offset: Double) -> [TrackSegment] {
        segments.map { s in
            var s = s
            s.start += offset; s.end += offset
            s.words = s.words?.map { WordSpan(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            s.speaker = speakerID(track)
            return TrackSegment(track: track, segment: s)
        }
    }

    static func speakerID(_ track: Int) -> String { "S\(track + 1)" }

    /// One speaker per track, named from the sheet (blank names become "Speaker N").
    static func speakers(names: [String]) -> [Speaker] {
        names.enumerated().map { i, n in
            let name = n.trimmingCharacters(in: .whitespacesAndNewlines)
            return Speaker(id: speakerID(i), name: name.isEmpty ? "Speaker \(i + 1)" : name)
        }
    }

    /// Every track's segments in one list by start time (track order breaks ties).
    static func merge(_ segments: [TrackSegment]) -> [Segment] {
        segments.sorted { a, b in
            if a.segment.start != b.segment.start { return a.segment.start < b.segment.start }
            if a.track != b.track { return a.track < b.track }
            return a.segment.end < b.segment.end
        }.map(\.segment)
    }

    // MARK: Mic bleed

    /// Lowercased letters and digits with single spaces.
    static func normalizedText(_ s: String) -> [Character] {
        var out: [Character] = []
        var space = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { if space && !out.isEmpty { out.append(" ") }; out.append(ch); space = false }
            else { space = true }
        }
        return out
    }

    /// 1 − edit distance / longer length, on normalized text. 0 when either is empty.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalizedText(a), y = normalizedText(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// RMS level in dBFS of `env` (linear, `frameRate` per second, in the track's own time) between two times on
    /// the shared timeline, for a track that starts at `offset`.
    static func level(_ env: [Float], from start: Double, to end: Double, offset: Double, frameRate: Double = frameRate) -> Double {
        guard !env.isEmpty else { return -120 }
        let a = max(0, Int(((start - offset) * frameRate).rounded(.down)))
        let b = min(env.count, max(a + 1, Int(((end - offset) * frameRate).rounded(.up))))
        guard a < b else { return -120 }
        var acc: Double = 0
        for i in a..<b { acc += Double(env[i]) * Double(env[i]) }
        let rms = (acc / Double(b - a)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }

    /// A track's speech level: the 95th percentile of its frame levels (dBFS).
    static func referenceLevel(_ env: [Float]) -> Double {
        guard !env.isEmpty else { return -120 }
        let db = env.map { 20 * log10(max(Double($0), 1e-6)) }.sorted()
        return db[min(db.count - 1, Int(Double(db.count) * 0.95))]
    }

    struct BleedSettings {
        /// Text at least this similar counts as the same words heard by two mics.
        var similarity = 0.8
        /// How far apart (seconds) two segments can be and still be the same words.
        var tolerance = 1.0
        /// A segment this far below its own track's speech level (dB) is bleed when another track is talking.
        var quietBelow = -45.0
    }

    /// Drops mic bleed from segments already on the shared timeline:
    /// 1. Two tracks with near-identical words within `tolerance`: keep the one whose mic is louder over that
    ///    stretch, drop the other.
    /// 2. A segment far below its own track's speech level that overlaps another track's speech.
    /// `envelopes[i]` is track i's RMS envelope in its own time; `offsets[i]` where it starts on the timeline.
    static func filterBleed(_ segments: [TrackSegment], envelopes: [[Float]], offsets: [Double],
                            frameRate: Double = frameRate, settings: BleedSettings = BleedSettings()) -> [TrackSegment] {
        let segs = segments.sorted { $0.segment.start < $1.segment.start }
        var dropped = Set<Int>()
        func env(_ t: Int) -> [Float] { t < envelopes.count ? envelopes[t] : [] }
        func off(_ t: Int) -> Double { t < offsets.count ? offsets[t] : 0 }
        func near(_ a: Segment, _ b: Segment, _ tol: Double) -> Bool { a.start < b.end + tol && b.start < a.end + tol }

        for i in segs.indices where !dropped.contains(i) {
            let a = segs[i]
            var j = i + 1
            while j < segs.count, segs[j].segment.start < a.segment.end + settings.tolerance {
                defer { j += 1 }
                let b = segs[j]
                guard b.track != a.track, !dropped.contains(j), near(a.segment, b.segment, settings.tolerance),
                      similarity(a.segment.text, b.segment.text) > settings.similarity else { continue }
                let from = min(a.segment.start, b.segment.start), to = max(a.segment.end, b.segment.end)
                let la = level(env(a.track), from: from, to: to, offset: off(a.track), frameRate: frameRate)
                let lb = level(env(b.track), from: from, to: to, offset: off(b.track), frameRate: frameRate)
                if la >= lb { dropped.insert(j) } else { dropped.insert(i); break }
            }
        }

        let refs = (0..<max(envelopes.count, (segs.map(\.track).max() ?? -1) + 1)).map { referenceLevel(env($0)) }
        let kept = segs.indices.filter { !dropped.contains($0) }
        var quiet = Set<Int>()
        for i in kept {
            let a = segs[i]
            let rel = level(env(a.track), from: a.segment.start, to: a.segment.end, offset: off(a.track), frameRate: frameRate) - refs[a.track]
            guard rel < settings.quietBelow else { continue }
            let overlapsOther = kept.contains { k in k != i && segs[k].track != a.track && near(a.segment, segs[k].segment, 0) && !quiet.contains(k) }
            if overlapsOther { quiet.insert(i) }
        }
        return kept.filter { !quiet.contains($0) }.map { segs[$0] }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
