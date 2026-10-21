import Foundation

// Test cases for MultitrackMath. Not part of any app target; run mac/tools/test-multitrack.sh.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name) \(detail())") }
}
func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

/// Deterministic pseudo-random numbers (xorshift), so every run is the same.
struct RNG {
    var s: UInt64
    mutating func next() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 1_000_000) / 1_000_000 }
}

/// A conversation: who talks in each 10 ms frame (0 = A, 1 = B, -1 = nobody), with turns of 1–6 s and pauses.
func conversation(seconds: Double, seed: UInt64) -> [Int] {
    var r = RNG(s: seed)
    var who: [Int] = []
    let n = Int(seconds * 100)
    var speaker = 0
    while who.count < n {
        let turn = Int((1 + r.next() * 5) * 100)
        for k in 0..<turn {
            // Syllable-ish flutter inside a turn: short dips every ~200 ms.
            who.append((k % 20) < 3 ? -1 : speaker)
        }
        let pause = Int((0.1 + r.next() * 0.8) * 100)
        who += [Int](repeating: -1, count: pause)
        speaker = r.next() < 0.75 ? 1 - speaker : speaker
    }
    return Array(who.prefix(n))
}

/// The envelope one mic hears: its own speaker loud, the other at `bleed` (linear), plus a noise floor.
func micEnvelope(_ who: [Int], me: Int, bleed: Float, seed: UInt64) -> [Float] {
    var r = RNG(s: seed)
    return who.map { w in
        let noise = Float(0.0008 + r.next() * 0.0004)
        let wobble = Float(0.7 + r.next() * 0.6)
        if w == me { return 0.25 * wobble + noise }
        if w >= 0 { return 0.25 * wobble * bleed + noise }
        return noise
    }
}

/// `env` as heard by a recorder that started `seconds` later (positive) or earlier (negative, padded with noise).
func shifted(_ env: [Float], by seconds: Double) -> [Float] {
    let d = Int((seconds * 100).rounded())
    if d >= 0 { return Array(env.dropFirst(d)) }
    return [Float](repeating: 0.001, count: -d) + env
}

// MARK: Offset estimation

let talk = conversation(seconds: 420, seed: 42)
let micA = micEnvelope(talk, me: 0, bleed: 0.06, seed: 7)
let micB = micEnvelope(talk, me: 1, bleed: 0.06, seed: 9)

for d in [0.0, 0.4, -1.25, 12.3, -27.5] {
    let a = MultitrackMath.estimateOffset(reference: micA, track: shifted(micB, by: d))
    check("offset \(d)", near(a.offset, d, 0.021), "got \(a.offset) confidence \(a.confidence)")
    check("offset \(d) confident", a.confidence >= MultitrackMath.minAlignConfidence, "confidence \(a.confidence)")
}

// Faint bleed (about 14 dB above the noise floor) still lines up.
let faintB = micEnvelope(talk, me: 1, bleed: 0.02, seed: 13)
let faint = MultitrackMath.estimateOffset(reference: micA, track: shifted(faintB, by: 0.7))
check("faint bleed offset", near(faint.offset, 0.7, 0.021) && faint.confidence >= MultitrackMath.minAlignConfidence, "got \(faint)")

// Three tracks: offsets() reports each against track 1.
let micC = micEnvelope(talk, me: 2, bleed: 0.06, seed: 11)   // nobody's own voice: only bleed of A and B
let offs = MultitrackMath.offsets(envelopes: [micA, shifted(micB, by: 0.4), shifted(micC, by: -2.0)])
check("offsets count", offs.count == 3)
check("offsets track 1 is 0", offs.first == 0)
check("offsets track 2", near(offs[1], 0.4, 0.021), "\(offs)")
check("offsets track 3", near(offs[2], -2.0, 0.021), "\(offs)")

// Fully isolated mics share no sound: the weak match isn't trusted and the track starts with track 1.
let isoA = micEnvelope(talk, me: 0, bleed: 0, seed: 21)
let isoNoise: [Float] = { var r = RNG(s: 99); return (0..<30000).map { _ in Float(0.0008 + r.next() * 0.0004) } }()
let iso = MultitrackMath.estimateOffset(reference: isoA, track: isoNoise)
check("noise has low confidence", iso.confidence < MultitrackMath.minAlignConfidence, "confidence \(iso.confidence)")
check("noise falls back to 0", MultitrackMath.offsets(envelopes: [isoA, isoNoise])[1] == 0)

// Short or empty input doesn't crash.
check("empty", MultitrackMath.estimateOffset(reference: [], track: micB).offset == 0)
check("tiny", MultitrackMath.estimateOffset(reference: [0.1, 0.2], track: [0.2, 0.1]).confidence == 0)

