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
check("two built-ins, the actions, with their IDs", builtIn.map(\.name) == TranscriptActions.builtIn.map(\.name)
      && builtIn.map(\.id) == TranscriptActions.builtIn.map(\.id) && builtIn.allSatisfy { $0.origin == .builtIn })
check("nine scenarios in the mockup's order, Plan my day last", scenarios.map(\.name) == ["Meeting notes", "1:1", "Client call", "Interview", "Lecture",
                                                                       "Sermon notes", "Brainstorm", "Daily reflection", "Plan my day"],
      "\(scenarios.map(\.name))")
let allIDs = (builtIn + scenarios).map(\.id)
check("every template has its own fixed ID", Set(allIDs).count == 11 && scenarios.allSatisfy { $0.origin == .scenario })
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
check("only Interview and Plan my day read times", (builtIn + scenarios).filter(\.usesTimestamps).map(\.name) == ["Interview", "Plan my day"],
      "\((builtIn + scenarios).filter(\.usesTimestamps).map(\.name))")
check("every template pulls things together (Journal entry, which rewrote in order, left)", (builtIn + scenarios).allSatisfy(\.extracts))

var mine = TemplateLibrary.duplicate(meeting, now: now)
mine.name = "Website client call"
check("Duplicate and edit makes a template of yours", mine.origin == .yours && mine.isEditable && mine.id != meeting.id
      && TemplateLibrary.duplicate(meeting).name == "Meeting notes copy" && mine.sections.map(\.name) == meeting.sections.map(\.name)
      && Set(mine.sections.map(\.id)).isDisjoint(with: meeting.sections.map(\.id)))
let planCopy = TemplateLibrary.duplicate(builtIn[0])
check("a built-in's copy drops the rule from its editable instruction (it's added back when it runs)", !planCopy.instructions.contains(rule)
      && TemplatePrompt.instruction(planCopy).hasSuffix(rule))
