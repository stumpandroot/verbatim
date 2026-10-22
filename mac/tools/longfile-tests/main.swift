import Foundation

// Tests for long-file sections (LongFilePlan.swift) and the language rules (LanguageRules.swift). Not part of any
// app target; run mac/tools/test-longfile.sh.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)\n    \(detail())") }
}

let sr = 16_000
let plan = SectionPlan.parakeet
func secs(_ s: Double) -> Int { Int(s * Double(sr)) }

// MARK: Section boundaries

/// Every plan must start at 0, end at the total, overlap each neighbor by exactly `overlap`, and keep each section
/// within window + slack.
func wellFormed(_ w: [Range<Int>], total: Int, plan: SectionPlan) -> String? {
    guard let first = w.first, let last = w.last else { return total == 0 ? nil : "no sections" }
    if first.lowerBound != 0 { return "first starts at \(first.lowerBound)" }
    if last.upperBound != total { return "last ends at \(last.upperBound), total \(total)" }
    for (i, r) in w.enumerated() {
        if r.count > plan.window + plan.slack { return "section \(i) is \(r.count) samples" }
        if r.isEmpty { return "section \(i) is empty" }
        if i > 0, r.lowerBound != w[i - 1].upperBound - plan.overlap { return "section \(i) starts at \(r.lowerBound), previous ends at \(w[i - 1].upperBound)" }
    }
    return nil
}

do {
    let w = plan.windows(total: 0)
    check("0 s: no sections", w.isEmpty, "\(w)")
    check("0 s: next() is nil", plan.next(after: nil, total: 0) == nil)
}
do {
    let w = plan.windows(total: secs(30))
    check("30 s: one section, the whole file", w == [0..<secs(30)], "\(w)")
}
do {
    let w = plan.windows(total: secs(300))
    check("5 min: one section, the whole file", w == [0..<secs(300)], "\(w)")
}
do {
    let total = secs(301)
    let w = plan.windows(total: total)
    check("5 min + 1 s: one section (the tail stays in it, within the 30 s slack)", w == [0..<total], "\(w)")
    check("5 min + 1 s: well formed", wellFormed(w, total: total, plan: plan) == nil, wellFormed(w, total: total, plan: plan) ?? "")
}
do {
    let total = secs(331)
    let w = plan.windows(total: total)
    check("5 min 31 s: two sections, the second starts 2 s before the first ends",
          w == [0..<secs(300), secs(298)..<total], "\(w)")
}
do {
    let total = secs(3 * 3600)
    let w = plan.windows(total: total)
    let problem = wellFormed(w, total: total, plan: plan)
    check("3 h: well formed (starts at 0, ends at the end, 2 s overlaps, none too long)", problem == nil, problem ?? "")
    // Starts every 298 s; the section starting at 10,430 s would leave 370 s (over 330), so one more starts at 10,728 s.
    check("3 h: 37 sections", w.count == 37, "\(w.count)")
    check("3 h: every section but the last is 5 min", w.dropLast().allSatisfy { $0.count == secs(300) })
    check("3 h: last section is 72 s", w.last?.count == secs(72), "\(String(describing: w.last?.count))")
    check("3 h: estimatedCount matches", plan.estimatedCount(total: total) == 37)
}
do {
    // Ending a section early (a quiet cut) moves only the next section's start.
    let r = plan.next(after: secs(295), total: secs(3600))
    check("after a quiet cut at 295 s, the next section starts at 293 s", r == secs(293)..<secs(593), "\(String(describing: r))")
    check("after the end, nothing", plan.next(after: secs(3600), total: secs(3600)) == nil)
}
do {
    let total = secs(25 * 60)
    let w = SectionPlan.apple.windows(total: total)
    let problem = wellFormed(w, total: total, plan: .apple)
    check("Apple plan, 25 min: well formed 1-minute sections", problem == nil && w.count == 26, (problem ?? "") + " count \(w.count)")
}

// MARK: Quiet cuts

