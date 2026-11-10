import Foundation

// Clean while you talk (Model/PreClean.swift): the shared checks (PreCleanChecks, also run by the Mac self-test), and
// whole dictations replayed as growing snapshots, where reusing parts must never change the words.
//   bash mac/tools/test-preclean.sh

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)\n    \(detail())") }
}
func report(_ results: [PreCleanChecks.Result]) {
    for r in results { check(r.name, r.ok, r.detail.replacingOccurrences(of: "\n", with: "⏎\n    ")) }
}

report(PreCleanChecks.run())

// MARK: Replays

/// Dictations as the rules write them: sentences, pauses as paragraph breaks, abbreviations, numbers, a question.
let dictations: [String] = [
    "I sent the draft to the client this morning. They want two more rounds of changes before Friday. After that we can book the crew for the shoot. Let me know if the budget still works for you.",
    "The catalog leads with wheels and wagons out in the field. We shot it over 3.5 days in early May.\n\nDr. Lane signed off on the proofs, e.g. the cover and the spread. Can you send the invoice by Friday? It should come to $4,500. Thanks for the quick turnaround on this one.",
    "First we need the photos from the spring shoot. Second we need the copy for every product page. Third we need the price list, and it has to match the catalog. I was thinking... maybe we print fewer this year. iPhone photos are fine for the web. Everything else should come from the studio.",
    "so we went to the store and then we went home and then we made dinner and nothing else happened that day at all",
    "今日は会議があります。明日は休みです。来週また連絡しますのでよろしくお願いします。資料は金曜日までに送ります。",
    "Is the venue confirmed for the ninth? I need to tell the caterer how many tables to bring! She said \"we can do forty.\" That should cover everyone on the list. Send me the floor plan when you have it.",
]

/// Every prefix cut at a word, the way a snapshot at a pause sees the dictation so far.
func snapshots(_ text: String) -> [String] {
    var out: [String] = []
    var words = 0
    for i in text.indices where text[i].isWhitespace {
        words += 1
        if words % 3 == 0 { out.append(String(text[..<i])) }
    }
    // Writing without spaces: cut every few characters instead.
    if out.isEmpty { out = stride(from: 5, to: text.count, by: 5).map { String(text.prefix($0)) } }
    return out
}

/// Seals every snapshot in turn, as the session does.
func sealAll(_ text: String) -> [PreClean.Part] {
    var parts: [PreClean.Part] = []
    for s in snapshots(text) { parts += PreClean.seal(sealed: parts, snapshot: s) }
    return parts
}

var replays = 0, reusedSomewhere = 0
var broken: [String] = []
for (n, text) in dictations.enumerated() {
    let parts = sealAll(text)
    let same = parts.map { PreClean.Outcome(text: $0.text, cleaned: false, note: nil) }
    // The final text is the dictation, or the dictation with a different ending or a changed word.
    var finals = [text, text + " And one more thing.", text + " actually never mind"]
    if let r = text.range(of: "the ") { finals.append(text.replacingCharacters(in: r, with: "that ")) }
    if let cut = snapshots(text).dropLast(2).last { finals.append(cut) }
    for final in finals {
        replays += 1
        let k = PreClean.reusable(parts, in: final)
        guard k > 0 else { continue }
        reusedSomewhere += 1
        guard let hit = PreClean.hit(parts, outcomes: same, count: k, in: final) else { broken.append("dictation \(n): no hit for \(k) part(s)"); continue }
        // With a model that changes nothing, reused parts plus the remainder are the final text, to the character.
        if hit.text + hit.remainderSep + hit.remainder != final { broken.append("dictation \(n): the joined text differs from the final text") }
        if hit.parts.contains(where: { $0.outcome.text.count > PreClean.maxPartCharacters }) { broken.append("dictation \(n): a part is too long") }
    }
    // The last sentence is never sealed, whatever the snapshots were.
    if let last = parts.last, text.hasSuffix(last.text) {
        broken.append("dictation \(n): the last sentence was sealed")
    }
}
check("replay: reused parts and the remainder always join back into the final text (\(replays) final texts, \(reusedSomewhere) with parts reused)",
      broken.isEmpty && reusedSomewhere >= 8, broken.joined(separator: "; ") + " reused=\(reusedSomewhere)")
check("replay: a dictation without sentence punctuation is never sealed", sealAll(dictations[3]).isEmpty)
check("replay: sentences that end with full-width marks are sealed", sealAll(dictations[4]).map(\.text).joined() == "今日は会議があります。明日は休みです。来週また連絡しますのでよろしくお願いします。")
check("replay: sealed parts never include a snapshot's cut-off last words",
      dictations.allSatisfy { text in sealAll(text).allSatisfy { p in text.contains(p.text) && ".!?\"。".contains(p.text.last ?? " ") } })

// The session, with a stand-in for the model.
let done = DispatchSemaphore(value: 0)
Task {
    report(await PreCleanChecks.runSession())
    done.signal()
}
done.wait()

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