let all = TemplateLibrary.all(yours: [mine])
check("library order: Scenarios, Yours, Built in", all.map(\.origin) == Array(repeating: .scenario, count: 9) + [.yours] + Array(repeating: .builtIn, count: 2))
check("a template is found by ID among all three", TemplateLibrary.template(mine.id, yours: [mine]) == mine
      && TemplateLibrary.template(meeting.id, yours: []) == meeting && TemplateLibrary.template(builtIn[1].id, yours: []) == builtIn[1]
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
check("defaults: every kind Off but Brain dump (Plan my day), skip short on, show first off, notify on",
      settings.assignments == [RecordingKind.brainDump.rawValue: TemplateLibrary.planMyDayID] && settings.skipShort && !settings.showFirst && settings.notify
      && settings == AutoRunSettings.startingChoices)
check("Run automatically lists nine kinds, Brain dump last, never dictations or Audio only", AutoRunSettings.kinds.count == 9 && AutoRunSettings.kinds.last == .brainDump
      && !AutoRunSettings.kinds.contains(.dictation) && !AutoRunSettings.kinds.contains(.audio))
settings.set(meeting.id, for: .meeting)
settings.set(reflection.id, for: .journal)
settings.set(mine.id, for: .interview)
settings.skipShort = false; settings.notify = false
settings.save(d)
let loaded = AutoRunSettings.load(d)
check("the per-kind assignment and options round-trip", loaded == settings && loaded.template(for: .meeting) == meeting.id && loaded.template(for: .talk) == nil)
check("one template per kind; a template can run for several kinds", { var s = loaded; s.set(meeting.id, for: .interview); return s.kinds(for: meeting.id) == [.meeting, .interview] && s.template(for: .interview) == meeting.id }())
check("\"4 of 9 kinds\" (with Brain dump's Plan my day)", loaded.assignedCount == 4)
let offD = UserDefaults(suiteName: "templates-tests-off-\(UUID().uuidString)")!
var turnedOff = AutoRunSettings.load(offD)
turnedOff.set(nil, for: .brainDump)
turnedOff.save(offD)
check("Brain dump turned Off stays Off", AutoRunSettings.load(offD).template(for: .brainDump) == nil)
let oldD = UserDefaults(suiteName: "templates-tests-old-\(UUID().uuidString)")!
oldD.set(try! JSONEncoder().encode([RecordingKind.meeting.rawValue: meeting.id.uuidString]), forKey: AutoRunSettings.assignmentsKey)
check("choices saved by a build before Brain dump get Plan my day for it, and keep theirs", AutoRunSettings.load(oldD).template(for: .brainDump) == TemplateLibrary.planMyDayID
      && AutoRunSettings.load(oldD).template(for: .meeting) == meeting.id)
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

check("eight choices in one order: Voice note, the four kinds, Thought, Brain dump, Audio only",
      RecordChoice.all == [.voiceNote, .kind(.meeting), .kind(.interview), .kind(.journal), .kind(.talk), .thought, .kind(.brainDump), .kind(.audio)])
// Record as shows five rows by default (consolidation, October 28, 2026).
let defaultRows = RecordAsRows()
check("Record as: five rows by default, in order", defaultRows.visible == [.voiceNote, .kind(.meeting), .thought, .kind(.brainDump), .kind(.audio)])
var editedRows = defaultRows
editedRows.set(.kind(.journal), shown: true)
editedRows.set(.voiceNote, shown: false)
editedRows.set(.kind(.audio), shown: false)
check("Edit Record as: a hidden row comes back in its place; Voice note never hides; any other row can",
      editedRows.visible == [.voiceNote, .kind(.meeting), .kind(.journal), .thought, .kind(.brainDump)])
let rowsSuite = UserDefaults(suiteName: "templates-tests-rows-\(UUID().uuidString)")!
check("nothing stored: the default five, not yet seeded", RecordAsRows.load(rowsSuite) == defaultRows && !RecordAsRows.isSeeded(rowsSuite))
editedRows.save(rowsSuite)
check("the rows round-trip", RecordAsRows.load(rowsSuite) == editedRows && RecordAsRows.isSeeded(rowsSuite))
rowsSuite.set(["talk", "hologram", "voiceNote"], forKey: RecordAsRows.key)
check("unknown IDs and Voice note are ignored when read", RecordAsRows.load(rowsSuite).hidden == ["talk"])
func picked(_ k: RecordingKind, daysAgo: Double, auto: Bool = false, deleted: Bool = false) -> Transcript {
    var t = Transcript(title: "x", source: .voiceMemo, sourceLabel: "", duration: 60, audioFileName: nil, model: "")
    t.kind = k; t.kindIsAuto = auto; t.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
    if deleted { t.deletedAt = now }
    return t
}
let recentRows = RecordAsRows.recentHiddenKinds([picked(.interview, daysAgo: 3), picked(.talk, daysAgo: 40), picked(.journal, daysAgo: 2, auto: true),
                                                 picked(.journal, daysAgo: 1, deleted: true), picked(.meeting, daysAgo: 1)], now: now)
check("a hidden kind you recorded in the last 30 days counts; older, guessed, or deleted ones don't", recentRows == ["interview"])
check("an install from before keeps it showing", RecordAsRows.seeded(existing: true, recent: recentRows).visible
      == [.voiceNote, .kind(.meeting), .kind(.interview), .thought, .kind(.brainDump), .kind(.audio)])
check("a new install starts with five", RecordAsRows.seeded(existing: false, recent: recentRows) == defaultRows)
check("By day's Journal hides on a new install with no entries, and shows with an entry or Journal entry on",
      !defaultRows.showsJournal(hasEntries: false) && defaultRows.showsJournal(hasEntries: true) && editedRows.showsJournal(hasEntries: false))
check("row names", RecordChoice.all.map(\.name) == ["Voice note", "Meeting", "Interview", "Journal entry", "Talk", "Thought", "Brain dump", "Audio only"])
check("serif names put the last word in italic", RecordChoice.voiceNote.serifParts == ("Voice ", "note") && RecordChoice.kind(.talk).serifParts == ("Talk", nil)
      && RecordChoice.kind(.journal).serifParts == ("Journal ", "entry"))
check("Mac right-click titles", RecordChoice.all.map(\.menuTitle) == ["Record", "Record a meeting", "Record an interview", "Record a journal entry", "Record a talk", "New thought",
                                                                     "Record a brain dump", "Record audio only"])
check("File › Record As titles", RecordChoice.all.map(\.commandTitle) == ["Voice Note", "Meeting…", "Interview", "Journal Entry", "Talk", "Thought", "Brain Dump", "Audio Only"])
check("VoiceOver actions", RecordChoice.all.map(\.actionName) == ["Record a voice note", "Record a meeting", "Record an interview", "Record a journal entry", "Record a talk", "New thought",
                                                                "Record a brain dump", "Record audio only"])
check("each choice has its own custom symbol", Set(RecordChoice.all.map(\.symbolName)).count == 8
      && RecordChoice.all.map(\.symbolName) == ["rec.voice", "rec.meeting", "rec.interview", "rec.journal", "rec.talk", "thought", "rec.braindump", "rec.audio"])
check("menu symbols: Voice note is mic, Audio only the waveform, Brain dump the head", RecordChoice.voiceNote.menuSymbol == "mic"
      && RecordChoice.kind(.audio).menuSymbol == "waveform" && RecordChoice.kind(.brainDump).menuSymbol == "brain.head.profile")
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
check("hint: Brain dump runs Plan my day from the start, and says what it files as when Off",
      RecordChoice.kind(.brainDump).hint(settings: AutoRunSettings.startingChoices, templates: trayLib) == "Runs Plan my day when it finishes"
      && RecordChoice.kind(.brainDump).hint(settings: AutoRunSettings(), templates: trayLib) == "Filed under Brain dumps")
check("hint: Audio only never names a template", RecordChoice.kind(.audio).hint(settings: { var s = AutoRunSettings(); s.set(meeting.id, for: .audio); return s }(), templates: trayLib) == "Keeps the sound, no transcript"
      && RecordChoice.kind(.audio).template(settings: { var s = AutoRunSettings(); s.set(meeting.id, for: .audio); return s }(), templates: trayLib) == nil
      && RecordChoice.kind(.audio).recorderLine(settings: AutoRunSettings(), templates: trayLib) == "Keeps the sound, no transcript")
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
check("tray: a quick tap is the plain Record", TR.isTap(held: false, trayOpen: false))
check("tray: a lift after the hold, or with the tray up, is not a tap",
      !TR.isTap(held: true, trayOpen: false) && !TR.isTap(held: true, trayOpen: true) && !TR.isTap(held: false, trayOpen: true))
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
      TemplateCopy.footer(madeOn: "Mac", here: "Mac") == "On this Mac with Apple Intelligence. Nothing leaves it. Made from this transcript; it can be wrong, so edit the result before you keep it."
      && TemplateCopy.footer(madeOn: "iPhone", here: "Mac").hasPrefix("On your iPhone with Apple Intelligence."))
