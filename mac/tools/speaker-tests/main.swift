import Foundation

// Speaker turns on transcript lines (Verbatim/Transcription/SpeakerTurns.swift), built from an iPhone import of a
// 1:01:59 YouTube podcast whose speaker changes landed a word or two off. Not part of any app target; run
// mac/tools/test-speakers.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)"); let d = detail(); if !d.isEmpty { print("    " + d) } }
}

/// Words 0.3 s long, 0.05 s apart, from `t0`; `pauseBefore` puts a longer pause before the word at that index.
func words(_ text: String, from t0: Double, pauseBefore: [Int: Double] = [:]) -> [WordSpan] {
    var t = t0
    return text.split(separator: " ").enumerated().map { k, w in
        t += pauseBefore[k] ?? 0
        defer { t += 0.35 }
        return WordSpan(text: String(w), start: t, end: t + 0.3)
    }
}

/// Lines as the engine cut them: `cuts` are word counts per line.
func lines(_ ws: [WordSpan], cuts: [Int]) -> [Segment] {
    var out: [Segment] = []
    var k = 0
    for c in cuts {
        let sub = Array(ws[k..<(k + c)])
        out.append(Segment(start: sub.first!.start, end: sub.last!.end, text: sub.map(\.text).joined(separator: " "), words: sub))
        k += c
    }
    return out
}

/// The transcript as the export reads it: consecutive lines of one speaker in one paragraph.
func paragraphs(_ segs: [Segment]) -> [String] {
    var out: [(String?, String)] = []
    for s in segs {
        if let last = out.last, last.0 == s.speaker { out[out.count - 1].1 += " " + s.text } else { out.append((s.speaker, s.text)) }
    }
    return out.map { "\($0.0.map { "Speaker " + $0.dropFirst() } ?? "?"): \($0.1)" }
}

/// Turns that change speaker at the start of word `index` (diarizer labels as FluidAudio names them).
func turns(_ ws: [WordSpan], changeAt index: Int, first: String = "D1", second: String = "D2") -> [SpeakerTurns.Turn] {
    let t = (ws[index - 1].end + ws[index].start) / 2
    return [(first, 0, t), (second, t, ws.last!.end + 1)]
}

func run(_ segs: [Segment], _ turns: [SpeakerTurns.Turn], split: Bool = true) -> [Segment] {
    var s = segs
    var none: [Segment]? = nil
    SpeakerTurns.assign(turns, to: &s, parallel: &none, split: split)
    return s
}

func index(of word: String, in ws: [WordSpan], after: Int = 0) -> Int { ws.indices.first { $0 >= after && ws[$0].text == word }! }

// "…that we'd be advocating for them legally as / Speaker 2: well." The engine cut its line before "well.", and
// the diarizer's change came at "well.".
do {
    let guest = "So who better to be speaking for justice for those very same babies that we're advocating for in the womb that we'd be advocating for them legally as well."
    let host = "We've got some really good news from preborn."
    let ws = words(guest + " " + host, from: 3000)
    let cut = index(of: "well.", in: ws)
    let segs = lines(ws, cuts: [cut, ws.count - cut])
    let out = paragraphs(run(segs, turns(ws, changeAt: cut)))
    check("“legally as / well.”: the sentence's last word stays with its speaker", out == ["Speaker 1: \(guest)", "Speaker 2: \(host)"], "\(out)")
    // The same change across a 2-second pause is left where the diarizer put it.
    let paused = words(guest + " " + host, from: 3000, pauseBefore: [cut: 2.0])
    let out2 = paragraphs(run(lines(paused, cuts: [cut, ws.count - cut]), turns(paused, changeAt: cut)))
    check("no text moves across a pause longer than 1.5 s", out2.count == 2 && out2[1].hasPrefix("Speaker 2: well."), "\(out2)")
}

// "…especially when we're / Speaker 1: talking about this fight." The diarizer changed four words early.
do {
    let host = "Are there any more scriptures like just as we wrap this up that you remind yourself of or that you like to remind others of, especially when we're talking about this fight."
    let guest = "Yeah, the other one that I I didn't read, but it's it's actually Romans 13."
    let ws = words(host + " " + guest, from: 3300)
    let change = index(of: "talking", in: ws)
    let segs = lines(ws, cuts: [change, ws.count - change])
    let out = paragraphs(run(segs, turns(ws, changeAt: change, first: "D2", second: "D1")))
    check("“especially when we're / talking about this fight.”: four words go back to the host", out == ["Speaker 1: \(host)", "Speaker 2: \(guest)"], "\(out)")
}

// "Speaker 1: What would your response be? Yes, well, …": the host's short question shared a line with the guest's
// answer (a sentence under six words doesn't end a line), so the whole line went to the guest.
do {
    let host = "But when the abolitionist crazies come out there, they're just making us all seem insane and then nothing gets passed because of them. What do you say? Because I know you've probably heard those kinds of accusations. What would your response be?"
    let guest = "Yes, well, it's very rare to see abolitionists actually opposing pro-life legislation. That's not something that I commonly see."
    let ws = words(host + " " + guest, from: 1450)
    let what = index(of: "What", in: ws, after: index(of: "accusations.", in: ws))
    let yes = index(of: "Yes,", in: ws)
    let rare = index(of: "legislation.", in: ws) + 1
    let segs = lines(ws, cuts: [what, rare - what, ws.count - rare])
    let want = ["Speaker 1: \(host)", "Speaker 2: \(guest)"]
    let atYes = paragraphs(run(segs, turns(ws, changeAt: yes)))
    check("“What would your response be? Yes, well”: the question is the host's (change at “Yes,”)", atYes == want, "\(atYes)")
    // The diarizer's change inside the question: the short sentence ends right after it, so it stays with the host.
    let inside = paragraphs(run(segs, turns(ws, changeAt: index(of: "your", in: ws, after: what))))
    check("a short sentence ending right after the change stays with the previous speaker", inside == want, "\(inside)")
    // A word late: "Yes," moves back to the guest.
    let late = paragraphs(run(segs, turns(ws, changeAt: yes + 1)))
    check("a change one word late moves back to the sentence start", late == want, "\(late)")
}

