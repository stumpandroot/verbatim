import Foundation

// The noisy-recording rules (Verbatim/Transcription/UnclearRules.swift) and Transcribe again's versions
// (Verbatim/Model/TranscriptVersions.swift), on synthetic segments and speech probabilities only: no audio, and never
// a private recording. Not part of any app target; run mac/tools/test-unclear.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 0.3) -> Bool { abs(a - b) <= tol }

/// Speech probabilities at FluidAudio's frame (256 ms): `floor` everywhere, then each (start, end, value) range.
let frame = 0.256
func probs(_ seconds: Double, floor: Float = 0.05, _ ranges: [(Double, Double, Float)]) -> SpeechProbabilities {
    let n = Int((seconds / frame).rounded(.up))
    var v = [Float](repeating: floor, count: n)
    for (a, b, p) in ranges {
        for i in 0..<n { let t = Double(i) * frame; if t >= a && t < b { v[i] = p } }
    }
    return SpeechProbabilities(frame: frame, values: v)
}
/// Words every 0.4 s across a range, all at confidence `p` (nil: an engine that gives none).
func words(_ a: Double, _ b: Double, p: Double?) -> [WordSpan] {
    stride(from: a, to: b, by: 0.4).enumerated().map { i, t in WordSpan(text: "w\(i)", start: t, end: t + 0.3, confidence: p) }
}

// MARK: Speech clips (what Whisper hears)

do {
    let p = probs(30, [(5, 10, 0.8), (10, 11, 0.1), (11, 15, 0.8)])
    let c = UnclearRules.speechClips(p)
    check("clips: a 1 s dip inside speech doesn't end the stretch (min silence 1.5 s)", c.count == 1, "\(c)")
    check("clips: padded by 0.5 s on each side", c.count == 1 && near(c[0].lowerBound, 4.5) && near(c[0].upperBound, 15.5), "\(c)")
    let two = UnclearRules.speechClips(probs(30, [(5, 8, 0.8), (11, 14, 0.8)]))
    check("clips: a 3 s pause splits two stretches", two.count == 2, "\(two)")
    let weak = UnclearRules.speechClips(probs(20, [(5, 10, 0.3)]))
    check("clips: 0.3 never starts speech (threshold 0.35)", weak.isEmpty, "\(weak)")
    let held = UnclearRules.speechClips(probs(30, [(5, 8, 0.8), (8, 12, 0.3), (12, 14, 0.8)]))
    check("clips: 0.3 between neg 0.2 and 0.35 keeps a stretch going", held.count == 1, "\(held)")
    let edge = UnclearRules.speechClips(probs(10, [(0, 3, 0.9), (9, 10, 0.9)]))
    check("clips: padding stays inside the recording", edge.first.map { $0.lowerBound >= 0 } == true && edge.last.map { $0.upperBound <= 10.3 } == true, "\(edge)")
    check("clips: coverage is the share of the recording", near(UnclearRules.coverage(c, duration: 30), 11.0 / 30, 0.05))
    check("thresholds: the report's 0.35 / 0.2 / 500 ms pad", UnclearRules.vadThreshold == 0.35 && UnclearRules.vadNegThreshold == 0.2 && UnclearRules.speechPad == 0.5)
    check("thresholds: never below 0.25 (0.15 let hallucinations back in)", UnclearRules.vadThreshold >= 0.25)
}

// MARK: Unclear spans

do {
    let p = probs(30, [(10, 16, 0.8)])
    let spans = UnclearRules.unclearSpans(words: words(10, 11, p: 0.9), speech: p)
    check("rule 1: speech with no heard word for 2 s or more is unclear", spans.count == 1 && spans[0].reason == .noWords, "\(spans)")
    check("rule 1: the span starts after the last heard word", spans.first.map { near($0.start, 11.4, 0.4) && near($0.end, 16, 0.4) } == true, "\(spans)")
    let short = UnclearRules.unclearSpans(words: [], speech: probs(30, [(10, 11.5, 0.8)]))
    check("rule 1: 1.5 s of speech with nothing heard isn't unclear (2 s minimum)", short.isEmpty, "\(short)")
    let apple = UnclearRules.unclearSpans(words: words(10, 16, p: nil), speech: p)
    check("rule 1: words without a confidence (Apple's engine) count as heard", apple.isEmpty, "\(apple)")
    let guesses = UnclearRules.unclearSpans(words: words(10, 16, p: 0.3), speech: p)
    check("rule 1: words all under 0.4 aren't heard, and the stretch is unclear", guesses.count == 1 && guesses[0].reason == .noWords, "\(guesses)")
    let dip = probs(30, [(10, 16, 0.8), (13, 13.26, 0.1)])
    let smoothedRun = UnclearRules.unclearSpans(words: [], speech: dip)
    check("rule 1: smoothing (0.5 s) carries a one-frame dip", smoothedRun.count == 1, "\(smoothedRun)")
    let quiet = UnclearRules.unclearSpans(words: [], speech: probs(30, floor: 0.3, []))
    check("rule 1: steady 0.3 (under 0.4) isn't speech", quiet.isEmpty, "\(quiet)")
    let none = UnclearRules.unclearSpans(words: words(10, 16, p: 0.9), speech: p)
    check("rule 1: nothing unclear when every stretch has heard words", none.isEmpty, "\(none)")
}