check("on-device line: one phrasing everywhere", TemplateCopy.onDevice("Mac") == "On this Mac with Apple Intelligence. Nothing leaves it.")

// MARK: Brain dump's offer

var bd = rec(.meeting, minutes: 3)
bd.kind = .brainDump; bd.kindIsAuto = false
let startS = AutoRunSettings.startingChoices
let bdOffer = AutoRunRules.offer(bd, settings: startS, templates: lib)
check("filed as a Brain dump afterward with nothing run: \"Now a Brain dump. Run Plan my day?\"", bdOffer?.text == "Now a Brain dump. Run Plan my day?"
      && bdOffer?.result == nil && bdOffer?.template == TemplateLibrary.planMyDayID, "\(String(describing: bdOffer))")
var bdDismissed = bd
AutoRunRules.dismissBrainDumpOffer(bdOffer!, on: &bdDismissed, device: "test-device")
check("Not now on it never offers again and never runs", AutoRunRules.offer(bdDismissed, settings: startS, templates: lib) == nil && decide(bdDismissed, startS) == .alreadyRan)
var bdRan = bd
bdRan.addTemplateResult(TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: "## Today\n- [ ] Call [00:04]"))
check("no offer once Plan my day has a result", AutoRunRules.offer(bdRan, settings: startS, templates: lib) == nil)
check("no offer with Brain dump Off", AutoRunRules.offer(bd, settings: AutoRunSettings(), templates: lib) == nil)
var bdAuto = rec(.meeting)
bdAuto.addTemplateResult(TemplateResult(templateId: meeting.id, name: "Meeting notes", text: "## Summary\nx", auto: true, kind: .meeting))
bdAuto.kind = .brainDump; bdAuto.kindIsAuto = false
var both = startS; both.set(meeting.id, for: .meeting)
check("a Meeting that ran Meeting notes, now a Brain dump: the offer replaces it", AutoRunRules.offer(bdAuto, settings: both, templates: lib)?.result == bdAuto.templateResults?.first?.id)
check("a short brain dump still runs Plan my day with Skip short recordings on", decide({ var x = rec(nil, minutes: 0.5); x.pickKindAtStart(.brainDump); return x }(), startS)
      == .run(TemplateLibrary.planMyDayID, .brainDump))
let planPrompt = TemplatePrompt.instruction(scenarios[8])
check("Plan my day: the mockup's instruction, its six sections, times on each line, and the no-add rule",
      planPrompt.hasPrefix(TemplateLibrary.planMyDayInstruction) && planPrompt.contains("1. Top three: checklist") && planPrompt.contains("6. Ideas: bullet points")
      && planPrompt.contains("[mm:ss] time of the line it came from") && !planPrompt.contains("None stated") && planPrompt.hasSuffix(rule))
check("Plan my day's ID follows the scenarios' pattern", TemplateLibrary.planMyDayID.uuidString == String(format: "5E7B0A02-F1A0-4C00-9000-%012d", 9))
check("Plan my day is Brain dump's, with a day glyph", scenarios[8].kinds == [.brainDump] && scenarios[8].glyph == TemplateGlyph.planDay && scenarios[8].origin == .scenario
      && TemplateLibrary.planMyDayID == scenarios[8].id && TranscriptActions.builtIn.count == 2)
