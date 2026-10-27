import Foundation

// Templates (Verbatim/Model/Templates.swift): the library, the prompt's no-add rule, Run automatically's per-kind
// assignment, skip rules, and run-once rule, a kind picked at the start of a recording, and the kind-change offer.
// Not part of any app target; run mac/tools/test-templates.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let rule = TranscriptActions.noAddRule
let now = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: Library

let builtIn = TemplateLibrary.builtIn, scenarios = TemplateLibrary.scenarios
check("five built-ins, the actions, with their IDs", builtIn.map(\.name) == TranscriptActions.builtIn.map(\.name)
      && builtIn.map(\.id) == TranscriptActions.builtIn.map(\.id) && builtIn.allSatisfy { $0.origin == .builtIn })
check("eight scenarios in the mockup's order", scenarios.map(\.name) == ["Meeting notes", "1:1", "Client call", "Interview", "Lecture",
                                                                       "Sermon notes", "Brainstorm", "Daily reflection"],
      "\(scenarios.map(\.name))")
let allIDs = (builtIn + scenarios).map(\.id)
check("every template has its own fixed ID", Set(allIDs).count == 13 && scenarios.allSatisfy { $0.origin == .scenario })
check("every built-in and scenario has sections and a summary", (builtIn + scenarios).allSatisfy { !$0.sections.isEmpty && !$0.summary.isEmpty })
let shipped: [TranscriptTemplate] = builtIn + scenarios
let sectionIDs: [UUID] = shipped.flatMap { t in t.sections.map { $0.id } }
let sectionCount: Int = shipped.reduce(0) { $0 + $1.sections.count }
check("section IDs are stable and unique", Set(sectionIDs).count == sectionCount)
let meeting = scenarios[0]
check("Meeting notes: Summary, Decisions, Action items, Open questions", meeting.sections.map(\.name) == ["Summary", "Decisions", "Action items", "Open questions"]
      && meeting.sections.map(\.format) == [.paragraph, .bullets, .checklist, .bullets] && meeting.kinds == [.meeting])
let reflection = scenarios[7]
check("Daily reflection: What happened, What stood out, For tomorrow, no advice", reflection.sections.map(\.name) == ["What happened", "What stood out", "For tomorrow"]
      && reflection.instructions.contains("Don't add advice") && reflection.kinds == [.journal])
check("only Interview and Key points read times", (builtIn + scenarios).filter(\.usesTimestamps).map(\.name) == ["Key points", "Interview"],
      "\((builtIn + scenarios).filter(\.usesTimestamps).map(\.name))")
check("Journal entry rewrites in order; the rest pull things together", (builtIn + scenarios).filter { !$0.extracts }.map(\.name) == ["Journal entry"])

var mine = TemplateLibrary.duplicate(meeting, now: now)
mine.name = "Website client call"
check("Duplicate and edit makes a template of yours", mine.origin == .yours && mine.isEditable && mine.id != meeting.id
      && TemplateLibrary.duplicate(meeting).name == "Meeting notes copy" && mine.sections.map(\.name) == meeting.sections.map(\.name)
      && Set(mine.sections.map(\.id)).isDisjoint(with: meeting.sections.map(\.id)))
let planCopy = TemplateLibrary.duplicate(builtIn[0])
check("a built-in's copy drops the rule from its editable instruction (it's added back when it runs)", !planCopy.instructions.contains(rule)
      && TemplatePrompt.instruction(planCopy).hasSuffix(rule))
let all = TemplateLibrary.all(yours: [mine])
check("library order: Scenarios, Yours, Built in", all.map(\.origin) == Array(repeating: .scenario, count: 8) + [.yours] + Array(repeating: .builtIn, count: 5))
check("a template is found by ID among all three", TemplateLibrary.template(mine.id, yours: [mine]) == mine
      && TemplateLibrary.template(meeting.id, yours: []) == meeting && TemplateLibrary.template(builtIn[4].id, yours: []) == builtIn[4]
      && TemplateLibrary.template(UUID(), yours: [mine]) == nil)