do {
    func w(_ t: Double, _ p: Double?) -> WordSpan { WordSpan(text: "x", start: t, end: t + 0.3, confidence: p) }
    let three = UnclearRules.unclearSpans(words: [w(1, 0.9), w(2, 0.2), w(2.5, 0.3), w(3, 0.1), w(4, 0.9)], speech: nil)
    check("rule 2: three words in a row under 0.35 make a span", three.count == 1 && three[0].reason == .lowConfidence && near(three[0].start, 2, 0.01) && near(three[0].end, 3.3, 0.01), "\(three)")
    let two = UnclearRules.unclearSpans(words: [w(1, 0.2), w(2, 0.2), w(3, 0.9), w(4, 0.2)], speech: nil)
    check("rule 2: two in a row isn't enough", two.isEmpty, "\(two)")
    let edge = UnclearRules.unclearSpans(words: [w(1, 0.35), w(2, 0.35), w(3, 0.35)], speech: nil)
    check("rule 2: exactly 0.35 isn't low", edge.isEmpty, "\(edge)")
    let gap = UnclearRules.unclearSpans(words: [w(1, 0.2), w(2, 0.2), w(10, 0.2)], speech: nil)
    check("rule 2: a long pause breaks a run", gap.isEmpty, "\(gap)")
    let merged = UnclearRules.merged([UnclearSpan(start: 1, end: 3, reason: .lowConfidence), UnclearSpan(start: 2, end: 5, reason: .noWords)])
    check("spans: overlapping spans merge, and missing words win the reason", merged == [UnclearSpan(start: 1, end: 5, reason: .noWords)], "\(merged)")
}

// MARK: Hallucinations

do {
    let silent = probs(60, [(20, 30, 0.8)])
    func seg(_ a: Double, _ b: Double, _ text: String) -> Segment { Segment(start: a, end: b, text: text) }
    check("drop: compression ratio over 2.4 (repeated text)",
          UnclearRules.drop(ScoredSegment(segment: seg(20, 25, "thank you thank you thank you"), compressionRatio: 2.6), speech: silent) == .repeated)
    check("keep: compression ratio 2.4 or under",
          UnclearRules.drop(ScoredSegment(segment: seg(20, 25, "a normal sentence here"), compressionRatio: 1.4), speech: silent) == nil)
    check("drop: no-speech over 0.6 with log probability under -1",
          UnclearRules.drop(ScoredSegment(segment: seg(22, 24, "Thank you very much."), avgLogprob: -1.3, noSpeechProb: 0.8), speech: nil) == .noSpeech)
    check("keep: no-speech over 0.6 but a confident log probability",
          UnclearRules.drop(ScoredSegment(segment: seg(22, 24, "Okay, let's go."), avgLogprob: -0.4, noSpeechProb: 0.8), speech: nil) == nil)
    check("drop: a short line over no speech (peak under 0.2)",
          UnclearRules.drop(ScoredSegment(segment: seg(40, 41.5, "Thank you.")), speech: silent) == .overSilence)
    check("keep: a long line over no speech (speech detection can miss soft speech)",
          UnclearRules.drop(ScoredSegment(segment: seg(40, 46, "one two three four five six seven eight nine ten")), speech: silent) == nil)
    check("keep: a short line inside speech",
          UnclearRules.drop(ScoredSegment(segment: seg(22, 23, "Thank you.")), speech: silent) == nil)
    check("keep: without speech probabilities the silence rule doesn't apply",
          UnclearRules.drop(ScoredSegment(segment: seg(40, 41.5, "Thank you.")), speech: nil) == nil)
    let cleaned = UnclearRules.clean([
        ScoredSegment(segment: seg(21, 24, "Her name's a kid in Alien."), avgLogprob: -0.3, compressionRatio: 1.2, noSpeechProb: 0.05),
        ScoredSegment(segment: seg(40, 41, "Thank you."), avgLogprob: -1.4, compressionRatio: 1.0, noSpeechProb: 0.9),
        ScoredSegment(segment: seg(50, 51, "you"), avgLogprob: -0.8, compressionRatio: 1.0, noSpeechProb: 0.2),
    ], speech: silent)
    check("clean: keeps the real line and drops both hallucinations", cleaned.kept.map(\.text) == ["Her name's a kid in Alien."], "\(cleaned.kept.map(\.text))")
    check("clean: counts why each was dropped", cleaned.dropped[.noSpeech] == 1 && cleaned.dropped[.overSilence] == 1, "\(cleaned.dropped)")
}