let planText = TemplatePrompt.instruction(scenarios[8], forText: true)
check("Plan my day on text asks for no times", planText.hasPrefix(TemplateLibrary.planMyDayInstruction) && !planText.contains("[mm:ss]") && planText.hasSuffix(rule))

// MARK: The consolidation (October 28, 2026)

let mk = TranscriptActions.makeAPlanID, je = TranscriptActions.journalEntryID, kp = TranscriptActions.keyPointsID
check("retired: Make a plan, Journal entry, and Key points leave the library", [mk, je, kp].allSatisfy { id in !TemplateLibrary.all(yours: []).contains { $0.id == id } }
      && [mk, je, kp].allSatisfy { TemplateLibrary.template($0, yours: []) == nil })
check("retired: Make a plan runs Plan my day, Journal entry Daily reflection, Key points nothing",
      TemplateLibrary.current(mk) == TemplateLibrary.planMyDayID && TemplateLibrary.current(je) == TemplateLibrary.dailyReflectionID
      && TemplateLibrary.current(kp) == nil && TemplateLibrary.current(meeting.id) == meeting.id && TemplateLibrary.dailyReflectionID == scenarios[7].id)
let oldPlan = TemplateResult(templateId: mk, name: "Make a plan", text: "## Tasks\n- [ ] Call Sam")
let oldKeys = TemplateResult(templateId: kp, name: "Key points", text: "## Key ideas\n- Cedar")
var oldAuto = TemplateResult(templateId: je, name: "Journal entry", text: "## Entry\nA long day.", auto: true, kind: .journal)
oldAuto.edited = false
check("retired: Run again on an old Make a plan result runs Plan my day in its place",
      TemplateLibrary.runAgain(oldPlan).map { $0.template == TemplateLibrary.planMyDayID && $0.replacing == oldPlan.id } == true)
check("retired: an automatic Journal entry result is replaced by Daily reflection",
      TemplateLibrary.runAgain(oldAuto).map { $0.template == TemplateLibrary.dailyReflectionID && $0.replacing == oldAuto.id } == true)
check("retired: a Key points result keeps rendering with no Run again", TemplateLibrary.runAgain(oldKeys) == nil
      && TemplateResultText.blocks(oldKeys.text) == [.heading("Key ideas"), .bullet("Cedar")])
let current = TemplateResult(templateId: meeting.id, name: "Meeting notes", text: "x")
check("a current template's Run again is unchanged", TemplateLibrary.runAgain(current).map { $0.template == meeting.id && $0.replacing == nil } == true)
check("one Templates list: a template is on recordings, and on selected text too when it's a text action",
      TemplateScope.of(template: meeting.id, textActions: []) == .recording
      && TemplateScope.of(template: TemplateLibrary.planMyDayID, textActions: [TemplateLibrary.planMyDayID]) == .both
      && TemplateScope.textAction.onText && TemplateScope.textAction.onRecording && !TemplateScope.recording.onText)
check("each is marked", TemplateScope.metaLine(.both, "Rewrites the text") == "Selected text and recordings · Rewrites the text"
      && TemplateScope.metaLine(.recording, "") == "Recordings" && TemplateScope.text.title == "Selected text")
let suiteRA = UserDefaults(suiteName: "templates-tests-retired-\(UUID().uuidString)")!
suiteRA.set(try! JSONEncoder().encode([RecordingKind.meeting.rawValue: mk.uuidString, RecordingKind.journal.rawValue: je.uuidString,
                                       RecordingKind.podcast.rawValue: kp.uuidString, RecordingKind.talk.rawValue: scenarios[4].id.uuidString]),
            forKey: AutoRunSettings.assignmentsKey)
let movedRA = AutoRunSettings.load(suiteRA)
check("Run automatically: Make a plan moves to Plan my day, Journal entry to Daily reflection, Key points turns Off",
      movedRA.template(for: .meeting) == TemplateLibrary.planMyDayID && movedRA.template(for: .journal) == TemplateLibrary.dailyReflectionID
      && movedRA.template(for: .podcast) == nil && movedRA.template(for: .talk) == scenarios[4].id)

// MARK: Audio only

var audio = rec(nil, minutes: 1.2)
audio.segments = []; audio.original = []
audio.pickKindAtStart(.audio)
audio.title = "Melody for the second verse"; audio.titleIsAuto = false
audio.notes = [Note(text: "", at: 31, isBookmark: true, markSource: "lockScreen"), Note(text: "Chorus starts", at: 58, isBookmark: true, markSource: "phoneApp")]
check("Audio only: the queue, AutoLabel, Ask, and Run automatically leave it alone", AudioOnlyRules.skipsQueue(audio) && !AudioOnlyRules.labels(audio)
      && !AudioOnlyRules.indexes(audio) && decide(audio, startS) == .notEligible && audio.showsAudioDetail && !audio.wantsSuggestedKind)