check("a built-in or scenario saved by mistake among yours never shows twice", TemplateLibrary.all(yours: [meeting, mine]).filter { $0.id == meeting.id }.count == 1)
var blank = TemplateLibrary.blank(now: now)
check("a blank template needs a name", TemplateLibrary.problem(blank) == "Give the template a name.")
blank.name = "Film idea"; blank.sections.append(TemplateSection("", .bullets))
check("every section needs a name", TemplateLibrary.problem(blank) == "Name every section.")
blank.sections[1].name = "Characters"
check("a named template with named sections saves", TemplateLibrary.problem(blank) == nil)
check("a summary line comes from the sections when you write none", TemplateLibrary.summaryLine(blank) == "Summary, characters")

// Synced like snippets: a template of yours round-trips, and one from a newer build still reads.
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let back = (try? enc.encode([mine])).flatMap { try? dec.decode([TranscriptTemplate].self, from: $0) }
check("a template of yours round-trips", back == [mine])
let future = #"[{"id":"\#(UUID().uuidString)","name":"Future","sections":[{"name":"Odd","format":"table"}],"kinds":["meeting","hologram"],"extra":1}]"#
let read = try? dec.decode([TranscriptTemplate].self, from: Data(future.utf8))
check("a newer build's template reads: unknown format and kind dropped to safe values", read?.first?.sections.first?.format == .bullets
      && read?.first?.kinds == [.meeting] && read?.first?.name == "Future")
check("templates merge like the other synced lists", SyncMerge.merge(local: [mine], remote: [], localTombstones: [], remoteTombstones: []).items == [mine])

// MARK: Prompt

let prompts = (builtIn + scenarios + [mine, blank]).map(TemplatePrompt.instruction)
check("every template prompt carries the no-add rule, once", prompts.allSatisfy { $0.hasSuffix(rule) && $0.components(separatedBy: rule).count == 2 })
var stripped = mine
stripped.instructions = "Notes from a call. " + rule
check("the rule comes back after someone deletes it, and isn't doubled when they keep it", TemplatePrompt.instruction(stripped).components(separatedBy: rule).count == 2
      && { var x = mine; x.instructions = "Notes from a call"; return TemplatePrompt.instruction(x).hasSuffix(rule) }())
check("a built-in runs with the action's own instruction", TemplatePrompt.instruction(builtIn[0]) == TranscriptActions.builtIn[0].instruction)
let mp = TemplatePrompt.instruction(meeting)
check("a scenario lists its sections in order as ## headings", mp.contains("1. Summary: a short paragraph.") && mp.contains("2. Decisions: bullet points")
      && mp.contains("3. Action items: checklist lines that start with \"- [ ] \"") && mp.contains("\"## \"")
      && mp.range(of: "1. Summary")!.lowerBound < mp.range(of: "4. Open questions")!.lowerBound)
check("a section with nothing says None stated", mp.contains("write \"None stated.\""))
check("Interview asks for quotes with times", TemplatePrompt.instruction(scenarios[3]).contains("[mm:ss]"))

// MARK: Run automatically

let d = UserDefaults(suiteName: "templates-tests-\(UUID().uuidString)")!
var settings = AutoRunSettings.load(d)
check("defaults: every kind Off, skip short on, show first off, notify on", settings.assignments.isEmpty && settings.skipShort && !settings.showFirst && settings.notify)
check("Run automatically lists eight kinds, never dictations", AutoRunSettings.kinds.count == 8 && !AutoRunSettings.kinds.contains(.dictation))
settings.set(meeting.id, for: .meeting)
settings.set(reflection.id, for: .journal)
settings.set(mine.id, for: .interview)
settings.skipShort = false; settings.notify = false
settings.save(d)
let loaded = AutoRunSettings.load(d)
check("the per-kind assignment and options round-trip", loaded == settings && loaded.template(for: .meeting) == meeting.id && loaded.template(for: .talk) == nil)
check("one template per kind; a template can run for several kinds", { var s = loaded; s.set(meeting.id, for: .interview); return s.kinds(for: meeting.id) == [.meeting, .interview] && s.template(for: .interview) == meeting.id }())
check("\"3 of 8 kinds\"", loaded.assignedCount == 3)
check("deleting a template of yours turns its kinds Off", loaded.pruned(existing: Set(TemplateLibrary.all(yours: []).map(\.id))).template(for: .interview) == nil
      && loaded.pruned(existing: Set(all.map(\.id))).template(for: .interview) == mine.id)
