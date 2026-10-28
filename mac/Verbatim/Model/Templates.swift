import Foundation

// Templates (mockup "Library features", section 1, October 26, 2026): a template is a name, an instruction, and the
// sections you want back. The two transcript actions are the Built in templates (Write a draft and Study notes; the
// consolidation of October 28, 2026 merged Make a plan into Plan my day and Journal entry into Daily reflection, and
// cut Key points), nine Scenario templates come with Verbose (the ninth is Plan my day), and you make your own (synced with the library as `templates.json`, like snippets). Each recording kind can
// have one template that runs on its own when a recording of that kind finishes (Run automatically, kept per device
// like other settings). Every template prompt carries the no-add rule (TranscriptActions.noAddRule) and runs on device
// with Apple Intelligence the way the actions do (Transcription/TemplateRunner.swift).
//
// Pure Foundation, so mac/tools/test-templates.sh checks the model, the assignment, the skip rules, and the run-once
// rule on Linux.

// MARK: - Sections

/// How a section is written.
enum TemplateSectionFormat: String, Codable, CaseIterable, Identifiable, TolerantEnum {
    case paragraph, bullets, checklist, quotes
    static var fallback: TemplateSectionFormat { .bullets }
    init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .paragraph: return "Paragraph"
        case .bullets: return "Bullets"
        case .checklist: return "Checklist"
        case .quotes: return "Quotes with times"
        }
    }

    /// What the prompt asks for under a section of this format.
    var prompt: String {
        switch self {
        case .paragraph: return "a short paragraph"
        case .bullets: return "bullet points that start with \"- \""
        case .checklist: return "checklist lines that start with \"- [ ] \", with an owner or a date only when the transcript states it"
        case .quotes: return "lines quoted word for word in quotation marks, each followed by the [mm:ss] time of its line"
        }
    }
}

struct TemplateSection: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var format: TemplateSectionFormat

    init(_ name: String, _ format: TemplateSectionFormat, id: UUID = UUID()) {
        self.id = id; self.name = name; self.format = format
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case id, name, format }
        let c = try d.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        format = (try? c.decodeIfPresent(TemplateSectionFormat.self, forKey: .format)) ?? .bullets
    }
}

// MARK: - Template

/// Where a template comes from: the two actions, the nine that come with Verbose, or yours.
enum TemplateOrigin: String, CaseIterable, Identifiable {
    case scenario, yours, builtIn
    var id: String { rawValue }
    var title: String {
        switch self {
        case .builtIn: return "Built in"
        case .scenario: return "Scenarios"
        case .yours: return "Yours"
        }
    }
    /// The eyebrow on a template's detail ("◇ Scenario template").
    var eyebrow: String {
        switch self {
        case .builtIn: return "Built-in template"
        case .scenario: return "Scenario template"
        case .yours: return "Yours"
        }
    }
}

/// Where a template works (consolidation, October 28, 2026: one Templates list holds the Mac's text actions and the
/// transcript templates, each marked): on text you select in any app (the Ribbon's menu), on a recording (Run a
/// template, Run automatically, a transcript's Actions), or both.
enum TemplateScope: String, CaseIterable, Sendable {
    case text, recording, both
    var title: String {
        switch self {
        case .text: return "Selected text"
        case .recording: return "Recordings"
        case .both: return "Selected text and recordings"
        }
    }
    var onText: Bool { self != .recording }
    var onRecording: Bool { self != .text }

    /// A template works on recordings; one that's also a text action (Plan my day, Daily reflection, Write a draft,
    /// Study notes, on the Mac) works on selected text too.
    static func of(template id: UUID, textActions: Set<UUID>) -> TemplateScope { textActions.contains(id) ? .both : .recording }

    /// A text action of yours or one that comes with Verbose: the Ribbon's menu on selected text, and a transcript's or a
    /// dictation's Actions menu on the Mac, so both.
    static let textAction = TemplateScope.both

    /// A row's meta line: "Selected text and recordings · Summary, decisions, action items".
    static func metaLine(_ scope: TemplateScope, _ rest: String) -> String { rest.isEmpty ? scope.title : scope.title + " · " + rest }
}

/// A template: a name, a short description, the instruction, its sections in order, and the kinds it suits. Yours
/// sync through the Store (`templates.json`, SyncMerge), so `updatedAt` stamps each change.
struct TranscriptTemplate: Codable, Equatable, Identifiable, Hashable, SyncEntry {
    var id = UUID()
    var name: String
    /// One line under the name ("Summary, decisions, action items, open questions").
    var summary: String
    /// What to write, in plain words. The no-add rule is added when it runs, even if you delete it here.
    var instructions: String
    var sections: [TemplateSection]
    /// The kinds it suits ("Use it for"): listed first in Run automatically's menus.
    var kinds: [RecordingKind]
    /// Its icon, by name (`TemplateGlyph`): the views map it to a BrandArt glyph or an SF Symbol in Native.
    var glyph: String = TemplateGlyph.custom
    var createdAt = Date()
    var updatedAt: Date? = nil

