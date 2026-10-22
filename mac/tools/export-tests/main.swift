import Foundation

// Tests for ExportCore.swift: timecodes, offsets, the text layout, subtitle segmentation, and file names. Not part
// of any app target; run mac/tools/test-export.sh.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name)\(detail().isEmpty ? "" : "\n  " + detail())") }
}
func eq<T: Equatable>(_ name: String, _ a: T, _ b: T) { check(name, a == b, "got \(a)\n  expected \(b)") }

// MARK: Timecodes

eq("bracketed under a minute", Timecode.format(4.6, style: .bracketed), "[00:00:04]")
eq("bracketed past an hour", Timecode.format(3723.9, style: .bracketed), "[01:02:03]")
eq("plain under an hour", Timecode.format(724, style: .plain), "12:04")
eq("plain past an hour", Timecode.format(3734, style: .plain), "1:02:14")
eq("plain seconds keep two digits", Timecode.format(31, style: .plain), "00:31")
eq("offset adds", Timecode.format(4, style: .bracketed, offset: 3600), "[01:00:04]")
eq("negative clamps to zero", Timecode.format(-3, style: .bracketed), "[00:00:00]")
eq("digits drop brackets", Timecode.digits(65, style: .bracketed), "00:01:05")
eq("cue SRT", Timecode.cue(62.345, sep: ","), "00:01:02,345")
eq("cue VTT rounds ms", Timecode.cue(3600.0005, sep: "."), "01:00:00.001")
eq("spoken minutes", Timecode.spoken(42 * 60 + 10), "42 min")
eq("spoken hours", Timecode.spoken(72 * 60), "1 h 12 min")
eq("spoken seconds", Timecode.spoken(38), "38 s")

eq("offset HH:MM:SS", Timecode.parseOffset("01:00:00"), 3600)
eq("offset MM:SS", Timecode.parseOffset("2:30"), 150)
eq("offset seconds with fraction", Timecode.parseOffset("12.5"), 12.5)
eq("offset fraction in last field", Timecode.parseOffset("00:00:01.25"), 1.25)
eq("offset empty is zero", Timecode.parseOffset("  "), 0)
eq("offset rejects 61 minutes", Timecode.parseOffset("00:61:00"), nil)
eq("offset rejects words", Timecode.parseOffset("abc"), nil)
eq("offset rejects four fields", Timecode.parseOffset("1:2:3:4"), nil)
eq("offset rejects fraction in hours", Timecode.parseOffset("1.5:00:00"), nil)
eq("offset text", Timecode.offsetText(3600), "01:00:00")
eq("offset text empty", Timecode.offsetText(0), "")
eq("offset text round trip", Timecode.parseOffset(Timecode.offsetText(5025.5)), 5025.5)

// MARK: Options persistence and old keys

do {
    let d = UserDefaults(suiteName: "export-tests-\(UUID().uuidString)")!
    d.set(false, forKey: "export.speakers"); d.set(true, forKey: "export.timecodes"); d.set("Transcript", forKey: "export.source")
    let old = ExportOptions.load(d)
    check("old keys: speakers off", old.speakerMode == .off)
    check("old keys: timecodes on means every paragraph", old.timecodeMode == .everyParagraph)
    check("old keys: source", old.source == .transcript)
    var o = ExportOptions()
    o.speakerMode = .everyParagraph; o.timecodeMode = .every30s; o.timecodeStyle = .plain; o.timecodeOffset = 3600
    o.moments = .end; o.includeHidden = true; o.summary = true; o.header = false
    o.subtitles = SubtitleSettings(charsPerLine: 32, linesPerCaption: 1, minDuration: 1.5, maxDuration: 5)
    o.save(to: d)
    eq("round trip", ExportOptions.load(d), o)
    check("old keys still written", d.bool(forKey: "export.speakers") && d.bool(forKey: "export.timecodes"))
}

// MARK: Layout

func sampleDoc() -> ExportDocument {
    ExportDocument(
        title: "Studio walkthrough with Ana",
        details: ["Meeting", "Oct 20, 2026", "42 min", "Ana, Tim"],
        summary: ExportSummary(overview: "Ana and Tim walked the new studio.", keyPoints: ["Two more stands"], byModel: true),
        paragraphs: [
            ExportParagraph(speaker: "Ana", pieces: [ExportPiece(start: 4, text: "This wall gets the best light.")]),
            ExportParagraph(speaker: "Tim", pieces: [ExportPiece(start: 31, text: "Agreed."), ExportPiece(start: 36, text: "Second key from the left?")]),
            ExportParagraph(speaker: "Tim", pieces: [ExportPiece(start: 50, text: "And darker behind.")]),
            ExportParagraph(speaker: "Ana", pieces: [ExportPiece(start: 72, text: "Two more stands.")]),
        ],
        moments: [ExportMoment(at: 31, text: "Bring the second key in from the left", bookmark: true)],
        footer: "Transcribed with Verbatim")
}