// Timing: a full five-minute window at the default lag range stays quick.
let t0 = Date()
_ = MultitrackMath.estimateOffset(reference: micA, track: shifted(micB, by: 3))
let elapsed = Date().timeIntervalSince(t0)
check("estimate is fast", elapsed < 1.0, "took \(elapsed) s")

// Envelope from samples: 16 kHz, 10 ms hops.
let sine = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
let env = MultitrackMath.envelope(sine, hop: 160)
check("envelope count", env.count == 100, "\(env.count)")
check("envelope rms", near(Double(env[50]), 0.5 / 2.0.squareRoot(), 0.01), "\(env[50])")

// Timeline: the earliest track starts at 0.
check("timeline", MultitrackMath.timeline([0, 0.4, -2]) == [2, 2.4, 0])
check("timeline single", MultitrackMath.timeline([0]) == [0])

// MARK: Offset text

check("text later", MultitrackMath.offsetText(0.4) == "starts 0.4 s later")
check("text earlier", MultitrackMath.offsetText(-1.25) == "starts 1.3 s earlier" || MultitrackMath.offsetText(-1.25) == "starts 1.2 s earlier", MultitrackMath.offsetText(-1.25) ?? "nil")
check("text seconds", MultitrackMath.offsetText(12.3) == "starts 12 s later")
check("text minutes", MultitrackMath.offsetText(65) == "starts 1:05 later")
check("text zero", MultitrackMath.offsetText(0.02) == nil)

// MARK: Speaker names

let names: [(String, String)] = [
    ("Tim_MV7.wav", "Tim"), ("Guest_SM7B.wav", "Guest"), ("ana-sm7b.WAV", "Ana"), ("02 - Ana (SM7B).wav", "Ana"),
    ("Track 3.wav", "Track 3"), ("AUDIO_002.wav", "AUDIO 002"), ("01.wav", "Track 01"), ("Tim.m4a", "Tim"),
    ("tim mv7 final.aiff", "Tim"), ("Zoom_Tr1.wav", "Zoom Tr1"),
]
for (file, want) in names {
    let got = MultitrackMath.speakerName(fromFile: file)
    check("name \(file)", got == want, "got \(got)")
}

// MARK: Similarity

check("same", MultitrackMath.similarity("Hello there, Tim.", "hello there tim") == 1)
check("close", MultitrackMath.similarity("So what got you into wagons?", "So what got you into wagon?") > 0.8)
check("different", MultitrackMath.similarity("So what got you into wagons?", "I grew up on a farm in Lancaster.") < 0.5)
check("empty similarity", MultitrackMath.similarity("", "anything") == 0)

// MARK: Placing and merging

let w = [WordSpan(text: "Hi", start: 1.0, end: 1.3), WordSpan(text: "there.", start: 1.3, end: 1.8)]
let placed = MultitrackMath.place([Segment(start: 1.0, end: 1.8, text: "Hi there.", words: w)], track: 1, offset: 0.5)
check("place shifts", placed[0].segment.start == 1.5 && placed[0].segment.end == 2.3)
check("place shifts words", placed[0].segment.words?.first?.start == 1.5 && placed[0].segment.words?.last?.end == 2.3)
check("place speaker", placed[0].segment.speaker == "S2" && placed[0].track == 1)

let t1 = MultitrackMath.place([Segment(start: 0, end: 2, text: "Welcome back."), Segment(start: 5, end: 7, text: "Tell me more.")], track: 0, offset: 0)
let t2 = MultitrackMath.place([Segment(start: 2.2, end: 4.5, text: "Thanks for having me."), Segment(start: 4.3, end: 4.5, text: "Sure.")], track: 1, offset: 0.4)
let merged = MultitrackMath.merge(t2 + t1)
check("merge order", merged.map(\.text) == ["Welcome back.", "Thanks for having me.", "Sure.", "Tell me more."], "\(merged.map(\.text))")
check("merge speakers", merged.map { $0.speaker ?? "" } == ["S1", "S2", "S2", "S1"])
let tie = MultitrackMath.merge(MultitrackMath.place([Segment(start: 1, end: 2, text: "b")], track: 1, offset: 0)
                               + MultitrackMath.place([Segment(start: 1, end: 2, text: "a")], track: 0, offset: 0))
check("merge tie by track", tie.map(\.text) == ["a", "b"])

let sp = MultitrackMath.speakers(names: ["Tim", "  ", "Ana"])
check("speakers", sp.map(\.id) == ["S1", "S2", "S3"] && sp.map(\.name) == ["Tim", "Speaker 2", "Ana"])

// MARK: Mic bleed