    init(id: UUID = UUID(), name: String, summary: String, instructions: String, sections: [TemplateSection],
         kinds: [RecordingKind], glyph: String = TemplateGlyph.custom) {
        self.id = id; self.name = name; self.summary = summary; self.instructions = instructions
        self.sections = sections; self.kinds = kinds; self.glyph = glyph
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case id, name, summary, instructions, sections, kinds, glyph, createdAt, updatedAt }
        let c = try d.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled template"
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        instructions = (try? c.decodeIfPresent(String.self, forKey: .instructions)) ?? ""
        sections = (try? c.decodeIfPresent([TemplateSection].self, forKey: .sections)) ?? []
        // Kinds a newer build added are dropped, never the whole template.
        let raw = (try? c.decodeIfPresent([String].self, forKey: .kinds)) ?? []
        kinds = raw.compactMap(RecordingKind.init(rawValue:))
        glyph = (try? c.decodeIfPresent(String.self, forKey: .glyph)) ?? TemplateGlyph.custom
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil
    }

    var origin: TemplateOrigin { TemplateLibrary.origin(of: id) }
    var isEditable: Bool { origin == .yours }
    /// Has a Quotes with times section, so the model sees each line's [mm:ss].
    var usesTimestamps: Bool {
        if let spec = TranscriptActions.spec(id) { return spec.timestamps }
        // Plan my day: each task links back to the line it came from.
        if id == TemplateLibrary.planMyDayID { return true }
        return sections.contains { $0.format == .quotes }
    }
    /// Pulls things together (parts are merged) rather than rewriting the words in order (parts are joined).
    var extracts: Bool { TranscriptActions.spec(id)?.extracts ?? true }
}

/// Icon names for templates. The views draw each as a BrandArt glyph (Verbose) or an SF Symbol (Native).
enum TemplateGlyph {
    static let plan = "plan", journal = "journal", draft = "draft", study = "study", keyPoints = "keyPoints"
    static let meeting = "meeting", oneOnOne = "oneOnOne", client = "client", interview = "interview", lecture = "lecture"
    static let sermon = "sermon", brainstorm = "brainstorm", reflection = "reflection", custom = "custom"
    /// Plan my day (DayPlan.swift): a day with a check.
    static let planDay = "planDay"
}

// MARK: - The library

