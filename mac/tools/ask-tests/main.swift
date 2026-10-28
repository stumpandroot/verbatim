import Foundation

// Ask your library (Verbatim/Model/Ask.swift) and recipes (AskRecipes.swift): scopes, passages, ranking and the relevance
// floor, digests, the prompt, citation checking, the footer, and recipe scheduling. The shared checks (AskChecks.swift)
// run in both self-tests too. Not part of any app target; run mac/tools/test-ask.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

AskChecks.run { check("shared: " + $0, $1) }

let now = Date(timeIntervalSince1970: 1_800_000_000)
let project = UUID()
let lib = AskChecks.samples(project: project, now: now)
let all = AskChecks.candidates(lib)

// MARK: Scopes

check("scope: a recording still transcribing isn't asked", { var t = lib[0]; t.status = .processing; return !AskScope.all.includes(t, now: now) }())
check("scope: a deleted recording isn't asked", { var t = lib[0]; t.deletedAt = now; return !AskScope.all.includes(t, now: now) }())
check("scope: a recording with no words isn't asked", { var t = lib[0]; t.segments = []; return !AskScope.all.includes(t, now: now) }())
check("scope: a deleted project matches nothing and says so", lib.filter { AskScope(source: .project(UUID())).includes($0, now: now) }.isEmpty
      && AskScope(source: .project(UUID())).label(projects: [:]) == "A deleted project · All time")
check("scope: labels", AskScope.all.label(projects: [:]) == "All time" && AskScope(range: .thisWeek).label(projects: [:]) == "This week"
      && AskScope(source: .project(project)).label(projects: [project: "Website refresh"]) == "Website refresh · All time"
      && AskScope(range: .thisWeek, source: .meetings).label(projects: [:]) == "Meetings · This week")