var withWords = audio; withWords.segments = [Segment(start: 0, end: 3, text: "La la la.")]
check("Audio only with words (filed afterward) still never runs a template, and opens as a transcript", decide(withWords, startS) == .notEligible && !withWords.showsAudioDetail)
var later = audio
later.beginTranscribeLater()
check("Transcribe: it queues, still Audio only until the words are in", later.status == .processing && later.isAudioOnly && !AudioOnlyRules.skipsQueue(later)
      && later.showsAudioDetail)
later.segments = [Segment(start: 0, end: 4, text: "The chorus goes up here.")]
later.status = .ready
later.finishTranscribeLater(as: nil)
check("Transcribe later: a plain voice note with its title and moments kept, ready for AutoLabel", later.kind == nil && later.kindIsAuto && later.wantsSuggestedKind
      && later.title == "Melody for the second verse" && later.notes == audio.notes && !later.isAudioOnly)
var asMeeting = audio
asMeeting.beginTranscribeLater()
asMeeting.segments = [Segment(start: 0, end: 4, text: "Hi.")]; asMeeting.status = .ready
asMeeting.finishTranscribeLater(as: .meeting)
asMeeting.duration = 600
check("Transcribe as a meeting: the kind is yours, and its template runs by the normal rules", asMeeting.kind == .meeting && !asMeeting.kindIsAuto
      && decide(asMeeting) == .run(meeting.id, .meeting))
var notAudio = rec(.journal); notAudio.finishTranscribeLater(as: .meeting)
check("finishing Transcribe later leaves anything not Audio only alone", notAudio.kind == .journal)
check("Transcribe as: Voice note and each kind, never Audio only", AudioOnlyRules.transcribeChoices.map(AudioOnlyRules.choiceName) == ["Voice note", "Meeting", "Interview", "Journal entry", "Talk", "Thought", "Brain dump"]
      && !AudioOnlyRules.transcribeChoices.contains(.audio) && AudioOnlyRules.menuTitle(.meeting) == "Transcribe as meeting")
check("Audio only's VoiceOver row", AudioOnlyRules.accessibilityLabel({ var x = audio; x.duration = 72; return x }()) == "Melody for the second verse, Audio only, 1 minute 12 seconds, no transcript, 2 moments")
check("the kinds you can pick include Brain dump and Audio only, last", Array(RecordingKind.pickable.suffix(2)) == [.brainDump, .audio]
      && !RecordingKind.modelKinds.contains(.audio) && !RecordingKind.modelKinds.contains(.brainDump))
let audioFile = (try? enc.encode(audio)).flatMap { try? dec.decode(Transcript.self, from: $0) }
check("the new kinds round-trip in the transcript file", audioFile?.kind == .audio && audioFile?.title == audio.title)

// MARK: Plan my day's result

let recorded = { () -> Date in var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 27; c.hour = 7; c.minute = 42; return Calendar(identifier: .gregorian).date(from: c)! }()
var greg = Calendar(identifier: .gregorian); greg.timeZone = TimeZone(identifier: "America/New_York")!
let canned = """
## Top three
- [ ] Send the bakery invoice [00:04]
- [ ] Finish the orchard storyboard before Thursday's call [00:11]
- [ ] Call the print shop about the menu proofs [00:19]

## Today
- [ ] Back up the cards from yesterday's shoot [00:27]

## Tomorrow
- [ ] Book the drone pilot for the farm shoot [00:41]
- [ ] Send the shot list to the client [00:47]

## This week
- [ ] Renew the portfolio site's domain [00:58]
- [ ] Pick up the lens from repair on Friday [01:06]

## Someday
- [ ] Redo the studio reel [01:15]

## Ideas
- A short series on how families run their farm stands [01:24]
- A mug with the barn logo for the welcome kits [01:39]
"""
let plan = DayPlan.parse(canned)
check("plan: the six sections from a canned result, in order", plan.shownSections == [.top, .today, .tomorrow, .week, .someday, .ideas]
      && plan.top.count == 3 && plan.tasks.count == 9 && plan.ideas.count == 2 && !plan.topInferred, "\(plan)")
check("plan: times come off the words and become the line's anchor", plan.top[0].text == "Send the bakery invoice" && plan.top[0].anchor == 4
      && plan.week[1].anchor == 66 && plan.ideas[1].anchor == 99)
check("plan: a named day under This week is kept; Someday has none", plan.week[1].weekday == 6 && plan.week[0].weekday == nil && plan.someday[0].weekday == nil
      && plan.top[1].weekday == nil)
