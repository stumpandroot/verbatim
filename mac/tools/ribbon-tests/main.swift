import Foundation

// The recording ribbon's rules (VerbatimWidgets/RibbonRules.swift). Not part of any app target; run
// mac/tools/test-ribbon.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: Where a finished take goes (owner decision)

let now = 1_800_000_000.0
check("keyboard up and showing the take: straight into the field",
      Ribbon.route(keyboardVisibleAt: now - 0.5, keyboardShowsTake: true, now: now) == .keyboard)
check("keyboard up but it hasn't picked the take up: clipboard",
      Ribbon.route(keyboardVisibleAt: now - 0.5, keyboardShowsTake: false, now: now) == .clipboard)
check("keyboard gone (stale mark): clipboard",
      Ribbon.route(keyboardVisibleAt: now - 10, keyboardShowsTake: true, now: now) == .clipboard)
check("keyboard never seen: clipboard",
      Ribbon.route(keyboardVisibleAt: 0, keyboardShowsTake: true, now: now) == .clipboard)
check("freshness edge: 2.5 s is stale", !Ribbon.keyboardUp(visibleAt: now - Ribbon.keyboardFresh, now: now))
check("freshness: 2.4 s is fresh", Ribbon.keyboardUp(visibleAt: now - 2.4, now: now))
check("a mark from the future (clock change) doesn't count", !Ribbon.keyboardUp(visibleAt: now + 30, now: now))
check("clipboard route copies", Ribbon.copies(.clipboard, alwaysCopy: false))
check("keyboard route leaves the clipboard alone", !Ribbon.copies(.keyboard, alwaysCopy: false))
check("keyboard route copies only with Also copy each dictation", Ribbon.copies(.keyboard, alwaysCopy: true))
check("result: keyboard inserts", Ribbon.resultPhase(.keyboard, copied: nil) == .inserted)
check("result: copied", Ribbon.resultPhase(.clipboard, copied: true) == .copied)
check("result: a failed background copy is reported, never silent", Ribbon.resultPhase(.clipboard, copied: false) == .failed)

// MARK: Take state machine

let id = UUID()
check("toggle with no session needs Verbose in front", Ribbon.decide(.idle, .toggle, sessionOn: false) == .needsForeground)
check("start with no session needs Verbose in front", Ribbon.decide(.idle, .start, sessionOn: false) == .needsForeground)
check("toggle with a session begins a take", Ribbon.decide(.idle, .toggle, sessionOn: true) == .begin)
check("toggle during a take finishes it", Ribbon.decide(.listening(id), .toggle, sessionOn: true) == .finish(id))
check("Done finishes the take", Ribbon.decide(.listening(id), .stop, sessionOn: true) == .finish(id))
check("Cancel cancels the take", Ribbon.decide(.listening(id), .cancel, sessionOn: true) == .cancel(id))
check("Done with no take does nothing", Ribbon.decide(.idle, .stop, sessionOn: true) == .none)
check("Cancel with no take does nothing", Ribbon.decide(.idle, .cancel, sessionOn: true) == .none)
check("Start during a take does nothing", Ribbon.decide(.listening(id), .start, sessionOn: true) == .none)
// Two presses, then two more: begin, finish, begin, finish.
var state = Ribbon.TakeState.idle
var actions: [String] = []
for _ in 0..<4 {
    switch Ribbon.decide(state, .toggle, sessionOn: true) {
    case .begin: let t = UUID(); state = .listening(t); actions.append("begin")
    case .finish: state = .idle; actions.append("finish")
    default: actions.append("other")
    }
}
check("presses alternate begin and finish", actions == ["begin", "finish", "begin", "finish"], actions.joined(separator: ","))

// MARK: Idle timeout and the 8-hour cap

check("timeout choices are 10, 30, and 60 minutes", Ribbon.timeoutChoices == [600, 1800, 3600])
check("no stored timeout: 30 minutes", Ribbon.normalizedTimeout(nil) == 1800)
check("a stored choice stays", Ribbon.normalizedTimeout(600) == 600 && Ribbon.normalizedTimeout(3600) == 3600)
check("old 1 and 5 minutes become 10", Ribbon.normalizedTimeout(60) == 600 && Ribbon.normalizedTimeout(300) == 600)
check("old 15 minutes becomes 10 (nearest, ties go shorter)", Ribbon.normalizedTimeout(900) == 600)
check("old until-I-end-it becomes 60", Ribbon.normalizedTimeout(0) == 3600)
check("timeout label", Ribbon.timeoutLabel(1800) == "30 minutes")
let start = Date(timeIntervalSince1970: now)
check("idle session ends at its timeout",
      Ribbon.endCheck(now: start.addingTimeInterval(1800), startedAt: start, endsAt: start.addingTimeInterval(1800), dictating: false) == .idle)
check("before the timeout it keeps going",
      Ribbon.endCheck(now: start.addingTimeInterval(1799), startedAt: start, endsAt: start.addingTimeInterval(1800), dictating: false) == .keep)
check("never ends during a take",
      Ribbon.endCheck(now: start.addingTimeInterval(9 * 3600), startedAt: start, endsAt: start, dictating: true) == .keep)
check("ends before the Live Activity's 8 hours",
      Ribbon.endCheck(now: start.addingTimeInterval(Ribbon.sessionCap), startedAt: start, endsAt: start.addingTimeInterval(9 * 3600), dictating: false) == .cap)
check("the cap is under 8 hours", Ribbon.sessionCap < Ribbon.activityLimit && Ribbon.activityLimit == 8 * 3600)

// MARK: Action button