settings = AutoRunSettings()
settings.set(meeting.id, for: .meeting)
settings.set(reflection.id, for: .journal)

func rec(_ kind: RecordingKind?, picked: Bool = false, minutes: Double = 30, ago: Double = 60) -> Transcript {
    var t = Transcript(title: "Call", source: .voiceMemo, sourceLabel: "Voice memo", duration: minutes * 60, audioFileName: nil, model: "")
    t.segments = [Segment(start: 0, end: 4, text: "We agreed to launch on November 18.")]
    t.createdAt = now.addingTimeInterval(-ago)
    t.kind = kind; t.kindIsAuto = !picked
    return t
}
let lib = TemplateLibrary.all(yours: [mine])
func decide(_ t: Transcript, _ s: AutoRunSettings = settings, pending: Bool = false) -> AutoRunRules.Decision {
    AutoRunRules.decide(t, settings: s, templates: lib, labelPending: pending, now: now)
}
check("a Meeting runs Meeting notes", decide(rec(.meeting)) == .run(meeting.id, .meeting))
check("a Journal entry runs Daily reflection", decide(rec(.journal)) == .run(reflection.id, .journal))
check("a kind set to Off waits for you", decide(rec(.talk)) == .off)
check("no kind yet waits for AutoLabel, then counts as Off", decide(rec(nil), pending: true) == .waitForKind && decide(rec(nil)) == .off)
check("Skip short recordings: under two minutes doesn't run", decide(rec(.meeting, minutes: 1.9)) == .short && decide(rec(.meeting, minutes: 2)) == .run(meeting.id, .meeting))
check("with Skip short recordings off, a short one runs", { var s = settings; s.skipShort = false; return decide(rec(.meeting, minutes: 0.5), s) == .run(meeting.id, .meeting) }())
var ran = rec(.meeting)
ran.autoRun = AutoRunMark(templateId: meeting.id, name: meeting.name, kind: .meeting, state: .done, device: "test-device", at: now)
check("run once: a recording that ran never runs again (relaunch, sync, Transcribe again)", decide(ran) == .alreadyRan)
for state in [AutoRunMark.State.waiting, .failed, .skipped] {
    var x = rec(.meeting); x.autoRun = AutoRunMark(templateId: meeting.id, name: "Meeting notes", kind: .meeting, state: state)
    check("run once: a \(state.rawValue) mark never starts a second run", decide(x) == .alreadyRan)
}
check("an old recording transcribed again doesn't start a template it never had", decide(rec(.meeting, ago: 3 * 24 * 3600)) == .notEligible)
var dictation = rec(.dictation); dictation.source = .dictation
check("dictations never run a template", decide(dictation) == .notEligible)
var processing = rec(.meeting); processing.status = .processing
check("an unfinished recording doesn't run", decide(processing) == .notEligible)
var deletedTemplate = settings; deletedTemplate.set(UUID(), for: .meeting)
check("a kind whose template is gone counts as Off", decide(rec(.meeting), deletedTemplate) == .off)
check("Notify me when it's done: over 20 minutes only, and only when on", AutoRunRules.notifies(rec(.meeting, minutes: 21), settings: settings)
      && !AutoRunRules.notifies(rec(.meeting, minutes: 20), settings: settings)
      && { var s = settings; s.notify = false; return !AutoRunRules.notifies(rec(.meeting, minutes: 90), settings: s) }())
var waiting = rec(.meeting)
waiting.autoRun = AutoRunMark(templateId: meeting.id, name: "Meeting notes", kind: .meeting, state: .waiting, device: "test-device")
check("a waiting run resumes on the device that started it, and nowhere else", AutoRunRules.resumes(waiting, device: "test-device")
      && !AutoRunRules.resumes(waiting, device: "other") && !AutoRunRules.resumes(ran, device: "test-device"))
