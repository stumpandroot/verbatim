import Foundation

// A calendar call's names and turns (MeetingNames, MeetingTurns, and the parts of SpeakerNames and Transcript they
// touch): who the call's track is, the meeting's word list, misheard names fixed after the call, and lines from two
// tracks tidied into turns. Not part of any app target; run mac/tools/test-meeting-names.sh. Every name, title, and
// line here is invented.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let me = MeetingNames.selfNames(stored: "Dana Reyes", account: "Dana Reyes")
let you = Speaker(id: "S1", name: "You"), chrome = Speaker(id: "S2", name: "Chrome")

/// Lines with the speakers and times given, words timed evenly across each line.
func line(_ speaker: String?, _ text: String, _ start: Double, _ end: Double) -> Segment {
    let parts = text.split(separator: " ").map(String.init)
    let step = (end - start) / Double(max(1, parts.count))
    let words = parts.enumerated().map { WordSpan(text: $0.element, start: start + step * Double($0.offset), end: start + step * Double($0.offset + 1)) }
    return Segment(start: start, end: end, text: text, words: words, speaker: speaker)
}

// MARK: 1. Calendar names

check("your names: whole and first, each once", me == ["Dana Reyes", "Dana"], "\(me)")
check("your names: the You page's name and the account's", MeetingNames.selfNames(stored: "Dee", account: "Dana Reyes") == ["Dee", "Dana Reyes", "Dana"])
check("your names: none known", MeetingNames.selfNames(stored: "", account: "") == [])
check("you: your full name, your first name alone", MeetingNames.isSelf("dana reyes", selfNames: me) && MeetingNames.isSelf("Dana", selfNames: me))
check("you: someone sharing your first name isn't you", !MeetingNames.isSelf("Dana Baker", selfNames: me))
check("others: you left out though the calendar didn't mark you", MeetingNames.others(["Dana Reyes", "Priya Shah", "priya shah"], selfNames: me) == ["Priya Shah"])

do {
    let one = MeetingContext(title: "Acme Planning Call", attendees: ["Dana Reyes", "Priya Shah"], app: "Chrome")
    check("the other side: the one other invitee", MeetingNames.remoteName(one, selfNames: me) == .init(name: "Priya Shah", reason: MeetingNames.onlyInviteeReason))
    let two = MeetingContext(title: "Acme Planning Call", attendees: ["Priya Shah", "Omar Haddad"])
    check("the other side: a group call names nobody", MeetingNames.remoteName(two, selfNames: me) == nil)
    check("the other side: a one-on-one title with nobody listed",
          MeetingNames.remoteName(MeetingContext(title: "Priya <> Dana"), selfNames: me) == .init(name: "Priya", reason: MeetingNames.titleReason))
    check("the other side: a title with neither half you names nobody", MeetingNames.remoteName(MeetingContext(title: "Acme x Globex"), selfNames: me) == nil)
    check("the other side: a plain title names nobody", MeetingNames.remoteName(MeetingContext(title: "Acme Planning Call"), selfNames: me) == nil)
}

check("titles: x", MeetingNames.titlePair("Dana x Priya") == ["Dana", "Priya"])
check("titles: slash with a description after", MeetingNames.titlePair("Dana / Priya Shah - weekly") == ["Dana", "Priya Shah"])
check("titles: description before", MeetingNames.titlePair("Weekly: Priya <> Dana") == ["Priya", "Dana"])
check("titles: and, with 1:1 around it", MeetingNames.titlePair("1:1 Priya and Dana") == ["Priya", "Dana"])
check("titles: filler in brackets", MeetingNames.titlePair("Priya & Dana (sync)") == ["Priya", "Dana"])
check("titles: generic words aren't names", MeetingNames.titlePair("Planning and Review") == nil && MeetingNames.titlePair("Design / Launch") == nil)
check("titles: lowercase isn't a name", MeetingNames.titlePair("dana x priya") == nil)
check("titles: no pair", MeetingNames.titlePair("Acme Planning Call") == nil)