do {
    var o = ExportOptions()
    o.summary = true; o.timecodeMode = .everyParagraph; o.moments = .end
    let txt = ExportLayout.text(sampleDoc(), o)
    let expected = """
    Studio walkthrough with Ana
    Meeting · Oct 20, 2026 · 42 min · Ana, Tim

    Summary (AI-generated)
    Ana and Tim walked the new studio.
    - Two more stands

    [00:00:04] Ana: This wall gets the best light.

    [00:00:31] Tim: Agreed. Second key from the left?

    [00:00:50] And darker behind.

    [00:01:12] Ana: Two more stands.

    Moments
    [00:00:31] Bring the second key in from the left
    """
    eq("text matches the mockup's shape", txt, expected)

    o.speakerMode = .everyParagraph; o.timecodeMode = .onSpeakerChange; o.summary = false; o.moments = .inline; o.header = false
    let t2 = ExportLayout.text(sampleDoc(), o)
    eq("speaker every paragraph, stamp on change, inline moment", t2, """
    [00:00:04] Ana: This wall gets the best light.

    [00:00:31] Tim: [★ Bring the second key in from the left] Agreed. Second key from the left?

    Tim: And darker behind.

    [00:01:12] Ana: Two more stands.
    """)

    o.speakerMode = .off; o.timecodeMode = .every30s; o.moments = .off; o.timecodeStyle = .plain
    eq("every 30 seconds", ExportLayout.text(sampleDoc(), o), """
    00:04 This wall gets the best light.

    00:31 Agreed. Second key from the left?

    And darker behind.

    01:12 Two more stands.
    """)

    o.timecodeMode = .off; o.singleParagraph = true; o.speakerMode = .onChange; o.provenance = true
    eq("one paragraph with footer", ExportLayout.text(sampleDoc(), o),
       "Ana: This wall gets the best light. Tim: Agreed. Second key from the left? And darker behind. Ana: Two more stands.\n\n—\nTranscribed with Verbatim")

    var m = ExportOptions(); m.summary = true; m.moments = .end; m.timecodeMode = .everyParagraph
    var doc = sampleDoc(); doc.link = { "https://youtu.be/x?t=\(Int($0))s" }
    let md = ExportLayout.markdown(doc, m)
    check("markdown H1", md.hasPrefix("# Studio walkthrough with Ana\n\n_Meeting · Oct 20, 2026 · 42 min · Ana, Tim_"), md)
    check("markdown summary and transcript headings", md.contains("## Summary (AI-generated)\n\nAna and Tim walked the new studio.\n\n- Two more stands\n\n## Transcript"), md)
    check("markdown bold speaker with linked stamp", md.contains("[00:00:04](https://youtu.be/x?t=4s) **Ana:** This wall"), md)
    check("markdown moments list", md.contains("## Moments\n\n- [00:00:31] Bring the second key"), md)

    var lines = ExportOptions(); lines.header = false; lines.timecodeMode = .everyParagraph
    var raw = sampleDoc(); raw.lineByLine = true
    check("raw transcript stamps sit one per line", ExportLayout.text(raw, lines).contains("best light.\n[00:00:31]"))
}

// MARK: Summary reflection

struct FakeSummary { var overview: String; var keyPoints: [String] }
struct WithSummary { var title = "x"; var summary: FakeSummary? ; var summaryByModel = true }
struct WithoutSummary { var title = "x" }
eq("reflects an optional summary", ExportSummary.reflect(WithSummary(summary: FakeSummary(overview: "O", keyPoints: ["a"]))),
   ExportSummary(overview: "O", keyPoints: ["a"], byModel: true))
eq("nil summary", ExportSummary.reflect(WithSummary(summary: nil)), nil)
eq("no summary property", ExportSummary.reflect(WithoutSummary()), nil)
eq("empty summary is none", ExportSummary.reflect(WithSummary(summary: FakeSummary(overview: " ", keyPoints: []))), nil)

// MARK: Subtitle layout

eq("one line when it fits", Subtitles.layout(["Hello", "there"], charsPerLine: 42, maxLines: 2), ["Hello there"])
let long = "This wall gets the best light in the morning so I would put the chair here".split(separator: " ").map(String.init)
if let l = Subtitles.layout(long, charsPerLine: 42, maxLines: 2) {
    check("two balanced lines", l.count == 2 && l.allSatisfy { $0.count <= 42 } && abs(l[0].count - l[1].count) <= 10, "\(l)")
    eq("no words lost", l.joined(separator: " "), long.joined(separator: " "))
} else { check("two lines fit", false) }
eq("too long for the lines", Subtitles.layout(long, charsPerLine: 20, maxLines: 2), nil)
eq("reserve counts on the first line", Subtitles.layout(["abcdefghij"], charsPerLine: 12, maxLines: 1, reserve: 5), ["abcdefghij"])
eq("reserve pushes to two lines", Subtitles.layout(["abcde", "fghij"], charsPerLine: 12, maxLines: 2, reserve: 5), ["abcde", "fghij"])
eq("an overlong word sits alone", Subtitles.layout(["Supercalifragilisticexpialidocious"], charsPerLine: 10, maxLines: 1), ["Supercalifragilisticexpialidocious"])