check("\"Waiting to run Meeting notes\"", waiting.autoRunWaitingText == "Waiting to run Meeting notes" && ran.autoRunWaitingText == nil)
check("runs this month count done marks for the kind", AutoRunRules.runsThisMonth([ran, waiting, rec(.meeting)], kind: .meeting, now: now) == 1
      && AutoRunRules.monthNote(7, kind: .meeting, assigned: true) == "Ran 7 times this month" && AutoRunRules.monthNote(1, kind: .talk, assigned: true) == "Ran once this month"
      && AutoRunRules.monthNote(0, kind: .idea, assigned: false).hasPrefix("Thoughts are short"))

// MARK: A picked kind

var picked = rec(nil)
picked.pickKindAtStart(.meeting)
check("Record a meeting: the kind is set and yours", picked.kind == .meeting && !picked.kindIsAuto && !picked.wantsSuggestedKind)
picked.applySuggestedKind(.note)
check("AutoLabel never overwrites a picked kind", picked.kind == .meeting)
var guessed = rec(nil)
guessed.applySuggestedKind(.note)
check("AutoLabel still fills in a kind nobody picked", guessed.kind == .note && guessed.kindIsAuto)
guessed.applySuggestedKind(.meeting)
check("AutoLabel's first guess stays", guessed.kind == .note)
check("the auto-run picks the template by the picked kind", decide(picked) == .run(meeting.id, .meeting)
      && { var x = rec(nil); x.pickKindAtStart(.journal); return decide(x, pending: true) == .run(reflection.id, .journal) }())
check("Record a kind offers four kinds, no Note, podcasts, or videos", RecordingKind.recordChoices == [.meeting, .interview, .journal, .talk])
check("record kind titles", RecordingKind.recordChoices.map(\.recordTitle) == ["Record a meeting", "Record an interview", "Record a journal entry", "Record a talk"])

// MARK: Record as (the iPhone's tray, the Mac's menus)

check("six choices in one order: Voice note, the four kinds, Thought", RecordChoice.all == [.voiceNote, .kind(.meeting), .kind(.interview), .kind(.journal), .kind(.talk), .thought])
check("row names", RecordChoice.all.map(\.name) == ["Voice note", "Meeting", "Interview", "Journal entry", "Talk", "Thought"])
check("serif names put the last word in italic", RecordChoice.voiceNote.serifParts == ("Voice ", "note") && RecordChoice.kind(.talk).serifParts == ("Talk", nil)
      && RecordChoice.kind(.journal).serifParts == ("Journal ", "entry"))
check("Mac right-click titles", RecordChoice.all.map(\.menuTitle) == ["Record", "Record a meeting", "Record an interview", "Record a journal entry", "Record a talk", "New thought"])
check("File › Record As titles", RecordChoice.all.map(\.commandTitle) == ["Voice Note", "Meeting…", "Interview", "Journal Entry", "Talk", "Thought"])
check("VoiceOver actions", RecordChoice.all.map(\.actionName) == ["Record a voice note", "Record a meeting", "Record an interview", "Record a journal entry", "Record a talk", "New thought"])
check("each choice has its own custom symbol", Set(RecordChoice.all.map(\.symbolName)).count == 6
      && RecordChoice.all.map(\.symbolName) == ["rec.voice", "rec.meeting", "rec.interview", "rec.journal", "rec.talk", "thought"])
check("Voice note leaves the kind to AutoLabel; Thought files as Thoughts", RecordChoice.voiceNote.kind == nil && RecordChoice.thought.kind == .idea
      && RecordChoice.kind(.meeting).kind == .meeting)
var trayAuto = AutoRunSettings()
trayAuto.set(meeting.id, for: .meeting)
trayAuto.set(reflection.id, for: .journal)
trayAuto.set(meeting.id, for: .idea)
let trayLib = TemplateLibrary.all(yours: [])
check("hint: a template assigned to the kind", RecordChoice.kind(.meeting).hint(settings: trayAuto, templates: trayLib) == "Runs Meeting notes when it finishes"
      && RecordChoice.kind(.journal).hint(settings: trayAuto, templates: trayLib) == "Runs \(reflection.name) when it finishes")