// Two mics, 20 s each at 100 frames/s. Tim talks 0–4 s (loud on mic 1, bleeds −26 dB into mic 2); Ana 5–9 s
// (the other way round); 12–14 s both talk at once, different words.
func bleedEnv(loud: [ClosedRange<Double>], bleed: [ClosedRange<Double>]) -> [Float] {
    (0..<2000).map { i in
        let t = Double(i) / 100
        if loud.contains(where: { $0.contains(t) }) { return 0.3 }
        if bleed.contains(where: { $0.contains(t) }) { return 0.015 }
        return 0.0005
    }
}
let envTim = bleedEnv(loud: [0...4, 12...14], bleed: [5...9])
let envAna = bleedEnv(loud: [5...9, 12...14], bleed: [0...4])
let tim = MultitrackMath.place([
    Segment(start: 0.1, end: 3.9, text: "Welcome back to the show, everyone."),
    Segment(start: 5.3, end: 8.7, text: "Thanks so much for having me here."),          // Ana's words, heard by Tim's mic
    Segment(start: 12.0, end: 14.0, text: "Right, exactly."),
], track: 0, offset: 0)
let ana = MultitrackMath.place([
    Segment(start: 0.4, end: 4.1, text: "Welcome back to the show everyone"),           // Tim's words, heard by Ana's mic
    Segment(start: 5.1, end: 8.9, text: "Thanks so much for having me here."),
    Segment(start: 12.1, end: 13.9, text: "No, I mean the other one."),
], track: 1, offset: 0)
let kept = MultitrackMath.filterBleed(tim + ana, envelopes: [envTim, envAna], offsets: [0, 0])
let keptText = kept.map { "\($0.track):\($0.segment.text)" }
check("bleed keeps the louder mic", keptText.contains("0:Welcome back to the show, everyone.") && keptText.contains("1:Thanks so much for having me here."), "\(keptText)")
check("bleed drops the quieter copy", !keptText.contains("1:Welcome back to the show everyone") && !keptText.contains("0:Thanks so much for having me here."), "\(keptText)")
check("crosstalk with different words stays", keptText.contains("0:Right, exactly.") && keptText.contains("1:No, I mean the other one."), "\(keptText)")
check("bleed count", kept.count == 4, "\(kept.count)")

// Offsets apply to levels: Ana's recorder started 2 s late, so her envelope is 2 s behind the timeline.
let anaLate = Array(envAna.dropFirst(200)) + [Float](repeating: 0.0005, count: 200)
let keptLate = MultitrackMath.filterBleed(tim + ana, envelopes: [envTim, anaLate], offsets: [0, 2])
check("bleed with offset", keptLate.count == 4 && keptLate.contains { $0.track == 1 && $0.segment.text.hasPrefix("Thanks") }, "\(keptLate.map { "\($0.track):\($0.segment.text)" })")

// Very quiet segments that overlap another track's speech go; very quiet ones on their own stay.
let envQuiet: [Float] = (0..<2000).map { i in
    let t = Double(i) / 100
    if (0...4).contains(t) { return 0.3 }                 // its own speech, sets the reference level
    if (5...9).contains(t) || (15...17).contains(t) { return 0.0012 }   // about −48 dB below it
    return 0.0005
}
let quietTrack = MultitrackMath.place([
    Segment(start: 0.2, end: 3.8, text: "Let's get started."),
    Segment(start: 5.5, end: 8.5, text: "mumble that sounds like nothing"),   // overlaps Ana: dropped
    Segment(start: 15.2, end: 16.8, text: "quiet aside"),                     // nobody else talking: kept
], track: 0, offset: 0)
let anaOnly = MultitrackMath.place([Segment(start: 5.1, end: 8.9, text: "Thanks so much for having me here.")], track: 1, offset: 0)
let keptQuiet = MultitrackMath.filterBleed(quietTrack + anaOnly, envelopes: [envQuiet, envAna], offsets: [0, 0]).map(\.segment.text)
check("quiet overlapping dropped", !keptQuiet.contains("mumble that sounds like nothing"), "\(keptQuiet)")
check("quiet alone kept", keptQuiet.contains("quiet aside"), "\(keptQuiet)")
check("loud kept", keptQuiet.contains("Let's get started.") && keptQuiet.contains("Thanks so much for having me here."), "\(keptQuiet)")

// Same track repeating itself is never treated as bleed.
let repeatTrack = MultitrackMath.place([Segment(start: 0, end: 1, text: "Okay."), Segment(start: 1.2, end: 2, text: "Okay.")], track: 0, offset: 0)
check("same track repeats stay", MultitrackMath.filterBleed(repeatTrack, envelopes: [envTim], offsets: [0]).count == 2)

// Missing envelopes don't crash and keep everything distinct.
check("no envelopes", MultitrackMath.filterBleed(t1 + t2, envelopes: [], offsets: []).count == 4)

print("multitrack tests: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