// MARK: Word timings

let ws = Subtitles.words(text: "one two three", start: 0, end: 3, timings: [(0, 0.5), (0.6, 1.2), (1.3, 3)], speaker: nil)
eq("uses engine timings when words match", ws.map(\.start), [0, 0.6, 1.3])
let est = Subtitles.words(text: "a bb ccc", start: 10, end: 19, timings: [(0, 1)], speaker: "S")
check("spreads by length when timings don't match", abs(est[0].start - 10) < 1e-9 && abs(est.last!.end - 19) < 1e-9 && est[2].end - est[2].start > est[0].end - est[0].start)

// MARK: Captions

func speech(_ text: String, from start: Double, wps: Double = 3, speaker: String? = nil) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { i, w in
        TimedWord(text: String(w), start: start + Double(i) / wps, end: start + Double(i + 1) / wps - 0.05, speaker: speaker)
    }
}

do {
    let words = speech("This wall gets the best light in the morning, so I would put the interview chair right here by the window. Can we bring the second key in from the left so the background stays darker? Yes, we will need two more stands for that.", from: 0)
    let s = SubtitleSettings()
    let caps = Subtitles.captions(words, s)
    check("captions made", !caps.isEmpty)
    check("every caption within chars and lines", caps.allSatisfy { $0.lines.count <= 2 && $0.lines.allSatisfy { $0.count <= 42 } }, "\(caps.map(\.lines))")
    check("every caption within longest", caps.allSatisfy { $0.end - $0.start <= s.maxDuration + 1e-9 })
    check("every caption at least shortest", caps.allSatisfy { $0.end - $0.start >= s.minDuration - 1e-9 })
    check("no overlaps", zip(caps, caps.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
    eq("no words lost or reordered", caps.flatMap(\.words), words.map(\.text))
    check("sentence ends break captions", caps.contains { $0.words.last == "window." } && caps.contains { $0.words.last == "darker?" }, "\(caps.map(\.words))")

    let narrow = Subtitles.captions(words, SubtitleSettings(charsPerLine: 20, linesPerCaption: 1, minDuration: 0.5, maxDuration: 3))
    check("narrow settings honored", narrow.allSatisfy { $0.lines.count == 1 && ($0.lines[0].count <= 20 || $0.words.count == 1) && $0.end - $0.start <= 3 + 1e-9 }, "\(narrow.map(\.lines))")
    check("narrow makes more captions", narrow.count > caps.count)

    // Slow speech: a long stretch with no punctuation must still break at the longest duration.
    let slow = speech("and then we kept walking along the river for a long while without saying much at all", from: 0, wps: 1)
    let sc = Subtitles.captions(slow, SubtitleSettings(charsPerLine: 42, linesPerCaption: 2, minDuration: 1, maxDuration: 4))
    check("slow speech breaks at the longest", sc.allSatisfy { $0.end - $0.start <= 4 + 1e-9 } && sc.count >= 4, "\(sc.map { ($0.start, $0.end) })")

    // A pause starts a new caption; a short blip merges forward or stretches into the gap.
    let paused = speech("Hello there.", from: 0) + speech("Much later now.", from: 10)
    let pc = Subtitles.captions(paused, SubtitleSettings())
    eq("pause breaks", pc.map(\.words), [["Hello", "there."], ["Much", "later", "now."]])
    check("short caption stretched to the shortest", pc[0].end - pc[0].start >= 1 - 1e-9)

    let blip = [TimedWord(text: "Okay.", start: 0, end: 0.2), TimedWord(text: "So", start: 0.3, end: 0.5), TimedWord(text: "here", start: 0.5, end: 0.8)]
    let bc = Subtitles.captions(blip, SubtitleSettings(charsPerLine: 42, linesPerCaption: 2, minDuration: 1, maxDuration: 7))
    eq("blip merges with the next caption", bc.map(\.words), [["Okay.", "So", "here"]])

    // No orphans: a caption that would end up as one word takes words from the one before.
    let run = speech("Agreed. Can we bring the second key in from the left so the background stays darker?", from: 0, wps: 4)
    let rc = Subtitles.captions(run, SubtitleSettings())
    check("no one-word orphan", rc.allSatisfy { $0.words.count > 2 }, "\(rc.map(\.lines))")
    eq("orphan fix keeps every word", rc.flatMap(\.words), run.map(\.text))

    // A stretch can't run into the next caption.
    let tight = [TimedWord(text: "Hi.", start: 0, end: 0.2), TimedWord(text: "Hey.", start: 0.4, end: 2, speaker: "B")]
    let tc = Subtitles.captions(tight, SubtitleSettings())
    check("stretch stops at the next caption", tc.count == 2 && abs(tc[0].end - 0.4) < 1e-9, "\(tc)")

    // Speakers: a change always breaks; labels per mode.
    let two = speech("Can we start?", from: 0, speaker: "Ana") + speech("Yes, rolling now.", from: 1.1, speaker: "Tim") + speech("Okay and also the lights.", from: 2.6, speaker: "Tim")
    let lc = Subtitles.captions(two, SubtitleSettings(charsPerLine: 24, linesPerCaption: 1, minDuration: 0.3, maxDuration: 7), speakerMode: .onChange)
    check("speaker change breaks", lc.first?.words == ["Can", "we", "start?"], "\(lc.map(\.words))")
    eq("labels only on changes", lc.map(\.label), ["Ana", "Tim"] + Array(repeating: nil, count: lc.count - 2))
    check("label room counted", lc.allSatisfy { ($0.label.map { $0.count + 2 } ?? 0) + $0.lines[0].count <= 24 || $0.words.count == 1 }, "\(lc.map { ($0.label, $0.lines) })")
    let every = Subtitles.captions(two, SubtitleSettings(charsPerLine: 24, linesPerCaption: 1, minDuration: 0.3, maxDuration: 7), speakerMode: .everyParagraph)
    check("labels on every caption", every.allSatisfy { $0.label != nil })

    let srt = Subtitles.srt(Array(lc.prefix(2)), offset: 3600)
    check("SRT shape", srt.hasPrefix("1\n01:00:00,000 --> ") && srt.contains("\nAna: Can we start?\n") && srt.contains("\n\n2\n"), srt)
    let vtt = Subtitles.vtt(Array(lc.prefix(2)))
    check("VTT shape", vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> ") && vtt.contains("<v Ana>Can we start?"), vtt)
    check("VTT escapes", Subtitles.vtt([Caption(start: 0, end: 1, lines: ["a < b & c"])]).contains("a &lt; b &amp; c"))
}

// MARK: File names

do {
    var used = Set<String>()
    eq("sanitized", ExportNames.unique("Q3: plan/review?", ext: "txt", used: &used), "Q3- plan-review-.txt")
    eq("de-duplicated", ExportNames.unique("Q3: plan/review?", ext: "txt", used: &used), "Q3- plan-review- 2.txt")
    eq("case-insensitive", ExportNames.unique("q3- PLAN-review-", ext: "txt", used: &used), "q3- PLAN-review- 3.txt")
    eq("empty title", ExportNames.unique("  ", ext: "md", used: &used), "Transcript.md")
    eq("hidden-file dot dropped", ExportNames.unique(".env notes", ext: "md", used: &used), "env notes.md")
    eq("existing files skipped", ExportNames.unique("Memo", ext: "srt", used: &used, exists: { $0 == "Memo.srt" }), "Memo 2.srt")
}

// MARK: Sources and the Apple Intelligence note

do {
    eq("source labels", ExportOptions.Source.allCases.map(\.label), ["Cleaned", "Original with corrections", "Original (engine words)"])
    eq("source raw values stay", ExportOptions.Source.allCases.map(\.rawValue), ["Document", "Transcript", "Engine"])
    let d = UserDefaults(suiteName: "export-tests-\(UUID().uuidString)")!
    check("AI note is on by default", ExportOptions.load(d).aiNote)
    var o = ExportOptions(); o.aiNote = false; o.source = .engine; o.save(to: d)
    let back = ExportOptions.load(d)
    check("AI note and engine source round trip", !back.aiNote && back.source == .engine)
    var doc = ExportDocument(title: "T", details: [], summary: nil,
                             paragraphs: [ExportParagraph(speaker: nil, pieces: [ExportPiece(start: 0, text: "Cleaned words.")])],
                             moments: [], footer: "")
    doc.aiNote = "Cleaned by Apple Intelligence from the original transcript."
    var n = ExportOptions(); n.header = true
    eq("AI note after the header", ExportLayout.text(doc, n), "T\n\nCleaned by Apple Intelligence from the original transcript.\n\nCleaned words.")
    eq("AI note in Markdown", ExportLayout.markdown(doc, n), "# T\n\n_Cleaned by Apple Intelligence from the original transcript._\n\nCleaned words.")
    n.aiNote = false
    eq("AI note off", ExportLayout.text(doc, n), "T\n\nCleaned words.")
}

print("export tests: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