check("hint: Run automatically off says what the kind really does", RecordChoice.kind(.interview).hint(settings: trayAuto, templates: trayLib) == "Filed under Interviews, every voice kept"
      && RecordChoice.kind(.talk).hint(settings: trayAuto, templates: trayLib) == "Filed under Talks, every voice kept"
      && RecordChoice.kind(.meeting).hint(settings: AutoRunSettings(), templates: trayLib) == "Filed under Meetings, every voice kept"
      && RecordChoice.kind(.journal).hint(settings: AutoRunSettings(), templates: trayLib) == "Filed under Journal by day")
check("hint: a deleted template counts as off", RecordChoice.kind(.meeting).hint(settings: trayAuto, templates: []) == "Filed under Meetings, every voice kept")
check("hint: Voice note and Thought never name a template", RecordChoice.voiceNote.hint(settings: trayAuto, templates: trayLib) == "Plain Record. Verbose picks the kind."
      && RecordChoice.thought.hint(settings: trayAuto, templates: trayLib) == "Adds to today\u{2019}s page")
check("the recorder's line", RecordChoice.voiceNote.recorderLine(settings: trayAuto, templates: trayLib) == "Verbose picks the kind after it listens"
      && RecordChoice.kind(.meeting).recorderLine(settings: trayAuto, templates: trayLib) == "Runs Meeting notes when it finishes")
check("the kinds' fallbacks match what the app does: every voice stays in a meeting, interview, or talk",
      [RecordingKind.meeting, .interview, .talk].allSatisfy { k in
          var t = rec(k); t.source = .voiceMemo
          t.segments = [Segment(start: 0, end: 50, text: "a", speaker: "S1"), Segment(start: 50, end: 55, text: "b", speaker: "S2")]
          return !t.hasBackgroundVoices
      })

typealias TR = RecordTrayRules
check("tray: lifting before the hold is a plain Record", TR.lift(opened: false, slid: false, over: nil) == .plainRecord
      && TR.lift(opened: false, slid: true, over: .kind(.meeting)) == .plainRecord)
check("tray: slide to a row and lift starts it", TR.lift(opened: true, slid: true, over: .kind(.meeting)) == .start(.kind(.meeting))
      && TR.lift(opened: true, slid: true, over: .thought) == .start(.thought))
check("tray: lift without sliding keeps it open for a tap", TR.lift(opened: true, slid: false, over: .kind(.meeting)) == .keepOpen
      && TR.lift(opened: true, slid: true, over: nil) == .keepOpen)
check("tray: sliding means more than 10 pt", !TR.slid(dx: 6, dy: 8) && TR.slid(dx: 0, dy: 10.5))
let trayRows: [(RecordChoice, minX: Double, minY: Double, maxX: Double, maxY: Double)] =
    RecordChoice.all.enumerated().map { i, c in (c, minX: 10, minY: 400 + Double(i) * 60, maxX: 380, maxY: 460 + Double(i) * 60) }
check("tray: the row under the finger", TR.row(atY: 470, x: 100, rows: trayRows) == .kind(.meeting) && TR.row(atY: 399, x: 100, rows: trayRows) == nil
      && TR.row(atY: 470, x: 5, rows: trayRows) == nil && TR.row(atY: 735, x: 100, rows: trayRows) == .thought)
check("tray: rows scrolled out of view don't count", TR.row(atY: 470, x: 100, rows: trayRows, visibleMinY: 500, visibleMaxY: 700) == nil)
check("tray: a swipe past a third of the height closes it", TR.dismisses(translation: 140, predicted: 150, height: 400)
      && !TR.dismisses(translation: 120, predicted: 140, height: 400))
check("tray: a fast flick closes it; dragging up never does", TR.dismisses(translation: 40, predicted: 300, height: 400)
      && !TR.dismisses(translation: -40, predicted: 300, height: 400))

// MARK: Results and the kind-change offer

var t = rec(.meeting)
let r1 = TemplateResult(templateId: meeting.id, name: "Meeting notes", text: "## Summary\nAlex wants it live.", auto: true, kind: .meeting, madeOn: "Mac", createdAt: now)
t.addTemplateResult(r1)
check("\"Ran automatically because this is a Meeting\"", AutoRunRules.reason(r1) == "Ran automatically because this is a Meeting"
      && AutoRunRules.reason(TemplateResult(templateId: meeting.id, name: "x", text: "", auto: true, kind: .interview)) == "Ran automatically because this is an Interview"
      && AutoRunRules.reason(TemplateResult(templateId: meeting.id, name: "x", text: "")) == nil)