do {
    // 20 s of "speech" (a loud tone) with a 600 ms pause 4 s before the end.
    var s = (0..<secs(20)).map { Float(sin(Double($0) * 0.07) * 0.3) }
    let pause = secs(16)..<secs(16.6)
    for i in pause { s[i] = 0.000_5 }
    if let cut = plan.quietCut(in: s) {
        check("quiet cut lands in the pause", pause.contains(cut), "cut at \(Double(cut) / Double(sr)) s")
    } else {
        check("quiet cut lands in the pause", false, "no cut found")
    }
    let steady = (0..<secs(20)).map { Float(sin(Double($0) * 0.07) * 0.3) }
    check("no quiet cut in steady speech", plan.quietCut(in: steady) == nil)
    check("quietestRun picks the lowest stretch", SectionPlan.quietestRun([5, 4, 1, 1, 6, 7], length: 2) == 2)
}

// MARK: Timestamp offsets

do {
    let rel = [SectionWord(text: "hello", start: 0.5, end: 0.9), SectionWord(text: "there", start: 1.0, end: 1.4)]
    let abs = SectionStitcher.offset(rel, by: 298)
    check("offset shifts start and end", abs == [SectionWord(text: "hello", start: 298.5, end: 298.9), SectionWord(text: "there", start: 299.0, end: 299.4)], "\(abs)")
    check("offset by 0 changes nothing", SectionStitcher.offset(rel, by: 0) == rel)
}

// MARK: Stitching

/// A simulated recording: one word every 0.37 s. Each section "hears" the words inside it with a little timing
/// jitter, loses words cut by its edges, and hears a word cut by its end as a fragment.
struct Truth { let words: [SectionWord] }
func truth(seconds: Double) -> Truth {
    var out: [SectionWord] = []
    var t = 0.1, i = 0
    while t + 0.3 < seconds { out.append(SectionWord(text: "w\(i)", start: t, end: t + 0.3)); t += 0.37; i += 1 }
    return Truth(words: out)
}
func hear(_ truth: Truth, section r: Range<Int>, jitter: Double) -> [SectionWord] {
    let s = Double(r.lowerBound) / Double(sr), e = Double(r.upperBound) / Double(sr)
    var out: [SectionWord] = []
    for w in truth.words {
        if w.start >= s && w.end <= e {
            out.append(SectionWord(text: w.text, start: w.start - s + jitter, end: w.end - s + jitter))
        } else if w.start < e && w.end > e {
            // Cut by the section's end: heard as a fragment.
            out.append(SectionWord(text: String(w.text.prefix(1)), start: w.start - s, end: e - s))
        }
        // A word cut by the section's start is lost.
    }
    return out
}
func runSections(_ truth: Truth, total: Int, plan: SectionPlan) -> [SectionWord] {
    var words: [SectionWord] = []
    var prevEnd: Int? = nil
    for (i, r) in plan.windows(total: total).enumerated() {
        let jitter = i % 2 == 0 ? 0.02 : -0.03
        let abs = SectionStitcher.offset(hear(truth, section: r, jitter: jitter), by: Double(r.lowerBound) / Double(sr))
        words = prevEnd.map { SectionStitcher.stitch(words, abs, overlapStart: Double(r.lowerBound) / Double(sr), overlapEnd: Double($0) / Double(sr)) } ?? abs
        prevEnd = r.upperBound
    }
    return words
}