let day = { (c: DateComponents?) -> String in c.map { "\($0.year!)-\($0.month!)-\($0.day!)" } ?? "none" }
check("plan: days resolve from the recording's date", day(DayPlan.due(plan.top[0], recordedAt: recorded, calendar: greg)) == "2026-10-27"
      && day(DayPlan.due(plan.tomorrow[0], recordedAt: recorded, calendar: greg)) == "2026-10-28"
      && day(DayPlan.due(plan.week[1], recordedAt: recorded, calendar: greg)) == "2026-10-30"
      && DayPlan.due(plan.week[0], recordedAt: recorded, calendar: greg) == nil && DayPlan.due(plan.someday[0], recordedAt: recorded, calendar: greg) == nil
      && DayPlan.due(plan.ideas[0], recordedAt: recorded, calendar: greg) == nil)
check("plan: a due date has no time (all day)", DayPlan.due(plan.top[0], recordedAt: recorded, calendar: greg).map { $0.hour == nil && $0.minute == nil } == true)
let aWeekLater = recorded.addingTimeInterval(7 * 86_400)
check("plan: opened a week later, Tomorrow is still the day after the recording", day(DayPlan.due(plan.tomorrow[0], recordedAt: recorded, calendar: greg)) == "2026-10-28"
      && DayPlan.dueLabel(DayPlan.due(plan.top[0], recordedAt: recorded, calendar: greg), now: aWeekLater, calendar: greg, locale: Locale(identifier: "en_US")) == "Tue, Oct 27"
      && DayPlan.dueLabel(DayPlan.due(plan.top[0], recordedAt: recorded, calendar: greg), now: recorded, calendar: greg) == "Today"
      && DayPlan.dueLabel(nil) == "No date")
check("plan: the Tomorrow heading's date", DayPlan.tomorrowLabel(recordedAt: recorded, calendar: greg, locale: Locale(identifier: "en_US")) == "Wed, Oct 28")
let saidSunday = DayPlan.item("Water the plants (Sunday) [00:30]", section: .week)
check("plan: a day in parentheses comes off and names the date", saidSunday.text == "Water the plants" && saidSunday.weekday == 1
      && day(DayPlan.due(saidSunday, recordedAt: recorded, calendar: greg)) == "2026-11-1")
let noTop = DayPlan.parse("## Today\n- [ ] One [00:01]\n- [ ] Two [00:02]\n- [ ] Three [00:03]\n- [ ] Four [00:04]\n\n## Someday\nNone stated.\n\n## Ideas\nNone stated.")
check("plan: no top three named, today's first three in the order said, and the section says so", noTop.topInferred && noTop.top.map(\.text) == ["One", "Two", "Three"]
      && noTop.today.map(\.text) == ["Four"] && noTop.shownSections == [.top, .today])
let said = DayPlan.parse("## Top three\nYou didn't name three, so these are the first three.\n- [ ] One [00:01]\n## Today\n- [ ] One [00:01]\n- [ ] Two [00:05]")
check("plan: the model saying it chose them shows the line; a task listed twice shows once", said.topInferred && said.top.map(\.text) == ["One"] && said.today.map(\.text) == ["Two"])
check("plan: an empty brain dump says so", DayPlan.parse("## Top three\nNone stated.").isEmpty && DayPlan.noTasksLine == "No tasks or ideas in what you said.")
check("plan: Someday's line", DayPlan.somedayLine == "And anything you didn\u{2019}t give a day")

// Send to Reminders (no EventKit here: the drafts are what the app hands it).
var sel = DayPlan.defaultSelection(plan, sent: [:])
check("reminders: every task checked, ideas unchecked", sel.count == 9 && !sel.contains(plan.ideas[0].key))
let drafts = DayPlan.drafts(plan, selected: sel, sent: [:], recordedAt: recorded, source: "Brain dump", anchorLabel: { $0.anchor.map { DayPlan.clock($0) } },
                            calendar: greg, locale: Locale(identifier: "en_US"))
check("reminders: nine, in the plan's order, due only where a day was said", drafts.count == 9 && drafts[0].title == "Send the bakery invoice"
      && day(drafts[0].due) == "2026-10-27" && day(drafts[4].due) == "2026-10-28" && drafts[6].due == nil && day(drafts[7].due) == "2026-10-30" && drafts[8].due == nil)