let again = TemplateResult(templateId: meeting.id, name: "Meeting notes", text: "## Summary\nNew.", auto: false, madeOn: "Mac")
t.addTemplateResult(again)
check("Run again replaces the result from the same template", t.shownTemplateResults.map(\.id) == [again.id])
t.templateResults = [r1]
check("no offer while the kind is unchanged", AutoRunRules.offer(t, settings: settings, templates: lib) == nil)
t.kind = .journal; t.kindIsAuto = false
let offer = AutoRunRules.offer(t, settings: settings, templates: lib)
check("kind changed: the offer appears", offer?.text == "Now a Journal. Run Daily reflection?" && offer?.template == reflection.id && offer?.result == r1.id)
check("kind changed: nothing runs on its own", decide(t) == .alreadyRan || t.autoRun == nil && t.templateResults?.count == 1)
var marked = t; marked.autoRun = AutoRunMark(templateId: meeting.id, name: "Meeting notes", kind: .meeting, state: .done)
check("kind changed after a run: the run-once mark keeps it from running again", decide(marked) == .alreadyRan)
t.kind = .talk
check("kind changed to an Off kind: no offer", AutoRunRules.offer(t, settings: settings, templates: lib) == nil)
t.kind = .journal
t.templateResults?[0].offerDismissed = RecordingKind.journal.rawValue
check("Not now hides the offer for that kind", AutoRunRules.offer(t, settings: settings, templates: lib) == nil)
t.templateResults?[0].offerDismissed = nil
let r2 = TemplateResult(templateId: reflection.id, name: "Daily reflection", text: "## What happened\nA walk.", kind: .journal, madeOn: "Mac")
var taken = t
taken.addTemplateResult(r2, replacing: offer?.result)
check("Run from the offer replaces the old result", taken.shownTemplateResults.map(\.id) == [r2.id])
check("the old result stays until you run the new one", t.shownTemplateResults.map(\.id) == [r1.id])
taken.removeTemplateResult(r2.id)
check("removing the last result clears the field", taken.templateResults == nil)

let encoded = (try? enc.encode(t)).flatMap { try? dec.decode(Transcript.self, from: $0) }
check("results and the mark round-trip in the transcript file", encoded?.templateResults == t.templateResults
      && { var y = t; y.autoRun = ran.autoRun; let z = (try? enc.encode(y)).flatMap { try? dec.decode(Transcript.self, from: $0) }; return z?.autoRun == ran.autoRun }())
let futureMark = #"{"templateId":"\#(UUID().uuidString)","name":"X","state":"thinking"}"#
check("a mark from a newer build reads as done (never run again)", (try? dec.decode(AutoRunMark.self, from: Data(futureMark.utf8)))?.state == .done)

// Result text.
let blocks = TemplateResultText.blocks("## Summary\nAlex wants the site live.\nThe homepage changes.\n\n## Decisions\n- Launch stays on November 18.\n**Action items**\n- [ ] Send headlines (Sam)\n- [x] Check the form\nNone stated.")
check("result text: headings, paragraphs, bullets, and checklist lines", blocks == [
    .heading("Summary"), .paragraph("Alex wants the site live. The homepage changes."), .heading("Decisions"), .bullet("Launch stays on November 18."),
    .heading("Action items"), .check("Send headlines (Sam)", done: false), .check("Check the form", done: true), .paragraph("None stated.")], "\(blocks)")
check("footer: on this Mac, or on your iPhone when it was made there",
      TemplateCopy.footer(madeOn: "Mac", here: "Mac") == "Made by Apple Intelligence from this transcript, on this Mac. It can be wrong; edit the result before you keep it."
      && TemplateCopy.footer(madeOn: "iPhone", here: "Mac").contains("on your iPhone"))

// The checks both self-tests run (TemplateChecks.swift), here too.
TemplateChecks.run { check("self-test: " + $0, $1) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