for minutes in [12.0, 31.5, 61.0] {
    let total = secs(minutes * 60)
    let t = truth(seconds: minutes * 60)
    let got = runSections(t, total: total, plan: plan)
    let texts = got.map(\.text)
    let expected = t.words.map(\.text)
    let dupes = Dictionary(grouping: texts, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    let missing = Set(expected).subtracting(texts).sorted()
    check("\(minutes) min: every word once, in order, across \(plan.windows(total: total).count) sections",
          texts == expected, "dupes \(dupes.prefix(5)), missing \(missing.prefix(5)), fragments \(texts.filter { !$0.hasPrefix("w") || $0.count == 1 }.prefix(5))")
    let ordered = zip(got, got.dropFirst()).allSatisfy { $0.start <= $1.start }
    check("\(minutes) min: times only move forward", ordered)
    // Each kept word's time is within the jitter of the real one.
    let close = zip(got, t.words).allSatisfy { abs($0.start - $1.start) <= 0.05 }
    check("\(minutes) min: offsets put every word at its real time", close)
}

do {
    // Hand-made seam: overlap 298–300 s. "something" is cut to "some" by the first section's end.
    let earlier = [SectionWord(text: "before", start: 296.0, end: 296.4), SectionWord(text: "the", start: 298.2, end: 298.4),
                   SectionWord(text: "quiet", start: 298.9, end: 299.3), SectionWord(text: "some", start: 299.6, end: 300.0)]
    let later = [SectionWord(text: "the", start: 298.22, end: 298.41), SectionWord(text: "quiet", start: 298.92, end: 299.31),
                 SectionWord(text: "something", start: 299.6, end: 300.2), SectionWord(text: "after", start: 300.5, end: 300.9)]
    let got = SectionStitcher.stitch(earlier, later, overlapStart: 298, overlapEnd: 300).map(\.text)
    check("seam: no duplicates, the whole word wins over the edge fragment", got == ["before", "the", "quiet", "something", "after"], "\(got)")
    // "the" sits 1.7 s from the earlier section's edge and 0.3 s from the later one's: the earlier one's copy is kept.
    let kept = SectionStitcher.stitch(earlier, later, overlapStart: 298, overlapEnd: 300)
    check("seam: each word comes from the section where it's farther from the edge",
          kept[1].start == 298.2 && kept[3].start == 299.6 && kept[3].end == 300.2, "\(kept)")
}
do {
    // A word only one section heard: kept when it's on that section's side of the overlap's middle (299 s).
    let earlier = [SectionWord(text: "a", start: 297.0, end: 297.3), SectionWord(text: "x", start: 299.5, end: 299.8)]
    let later = [SectionWord(text: "y", start: 298.1, end: 298.4), SectionWord(text: "b", start: 299.2, end: 299.5),
                 SectionWord(text: "c", start: 301, end: 301.3)]
    let got = SectionStitcher.stitch(earlier, later, overlapStart: 298, overlapEnd: 300).map(\.text)
    check("seam: a word only one section heard is kept on that section's side, dropped on the other",
          got == ["a", "b", "c"], "\(got)")
    let one = SectionStitcher.stitch([earlier[0]], [later[1], later[2]], overlapStart: 298, overlapEnd: 300).map(\.text)
    check("seam: a word heard only by the later section, on its side, is kept", one == ["a", "b", "c"], "\(one)")
    check("seam: empty sections pass the other side through",
          SectionStitcher.stitch([], later, overlapStart: 298, overlapEnd: 300) == later
          && SectionStitcher.stitch(earlier, [], overlapStart: 298, overlapEnd: 300) == earlier)
}

// MARK: Language rules

check("Parakeet v3 covers 25 languages", LanguageRules.parakeetV3.count == 25)
check("Japanese and Mandarin are outside v3", !LanguageRules.parakeetV3.contains("ja") && !LanguageRules.parakeetV3.contains("zh"))
check("base codes", LanguageRules.base("zh-Hans") == "zh" && LanguageRules.base("pt_BR") == "pt" && LanguageRules.base("ES") == "es")
check("Japanese words join without spaces", LanguageRules.joiner(for: "ja") == "" && LanguageRules.joiner(for: "es") == " ")

check("guess: clear Spanish from a v3 pass", LanguageGuess.evaluate([("es", 0.93), ("pt", 0.04)], words: 40, englishOnlyPass: false) == .known("es", 0.93))
check("guess: too few words is unknown", LanguageGuess.evaluate([("es", 0.99)], words: 3, englishOnlyPass: false) == .unknown)
check("guess: no clear winner is unknown", LanguageGuess.evaluate([("it", 0.3), ("es", 0.25), ("pt", 0.2)], words: 20, englishOnlyPass: false) == .unknown)
check("guess: clean English from a v2 pass", LanguageGuess.evaluate([("en", 0.95)], words: 50, englishOnlyPass: true) == .known("en", 0.95))
check("guess: English words the v2 model wasn't sure of are only likely English",
      LanguageGuess.evaluate([("en", 0.9)], words: 40, englishOnlyPass: true, confidence: 0.62) == .likelyEnglish)
check("guess: likely English gets a second opinion", LanguageGuess.likelyEnglish.wantsConfirmation)
check("guess: confident v2 English is English", LanguageGuess.evaluate([("en", 0.9)], words: 40, englishOnlyPass: true, confidence: 0.93) == .known("en", 0.9))
check("guess: muddled v2 pass is not English", LanguageGuess.evaluate([("en", 0.4), ("nl", 0.3)], words: 30, englishOnlyPass: true) == .notEnglish)
check("guess: regional codes merge", LanguageGuess.evaluate([("zh-Hans", 0.5), ("zh-Hant", 0.3)], words: 10, englishOnlyPass: false) == .known("zh", 0.8))
check("guess: sure guesses need no second opinion", !LanguageGuess.known("es", 0.9).wantsConfirmation && LanguageGuess.known("es", 0.6).wantsConfirmation && LanguageGuess.unknown.wantsConfirmation)
check("guess: English never gets a second opinion", !LanguageGuess.known("en", 0.62).wantsConfirmation)
check("candidates: the guess first, then device languages, never English, no repeats",
      LanguageGuess.known("tr", 0.6).candidates(device: ["en-US", "ja-JP", "tr", "zh-Hans", "ko"]) == ["tr", "ja", "zh"])
check("candidates: unknown uses device languages", LanguageGuess.unknown.candidates(device: ["en", "es-MX"]) == ["es"])
check("pick: best confident candidate", LanguageGuess.pick([("ja", 0.42, 30), ("zh", 0.81, 25), ("ko", 0.9, 2)]) == "zh")
check("pick: nothing confident", LanguageGuess.pick([("ja", 0.3, 30)]) == nil)

let apple: (String) -> Bool = { ["ja", "zh", "es", "ko"].contains($0) }
let none: (String) -> Bool = { _ in false }
check("route: English on v2 stays", LanguageRoute.decide(.known("en", 0.9), model: "v2", v3Downloaded: false, appleSupports: apple) == .keep("en"))
check("route: Spanish on v2 switches to v3 when it's downloaded", LanguageRoute.decide(.known("es", 0.9), model: "v2", v3Downloaded: true, appleSupports: apple) == .useV3("es"))
check("route: Spanish on v2 offers v3 when it isn't", LanguageRoute.decide(.known("es", 0.9), model: "v2", v3Downloaded: false, appleSupports: apple) == .offerV3("es"))
check("route: Spanish picked by hand downloads v3 in the job", LanguageRoute.decide(.known("es", 1), model: "v2", v3Downloaded: false, appleSupports: apple, explicit: true) == .useV3("es"))
check("route: Spanish on v3 stays", LanguageRoute.decide(.known("es", 0.9), model: "v3", v3Downloaded: true, appleSupports: apple) == .keep("es"))
check("route: Spanish on Ultra stays", LanguageRoute.decide(.known("es", 0.9), model: "ultra", v3Downloaded: false, appleSupports: apple) == .keep("es"))
check("route: Japanese goes to Apple's recognizer", LanguageRoute.decide(.known("ja", 0.9), model: "v3", v3Downloaded: true, appleSupports: apple) == .apple("ja"))
check("route: Mandarin with no Apple recognizer is unsupported", LanguageRoute.decide(.known("zh", 0.9), model: "v2", v3Downloaded: false, appleSupports: none) == .unsupported("zh"))
check("route: not English on v2 without v3 offers v3", LanguageRoute.decide(.notEnglish, model: "v2", v3Downloaded: false, appleSupports: apple) == .offerV3(nil))
check("route: likely English with no second opinion stays English", LanguageRoute.decide(.likelyEnglish, model: "v2", v3Downloaded: false, appleSupports: apple) == .keep("en"))
check("route: unknown keeps the model", LanguageRoute.decide(.unknown, model: "v2", v3Downloaded: false, appleSupports: apple) == .keep(nil))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