var chips = AskScope.all
chips.tap(.meetings); chips.tap(.thoughts)
check("scope: one source at a time; tapping it again clears it", chips.source == .thoughts && { var x = chips; x.tap(.thoughts); return x.source == .all }())
chips.tapWeek()
check("scope: This week toggles", chips.range == .thisWeek && { var x = chips; x.tapWeek(); return x.range == .allTime }())
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
check("scope: encodes as one string", String(data: try! enc.encode([AskScope(range: .thisWeek, source: .meetings)]), encoding: .utf8) == #"["week|meetings"]"#)
check("scope: an unknown scope from a newer build reads as All", (try? dec.decode([AskScope].self, from: Data(#"["decade|galaxy"]"#.utf8))) == [AskScope.all])
check("scope: the week boundary is seven days", { var t = lib[2]; t.createdAt = now.addingTimeInterval(-7 * 86_400 + 60); return AskScope(range: .thisWeek).includes(t, now: now) }()
      && { var t = lib[2]; t.createdAt = now.addingTimeInterval(-7 * 86_400 - 60); return !AskScope(range: .thisWeek).includes(t, now: now) }())

// MARK: Passages

let call = lib[0]
let callPassages = AskPassages.build(call)
check("passages: every passage starts at a real line", callPassages.allSatisfy { p in call.segments.contains { $0.id == p.segmentId && $0.start == p.start } })
check("passages: speakers' names lead their lines", callPassages.contains { $0.text.hasPrefix("Sam: ") } && callPassages.contains { $0.text.contains("Alex: ") })
check("passages: a long pause starts a new passage", callPassages.count >= 3, "\(callPassages.map(\.start))")
check("passages: numbered in order", callPassages.map(\.index) == Array(0..<callPassages.count) && callPassages.map(\.start) == callPassages.map(\.start).sorted())
check("passages: IDs are unique", Set(callPassages.map(\.id)).count == callPassages.count)
var long = AskChecks.recording("Lecture", kind: .talk, daysAgo: 0, now: now, lines: (0..<40).map { (Double($0) * 5, nil, "This is sentence number \($0) of the lecture about type on screens.") })
let lectures = AskPassages.build(long)
check("passages: a long talk becomes passages of about 70 words, never over 110", lectures.count > 3 && lectures.allSatisfy { AskPassages.wordCount($0.text) <= AskPassages.maxWords },
      "\(lectures.map { AskPassages.wordCount($0.text) })")
let runOn = String(repeating: "Words keep coming here. ", count: 80)
long.segments = [Segment(start: 0, end: 600, text: runOn)]
let split = AskPassages.build(long)
check("passages: one very long line is split at sentence ends, keeping its start", split.count > 2 && split.allSatisfy { $0.start == 0 && AskPassages.wordCount($0.text) <= AskPassages.maxWords })
var fillers = lib[1]; fillers.segments.insert(Segment(start: 1, end: 2, text: "Um."), at: 0)
check("passages: filler-only lines are left out", !AskPassages.build(fillers).contains { $0.text.hasPrefix("Um.") })
check("passages: the fingerprint is stable", AskPassages.fingerprint(call) == AskPassages.fingerprint(call))
check("passages: the fingerprint changes with a word", { var t = call; t.segments[1].text += " Really."; return AskPassages.fingerprint(t) != AskPassages.fingerprint(call) }())
check("passages: the fingerprint changes with a speaker's name", { var t = call; t.speakers[1].name = "Alexandra"; return AskPassages.fingerprint(t) != AskPassages.fingerprint(call) }())
check("passages: the fingerprint ignores the title", { var t = call; t.title = "Renamed"; return AskPassages.fingerprint(t) == AskPassages.fingerprint(call) }())

// MARK: Words

check("words: common words and question words are left out", AskText.tokens("What did Alex want changed on the homepage?") == ["alex", "want", "chang", "homepage"],
      "\(AskText.tokens("What did Alex want changed on the homepage?"))")
check("words: plurals and endings match", AskText.tokens("headlines") == AskText.tokens("headline") && AskText.tokens("Studies") == AskText.tokens("study")
      && AskText.tokens("testing") == AskText.tokens("test"))
check("words: accents and apostrophes", AskText.tokens("Café") == ["cafe"] && AskText.tokens("Alex's form") == ["alex", "form"] && AskText.tokens("don’t") == ["don"])

// MARK: Ranking

let q = "What did Alex want changed on the homepage?"
let hits = AskRanker.rank(question: q, candidates: all)
check("ranking: the homepage passage first", hits.first?.passage.text.contains("homepage") == true, "\(hits.map(\.passage.text))")
check("ranking: scores are sorted", zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
check("ranking: a one-word question matches any passage with the word", AskRanker.rank(question: "headline", candidates: all).count >= 2)
check("ranking: the title helps", { let h = AskRanker.rank(question: "website pricing", candidates: all); return h.first?.candidate.title == AskChecks.clientTitle }())
let none = AskRanker.rank(question: "Where did I park the car?", candidates: all)
check("ranking: nothing relevant", none.isEmpty)
let closest = AskRanker.rank(question: "Where did I park the car?", candidates: all, all: true)
check("ranking: but every passage is there for the closest", closest.count == all.count)
// Meaning: fake embeddings, the question close to the review's passage only.
var vecs = all
for i in vecs.indices { vecs[i].vector = vecs[i].passage.text.contains("calendar dots") ? [1, 0, 0] : [0, 1, 0] }
let semantic = AskRanker.rank(question: "Which color reads better for the little markers?", candidates: vecs, questionVector: [0.95, 0.1, 0])
check("ranking: a passage close in meaning counts with none of the words", semantic.first?.passage.text.contains("calendar dots") == true && semantic.count == 1,
      "\(semantic.map { ($0.passage.text, $0.semantic ?? -1) })")
check("ranking: cosine", abs(AskRanker.cosine([1, 0], [1, 0]) - 1) < 1e-6 && abs(AskRanker.cosine([1, 0], [0, 1])) < 1e-6 && AskRanker.cosine([1], [1, 2]) == 0)
let many: [AskCandidate] = (0..<30).map { i in
    AskCandidate(passage: AskPassage(transcriptId: i < 20 ? lib[0].id : lib[1].id, index: i, segmentId: UUID(), start: Double(i), end: Double(i) + 1,
                                     text: "The headline came up again in part \(i). " + String(repeating: "more words ", count: 30)),
                 title: "T", createdAt: now)
}
let sel = AskRanker.select(AskRanker.rank(question: "headline", candidates: many))
check("ranking: at most four from one recording and twelve in all", sel.count <= 12 && Dictionary(grouping: sel, by: \.passage.transcriptId).values.allSatisfy { $0.count <= 4 })
check("ranking: within the budget", sel.reduce(0) { $0 + min($1.passage.text.count, AskRanker.passageChars) } <= AskRanker.charBudget)
let thoughts = (0..<5).map { i in AskChecks.recording("Thought \(i)", kind: .idea, daysAgo: Double(i) / 10, now: now, lines: [(0, nil, "Idea number \(i) about something new.")]) }
let ov = AskRanker.overview(question: "Weekly digest of my thoughts", candidates: AskChecks.candidates(thoughts))
check("ranking: a digest takes every recording, newest first", ov.map(\.candidate.title) == ["Thought 0", "Thought 1", "Thought 2", "Thought 3", "Thought 4"], "\(ov.map(\.candidate.title))")
let meetings = AskChecks.candidates(lib.filter { $0.kind == .meeting })
let tasks = AskRanker.overview(question: "Action items from this week's meetings", candidates: meetings)
check("ranking: action items lead with commitments", tasks.first?.passage.text.contains("I'll send") == true, "\(tasks.map(\.passage.text))")

// MARK: Prompt

let given = AskRanker.select(hits)
let prompt = AskPrompt.prompt(question: q, passages: given)
check("prompt: numbered passages with their recording and time", prompt.contains("[1] \(AskChecks.clientTitle), ") && prompt.contains(", at 12:40") && prompt.hasSuffix("Answer with citations:"))
check("prompt: the instructions demand citations and only the passages", AskPrompt.instructions.contains("only the numbered passages") && AskPrompt.instructions.contains("Every sentence needs at least one citation")
      && AskPrompt.instructions.contains(AskPrompt.notFound))
check("prompt: a long passage is cut", { let h = AskHit(candidate: AskCandidate(passage: AskPassage(transcriptId: UUID(), index: 0, segmentId: UUID(), start: 0, end: 1, text: String(repeating: "x", count: 2000)), title: "T", createdAt: now), score: 1, matched: 1, semantic: nil)
    return AskPrompt.prompt(question: "x", passages: [h]).count < 1000 }())
check("format: times", AskFormat.time(492) == "8:12" && AskFormat.time(1625) == "27:05" && AskFormat.time(3734) == "1:02:14" && AskFormat.time(-3) == "0:00")

// MARK: Citations

let three = Array(AskRanker.rank(question: q, candidates: all, all: true).prefix(3))
let sample = AskCitations.parse(AskChecks.sampleAnswer, passages: three)
check("citations: the sample answer keeps four sentences in two paragraphs", sample?.blocks.count == 2
      && { if case .paragraph(let s) = sample!.blocks[0] { return s.count == 2 } else { return false } }(), "\(String(describing: sample?.blocks))")
check("citations: three sources, numbered in order", sample?.citations.map(\.number) == [1, 2, 3])
check("citations: markers leave clean text", sample?.plainText.hasPrefix("Alex asked for a shorter headline, because on a phone it fills the screen before anything else shows, and for the contact form to sit higher on the page. [1]") == true,
      sample?.plainText ?? "nil")
check("citations: Copy ends with the sources", sample?.plainText.contains("\n\nSources:\n[1] ") == true)
let markers = AskCitations.stripMarkers("Move it up [1, 3] and test [2-4] it .")
check("citations: lists and ranges", markers.numbers == [1, 3, 2, 3, 4] && markers.text == "Move it up and test it.", "\(markers)")
check("citations: a number after the period stays with its sentence", AskCitations.sentences("One thing. [2] Another [1].") == ["One thing. [2]", "Another [1]."])
check("citations: brackets that aren't numbers stay", AskCitations.stripMarkers("Use [brackets] here [1].").text == "Use [brackets] here.")
check("citations: e.g. doesn't end a sentence", AskCitations.sentences("Use short words, e.g. Record [1]. Done [2].").count == 2)
let bullets = AskCitations.parse("Website refresh\n- Move the export button [1]\n- Day headers use the mono date [2]\n\nErrands:\n- Printer paper [3]\nSources:\n[1] Thoughts, 9:14", passages: three)
check("citations: headings and bullets for a digest", bullets?.blocks == [.heading("Website refresh"), .bullet([AskSentence(text: "Move the export button", cites: [1])]),
                                                                       .bullet([AskSentence(text: "Day headers use the mono date", cites: [2])]),
                                                                       .heading("Errands"), .bullet([AskSentence(text: "Printer paper", cites: [3])])],
      "\(String(describing: bullets?.blocks))")
check("citations: a heading with nothing cited under it goes", AskCitations.parse("## Empty\n- Nothing here\n## Kept\n- Something [1]", passages: three)?.blocks
      == [.heading("Kept"), .bullet([AskSentence(text: "Something", cites: [1])])])
check("citations: a repeated number shows once per sentence", AskCitations.parse("Twice [1][1].", passages: three)?.blocks == [.paragraph([AskSentence(text: "Twice.", cites: [1])])])
check("citations: zero isn't a passage", AskCitations.parse("Zero [0]. One [1].", passages: three)?.plainText.hasPrefix("One. [1]") == true)
check("citations: NOT_FOUND with a period is no answer", AskCitations.parse("NOT_FOUND.", passages: three) == nil)
check("citations: a refusal with no citations is no answer", AskCitations.parse("I'm sorry, I can't help with that.", passages: three) == nil)
check("citations: each citation points at its passage", sample?.citations.enumerated().allSatisfy { i, c in c.segmentId == three[i].passage.segmentId && c.start == three[i].passage.start && c.title == three[i].candidate.title } == true)
check("citations: the first sentence for a notification", sample?.firstSentence.hasPrefix("Alex asked for a shorter headline") == true)

// MARK: Result

var res = AskResult(question: q, scope: .all, state: .answered, device: "Mac", askedAt: now)
res.passageCount = 9; res.recordingCount = 2
check("result: the footer", res.footer(native: false) == "On this Mac with Apple Intelligence. Nothing leaves it. Verbose found 9 passages in 2 recordings first, then answered from them."
      && res.footer(native: true) == "From 9 passages in 2 recordings, answered on this Mac.")
res.passageCount = 1; res.recordingCount = 1; res.device = "iPhone"
check("result: the footer in the singular", res.footer(native: true) == "From 1 passage in 1 recording, answered on this iPhone.")
var nf = AskResult(question: q, scope: AskScope(source: .thoughts), state: .nothingFound, device: "Mac")
check("result: nothing found says so", nf.message(scopeLabel: "Thoughts · All time") == "Nothing in Thoughts · All time matches this question, so Verbose didn't answer. Try All, or other words.")
nf.scope = .all
check("result: nothing found in the whole library", nf.message(scopeLabel: "All time").hasPrefix("Nothing in your library matches"))
var so = AskResult(question: q, scope: .all, state: .searchOnly, device: "Mac")
so.reason = "Answers need Apple Intelligence, which is off on this Mac."
check("result: search only gives its reason in one line", so.message(scopeLabel: "") == "Answers need Apple Intelligence, which is off on this Mac. These are the passages that match.")
res.answer = sample
check("result: round-trips", (try? enc.encode(res)).flatMap { try? dec.decode(AskResult.self, from: $0) } == res)
check("result: a newer build's result still reads", (try? dec.decode(AskResult.self, from: Data(#"{"question":"Q","state":"telepathy","extra":1}"#.utf8)))?.state == .nothingFound)

// MARK: Recipes and their schedules

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
// Friday, October 23, 2026 is a Friday.
let fri4 = RecipeSchedule(weekday: 6, hour: 16, minute: 0, since: date(2026, 10, 1, 9))
check("schedule: the next run is this Friday at 4 PM", RecipeScheduling.next(after: date(2026, 10, 21, 10), fri4, calendar: cal) == date(2026, 10, 23, 16))
check("schedule: on Friday after 4 PM, the next is a week later", RecipeScheduling.next(after: date(2026, 10, 23, 16, 1), fri4, calendar: cal) == date(2026, 10, 30, 16))
check("schedule: on Friday before 4 PM, it's that afternoon", RecipeScheduling.next(after: date(2026, 10, 23, 15, 59), fri4, calendar: cal) == date(2026, 10, 23, 16))
check("schedule: the last time on or before now", RecipeScheduling.last(onOrBefore: date(2026, 10, 26, 9), fri4, calendar: cal) == date(2026, 10, 23, 16)
      && RecipeScheduling.last(onOrBefore: date(2026, 10, 23, 16), fri4, calendar: cal) == date(2026, 10, 23, 16))
check("schedule: daylight saving time keeps 4 PM", RecipeScheduling.next(after: date(2026, 10, 31, 12), fri4, calendar: cal) == date(2026, 11, 6, 16))
check("schedule: owed at 4 PM on Friday", RecipeScheduling.due(fri4, lastRun: date(2026, 10, 16, 16, 2), now: date(2026, 10, 23, 16, 0), calendar: cal) == date(2026, 10, 23, 16))
check("schedule: not owed a minute before", RecipeScheduling.due(fri4, lastRun: date(2026, 10, 16, 16, 2), now: date(2026, 10, 23, 15, 59), calendar: cal) == nil)
check("schedule: the Mac was asleep three weeks: owed once, for the latest Friday", RecipeScheduling.due(fri4, lastRun: date(2026, 10, 2, 16, 1), now: date(2026, 10, 26, 8), calendar: cal) == date(2026, 10, 23, 16))
check("schedule: and once it ran, not again", RecipeScheduling.due(fri4, lastRun: date(2026, 10, 26, 8, 1), now: date(2026, 10, 26, 9), calendar: cal) == nil
      && RecipeScheduling.due(fri4, lastRun: date(2026, 10, 26, 8, 1), now: date(2026, 10, 29, 9), calendar: cal) == nil)
check("schedule: until the next Friday", RecipeScheduling.due(fri4, lastRun: date(2026, 10, 26, 8, 1), now: date(2026, 10, 30, 16, 5), calendar: cal) == date(2026, 10, 30, 16))
let fresh = RecipeSchedule(weekday: 6, hour: 16, minute: 0, since: date(2026, 10, 23, 17))
check("schedule: set after this week's time, it waits for next week", RecipeScheduling.due(fresh, lastRun: nil, now: date(2026, 10, 24, 9), calendar: cal) == nil
      && RecipeScheduling.due(fresh, lastRun: nil, now: date(2026, 10, 30, 16), calendar: cal) == date(2026, 10, 30, 16))
check("schedule: words", RecipeSchedule(weekday: 2, hour: 8, minute: 30).label == "Every Monday at 8:30 AM" && RecipeSchedule(weekday: 1, hour: 0, minute: 5).time == "12:05 AM"
      && RecipeSchedule(weekday: 7, hour: 12, minute: 0).shortLabel == "Saturdays, 12:00 PM")
check("schedule: out-of-range values are clamped", RecipeSchedule(weekday: 9, hour: 30, minute: 99).weekday == 7 && RecipeSchedule(weekday: 0, hour: -1, minute: -1).hour == 0)

let digestRecipe = AskRecipe(question: "Weekly digest of my thoughts", scope: AskScope(range: .thisWeek, source: .thoughts), createdAt: date(2026, 10, 1, 9))
let actions = AskRecipe(question: "Action items from this week's meetings", scope: AskScope(range: .thisWeek, source: .meetings), createdAt: date(2026, 10, 1, 9))
let anytime = AskRecipe(question: "What did I say about Website refresh", scope: AskScope(source: .project(project)), createdAt: date(2026, 10, 1, 9))
var device = RecipeDeviceState()
device.schedules[digestRecipe.id] = fri4
device.schedules[actions.id] = RecipeSchedule(weekday: 2, hour: 8, minute: 30, since: date(2026, 10, 1, 9))
let owed = device.due([digestRecipe, actions, anytime], now: date(2026, 10, 26, 9), calendar: cal)
check("device: both scheduled recipes are owed, oldest first; Any time never is", owed.map(\.0.id) == [digestRecipe.id, actions.id] && owed.map(\.1) == [date(2026, 10, 23, 16), date(2026, 10, 26, 8, 30)])
device.lastRun[digestRecipe.id] = date(2026, 10, 26, 9); device.lastRun[actions.id] = date(2026, 10, 26, 9)
check("device: after running, none are owed", device.due([digestRecipe, actions, anytime], now: date(2026, 10, 26, 10), calendar: cal).isEmpty)
check("device: the soonest next run", device.nextRun([digestRecipe, actions, anytime], after: date(2026, 10, 26, 10), calendar: cal) == date(2026, 10, 30, 16))
check("device: deleted recipes' schedules go", device.pruned([anytime]).schedules.isEmpty && device.pruned([actions]).schedules.count == 1)
let defaults = UserDefaults(suiteName: "ask-tests-\(UUID().uuidString)")!
device.save(defaults)
check("device: schedules are kept on this device", RecipeDeviceState.load(defaults) == device)

check("recipes: sync like the other lists", SyncMerge.merge(local: [digestRecipe], remote: [anytime], localTombstones: [], remoteTombstones: []).items.count == 2)
let futureRecipe = #"[{"id":"\#(UUID().uuidString)","question":"Q","scope":"week|meetings","color":"teal"}]"#
check("recipes: a newer build's recipe reads", (try? dec.decode([AskRecipe].self, from: Data(futureRecipe.utf8)))?.first?.scope == AskScope(range: .thisWeek, source: .meetings))
check("recipes: suggestions without a project", RecipeSuggestions.all(projects: []).last?.question == "What did I decide this week")
check("recipes: suggestions' schedules", RecipeSuggestions.all(projects: []).compactMap { $0.schedule.map { "\($0.weekday) \($0.hour):\($0.minute)" } } == ["6 16:0", "2 8:30"])

let rr = AskResult(question: "Q", scope: .all, state: .answered, device: "Mac")
let digests = (0..<12).map { i in AskDigest(recipeId: i < 10 ? digestRecipe.id : actions.id, ranAt: now.addingTimeInterval(Double(i)), scheduled: true, result: rr) }
let kept = AskDigest.trimmed(digests)
check("digests: newest first, at most eight per recipe", kept.first?.ranAt == now.addingTimeInterval(11) && kept.filter { $0.recipeId == digestRecipe.id }.count == 8 && kept.count == 10)

// MARK: Deleting

let base = FileManager.default.temporaryDirectory.appendingPathComponent("ask-tests-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: AskStorage.indexFolder(in: base), withIntermediateDirectories: true)
let keepID = UUID(), goneID = UUID()
for id in [keepID, goneID] { try? Data("x".utf8).write(to: AskStorage.indexFile(id, in: base)) }
try? Data("[]".utf8).write(to: AskStorage.historyFile(in: base))
try? Data("[]".utf8).write(to: AskStorage.digestsFile(in: base))
AskStorage.removeIndex(for: [goneID], in: base)
let fm = FileManager.default
check("delete: a deleted recording's passages leave the index at once, the others stay",
      !fm.fileExists(atPath: AskStorage.indexFile(goneID, in: base).path) && fm.fileExists(atPath: AskStorage.indexFile(keepID, in: base).path))
check("delete: the index lives in Ask Index, one file per recording", AskStorage.indexFile(keepID, in: base).deletingLastPathComponent().lastPathComponent == "Ask Index"
      && AskStorage.indexFile(keepID, in: base).lastPathComponent == keepID.uuidString + ".plist")
AskStorage.removeAll(in: base)
check("delete all: the index folder, recent questions, and digests go", !fm.fileExists(atPath: AskStorage.indexFolder(in: base).path)
      && !fm.fileExists(atPath: AskStorage.historyFile(in: base).path) && !fm.fileExists(atPath: AskStorage.digestsFile(in: base).path))
AskStorage.removeAll(in: base)
check("delete all: running it again with nothing there is fine", !fm.fileExists(atPath: AskStorage.indexFolder(in: base).path))
try? fm.removeItem(at: base)

var cited = res
cited.state = .answered
cited.found = sample!.citations
cited.passageCount = 3; cited.recordingCount = Set(sample!.citations.map(\.transcriptId)).count
let callID = lib[0].id, reviewID = lib[1].id
let noCall = AskCleanup.pruned(cited, removing: [callID])
check("delete: citations of a deleted recording go, and the rest are renumbered", noCall.answer?.citations.map(\.number) == [1]
      && noCall.answer?.citations.allSatisfy { $0.transcriptId == reviewID } == true, "\(String(describing: noCall.answer?.citations.map(\.title)))")
check("delete: sentences that cited only it go", noCall.answer?.blocks.count == 1 && noCall.answer?.plainText.hasPrefix("In Monday's design review") == true,
      noCall.answer?.plainText ?? "nil")
check("delete: the counts follow what's left", noCall.passageCount == 1 && noCall.recordingCount == 1 && noCall.found.map(\.number) == [1])
let emptied = AskCleanup.pruned(cited, removing: [callID, reviewID])
check("delete: an answer with nothing left becomes nothing found", emptied.answer == nil && emptied.state == .nothingFound && emptied.found.isEmpty)
check("delete: an unrelated recording changes nothing", AskCleanup.pruned(cited, removing: [UUID()]) == cited)
let digestsBefore = [AskDigest(recipeId: actions.id, ranAt: now, scheduled: true, result: cited)]
let digestsAfter = AskCleanup.pruned(digestsBefore, removing: [callID])
check("delete: digests that cite a deleted recording drop those citations", digestsAfter.first?.result.answer?.citations.contains { $0.transcriptId == callID } == false
      && digestsAfter.first?.result.answer?.citations.isEmpty == false)

// Recipes are hidden until you show them, and show while you have one (consolidation, October 28, 2026).
check("recipes: hidden by default, shown by the switch or while you have one", !RecipesSetting.shows(stored: false, hasRecipes: false)
      && RecipesSetting.shows(stored: true, hasRecipes: false) && RecipesSetting.shows(stored: false, hasRecipes: true) && RecipesSetting.key == "ask.showRecipes")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