check("the Action button dictates unless you choose otherwise", Ribbon.actionChoice(nil) == .dictate && Ribbon.actionChoice("nonsense") == .dictate)
check("stored choices round-trip", Ribbon.ActionChoice.allCases.filter(\.available).allSatisfy { Ribbon.actionChoice($0.rawValue) == $0 })
check("choice titles match the mockup", Ribbon.ActionChoice.allCases.map(\.title)
      == ["Dictate", "Record a voice note", "Live captions", "What's playing", "Quick capture to Thought pad"])
check("only dictation runs without opening Verbose", Ribbon.ActionChoice.allCases.filter { !$0.needsForeground } == [.dictate])
check("each row says whether it works in place", Ribbon.ActionChoice.dictate.detail == "Starts or stops a take, in place."
      && Ribbon.ActionChoice.voiceNote.detail == "Opens Verbose." && Ribbon.ActionChoice.captions.detail == "Opens Verbose."
      && Ribbon.ActionChoice.whatsPlaying.detail == "Opens the iOS broadcast sheet first.")
check("Quick capture can't be chosen until the Thought pad is on iPhone", !Ribbon.ActionChoice.quickCapture.available
      && Ribbon.ActionChoice.quickCapture.detail == "Needs the Thought pad on iPhone (coming with sync)")
check("a stored Quick capture reads as Dictate", Ribbon.actionChoice("quickCapture") == .dictate)
check("the old stored choices keep their meaning", Ribbon.actionChoice("dictate") == .dictate && Ribbon.actionChoice("voiceNote") == .voiceNote
      && Ribbon.actionChoice("captions") == .captions)
check("Settings row values", Ribbon.ActionChoice.allCases.map(\.shortTitle) == ["Dictate", "Voice note", "Captions", "What's playing", "Quick capture"])
check("the copy is timeless", Ribbon.ActionChoice.allCases.allSatisfy { c in
    ["currently", "soon", "latest", "today"].allSatisfy { !(c.title + " " + c.detail).lowercased().contains($0) } })

// MARK: The expanded Dynamic Island's words and target

check("no words, no line", Ribbon.islandWords("") == nil && Ribbon.islandWords("  \n ") == nil)
check("short words pass on one line", Ribbon.islandWords("Thursday works.\nNoon") == "Thursday works. Noon")
let long = "Thanks Chris, Thursday works. Noon at the usual place, and I'll bring the wheel samples and the strap hinges too"
let line = Ribbon.islandWords(long) ?? ""
check("the line keeps the last 80 characters or fewer", line.count <= Ribbon.islandWordsLimit && long.hasSuffix(line), line)
check("the line starts at a word boundary", long.contains(" " + line))
check("one giant word is cut, not dropped", (Ribbon.islandWords(String(repeating: "a", count: 200)) ?? "").count == 80)
check("the line fits ActivityKit's 4 KB easily", (Ribbon.islandWords(String(repeating: "\u{1F600} ", count: 400)) ?? "").utf8.count < Ribbon.contentStateLimit / 4)
let split = Ribbon.splitWords("Noon at the usual place, and I'll bring the wheel samples")
check("older words dim, the newest three stay bright", split.older == "Noon at the usual place, and I'll bring " && split.newest == "the wheel samples")
check("three words or fewer are all newest", Ribbon.splitWords("the wheel samples") == ("", "the wheel samples"))
check("full builds name the app", Ribbon.target(hostName: "Messages", appStore: false) == "Messages")
check("App Store builds never name the app", Ribbon.target(hostName: "Messages", appStore: true) == "the Verbose keyboard")
check("an unknown app is the keyboard", Ribbon.target(hostName: nil, appStore: false) == "the Verbose keyboard"
      && Ribbon.target(hostName: " ", appStore: false) == "the Verbose keyboard")
check("Into Messages", Ribbon.intoLine("Messages") == "Into Messages" && Ribbon.intoLine(nil) == "Into the Verbose keyboard")
check("the Lock Screen line", Ribbon.lockLine(target: "Messages", take: 3) == "Into Messages · take 3 of this session"
      && Ribbon.lockLine(target: nil, take: 0) == "Into the Verbose keyboard · take 1 of this session")
check("the words setting has its own key", Ribbon.islandWordsKey == "ribbon.islandWords")

// MARK: Live Activity words (no transcript text, ever)

check("Copied · 42 words", Ribbon.headline(.copied, words: 42) == "Copied · 42 words")
check("Inserted · 1 word", Ribbon.headline(.inserted, words: 1) == "Inserted · 1 word")
check("ready headline", Ribbon.headline(.ready, words: 0) == "Verbose session on")
check("ready detail counts takes", Ribbon.detail(.ready, takes: 3, message: nil) == "Press the Action button to dictate. 3 takes so far."
      && Ribbon.detail(.ready, takes: 1, message: nil).hasSuffix("1 take so far.")
      && Ribbon.detail(.ready, takes: 0, message: nil) == "Press the Action button to dictate.")
check("the copy failure says what to do", Ribbon.detail(.failed, takes: 0, message: nil) == "Couldn't copy. Open Verbose to get your words.")
check("word count ignores punctuation", Ribbon.wordCount("Thursday works. Noon — at the usual place?") == 7)
let words = "Thursday works noon at the usual place"
for phase in [Ribbon.Phase.ready, .listening, .transcribing, .copied, .inserted, .failed, .ended] {
    let shown = Ribbon.headline(phase, words: 7) + " " + Ribbon.detail(phase, takes: 2, message: nil)
    check("no transcript text in \(phase.rawValue)", !shown.contains("usual place") && !shown.contains(words))
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