enum TemplateLibrary {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "5E7B0A02-F1A0-4C00-9000-%012d", n))! }

    /// The two actions as templates (Write a draft and Study notes), with the sections each one writes. They run with
    /// the action's own instruction.
    static let builtIn: [TranscriptTemplate] = TranscriptActions.builtIn.map { a in
        let shape: (String, [TemplateSection], [RecordingKind], String) = {
            switch a.name {
            case "Write a draft": return ("An email or message from your thoughts", [TemplateSection("Draft", .paragraph, id: sid(a.id, 1))], [.note, .idea], TemplateGlyph.draft)
            default: return ("Topics in order, with key terms in bold", [TemplateSection("Topics", .bullets, id: sid(a.id, 1))], [.talk, .video], TemplateGlyph.study)
            }
        }()
        var t = TranscriptTemplate(id: a.id, name: a.name, summary: shape.0, instructions: a.instruction, sections: shape.1, kinds: shape.2, glyph: shape.3)
        t.createdAt = Date(timeIntervalSince1970: 1_792_000_000)
        return t
    }

    /// A stable section ID for a built-in or scenario template, so its sections compare equal across launches.
    private static func sid(_ template: UUID, _ n: Int) -> UUID {
        UUID(uuidString: template.uuidString.replacingOccurrences(of: "-4C00-", with: String(format: "-4C%02d-", n))) ?? UUID()
    }

    private static func scenario(_ n: Int, _ name: String, _ summary: String, _ kinds: [RecordingKind], _ glyph: String,
                                 _ instructions: String, _ sections: [(String, TemplateSectionFormat)]) -> TranscriptTemplate {
        let tid = id(n)
        var t = TranscriptTemplate(id: tid, name: name, summary: summary, instructions: instructions,
                                   sections: sections.enumerated().map { TemplateSection($1.0, $1.1, id: sid(tid, $0 + 1)) },
                                   kinds: kinds, glyph: glyph)
        t.createdAt = Date(timeIntervalSince1970: 1_792_000_000)
        return t
    }

    /// Plan my day's ID: Brain dump's template from the start (`AutoRunSettings.load`), and the one whose result
    /// draws as a plan with Send to Reminders (DayPlan.swift).
    static let planMyDayID = Transcript.planMyDayID
    /// Daily reflection's ID: Journal entry merged into it.
    static let dailyReflectionID = id(8)

    /// The built-in templates the consolidation (October 28, 2026) retired, and what took each one's place: Make a
    /// plan became Plan my day, Journal entry became Daily reflection, and Key points was cut (nil). Their results
    /// stay on their transcripts and keep rendering, under the name they ran with.
    static let retired: [UUID: UUID?] = [
        TranscriptActions.makeAPlanID: planMyDayID,
        TranscriptActions.journalEntryID: dailyReflectionID,
        TranscriptActions.keyPointsID: nil,
    ]

    /// The template that runs for an ID now: the ID itself, or what replaced a retired one (nil when it was cut).
    static func current(_ id: UUID) -> UUID? {
        guard let r = retired[id] else { return id }
        return r
    }

    /// Run again on a result: the template to run and the result it replaces. A result from a retired template runs
    /// its replacement in its place (Make a plan's runs Plan my day); one from a cut template (Key points) has no Run
    /// again (nil). An automatic result stays marked as automatic and is replaced in place.
    static func runAgain(_ r: TemplateResult) -> (template: UUID, replacing: UUID?)? {
        guard let now = current(r.templateId) else { return nil }
        if now != r.templateId { return (now, r.id) }
        return (now, r.auto ? r.id : nil)
    }

    /// Plan my day's instruction (approved mockup "Verbose Brain Dump", section 10). The no-add rule is added when it
    /// runs, as for every template.
    static let planMyDayInstruction = "Make a plan for the speaker's day from what they said. Put the three tasks they call most important under Top three, in their order; if they don't name them, use the first three tasks for today in the order said, and say so. Sort the other tasks by when the speaker said they'd do them: Today, Tomorrow, This week, or Someday. Name a day only when the transcript names it. Put tasks with no day under Someday. Put ideas that aren't tasks under Ideas, in the speaker's words. Leave out a section with nothing in it."

    /// The nine that come with Verbose. Plan my day is ninth, a Scenario template: "Built in" means the two transcript
    /// actions (TranscriptActions.builtIn).
    static let scenarios: [TranscriptTemplate] = [
        scenario(1, "Meeting notes", "Summary, decisions, action items, open questions", [.meeting], TemplateGlyph.meeting,
                 "Write notes from a call or meeting with two or more people. Pull out what was decided and who does what, using only what was said. Name a person only when the transcript names them.",
                 [("Summary", .paragraph), ("Decisions", .bullets), ("Action items", .checklist), ("Open questions", .bullets)]),
        scenario(2, "1:1", "Updates, blockers, feedback, and next steps", [.meeting], TemplateGlyph.oneOnOne,
                 "Write notes from a one-on-one conversation between two people. Keep each update, blocker, and piece of feedback with the person who gave it.",
                 [("Updates", .bullets), ("Blockers", .bullets), ("Feedback", .bullets), ("Next steps", .checklist)]),
        scenario(3, "Client call", "What they asked for, dates, and follow-ups", [.meeting], TemplateGlyph.client,
                 "Write notes from a call with a client. Pull out what the client asked for, and keep every date, number, and price exactly as said.",
                 [("What they asked for", .bullets), ("Dates and numbers", .bullets), ("Follow-ups", .checklist)]),
        scenario(4, "Interview", "Questions, answers, and quotes with times", [.interview, .podcast], TemplateGlyph.interview,
                 "Write notes from an interview. Pair each question with the answer given, in order and in a few words. Keep quotes word for word.",
                 [("Questions and answers", .bullets), ("Quotes", .quotes)]),
        scenario(5, "Lecture", "Topics in order, terms, and questions to review", [.talk, .video], TemplateGlyph.lecture,
                 "Write notes from a lecture or class. Follow the order of the topics. Define a term only when the speaker defines it.",
                 [("Topics", .bullets), ("Key terms", .bullets), ("Questions to review", .bullets)]),
        scenario(6, "Sermon notes", "Passages, main points, and one thing to apply", [.talk], TemplateGlyph.sermon,
                 "Write notes from a sermon. List the passages the speaker cites exactly as said, the main points in order, and what the speaker asked listeners to do. Don't add interpretation or application the speaker didn't give.",
                 [("Passages", .bullets), ("Main points", .bullets), ("To apply", .bullets)]),
        scenario(7, "Brainstorm", "Ideas, themes, and next steps", [.idea, .meeting, .note], TemplateGlyph.brainstorm,
                 "Collect every idea from a brainstorm, in the speaker's words where you can. Group related ideas under themes the transcript suggests. Don't rank, judge, or extend the ideas.",
                 [("Ideas", .bullets), ("Themes", .bullets), ("Next steps", .checklist)]),
        scenario(8, "Daily reflection", "What happened, what stood out, and for tomorrow", [.journal], TemplateGlyph.reflection,
                 "Sort what the speaker said about their day into the sections, in their own voice. Don't add advice, feelings, lessons, or conclusions the speaker didn't say.",
                 [("What happened", .paragraph), ("What stood out", .bullets), ("For tomorrow", .bullets)]),
        scenario(9, "Plan my day", "Top three, then tasks by day, and ideas", [.brainDump], TemplateGlyph.planDay,
                 planMyDayInstruction,
                 [("Top three", .checklist), ("Today", .checklist), ("Tomorrow", .checklist), ("This week", .checklist),
                  ("Someday", .checklist), ("Ideas", .bullets)]),
    ]

    static let scenarioIDs: Set<UUID> = Set(scenarios.map(\.id))

    static func origin(of id: UUID) -> TemplateOrigin {
        if TranscriptActions.isBuiltIn(id) { return .builtIn }
        if scenarioIDs.contains(id) { return .scenario }
        return .yours
    }

    /// Every template in library order: Scenarios, Yours (newest first), Built in.
    static func all(yours: [TranscriptTemplate]) -> [TranscriptTemplate] {
        scenarios + yours.filter { origin(of: $0.id) == .yours }.sorted { $0.createdAt > $1.createdAt } + builtIn
    }

    static func template(_ id: UUID, yours: [TranscriptTemplate]) -> TranscriptTemplate? {
        builtIn.first { $0.id == id } ?? scenarios.first { $0.id == id } ?? yours.first { $0.id == id }
    }

    /// A template filtered by the library's chips.
    static func filtered(_ list: [TranscriptTemplate], origin: TemplateOrigin?, autoOnly: Bool, settings: AutoRunSettings) -> [TranscriptTemplate] {
        list.filter { t in
            (origin == nil || t.origin == origin) && (!autoOnly || !settings.kinds(for: t.id).isEmpty)
        }
    }

    /// Duplicate and edit: a copy that's yours, named "<name> copy", with the action's instruction and its sections.
    /// A built-in's copy runs its sections from the prompt, since it no longer has the action's own instruction.
    static func duplicate(_ t: TranscriptTemplate, now: Date = Date()) -> TranscriptTemplate {
        var copy = TranscriptTemplate(name: t.name + " copy", summary: t.summary,
                                      instructions: t.instructions.replacingOccurrences(of: " " + TranscriptActions.noAddRule, with: "")
                                        .replacingOccurrences(of: TranscriptActions.noAddRule, with: "")
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                      sections: t.sections.map { TemplateSection($0.name, $0.format) }, kinds: t.kinds, glyph: t.glyph)
        copy.createdAt = now
        return copy
    }

    /// A new, empty template of yours.
    static func blank(now: Date = Date()) -> TranscriptTemplate {
        var t = TranscriptTemplate(name: "", summary: "", instructions: "", sections: [TemplateSection("Summary", .paragraph)], kinds: [])
        t.createdAt = now
        return t
    }

    /// Why a template of yours can't be saved yet (nil when it can).
    static func problem(_ t: TranscriptTemplate) -> String? {
        if t.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the template a name." }
        if t.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && t.sections.isEmpty { return "Say what it should write, or add a section." }
        if t.sections.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "Name every section." }
        return nil
    }

    /// The summary line a template of yours shows when you didn't write one: its sections, in order.
    static func summaryLine(_ t: TranscriptTemplate) -> String {
        let s = t.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        let names = t.sections.map(\.name).filter { !$0.isEmpty }
        guard let first = names.first else { return "No sections yet" }
        return ([first] + names.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
    }
}