// "Speaker 1: What are you talking about? Yes, so …"
do {
    let host = "Now some of what you're saying my audience has never heard before and might be confused when you're saying that pro-life organizations are trying to stop the efforts of equal protection and abolitionist bills that would totally outlaw abortion. What are you talking about?"
    let guest = "Yes, so the the first time I was exposed to this and really when I really started to look at these arguments was in 2022, the same year that Dobbs was overturned."
    let ws = words(host + " " + guest, from: 1637)
    let what = index(of: "What", in: ws, after: index(of: "abortion.", in: ws))
    let segs = lines(ws, cuts: [what, ws.count - what])
    let out = paragraphs(run(segs, turns(ws, changeAt: index(of: "Yes,", in: ws))))
    check("“What are you talking about? Yes, so”: the question is the host's", out == ["Speaker 1: \(host)", "Speaker 2: \(guest)"], "\(out)")
}

// "Jenna, / thanks so much …": a change one word late in a long sentence moves back to its start.
do {
    let guest = "With the same things happening."
    let host = "Jenna, thanks so much for taking the time to join us."
    let ws = words(guest + " " + host, from: 60)
    let segs = lines(ws, cuts: [ws.count])
    let out = paragraphs(run(segs, turns(ws, changeAt: index(of: "thanks", in: ws))))
    check("“Jenna, / thanks so much”: back to the sentence start", out == ["Speaker 1: \(guest)", "Speaker 2: \(host)"], "\(out)")
}

// Lines that keep their shape.
do {
    let ws = words("We talked about the roof. The cedar comes Friday and the crew starts Monday morning early.", from: 0)
    let segs = lines(ws, cuts: [5, ws.count - 5])
    let t = turns(ws, changeAt: 10)   // mid-sentence, five words from either end
    let whole = run(segs, t, split: false)
    check("without split, the line count stays (Continue matches lines by index)", whole.count == segs.count && whole.map(\.id) == segs.map(\.id))
    check("without split, a line takes the speaker of most of its words", whole.map(\.speaker) == ["S1", "S2"], "\(whole.map(\.speaker))")
    let cut = run(segs, t)
    check("a change with no sentence boundary in reach stays where the diarizer put it",
          paragraphs(cut) == ["Speaker 1: We talked about the roof. The cedar comes Friday and", "Speaker 2: the crew starts Monday morning early."], "\(paragraphs(cut))")
    check("the first piece keeps the line's id", cut.first?.id == segs.first?.id && cut[1].id == segs[1].id)

    var noWords = [Segment(start: 0, end: 4, text: "Call John about the shed."), Segment(start: 4, end: 9, text: "Order the cedar on Friday.")]
    var none: [Segment]? = nil
    let order = SpeakerTurns.assign([("D7", 0, 3.5), ("D3", 3.5, 9)], to: &noWords, parallel: &none, split: true)
    check("lines without word timings take the speaker who talks most of their span", noWords.map(\.speaker) == ["S1", "S2"] && order == ["D7", "D3"])

    var unlabeled = segs
    SpeakerTurns.assign([], to: &unlabeled, parallel: &none, split: true)
    check("no turns: lines keep their speaker", unlabeled.map(\.speaker) == [nil, nil] && unlabeled.count == segs.count)
}

// A finished transcript: its original lines are cut alongside, and lines with corrections stay whole.
do {
    let guest = "We'd be advocating for them legally as well."
    let host = "We've got some really good news from preborn."
    let ws = words(guest + " " + host, from: 0)
    let cut = index(of: "well.", in: ws)
    let segs = lines(ws, cuts: [cut, ws.count - cut])
    var fixed = segs
    var original: [Segment]? = segs
    SpeakerTurns.assign(turns(ws, changeAt: cut), to: &fixed, parallel: &original, split: true)
    check("the original lines are cut the same way, with the same ids", original.map { $0.map(\.id) } == fixed.map(\.id) && original.map { $0.map(\.speaker) } == fixed.map(\.speaker) && fixed.count == 3)
    var kept = segs
    var original2: [Segment]? = segs
    SpeakerTurns.assign(turns(ws, changeAt: cut), to: &kept, parallel: &original2, split: true, keepWhole: [segs[1].id])
    check("a line with a correction isn't cut", kept.count == 2 && original2?.count == 2)
    var mismatched = segs
    var short: [Segment]? = [segs[0]]
    SpeakerTurns.assign(turns(ws, changeAt: cut), to: &mismatched, parallel: &short, split: true)
    check("lines that don't pair up with the originals aren't cut", mismatched.count == 2 && short?.count == 1)
}

check("sentence ends", SpeakerTurns.endsSentence("accusations.") && SpeakerTurns.endsSentence("be?") && SpeakerTurns.endsSentence("said.”")
      && !SpeakerTurns.endsSentence("Mr.") && !SpeakerTurns.endsSentence("Yes,") && !SpeakerTurns.endsSentence("as"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