// MARK: Splitting at long pauses

do {
    let ws = [WordSpan(text: "So", start: 0, end: 0.3), WordSpan(text: "anyway,", start: 0.4, end: 0.8),
              WordSpan(text: "it's", start: 5.5, end: 5.7), WordSpan(text: "over.", start: 5.8, end: 6.2)]
    var s = Segment(start: 0, end: 6.2, text: "So anyway, it's over.", words: ws, speaker: "S1")
    let parts = UnclearRules.splitAtGaps(s)
    check("split: a 4.7 s pause between words splits the line", parts.count == 2 && parts[0].text == "So anyway," && parts[1].text == "it's over.", "\(parts.map(\.text))")
    check("split: the first part keeps the line's id and both keep the speaker", parts.first?.id == s.id && parts.allSatisfy { $0.speaker == "S1" })
    check("split: times follow the words", parts.count == 2 && parts[1].start == 5.5 && parts[0].end == 0.8)
    s.words?[2].start = 3.5; s.words?[2].end = 3.7
    check("split: a 2.7 s pause doesn't", UnclearRules.splitAtGaps(s).count == 1)
    check("split: a line without word timings stays whole", UnclearRules.splitAtGaps(Segment(start: 0, end: 9, text: "x y")).count == 1)
}

// MARK: Reading view and exports

do {
    let ws = [WordSpan(text: "the", start: 0, end: 0.2, confidence: 0.9), WordSpan(text: "bear", start: 0.3, end: 0.5, confidence: 0.2),
              WordSpan(text: "feed", start: 0.6, end: 0.8, confidence: 0.1), WordSpan(text: "in", start: 0.9, end: 1, confidence: 0.3),
              WordSpan(text: "annihilation", start: 1.1, end: 1.8, confidence: 0.6), WordSpan(text: "uh", start: 1.9, end: 2, confidence: 0.2)]
    let low = UnclearRules.lowWords(Segment(start: 0, end: 2, text: "the bear feed in annihilation uh", words: ws))
    check("marks: words under 0.35 are marked", low == [1, 2, 3, 5], "\(low.sorted())")
    check("marks: words without confidence aren't marked", UnclearRules.lowWords(Segment(start: 0, end: 1, text: "a b", words: [WordSpan(text: "a", start: 0, end: 0.4), WordSpan(text: "b", start: 0.5, end: 1)])).isEmpty)
    check("label: \"unclear 2:10\"", UnclearRules.label(130.7) == "unclear 2:10", UnclearRules.label(130.7))
    check("label: past an hour", UnclearRules.label(3725) == "unclear 1:02:05", UnclearRules.label(3725))
    let spans = [UnclearSpan(start: 20, end: 23), UnclearSpan(start: 40, end: 42, reason: .lowConfidence), UnclearSpan(start: 99, end: 101)]
    let placed = UnclearRules.placements(spans, lineStarts: [0, 10, 24, 50])
    check("placements: a chip goes before the first line after it", placed.count == 2 && placed[0].before == 2, "\(placed.map(\.before))")
    check("placements: after the last line, at the end", placed.count == 2 && placed[1].before == Int.max)
    check("placements: low-confidence runs show as marked words, not chips", !placed.contains { $0.span.reason == .lowConfidence })
    check("suggest: more than 2 unclear spans per 10 minutes", UnclearRules.suggestsAnotherPass(Array(repeating: UnclearSpan(start: 0, end: 2), count: 3), duration: 600))
    check("suggest: 2 per 10 minutes isn't", !UnclearRules.suggestsAnotherPass(Array(repeating: UnclearSpan(start: 0, end: 2), count: 2), duration: 600))
}