// MARK: - The prompt

enum TemplatePrompt {
    /// The instruction a template runs with. A built-in action runs with its own instruction unchanged; every other
    /// template is its instruction, then its sections as "## Name" headings in order, then the no-add rule (added
    /// even after someone deletes it).
    static func instruction(_ t: TranscriptTemplate) -> String { instruction(t, forText: false) }

    /// `forText` is for a template run on text with no line times (Plan my day and Daily reflection as text actions).
    static func instruction(_ t: TranscriptTemplate, forText: Bool) -> String {
        if let spec = TranscriptActions.spec(t.id) { return TranscriptActions.withRule(spec.instruction) }
        var s = t.instructions
            .replacingOccurrences(of: TranscriptActions.noAddRule, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.hasSuffix(".") { s += "." }
        let sections = t.sections.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if !sections.isEmpty {
            let list = sections.enumerated().map { i, x in "\(i + 1). \(x.name.trimmingCharacters(in: .whitespaces)): \(x.format.prompt)." }
            s += (s.isEmpty ? "" : " ") + "Write these sections in this order. Start each one with its name on its own line after \"## \". "
                + list.joined(separator: " ")
            if t.id == TemplateLibrary.planMyDayID {
                // Its own instruction leaves out empty sections; each task and idea links back to its line.
                if !forText { s += " End each task and idea with the [mm:ss] time of the line it came from." }
            } else {
                s += " If the transcript says nothing for a section, write \"None stated.\" under it."
            }
        }
        return TranscriptActions.withRule(s)
    }
}

// MARK: - Run automatically

/// Run automatically's choices, kept per device like other settings (never synced; the results sync with the
/// library): one template or Off per kind, and three options.
struct AutoRunSettings: Equatable {
    static let assignmentsKey = "templates.auto"
    static let skipShortKey = "templates.skipShort"
    static let showFirstKey = "templates.showFirst"
    static let notifyKey = "templates.notify"
    /// Set once Run automatically's choices are saved on this device: Brain dump's Plan my day is seeded only before it,
    /// so turning Brain dump Off stays Off.
    static let seededKey = "templates.auto.seeded"

    /// Kind raw value → template ID. A kind that isn't here is Off.
    var assignments: [String: UUID] = [:]
    /// Skip short recordings (under two minutes). On by default.
    var skipShort = true
    /// Show the result first: transcripts with an automatic result open on it. Off by default.
    var showFirst = false
    /// Notify me when it's done, for recordings over 20 minutes. On by default.
    var notify = true

    /// The kinds Run automatically lists, in the mockup's order, then Brain dump. Dictations never run a template, and
    /// neither does Audio only (no transcript; the screens list it with no picker).
    static let kinds: [RecordingKind] = [.meeting, .journal, .idea, .interview, .talk, .podcast, .note, .video, .brainDump]

    /// What a device starts with: every kind Off but Brain dump, which runs Plan my day, because the plan is the point
    /// of the kind (decision 4, October 27, 2026).
    static var startingChoices: AutoRunSettings {
        var s = AutoRunSettings()
        s.set(TemplateLibrary.planMyDayID, for: .brainDump)
        return s
    }

    func template(for kind: RecordingKind) -> UUID? { assignments[kind.rawValue] }
    mutating func set(_ template: UUID?, for kind: RecordingKind) { assignments[kind.rawValue] = template }
    /// The kinds a template runs for, in Run automatically's order.
    func kinds(for template: UUID) -> [RecordingKind] { Self.kinds.filter { assignments[$0.rawValue] == template } }
    /// How many kinds have a template ("5 of 8 kinds").
    var assignedCount: Int { Self.kinds.filter { assignments[$0.rawValue] != nil }.count }

    /// Drops assignments to templates that no longer exist (a template of yours deleted here or on the other device).
    func pruned(existing: Set<UUID>) -> AutoRunSettings {
        var s = self
        s.assignments = assignments.filter { existing.contains($0.value) }
        return s
    }