check("reminders: each says where it came from", drafts[0].notes == "From Verbose \u{00B7} Brain dump, Tue, Oct 27, 0:04", drafts[0].notes)
sel.insert(plan.ideas[0].key)
let withIdea = DayPlan.drafts(plan, selected: sel, sent: [:], recordedAt: recorded, source: "Brain dump", anchorLabel: { _ in nil }, calendar: greg)
check("reminders: a checked idea goes in with no date", withIdea.count == 10 && withIdea.last?.title == plan.ideas[0].text && withIdea.last?.due == nil)
var sentIDs: [String: String] = [:]
for (i, d) in drafts.enumerated() { sentIDs[d.key] = "reminder-\(i)" }
check("reminders: never twice; a second send adds only what's new", DayPlan.drafts(plan, selected: Set(plan.tasks.map(\.key)), sent: sentIDs, recordedAt: recorded, source: "Brain dump",
                                                                                   anchorLabel: { _ in nil }, calendar: greg).isEmpty
      && DayPlan.defaultSelection(plan, sent: sentIDs).isEmpty && DayPlan.allSent(plan, sent: sentIDs))
check("reminders: the messages", DayPlan.sentMessage(added: 9, already: 0, list: "Studio") == "Added 9 reminders to Studio"
      && DayPlan.sentMessage(added: 2, already: 9, list: "Studio") == "Added 2. 9 were already in Reminders."
      && DayPlan.sentStatus(plan, sent: sentIDs) == "9 in Reminders" && DayPlan.sentStatus(plan, sent: [:]) == nil)
var resent = rec(.brainDump)
var first = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: canned)
first.sent = sentIDs
resent.addTemplateResult(first)
resent.addTemplateResult(TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: canned))
check("Run again keeps what's in Reminders marked as sent", resent.templateResults?.count == 1 && resent.templateResults?.first?.sent == sentIDs)
let sentFile = (try? enc.encode(resent)).flatMap { try? dec.decode(Transcript.self, from: $0) }
check("sent reminders round-trip in the transcript file", sentFile?.templateResults?.first?.sent == sentIDs)
var marking = rec(.brainDump)
let planResult = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: canned)
marking.addTemplateResult(planResult)
marking.recordSentReminders(["a|4": "r1"], result: planResult.id)
marking.recordSentReminders(["b|11": "r2"], result: planResult.id)
check("sending records the reminders on the result and beside it", marking.templateResults?.first?.sent == ["a|4": "r1", "b|11": "r2"] && marking.remindersSent == ["a|4": "r1", "b|11": "r2"])
// What a build before Brain dump writes back: the result without its "sent", the transcript's unknown key kept.
var olderSaved = (try? JSONSerialization.jsonObject(with: try enc.encode(marking))) as? [String: Any] ?? [:]
if var results = olderSaved["templateResults"] as? [[String: Any]] { results[0]["sent"] = nil; results[0]["kind"] = nil; olderSaved["templateResults"] = results }
let reread = (try? JSONSerialization.data(withJSONObject: olderSaved)).flatMap { try? dec.decode(Transcript.self, from: $0) }
check("an older build dropping the result's copy never makes a plan send twice", reread?.templateResults?.first?.sent == ["a|4": "r1", "b|11": "r2"])

// Organize today's thoughts and the Mac's note.
let thoughts = ["Send the bakery invoice today.", "The storyboard needs the barn shot moved up.", "Call the print shop about the menu proofs."]
let input = DayPlan.input(thoughts, title: "Thoughts", createdAt: recorded)
check("thoughts: one line a minute, so a time names its thought", input.segments.map(\.start) == [0, 60, 120] && input.segments.map(\.text) == thoughts)
let tp = DayPlan.parse("## Top three\n- [ ] Send the bakery invoice [00:00]\n- [ ] Call the print shop [02:00]\n## Ideas\n- A mug [05:00]")
check("thoughts: each task links back to its thought", DayPlan.index(of: tp.top[0], count: 3) == 0 && DayPlan.index(of: tp.top[1], count: 3) == 2
      && DayPlan.index(of: tp.ideas[0], count: 3) == nil)
check("note: paragraphs between blank lines", DayPlan.paragraphs("First line.\nStill first.\n\n\nSecond.\n  \nThird.") == ["First line. Still first.", "Second.", "Third."])
var rec1 = DayPlanRecord(day: "2026-10-27", source: .thoughts)
rec1.text = "## Top three\n- [ ] A [00:00]"; rec1.thoughtIDs = [UUID(), UUID()]
check("a day's plan has one ID per day and source, on every device", rec1.id == DayPlanRecord.id(day: "2026-10-27", source: .thoughts)
      && rec1.id != DayPlanRecord.id(day: "2026-10-27", source: .note) && rec1.id != DayPlanRecord.id(day: "2026-10-28", source: .thoughts))