// MARK: Stored form

do {
    let data = try! JSONEncoder().encode(WordSpan(text: "Welch", start: 1, end: 1.4, confidence: 0.74129))
    let json = String(data: data, encoding: .utf8) ?? ""
    check("word: confidence is stored as \"p\" with two decimals", json.contains("\"p\":0.74") && !json.contains("confidence"), json)
    let old = try! JSONDecoder().decode(WordSpan.self, from: Data(#"{"text":"a","start":0,"end":1}"#.utf8))
    check("word: a word from an older build reads without a confidence", old.confidence == nil)
    let plain = String(data: try! JSONEncoder().encode(WordSpan(text: "a", start: 0, end: 1)), encoding: .utf8) ?? ""
    check("word: no confidence, no key", !plain.contains("\"p\""), plain)
    let future = try! JSONDecoder().decode(UnclearSpan.self, from: Data(#"{"start":3,"end":5,"reason":"crosstalk"}"#.utf8))
    check("span: a reason from a newer build reads as missing words", future == UnclearSpan(start: 3, end: 5, reason: .noWords))
    let guess = try! JSONDecoder().decode(UnclearSpan.self, from: try! JSONEncoder().encode(UnclearSpan(start: 1, end: 2, reason: .lowConfidence)))
    check("span: a low-confidence span round-trips", guess.reason == .lowConfidence)

    var t = Transcript(title: "Lawn", source: .voiceMemo, sourceLabel: "Voice memo", duration: 60, audioFileName: "a.m4a", model: "m")
    t.unclear = [UnclearSpan(start: 10, end: 13)]
    t.previousVersion = TranscriptVersion(segments: [Segment(start: 0, end: 1, text: "old")], engine: "fluid", model: "Parakeet TDT v2")
    t.rerunRequest = RerunRequest(engine: "whisper", model: "large-v3_turbo", device: "phone", deviceName: "Tim's iPhone")
    let back = try! JSONDecoder().decode(Transcript.self, from: try! JSONEncoder().encode(t))
    check("transcript: unclear spans, the kept version, and the request round-trip",
          back.unclear == t.unclear && back.previousVersion?.segments.first?.text == "old" && back.rerunRequest?.model == "large-v3_turbo")
    var bare = Transcript(title: "x", source: .voiceMemo, sourceLabel: "", duration: 1, audioFileName: nil, model: "")
    bare.unclear = nil
    let bareJSON = String(data: try! JSONEncoder().encode(bare), encoding: .utf8) ?? ""
    check("transcript: nothing written for transcripts without them", !bareJSON.contains("unclear") && !bareJSON.contains("previousVersion") && !bareJSON.contains("rerunRequest"))
    let broken = #"{"title":"x","unclear":"nope","previousVersion":7,"rerunRequest":[1]}"#
    let read = try? JSONDecoder().decode(Transcript.self, from: Data(broken.utf8))
    check("transcript: shapes it can't read are dropped, never the whole file", read != nil && read?.unclear == nil && read?.previousVersion == nil && read?.rerunRequest == nil)
    check("transcript: the new keys are known (not kept as a newer build's)", ["unclear", "previousVersion", "rerunRequest"].allSatisfy(Transcript.knownKeys.contains))
}

// MARK: Transcribe again: edits, carry-over, and switching back

func lines(_ spans: [(Double, Double, String?)]) -> [Segment] { spans.map { Segment(start: $0.0, end: $0.1, text: "line \(Int($0.0))", speaker: $0.2) } }

do {
    var t = Transcript(title: "Call", source: .voiceMemo, sourceLabel: "", duration: 20, audioFileName: "c.m4a", model: "Parakeet TDT v2")
    t.original = lines([(0, 10, "S1"), (10, 20, "S2")]); t.segments = t.original
    check("edits: none on a fresh transcript", !t.hasHandEdits)
    t.corrections = [Correction(segmentId: t.segments[0].id, from: "lit it's", to: "Lititz", byDictionary: true)]
    t.segments[0].text = "Lititz"
    check("edits: a Dictionary fix isn't a hand edit", !t.hasHandEdits)
    t.corrections.append(Correction(segmentId: t.segments[1].id, from: "a", to: "b", byDictionary: false))
    check("edits: your own fix is", t.hasHandEdits)
    t.corrections = []; t.segments[0].text = "line 0"; t.segments[1].text = "typed over"
    check("edits: a line changed without a correction is", t.hasHandEdits)
}

do {
    var t = Transcript(title: "Call", source: .voiceMemo, sourceLabel: "", duration: 20, audioFileName: "c.m4a", model: "Parakeet TDT v2")
    t.engine = "fluid"
    t.original = lines([(0, 10, "S1"), (10, 20, "S2")]); t.segments = t.original
    t.speakers = [Speaker(id: "S1", name: "Tim"), Speaker(id: "S2", name: "Speaker 2")]
    let oldLine = t.segments[1].id
    t.notes = [Note(text: "moment", at: 13, segmentId: oldLine, isBookmark: true), Note(text: "untimed", segmentId: t.segments[0].id), Note(text: "loose")]
    let before = t.currentVersion
    t.previousVersion = before
    // New words from Whisper Turbo, without speakers.
    t.original = lines([(0, 5, nil), (5, 12, nil), (12, 20, nil)]); t.segments = t.original
    t.speakers = []; t.engine = "whisper"; t.model = "Whisper Large v3 Turbo"
    t.carryOver(from: before)
    check("carry-over: speakers follow time (most overlap wins)", t.segments.map(\.speaker) == ["S1", "S1", "S2"], "\(t.segments.map(\.speaker))")
    check("carry-over: the engine's own lines get them too", t.original.map(\.speaker) == ["S1", "S1", "S2"])
    check("carry-over: names stay", t.speakers.map(\.name) == ["Tim", "Speaker 2"], "\(t.speakers.map(\.name))")
    check("carry-over: a moment moves to the new line at its time", t.notes[0].segmentId == t.segments[2].id)
    check("carry-over: a note without a time moves to the line at its old line's middle (5 s)", t.notes[1].segmentId == t.segments[1].id)
    check("carry-over: a note with no line stays as it is", t.notes[2].segmentId == nil && t.notes[2].text == "loose")
    check("turbo: the transcript knows it ran on Whisper Turbo", t.isTurbo)

    let turboFirst = t.segments.map(\.id)
    check("switch back: swaps to the kept words", t.switchVersion() && t.engine == "fluid" && t.segments.count == 2 && t.speakers.count == 2)
    check("switch back: the Turbo words are kept in turn", t.previousVersion?.engine == "whisper" && t.previousVersion?.segments.map(\.id) == turboFirst)
    check("switch back: the moment moves with it", t.notes[0].segmentId == t.segments[1].id)
    check("switch again: back to Whisper Turbo", t.switchVersion() && t.isTurbo && t.segments.map(\.id) == turboFirst)
    var none = Transcript(title: "x", source: .voiceMemo, sourceLabel: "", duration: 1, audioFileName: nil, model: "")
    check("switch: nothing to switch to without a kept version", !none.switchVersion())
}

do {
    var t = Transcript(title: "x", source: .voiceMemo, sourceLabel: "", duration: 9, audioFileName: "a.m4a", model: "")
    t.original = lines([(0, 9, "S1")]); t.segments = t.original
    t.speakers = [Speaker(id: "S1", name: "Tim")]
    let old = t.currentVersion
    t.segments = lines([(0, 9, "S1"), (9, 12, "S2")]); t.original = t.segments
    t.speakers = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")]
    t.carryOver(from: old)
    check("carry-over: new words that found their own speakers keep them", t.speakers.count == 2 && t.segments.last?.speaker == "S2")
}

do {
    var t = Transcript(title: "x", source: .voiceMemo, sourceLabel: "", duration: 9, audioFileName: "a.m4a", model: "")
    t.rerunRequest = RerunRequest(engine: "whisper", model: "large-v3_turbo")
    check("waiting: \"Waiting for your Mac\" until a Mac takes it", t.stageText == "Waiting for your Mac", t.stageText)
    t.status = .processing; t.processingDevice = "mac-1"; t.processingDeviceName = "Tim's Mac"
    check("waiting: then it says where it runs", t.stageText == "Transcribing on Tim's Mac", t.stageText)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