    static func load(_ d: UserDefaults = .standard) -> AutoRunSettings {
        var s = AutoRunSettings()
        if let data = d.data(forKey: assignmentsKey), let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            // A kind that ran a retired template runs what replaced it (Make a plan: Plan my day; Journal entry: Daily
            // reflection), and one that ran Key points turns Off. The next save writes it that way.
            s.assignments = raw.compactMapValues(UUID.init(uuidString:)).compactMapValues(TemplateLibrary.current)
        }
        // Before this device saved its choices with Brain dump in them (a new install, or a build from before Brain
        // dump): Brain dump starts with Plan my day.
        if !d.bool(forKey: seededKey), s.assignments[RecordingKind.brainDump.rawValue] == nil {
            s.assignments[RecordingKind.brainDump.rawValue] = TemplateLibrary.planMyDayID
        }
        if d.object(forKey: skipShortKey) != nil { s.skipShort = d.bool(forKey: skipShortKey) }
        if d.object(forKey: showFirstKey) != nil { s.showFirst = d.bool(forKey: showFirstKey) }
        if d.object(forKey: notifyKey) != nil { s.notify = d.bool(forKey: notifyKey) }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(assignments.mapValues(\.uuidString)) { d.set(data, forKey: Self.assignmentsKey) }
        d.set(skipShort, forKey: Self.skipShortKey)
        d.set(showFirst, forKey: Self.showFirstKey)
        d.set(notify, forKey: Self.notifyKey)
        d.set(true, forKey: Self.seededKey)
    }
}

/// When a template runs on its own, pure so the self-tests and mac/tools/test-templates.sh check it.
enum AutoRunRules {
    /// Skip short recordings: under two minutes.
    static let shortLimit: Double = 120
    /// Notify me when it's done: recordings over 20 minutes.
    static let notifyLimit: Double = 20 * 60
    /// Only recordings made in the last two days run automatically, so Transcribe again on an old recording never
    /// starts a template it never had.
    static let newWindow: Double = 2 * 24 * 3600
    /// How long a finished recording waits for its kind (AutoLabel) before Run automatically gives up on it.
    static let labelWait: Double = 180

    enum Decision: Equatable {
        /// Run this template, for this kind.
        case run(UUID, RecordingKind)
        /// The kind has no template (Off), or the recording has no kind yet and won't get one.
        case off
        /// Under two minutes with Skip short recordings on.
        case short
        /// It already ran (or is waiting, failed, or was skipped): once per recording.
        case alreadyRan
        /// Not a recording that runs templates: a dictation, unfinished, deleted, or older than two days.
        case notEligible
        /// Its kind is still being worked out (AutoLabel): wait.
        case waitForKind
    }

    /// What Run automatically does with a recording that just finished. `labelPending` is true while AutoLabel may
    /// still give it a kind. A kind you picked (`kindIsAuto == false`) wins over the guess; AutoLabel never replaces it.
    static func decide(_ t: Transcript, settings: AutoRunSettings, templates: [TranscriptTemplate], labelPending: Bool,
                       now: Date = Date()) -> Decision {
        // Audio only has no transcript to run on until you transcribe it (and then it's a voice note).
        guard t.status == .ready, t.deletedAt == nil, !t.isDictation, !t.isAudioOnly, !t.segments.isEmpty else { return .notEligible }
        guard t.autoRun == nil else { return .alreadyRan }
        guard now.timeIntervalSince(t.createdAt) < newWindow else { return .notEligible }
        guard let kind = t.kind else { return labelPending ? .waitForKind : .off }
        guard AutoRunSettings.kinds.contains(kind), let id = settings.template(for: kind),
              templates.contains(where: { $0.id == id }) else { return .off }
        // A brain dump is often short, and its plan is the point: Skip short recordings leaves it alone.
        if settings.skipShort && t.duration < shortLimit && kind != .brainDump { return .short }
        return .run(id, kind)
    }

    /// Notify me when it's done: on, and the recording is over 20 minutes.
    static func notifies(_ t: Transcript, settings: AutoRunSettings) -> Bool { settings.notify && t.duration > notifyLimit }

    /// "Ran automatically because this is a Meeting".
    static func reason(_ r: TemplateResult) -> String? {
        guard r.auto else { return nil }
        guard let k = r.kind else { return "Ran automatically" }
        return "Ran automatically because this is \(article(k)) \(k.label)"
    }