check("a day's plan counts thoughts added since", rec1.newThoughts(in: rec1.thoughtIDs + [UUID(), UUID()]) == 2 && DayPlanRecord(day: "2026-10-27", source: .thoughts).newThoughts(in: [UUID()]) == 0)
let recBack = (try? enc.encode([rec1])).flatMap { try? dec.decode([DayPlanRecord].self, from: $0) }
check("a day's plan round-trips, and a newer build's source reads safely", recBack == [rec1]
      && (try? dec.decode(DayPlanRecord.self, from: Data(#"{"day":"2026-10-27","source":"watch","extra":1}"#.utf8)))?.source == .thoughts)
check("plans merge like the other synced lists", SyncMerge.merge(local: [rec1], remote: [], localTombstones: [], remoteTombstones: []).items == [rec1])
check("day keys", DayPlanRecord.dayKey(recorded, calendar: greg) == "2026-10-27" && DayPlanRecord.date("2026-10-27", calendar: greg).map { greg.component(.day, from: $0) } == 27)

// The checks both self-tests run (TemplateChecks.swift), here too.
// Send tasks (TaskSend.swift): Things, OmniFocus, and the share sheet's checklist.
do {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
    let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
    let drafts = [
        DayPlan.ReminderDraft(key: "a", title: "Send the bakery invoice & receipt", due: DateComponents(year: 2026, month: 11, day: 3), notes: "From Verbose · Brain dump, Tue, Nov 3, 0:04"),
        DayPlan.ReminderDraft(key: "b", title: "Email kim@studio.co", due: DateComponents(year: 2026, month: 11, day: 5), notes: ""),
        DayPlan.ReminderDraft(key: "c", title: "Call the print shop", due: nil, notes: "From Verbose"),
    ]
    let items = TaskSend.thingsItems(drafts, today: today, calendar: cal)
    let a0 = items[0]["attributes"] as? [String: Any] ?? [:]
    let a1 = items[1]["attributes"] as? [String: Any] ?? [:]
    let a2 = items[2]["attributes"] as? [String: Any] ?? [:]
    check("things: a task due today is When Today with a deadline", a0["when"] as? String == "today" && a0["deadline"] as? String == "2026-11-03")
    check("things: a later day is a deadline, not When", a1["when"] == nil && a1["deadline"] as? String == "2026-11-05")
    check("things: no date, no When or deadline; the notes come along", a2["when"] == nil && a2["deadline"] == nil && a2["notes"] as? String == "From Verbose")
    let tu = TaskSend.thingsURL(drafts, today: today, calendar: cal)?.absoluteString ?? ""
    check("things: one json link that reveals, with & encoded", tu.hasPrefix("things:///json?data=") && tu.hasSuffix("&reveal=true") && !tu.dropLast(12).contains("&") && tu.contains("%26"))
    check("things: nothing to send is no link", TaskSend.thingsURL([], today: today) == nil)
    let tp = TaskSend.taskPaper(drafts)
    check("omnifocus: TaskPaper with due dates and indented notes",
          tp.hasPrefix("- Send the bakery invoice & receipt @due(2026-11-03)\n\tFrom Verbose") && tp.contains("- Call the print shop\n\tFrom Verbose"))
    check("omnifocus: a task's @ isn't read as a tag", tp.contains("- Email kim at studio.co @due(2026-11-05)"))
    check("omnifocus: one paste link into the Inbox", (TaskSend.omniFocusURL(drafts)?.absoluteString ?? "").hasPrefix("omnifocus:///paste?target=inbox&content=-%20Send"))
    let list = TaskSend.checklist(drafts, title: "Plan for Tue, Nov 3", now: today, calendar: cal, locale: Locale(identifier: "en_US"))
    check("share: a checklist with the day in parentheses",
          list == "Plan for Tue, Nov 3\n- [ ] Send the bakery invoice & receipt (Today)\n- [ ] Email kim@studio.co (Thu, Nov 5)\n- [ ] Call the print shop", list)
    let all = TaskDestination.allCases
    check("menu: Things and OmniFocus only when installed", TaskDestination.offered(installed: { _ in false }) == [.reminders, .share] && TaskDestination.offered(installed: { _ in true }) == all)
    check("button: names the last app while it's offered", TaskDestination.buttonTitle(last: .things, offered: all) == "Send to Things"
          && TaskDestination.buttonTitle(last: .things, offered: [.reminders, .share]) == "Send tasks"
          && TaskDestination.buttonTitle(last: .share, offered: all) == "Send tasks" && TaskDestination.buttonTitle(last: nil, offered: all) == "Send tasks")
    check("sheet: starts where you sent last, else Reminders", TaskDestination.starting(last: .omnifocus, offered: all) == .omnifocus
          && TaskDestination.starting(last: .omnifocus, offered: [.reminders, .share]) == .reminders)
    check("sheet: the confirm button", TaskDestination.reminders.actionTitle(count: 4) == "Add 4 to Reminders" && TaskDestination.things.actionTitle(count: 1) == "Add 1 to Things" && TaskDestination.share.actionTitle(count: 2) == "Share 2")
}

TemplateChecks.run { check("self-test: " + $0, $1) }
PlanChecks.run { check("self-test: " + $0, $1) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