check("call labels: the app is a label, not a person", chrome.isAppLabel && chrome.isUnnamed && Speaker(id: "S2", name: "Others").isUnnamed
      && Speaker(id: "S2", name: "Microsoft Teams").isUnnamed)
check("call labels: a name and You aren't", !Speaker(id: "S2", name: "Priya").isUnnamed && !you.isUnnamed)

do {
    var t = Transcript(title: "Acme Planning Call", source: .app, sourceLabel: "Meeting", duration: 60, audioFileName: nil, model: "")
    t.speakers = [you, Speaker(id: "S2", name: "Huddle Room")]
    t.meeting = MeetingContext(title: "Acme Planning Call", attendees: ["Priya Shah"], app: "Huddle Room")
    check("call labels: whatever the capture called the track", t.isUnnamed(t.speakers[1]) && !t.isUnnamed(t.speakers[0]))

    t.speakers = [you, chrome]
    t.speakerSuggestions = MeetingNames.suggestions(t.meeting!, selfNames: me, speakerId: "S2")
    check("suggestions: the one invitee, from the calendar", t.speakerSuggestions?.count == 1 && t.speakerSuggestions?.first?.fromCalendar == true
          && t.speakerSuggestions?.first?.reasons == [MeetingNames.onlyInviteeReason])
    check("suggestions: shown for the app-named track", t.visibleSpeakerSuggestions.map(\.name) == ["Priya Shah"])
    t.speakers[1].name = "Priya Shah"
    check("suggestions: gone once the track is named", t.visibleSpeakerSuggestions.isEmpty)

    // Two invitees: in the menu only, until what people say backs one.
    t.speakers = [you, chrome]
    t.meeting = MeetingContext(title: "Acme Planning Call", attendees: ["Priya Shah", "Omar Haddad"], app: "Chrome")
    t.speakerSuggestions = MeetingNames.suggestions(t.meeting!, selfNames: me, speakerId: "S2")
    check("suggestions: two invitees are in the menu, not shown", t.visibleSpeakerSuggestions.isEmpty && t.calendarNames(for: "S2") == ["Priya Shah", "Omar Haddad"])
    t.segments = [
        line("S1", "Hey Priya, thanks for making time today.", 0, 3),
        line("S2", "Of course. Good to see you, Dana.", 3, 6),
        line("S1", "So the first thing is the budget.", 6, 9),
        line("S2", "Right, I have the numbers here.", 9, 12),
    ]
    var input = SpeakerNames.Input(segments: t.segments, speakers: t.speakers)
    input.attendees = MeetingNames.others(t.meeting!.attendees, selfNames: me)
    input.selfNames = me
    input.appName = "Chrome"
    let found = SpeakerNames.suggest(input)
    check("speech: \"Hey Priya\" on your side names the call's side, in the invite's spelling",
          found.count == 1 && found.first?.speakerId == "S2" && found.first?.name == "Priya Shah", "\(found)")
    check("speech: your name on their side never names anyone", !found.contains { $0.name.hasPrefix("Dana") })
    t.speakerSuggestions = SpeakerNames.merge(existing: t.speakerSuggestions, new: found)
    let shown = t.visibleSpeakerSuggestions
    check("speech: backs the invitee, who now shows with both reasons",
          shown.map(\.name) == ["Priya Shah"] && shown.first?.sources.contains("speech") == true
          && shown.first?.reasons.last == MeetingNames.invitedReason && (shown.first?.reasons.count ?? 0) >= 2, "\(shown)")

    var stray = SpeakerNames.Input(segments: [line("S1", "Thanks, Marisol, that helps.", 0, 3), line("S2", "Sure thing.", 3, 5),
                                              line("S1", "Marisol, can you send it?", 5, 8), line("S2", "Will do.", 8, 10)], speakers: [you, chrome])
    stray.attendees = ["Priya Shah"]
    stray.selfNames = me
    check("speech: with an invite, a name nobody invited isn't suggested", SpeakerNames.suggest(stray).isEmpty)
    stray.attendees = []
    check("speech: without one it is, for the app-named track", SpeakerNames.suggest(stray).first?.name == "Marisol")

    // The meeting's context round-trips; files without it read as before.
    let enc = JSONEncoder(), dec = JSONDecoder()
    enc.dateEncodingStrategy = .iso8601; dec.dateDecodingStrategy = .iso8601
    let back = try? dec.decode(Transcript.self, from: enc.encode(t))
    check("context: round-trips", back?.meeting == t.meeting)
    let old = Data(#"{"title":"Old","speakers":[{"id":"S1","name":"Zoom"}]}"#.utf8)
    check("context: absent in an older file", (try? dec.decode(Transcript.self, from: old)).map { $0.meeting == nil } == true)
    let odd = Data(#"{"title":"Odd","meeting":{"title":"T","attendees":"nope","extra":1}}"#.utf8)
    check("context: a field it can't read is dropped, not the file", (try? dec.decode(Transcript.self, from: odd)).map { $0.meeting?.title == "T" && $0.meeting?.attendees == [] } == true)
    check("past names: an app label never becomes one", SpeakerNames.pastNames([t]).isEmpty)
}

// MARK: 2. The meeting's words

do {
    let m = MeetingContext(title: "ZORP Garden Page Meeting", attendees: ["Priya Shah", "Dana Reyes"], app: "Chrome")
    let v = MeetingNames.vocabulary(m, selfNames: me)
    check("words: first names, yours, the title's, then full names", v == ["Priya", "Dana", "ZORP", "Garden", "Priya Shah", "Dana Reyes"], "\(v)")
    let filled = MeetingNames.vocabulary(m, selfNames: me, dictionary: ["Lititz", "Castwell", "priya", "Orchard", "Kestrel", "Bramble", "Wren"])
    check("words: the Dictionary fills to ten, each once", filled.count == MeetingNames.maxTerms && filled.suffix(4) == ["Lititz", "Castwell", "Orchard", "Kestrel"], "\(filled)")
    check("words: title terms keep acronyms and names, drop generic words",
          MeetingNames.titleTerms("Acme Planning Call") == ["Acme"] && MeetingNames.titleTerms("Q4 review with OKAPI team, FYI") == ["Q4", "OKAPI"]
          && MeetingNames.titleTerms("Weekly sync") == [])
    check("words: at most three from a title", MeetingNames.titleTerms("Acme Globex Initech Umbrella Hooli").count == 3)
    check("words: Whisper's prompt reads like a transcript",
          MeetingNames.whisperPrompt(m, terms: v) == "ZORP Garden Page Meeting. Priya, Dana, Priya Shah, Dana Reyes.", MeetingNames.whisperPrompt(m, terms: v))
    check("words: no prompt without words", MeetingNames.whisperPrompt(MeetingContext(), terms: []) == "")

    // A rescored line goes back on its words' times.
    let words = [WordSpan(text: "Welcome", start: 1, end: 1.4), WordSpan(text: "to", start: 1.4, end: 1.5), WordSpan(text: "the", start: 1.5, end: 1.6),
                 WordSpan(text: "Zor", start: 1.6, end: 1.8), WordSpan(text: "Pee", start: 1.8, end: 2.0), WordSpan(text: "team.", start: 2.0, end: 2.4, confidence: 0.9)]
    let a = Segment(start: 1, end: 2.4, text: words.map(\.text).joined(separator: " "), words: words, speaker: "S1")
    let b = line("S1", "Thanks for coming.", 3, 4)
    let segs = [a, b]
    check("windows: lines with word timings, about 30 seconds each",
          MeetingNames.windows(segs) == [0..<2] && MeetingNames.windows([line(nil, "One two.", 0, 20), line(nil, "Three four.", 20, 40), Segment(start: 40, end: 41, text: "x")]) == [0..<1, 1..<2])
    let r = MeetingNames.rescored(segs, range: 0..<2, text: "Welcome to the ZORP team. Thanks for coming.")
    check("rescored: the swap takes the time of the words it replaced",
          r?[0].text == "Welcome to the ZORP team." && r?[0].words?.count == 5 && r?[0].words?[3].start == 1.6 && r?[0].words?[3].end == 2.0
          && r?[0].words?[4].confidence == 0.9 && r?[0].id == a.id, "\(String(describing: r))")
    check("rescored: the other line is as it was", r?[1].text == b.text && r?[1].id == b.id && r?[1].words == b.words)
    check("rescored: unchanged text is nil", MeetingNames.rescored(segs, range: 0..<2, text: a.text + " " + b.text) == nil)
    check("rescored: too much changed is nil", MeetingNames.rescored(segs, range: 0..<2, text: "Something else entirely here now.") == nil)
    let noWords = Segment(start: 0, end: 1, text: "No timings.")
    check("rescored: a line without timings is left alone", MeetingNames.rescored([noWords], range: 0..<1, text: "No timing.") == nil)
}

// MARK: 3. Names fixed after the call

do {
    let people = ["Priya Shah"]
    var segs = [
        line("S1", "Okay, that covers it. Thanks, Sam.", 0, 4),
        line("S2", "Sounds good, thanks Robin.", 4, 6),
        line("S1", "Thanks, Priya. We met Sam yesterday.", 6, 9),
        line("S2", "Thanks, Team. Bye, everyone.", 9, 11),
        line("S1", "Sam, can you share the deck?", 11, 13),
        line("S1", "Unfortunately, we ran out of time. Honestly, can you send it?", 13, 16),
        line("S2", "Thanks, Boston.", 16, 17),
        line("S1", "Thanks, Marco.", 17, 18),
        line("S1", "thanks lee", 18, 19),
    ]
    let fixes = MeetingNames.nameFixes(segs, speakers: [you, chrome], attendees: people, selfNames: me, known: ["Marco Ruiz"])
    let summary = fixes.map { "\($0.segment):\($0.from)>\($0.to)" }
    check("names: your sign-off names the invitee; theirs names you; a vocative at the start",
          summary == ["0:Sam>Priya", "1:Robin>Dana", "4:Sam>Priya"], "\(summary)")

    let heard = segs
    var corrections: [Correction] = []
    let n = MeetingNames.correctNames(&segs, corrections: &corrections, speakers: [you, chrome], attendees: people, selfNames: me, known: ["Marco Ruiz"])
    check("names: applied, each a name fix with its place", n == 3 && corrections.count == 3 && corrections.allSatisfy { $0.isNameFix && !$0.byDictionary }
          && segs[0].text == "Okay, that covers it. Thanks, Priya." && segs[1].text == "Sounds good, thanks Dana." && segs[4].text == "Priya, can you share the deck?")
    check("names: what was said elsewhere stays", segs[2].text == "Thanks, Priya. We met Sam yesterday." && segs[8].text == "thanks lee")
    var t = Transcript(title: "x", source: .app, sourceLabel: "Meeting", duration: 20, audioFileName: nil, model: "")
    t.segments = segs; t.corrections = corrections
    t.original = heard
    t.undo(corrections[0])
    check("names: Undo puts the heard word back there only", t.segments[0].text == "Okay, that covers it. Thanks, Sam." && t.corrections.count == 2)
    check("names: name fixes aren't your edits", !t.hasHandEdits)

    // A group call: only a name that sounds like the word.
    let group = ["Priya Shah", "Omar Haddad"]
    let g = MeetingNames.nameFixes([line("S1", "Thanks, Sam.", 0, 1), line("S1", "Thanks, Omer.", 1, 2)], speakers: [you, chrome], attendees: group, selfNames: me)
    check("names: with several invitees, only one that sounds alike", g.map(\.to) == ["Omar"] && g.first?.segment == 1, "\(g)")
    check("names: no invite, no fixes", MeetingNames.nameFixes([line("S1", "Thanks, Sam.", 0, 1)], speakers: [you, chrome], attendees: [], selfNames: me).isEmpty)
    check("names: a word heard in lowercase elsewhere is a word, not a name",
          MeetingNames.nameFixes([line("S1", "Thanks, Will.", 0, 1), line("S2", "I will.", 1, 2)], speakers: [you, chrome], attendees: people, selfNames: me).isEmpty)
    check("names: no speakers, only a name that sounds alike",
          MeetingNames.nameFixes([line(nil, "Thanks, Pria.", 0, 1), line(nil, "Thanks, Sam.", 1, 2)], speakers: [], attendees: people, selfNames: me).map(\.to) == ["Priya"])
    check("vocatives: where they are", MeetingNames.vocatives(in: "Good to see you, Sam. Bye Lee!").map(\.word) == ["Sam", "Lee"]
          && MeetingNames.vocatives(in: "I talked to the vendor, Sam.").isEmpty)
}

// MARK: 4. Turns from two tracks

func words(_ segs: [Segment]) -> [String] { segs.flatMap { $0.text.split(separator: " ").map(String.init) }.sorted() }

do {
    // You were cut by the other side's "The", which starts their next line.
    let lines = [
        line("S1", "So what do you think", 5, 10.1),
        line("S2", "The", 10.0, 10.2),
        line("S1", "about the header?", 10.3, 11),
        line("S2", "page looks good to me.", 11.2, 13),
    ]
    var corrections: [Correction] = []
    let r = MeetingTurns.tidy(lines, originals: [:], corrections: &corrections)
    check("turns: the fragment joins its sentence, your cut sentence joins up",
          r.fixed.map(\.text) == ["So what do you think about the header?", "The page looks good to me."], "\(r.fixed.map(\.text))")
    check("turns: speakers and times follow", r.fixed.map(\.speaker) == ["S1", "S2"] && r.fixed[0].start == 5 && r.fixed[0].end == 11
          && r.fixed[1].start == 10.0 && r.fixed[1].end == 13)
    check("turns: no word lost, word timings kept in order", words(r.fixed) == words(lines)
          && r.fixed[1].words?.map(\.text) == ["The", "page", "looks", "good", "to", "me."] && r.fixed[1].words?.first?.start == 10.0)
    check("turns: the engine's lines join the same way", r.original.map(\.id) == r.fixed.map(\.id) && r.original.map(\.text) == r.fixed.map(\.text))
}

do {
    let lines = [
        line("S1", "I was thinking that we", 0, 3),
        line("S2", "yeah", 2.8, 3.0),
        line("S1", "should move the page first.", 3.2, 5),
        line("S2", "Sounds right.", 5.5, 6),
    ]
    var c: [Correction] = []
    let r = MeetingTurns.tidy(lines, originals: [:], corrections: &c)
    check("turns: a backchannel over a sentence waits for its end",
          r.fixed.map(\.text) == ["I was thinking that we should move the page first.", "yeah", "Sounds right."]
          && r.fixed.map(\.speaker) == ["S1", "S2", "S2"], "\(r.fixed.map(\.text))")
    check("turns: the backchannel keeps its own time", r.fixed[1].start == 2.8 && r.fixed[1].end == 3.0)
}

do {
    let between = [line("S1", "First point.", 0, 2), line("S2", "Right.", 2.1, 2.4), line("S1", "Second point.", 2.6, 4)]
    var c: [Correction] = []
    check("turns: a reply between whole sentences stays", MeetingTurns.tidy(between, originals: [:], corrections: &c).fixed.map(\.text) == between.map(\.text))
    let paused = [line("S1", "And then we", 0, 2), line("S2", "Should I go ahead?", 2, 4), line("S1", "will see.", 6.5, 8)]
    check("turns: a long pause isn't one sentence", MeetingTurns.tidy(paused, originals: [:], corrections: &c).fixed.map(\.text) == paused.map(\.text))
    let alone = [line("S1", "The", 0, 0.2), line("S2", "Go on, please.", 0.3, 2)]
    check("turns: a fragment with nothing to join stays", MeetingTurns.tidy(alone, originals: [:], corrections: &c).fixed.map(\.text) == alone.map(\.text))
    let talk = [line("S1", "The plan for the launch is that we", 0, 4), line("S2", "Wait, before that, can we talk about the budget?", 2, 6),
                line("S1", "ship the page on Monday.", 4.5, 7)]
    let r = MeetingTurns.tidy(talk, originals: [:], corrections: &c)
    check("turns: talk over a sentence goes after it", r.fixed.map(\.text) == ["The plan for the launch is that we ship the page on Monday.", talk[1].text])
}

do {
    // A Dictionary fix in the right-hand line moves with its words, and Undo still finds it.
    var engine = [line("S1", "We should ask", 0, 2), line("S2", "Mm", 1.9, 2.0), line("S1", "the kessel team.", 2.2, 3)]
    var fixed = engine
    var corrections: [Correction] = []
    let ranges = CorrectionEdits.wordRanges(of: "kessel", in: fixed[2].text)
    CorrectionEdits.apply(ranges, in: &fixed, at: 2, to: "Kestrel", label: "kessel", byDictionary: true, corrections: &corrections)
    engine[2].id = fixed[2].id
    let originals = Dictionary(uniqueKeysWithValues: engine.map { ($0.id, $0) })
    let r = MeetingTurns.tidy(fixed, originals: originals, corrections: &corrections)
    check("turns: joined with the Dictionary fix in place", r.fixed.first?.text == "We should ask the Kestrel team." && r.original.first?.text == "We should ask the kessel team.")
    let span = corrections.first?.spans?.first
    check("turns: the fix's place moved with it", corrections.first?.segmentId == r.fixed.first?.id
          && span.map { (r.fixed[0].text as NSString).substring(with: $0.range) } == "Kestrel")
    var t = Transcript(title: "x", source: .app, sourceLabel: "Meeting", duration: 3, audioFileName: nil, model: "")
    t.segments = r.fixed; t.original = r.original; t.corrections = corrections
    t.undo(corrections[0])
    check("turns: Undo after joining puts the heard word back", t.segments.first?.text == "We should ask the kessel team.")
}

do {
    // Many lines, no word lost, every line's time inside the recording, ids unique.
    var lines: [Segment] = []
    var tm = 0.0
    let texts = ["So the", "yeah", "first thing is", "Mm-hmm.", "the budget for", "Right", "next quarter.", "Okay.", "And", "the", "launch date is", "Sure", "still open."]
    for (k, s) in texts.enumerated() { lines.append(line(k % 2 == 0 ? "S1" : "S2", s, tm, tm + 0.8)); tm += 0.6 }
    var c: [Correction] = []
    let r = MeetingTurns.tidy(lines, originals: [:], corrections: &c)
    check("turns: a busy stretch keeps every word", words(r.fixed) == words(lines), "\(r.fixed.map { ($0.speaker ?? "") + ": " + $0.text })")
    check("turns: ids stay unique", Set(r.fixed.map(\.id)).count == r.fixed.count)
    check("turns: fewer, longer turns", r.fixed.count < lines.count)
    check("fragments and backchannels", MeetingTurns.isFragment("The") && !MeetingTurns.isFragment("No.") && !MeetingTurns.isFragment("three words here")
          && MeetingTurns.isBackchannel("mm-hmm") && MeetingTurns.isBackchannel("Got it.") && !MeetingTurns.isBackchannel("Really?")
          && !MeetingTurns.isBackchannel("the budget"))
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