    /// "a Meeting", "an Interview".
    static func article(_ k: RecordingKind) -> String {
        guard let first = k.label.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    struct Offer: Equatable {
        /// The automatic result it runs in place of; nil when nothing ran automatically (a kind changed to Brain dump).
        var result: UUID?
        var kind: RecordingKind
        var template: UUID
        var templateName: String
        /// "Now a Meeting. Run Meeting notes?"
        var text: String { "Now \(AutoRunRules.article(kind)) \(kind.label). Run \(templateName)?" }
    }

    /// The kind changed after a template ran automatically: offer the new kind's template, never run it on its own.
    /// Nothing when the new kind is Off, its template already wrote a result here, it's the same template, or the
    /// offer was dismissed for this kind.
    static func offer(_ t: Transcript, settings: AutoRunSettings, templates: [TranscriptTemplate]) -> Offer? {
        if let results = t.templateResults, let r = results.first(where: { $0.auto }), let old = r.kind {
            guard let now = t.kind, now != old, r.offerDismissed != now.rawValue,
                  let id = settings.template(for: now), id != r.templateId,
                  !results.contains(where: { $0.templateId == id }),
                  let tpl = templates.first(where: { $0.id == id }) else { return nil }
            return Offer(result: r.id, kind: now, template: id, templateName: tpl.name)
        }
        return brainDumpOffer(t, settings: settings, templates: templates)
    }

    /// A recording you filed as a Brain dump after it finished, with nothing run automatically: "Now a Brain dump. Run
    /// Plan my day?" (Brain dump's template), once. Not now marks it (`dismissBrainDumpOffer`). The screens also wait
    /// while Run automatically still decides on a recording that just finished (`TemplateCenter.isPending`).
    static func brainDumpOffer(_ t: Transcript, settings: AutoRunSettings, templates: [TranscriptTemplate]) -> Offer? {
        let results = t.templateResults ?? []
        guard t.kind == .brainDump, !t.kindIsAuto, t.status == .ready, t.deletedAt == nil, !t.segments.isEmpty,
              t.autoRun == nil, !results.contains(where: { $0.auto }),
              let id = settings.template(for: .brainDump), !results.contains(where: { $0.templateId == id }),
              let tpl = templates.first(where: { $0.id == id }) else { return nil }
        return Offer(result: nil, kind: .brainDump, template: id, templateName: tpl.name)
    }

    /// Not now on an offer with no result to mark: the recording's Run automatically mark says it was skipped, so the
    /// offer never comes back and nothing runs on its own.
    static func dismissBrainDumpOffer(_ offer: Offer, on t: inout Transcript, device: String) {
        guard offer.result == nil, t.autoRun == nil else { return }
        t.autoRun = AutoRunMark(templateId: offer.template, name: offer.templateName, kind: offer.kind, state: .skipped, device: device, note: "Not now")
    }

    /// A waiting run this device should pick back up at launch (iOS suspended the app before it finished).
    static func resumes(_ t: Transcript, device: String) -> Bool {
        guard let m = t.autoRun, m.state == .waiting, m.device == device, t.deletedAt == nil, t.status == .ready else { return false }
        return !(t.templateResults ?? []).contains { $0.templateId == m.templateId && $0.auto }
    }

    /// How many recordings of a kind ran a template automatically this month ("Ran 7 times this month").
    static func runsThisMonth(_ list: [Transcript], kind: RecordingKind, now: Date = Date(), calendar: Calendar = .current) -> Int {
        list.filter { t in
            guard t.deletedAt == nil, let m = t.autoRun, m.state == .done, m.kind == kind else { return false }
            return calendar.isDate(m.at, equalTo: now, toGranularity: .month)
        }.count
    }

    /// The note beside a kind's row: "Ran 7 times this month", "Ran once", or a hint for Thoughts.
    static func monthNote(_ count: Int, kind: RecordingKind, assigned: Bool) -> String {
        if kind == .idea, !assigned { return "Thoughts are short; read them on today's page" }
        switch count {
        case 0: return assigned ? "Hasn't run this month" : ""
        case 1: return "Ran once this month"
        default: return "Ran \(count) times this month"
        }
    }
}

// MARK: - Results

extension Transcript {
    /// Adds a template's result, replacing an earlier one from the same template (and `replacing`, when given: the
    /// result a kind-change offer runs in place of). Newest first.
    mutating func addTemplateResult(_ r: TemplateResult, replacing: UUID? = nil) {
        var r = r
        // Run again keeps what was sent to Reminders: the tasks match by their words and their line (DayPlan.Item.key).
        if r.sent == nil, let old = (templateResults ?? []).first(where: { $0.templateId == r.templateId || $0.id == replacing }), let sent = old.sent {
            r.sent = sent
        }
        var list = (templateResults ?? []).filter { $0.templateId != r.templateId && $0.id != replacing }
        list.insert(r, at: 0)
        templateResults = list
    }

    mutating func removeTemplateResult(_ id: UUID) {
        let list = (templateResults ?? []).filter { $0.id != id }
        templateResults = list.isEmpty ? nil : list
    }

    /// Results to show (nil-safe), newest first.
    var shownTemplateResults: [TemplateResult] { templateResults ?? [] }

    /// "Waiting to run Meeting notes" while Run automatically's run is queued here.
    var autoRunWaitingText: String? {
        guard let m = autoRun, m.state == .waiting else { return nil }
        return "Waiting to run \(m.name)"
    }
}

/// A result's text as blocks to draw: section headings, paragraphs, bullets, checklist lines, and quotes.
enum TemplateResultText {
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(String)
        case check(String, done: Bool)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let h = heading(line) { flush(); out.append(.heading(h)); continue }
            if let (item, done) = checkItem(line) { flush(); out.append(.check(item, done: done)); continue }
            if let p = ["- ", "• ", "* ", "– "].first(where: { line.hasPrefix($0) }) {
                flush(); out.append(.bullet(String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces))); continue
            }
            para.append(line)
        }
        flush()
        return out
    }

    /// "## Decisions", "### Decisions", or "**Decisions**" alone on its line.
    private static func heading(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let h = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return h.isEmpty ? nil : stripColon(h)
        }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            let h = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            return h.contains("**") ? nil : stripColon(h)
        }
        return nil
    }

    private static func stripColon(_ s: String) -> String { s.hasSuffix(":") ? String(s.dropLast()) : s }

    private static func checkItem(_ line: String) -> (String, Bool)? {
        for p in ["- [ ] ", "* [ ] ", "[ ] "] where line.hasPrefix(p) { return (String(line.dropFirst(p.count)), false) }
        for p in ["- [x] ", "- [X] ", "* [x] ", "[x] "] where line.hasPrefix(p) { return (String(line.dropFirst(p.count)), true) }
        return nil
    }

    /// Plain text for Copy and notes: the result as written, trimmed.
    static func plain(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The footer under every result. Every on-device promise reads the same way (Templates, Ask, and You): "On this Mac
/// with Apple Intelligence. Nothing leaves it." and then what's specific to the place.
enum TemplateCopy {
    /// "On this Mac with Apple Intelligence. Nothing leaves it. Made from this transcript; it can be wrong, so edit the
    /// result before you keep it."
    static func footer(madeOn: String, here: String) -> String {
        let place = madeOn.isEmpty || madeOn == here ? "On this \(here)" : "On your \(madeOn)"
        return "\(place) with Apple Intelligence. Nothing leaves it. Made from this transcript; it can be wrong, so edit the result before you keep it."
    }
    /// The line under Run automatically's options and the editor: "On this Mac with Apple Intelligence. Nothing leaves it."
    static func onDevice(_ here: String) -> String { "On this \(here) with Apple Intelligence. Nothing leaves it." }
    static let ruleNote = "Verbose adds: \u{201C}\(TranscriptActions.noAddRule)\u{201D}"
}

// MARK: - Record a kind

extension RecordingKind {
    /// The kinds you can pick when you start recording, between Voice note and Thought in `RecordChoice.all`. Note left
    /// the list (a plain Record covers it); podcasts and videos are imports.
    static let recordChoices: [RecordingKind] = [.meeting, .interview, .journal, .talk]

    /// "Record a meeting", "Record an interview", "Record a journal entry", "Record a brain dump", "Record audio only".
    var recordTitle: String {
        switch self {
        case .journal: return "Record a journal entry"
        case .interview: return "Record an interview"
        case .audio: return "Record audio only"
        default: return "Record \(AutoRunRules.article(self)) \(label.lowercased())"
        }
    }
}

/// One way to start recording (approved mockup "Record as", October 26, 2026), in this order everywhere: the iPhone's
/// Record as tray, the Mac's right-click menu on Record, File › Record As, and VoiceOver's actions on Record. Voice
/// note is the plain Record (Verbose picks the kind); the four kinds are yours from the start; Thought starts the New
/// thought flow (Stop & add, today's page), never an ordinary recording of the Thoughts kind. Brain dump records as
/// that kind (Plan my day runs when it finishes); Audio only keeps the sound and isn't transcribed (AudioOnly.swift).
enum RecordChoice: Hashable, Identifiable {
    case voiceNote
    case kind(RecordingKind)
    case thought

    /// Voice note, Meeting, Interview, Journal entry, Talk, Thought, Brain dump, and Audio only (decision 2, October 27,
    /// 2026: the two new rows come after Thought, so the six you know stay where your thumb expects them).
    static let all: [RecordChoice] = [.voiceNote] + RecordingKind.recordChoices.map { .kind($0) } + [.thought, .kind(.brainDump), .kind(.audio)]

    var id: String {
        switch self {
        case .voiceNote: return "voiceNote"
        case .kind(let k): return k.rawValue
        case .thought: return "thought"
        }
    }

    /// The row's name: "Voice note", "Meeting", "Interview", "Journal entry", "Talk", "Thought".
    var name: String {
        switch self {
        case .voiceNote: return "Voice note"
        case .kind(.journal): return "Journal entry"
        case .kind(let k): return k.label
        case .thought: return "Thought"
        }
    }

    /// The name in the serif with its last word in italic ("Voice" + "note"); one-word names have no italic part.
    var serifParts: (String, String?) {
        let n = name
        guard let space = n.lastIndex(of: " ") else { return (n, nil) }
        return (String(n[..<space]) + " ", String(n[n.index(after: space)...]))
    }

    /// The Mac's right-click menu: "Record", "Record a meeting", …, "New thought" (the ⌃⌥P action's name).
    var menuTitle: String {
        switch self {
        case .voiceNote: return "Record"
        case .kind(let k): return k.recordTitle
        case .thought: return "New thought"
        }
    }

    /// File › Record As, in the menu bar's title case: "Voice Note", "Meeting…" (the consent sheet comes first), and so on.
    var commandTitle: String {
        switch self {
        case .voiceNote: return "Voice Note"
        case .kind(.meeting): return "Meeting…"
        case .kind(.journal): return "Journal Entry"
        case .kind(.brainDump): return "Brain Dump"
        case .kind(.audio): return "Audio Only"
        case .kind(let k): return k.label
        case .thought: return "Thought"
        }
    }

    /// VoiceOver's named action on Record: "Record a voice note", "Record a meeting", …, "New thought".
    var actionName: String {
        switch self {
        case .voiceNote: return "Record a voice note"
        case .kind(let k): return k.recordTitle
        case .thought: return "New thought"
        }
    }

    /// The kind the recording is filed as from the start: none for Voice note (AutoLabel picks), Thoughts for Thought.
    var kind: RecordingKind? {
        switch self {
        case .voiceNote: return nil
        case .kind(let k): return k
        case .thought: return .idea
        }
    }

    /// The custom symbol exported from the kind's BrandArt glyph (mac/tools/gen_symbol.py), for menus the system draws.
    var symbolName: String {
        switch self {
        case .voiceNote: return "rec.voice"
        case .kind(.meeting): return "rec.meeting"
        case .kind(.interview): return "rec.interview"
        case .kind(.journal): return "rec.journal"
        case .kind(.talk): return "rec.talk"
        case .kind(.brainDump): return "rec.braindump"
        case .kind(.audio): return "rec.audio"
        case .kind: return "rec.voice"
        case .thought: return "thought"
        }
    }

    /// The SF Symbol in the Native look.
    var nativeSymbol: String {
        switch self {
        case .voiceNote: return "mic"
        case .kind(.meeting): return "person.2"
        case .kind(.interview): return "quote.bubble"
        case .kind(.journal): return "book"
        case .kind(.talk): return "person.wave.2"
        case .kind(.brainDump): return "brain.head.profile"
        case .kind(.audio): return "waveform"
        case .kind: return "mic"
        case .thought: return "lightbulb"
        }
    }

    /// The template Run automatically runs for this choice when the recording finishes, if one is assigned and still
    /// exists. Voice note's kind isn't known yet; a thought never runs one from here (Thoughts are short).
    func template(settings: AutoRunSettings, templates: [TranscriptTemplate]) -> TranscriptTemplate? {
        guard case .kind(let k) = self, k != .audio, let id = settings.template(for: k) else { return nil }
        return templates.first { $0.id == id }
    }

    /// What a kind does with Run automatically off for it. Only what the app really does: the Library files it under
    /// its kind, Journal entries fill Journal by day, and Main speaker only never folds a voice away in a meeting,
    /// interview, or talk (`Transcript.hasBackgroundVoices`).
    var fallbackHint: String {
        switch self {
        case .voiceNote: return "Plain Record. Verbose picks the kind."
        case .kind(.meeting): return "Filed under Meetings, every voice kept"
        case .kind(.interview): return "Filed under Interviews, every voice kept"
        case .kind(.journal): return "Filed under Journal by day"
        case .kind(.talk): return "Filed under Talks, every voice kept"
        case .kind(.brainDump): return "Filed under Brain dumps"
        case .kind(.audio): return RecordChoice.audioOnlyLine
        case .kind(let k): return "Filed as \(AutoRunRules.article(k)) \(k.label)"
        case .thought: return "Adds to today\u{2019}s page"
        }
    }

    /// The line under the row: "Runs Meeting notes when it finishes" when Run automatically has a template for the
    /// kind, otherwise what the kind does.
    func hint(settings: AutoRunSettings, templates: [TranscriptTemplate]) -> String {
        // Audio only never names a template: none can run on it.
        if case .kind(.audio) = self { return Self.audioOnlyLine }
        if let t = template(settings: settings, templates: templates) { return "Runs \(t.name) when it finishes" }
        return fallbackHint
    }

    /// Audio only's line, everywhere it's described.
    static let audioOnlyLine = "Keeps the sound, no transcript"

    /// Audio only: Stop saves the sound and nothing is transcribed.
    var isAudioOnly: Bool { if case .kind(.audio) = self { return true }; return false }

    /// The line under the recorder's timer: the template that will run, or what happens without one.
    func recorderLine(settings: AutoRunSettings, templates: [TranscriptTemplate]) -> String {
        if case .voiceNote = self { return "Verbose picks the kind after it listens" }
        return hint(settings: settings, templates: templates)
    }
}

/// The Record as tray's gesture (iPhone), pure so the Linux tests and the self-test check it: touch and hold 0.4 s to
/// open; moving more than 10 pt first cancels (the scroll view takes it); lifting sooner is a plain Record. With the
/// tray open, sliding more than 10 pt and lifting on a row starts it; lifting without sliding keeps the tray open for a
/// tap. A swipe down past a third of the tray's height, or a fast flick, closes it.
enum RecordTrayRules {
    static let hold: Double = 0.4
    static let cancelDistance: Double = 10
    static let slideDistance: Double = 10
    /// A flick: the drag's predicted end lands this far past where it was let go.
    static let flickDistance: Double = 180
    /// The tray never grows past this share of the screen; its rows scroll instead.
    static let maxHeightShare: Double = 0.8

    enum Lift: Equatable {
        /// Lifted before the hold: the plain Record.
        case plainRecord
        /// Lifted on a row after sliding: start that choice.
        case start(RecordChoice)
        /// Lifted without sliding, or between rows: the tray stays open for a tap.
        case keepOpen
    }

    /// What lifting the finger does.
    static func lift(opened: Bool, slid: Bool, over row: RecordChoice?) -> Lift {
        guard opened else { return .plainRecord }
        guard slid, let row else { return .keepOpen }
        return .start(row)
    }

    /// A lift from Record without moving is a tap (the plain Record) only when the press never reached the hold and
    /// no tray is up. Taps and the hold are recognized side by side, so a lift after the hold reaches here too.
    static func isTap(held: Bool, trayOpen: Bool) -> Bool { !held && !trayOpen }

    /// The finger has moved far enough from where the tray opened to count as sliding.
    static func slid(dx: Double, dy: Double) -> Bool { (dx * dx + dy * dy).squareRoot() > slideDistance }

    /// The row under the finger: the first whose frame (minY, maxY, in the same space as `y`) holds it, inside the
    /// list's visible band when the rows scroll.
    static func row(atY y: Double, x: Double, rows: [(RecordChoice, minX: Double, minY: Double, maxX: Double, maxY: Double)],
                    visibleMinY: Double = -.infinity, visibleMaxY: Double = .infinity) -> RecordChoice? {
        guard y >= visibleMinY, y <= visibleMaxY else { return nil }
        return rows.first { x >= $0.minX && x <= $0.maxX && y >= $0.minY && y < $0.maxY }?.0
    }

    /// A swipe down closes the tray past a third of its height, or on a flick; a shorter drag springs back.
    static func dismisses(translation: Double, predicted: Double, height: Double) -> Bool {
        guard translation > 0 else { return false }
        return translation > height / 3 || predicted - translation > flickDistance
    }
}

extension Transcript {
    /// A recording started with a picked kind ("Record a meeting"): the kind is yours, so AutoLabel never replaces it,
    /// and it decides which template runs automatically.
    mutating func pickKindAtStart(_ kind: RecordingKind?) {
        guard let kind else { return }
        self.kind = kind
        kindIsAuto = false
    }

    /// AutoLabel's guess may fill in a kind only while there's none and nobody picked one.
    var wantsSuggestedKind: Bool { kind == nil && kindIsAuto }

    /// Applies AutoLabel's guess, never over a kind you picked (at the start of a recording or afterward).
    mutating func applySuggestedKind(_ k: RecordingKind) {
        if wantsSuggestedKind { kind = k }
    }
}
