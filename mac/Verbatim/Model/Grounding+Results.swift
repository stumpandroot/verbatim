import Foundation

// The AI output checks (Grounding.swift) for what Apple Intelligence writes in the apps: a transcript's summary, a
// template's result, Plan my day (in a recording, over a day's thoughts, or over the Mac's brain dump note), and Ask's
// answers. Each check runs when the result is shown, once per text (`GroundingMemo`), and the views put its note under
// the result (`GroundingNote`). Nothing is stored, so results made before the checks are checked too, and an edit the
// person makes is theirs: edited summaries and results aren't checked.
//
// Pure Foundation: mac/tools/test-grounding.sh runs these with the real Transcript, TemplateResult, DayPlan, and Ask
// types on Linux.

enum GroundingChecks {
    /// A recording as the model read it: its lines with their times. Speaker names, the title, and About me support
    /// names and days, never numbers.
    static func source(_ t: Transcript, aboutMe: String? = nil) -> GroundingSource {
        let lines = t.segments.map { GroundingLine(start: $0.start, end: $0.end, text: $0.text) }
        let known = t.speakers.map(\.label) + [t.title] + (aboutMe.map { [$0] } ?? [])
        return GroundingSource(lines: lines, known: known, duration: t.duration > 0 ? t.duration : nil)
    }

    /// Lines without times (a day's thoughts, a note's paragraphs): each spans a minute, as Plan my day numbers them
    /// (`DayPlan.input`).
    static func source(lines: [String], aboutMe: String? = nil) -> GroundingSource {
        var s = GroundingSource(lines: lines.enumerated().map { GroundingLine(start: Double($0.offset) * 60, end: Double($0.offset) * 60 + 59, text: $0.element) },
                                known: aboutMe.map { [$0] } ?? [])
        s.separateLines = true
        return s
    }

    // MARK: Summaries

    /// What a model-written summary says that the transcript doesn't. Nothing for a summary the person wrote or edited.
    static func summary(_ t: Transcript, aboutMe: String? = nil) -> [GroundingFinding] {
        guard let s = t.summary, t.summaryByModel, !s.isEmpty else { return [] }
        let text = s.plainText
        return GroundingMemo.shared.findings(key(1, text, t, aboutMe)) { Grounding.check(text, against: source(t, aboutMe: aboutMe)) }
    }

    static func summaryNote(_ t: Transcript, aboutMe: String? = nil) -> String? {
        GroundingNote.text(summary(t, aboutMe: aboutMe))
    }

    // MARK: Template results

    /// What a template's result says that the transcript doesn't. Plan my day's result is checked as a plan. Nothing
    /// for a result the person edited.
    static func result(_ r: TemplateResult, in t: Transcript, aboutMe: String? = nil) -> [GroundingFinding] {
        guard !r.edited, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let text = r.text
        let isPlan = DayPlan.isPlan(r)
        return GroundingMemo.shared.findings(key(isPlan ? 2 : 3, text, t, aboutMe)) {
            let src = source(t, aboutMe: aboutMe)
            if isPlan { return plan(text, source: src) }
            return Grounding.unique(Grounding.check(text, against: src) + priorities(checklist(text), words: listPriorityWords, source: src))
        }
    }

    static func resultNote(_ r: TemplateResult, in t: Transcript, aboutMe: String? = nil) -> String? {
        GroundingNote.text(result(r, in: t, aboutMe: aboutMe))
    }

    /// A result's task lines ("- [ ] …").
    static func checklist(_ text: String) -> [String] {
        TemplateResultText.blocks(text).compactMap { if case .check(let s, _) = $0 { return s } else { return nil } }
    }

    // MARK: Plans

    /// Plan my day over a day's thoughts or the Mac's brain dump note: `lines` are what it read, in order.
    static func dayPlan(_ text: String, lines: [String], aboutMe: String? = nil) -> [GroundingFinding] {
        guard !text.isEmpty, !lines.isEmpty else { return [] }
        var h = Hasher()
        h.combine(4); h.combine(text); h.combine(lines); h.combine(aboutMe)
        return GroundingMemo.shared.findings(h.finalize()) { plan(text, source: source(lines: lines, aboutMe: aboutMe)) }
    }

    /// `source` finishes the note's "aren't in …" for a day plan.
    static func dayPlanNote(_ text: String, lines: [String], fromNote: Bool, aboutMe: String? = nil) -> String? {
        GroundingNote.text(dayPlan(text, lines: lines, aboutMe: aboutMe), source: fromNote ? "your note" : "these thoughts")
    }

    /// A day's plan against what it read: the note's paragraphs, or the thoughts' words (`words`, by thought ID) in
    /// the order the plan numbered them.
    static func dayPlanNote(_ r: DayPlanRecord, words: (UUID) -> String?, aboutMe: String? = nil) -> String? {
        let lines = r.source == .note ? r.paragraphs : r.thoughtIDs.compactMap(words)
        return dayPlanNote(r.text, lines: lines, fromNote: r.source == .note, aboutMe: aboutMe)
    }

    /// A plan's checks: everything a result gets, then each task under Tomorrow or This week against the lines around
    /// its time (it needs a day said there), the Top three against the whole source (something must say what matters
    /// most), and "urgent" or "ASAP" on a task against the whole source.
    static func plan(_ text: String, source: GroundingSource) -> [GroundingFinding] {
        var found = Grounding.check(text, against: source)
        let p = DayPlan.parse(text)
        for item in p.tomorrow + p.week {
            let window = item.anchor.map { source.window(around: $0) } ?? []
            let words = Set(GroundingText.tokenize((window.isEmpty ? source.lines : window).map(\.text).joined(separator: " ")).map(\.norm))
            let supported = item.section == .tomorrow ? namesTomorrow(words) : namesThisWeek(words)
            if !supported { found.append(GroundingFinding(kind: .dayNotSaid, text: item.text)) }
        }
        if !p.top.isEmpty, !p.topInferred, !namesWhatMatters(source.lines.map(\.text).joined(separator: " ")) {
            found.append(GroundingFinding(kind: .topNotNamed, text: "Top three"))
        }
        found += priorities(p.tasks.map { $0.said ?? $0.text }, words: taskPriorityWords, source: source)
        return Grounding.unique(found)
    }

    /// Words that name a day for a task under Tomorrow: "tomorrow", "in the morning", a weekday, or a date.
    static func namesTomorrow(_ words: Set<String>) -> Bool {
        if !words.isDisjoint(with: ["tomorrow", "tomorrows", "morning"]) { return true }
        return namesADate(words)
    }

    /// Words that name a day for a task under This week: the week, the weekend, a few days, a weekday, or a date.
    static func namesThisWeek(_ words: Set<String>) -> Bool {
        if !words.isDisjoint(with: ["week", "weeks", "weekend", "weekends", "days", "tomorrow", "today", "tonight", "next"]) { return true }
        return namesADate(words)
    }

    private static func namesADate(_ words: Set<String>) -> Bool {
        words.contains { w in
            GroundingText.weekday(w, capitalized: false) != nil
                || (w != "may" && GroundingText.month(w, capitalized: true, nextIsNumber: false) != nil)
                || w.range(of: #"^\d+(st|nd|rd|th)$"#, options: .regularExpression) != nil
        }
    }

    /// Words that say what matters most: a Top three needs one of them somewhere in the source.
    static let priorityCues: Set<String> = [
        "important", "importantly", "importance", "priority", "priorities", "prioritize", "top", "most", "main", "biggest",
        "big", "key", "crucial", "critical", "urgent", "urgently", "asap", "first", "firstly", "must", "essential", "matters",
        "matter", "focus", "major", "primary",
    ]

    /// The source says what matters most: a cue word, or "three things", "3 tasks" (not "three hundred dollars").
    static func namesWhatMatters(_ text: String) -> Bool {
        let toks = GroundingText.tokenize(text).map(\.norm)
        if !Set(toks).isDisjoint(with: priorityCues) { return true }
        let after: Set<String> = ["things", "tasks", "items", "jobs", "priorities", "goals"]
        return zip(toks, toks.dropFirst()).contains { ($0 == "three" || $0 == "3") && after.contains($1) }
    }

    /// Priority words a plan's task can't add on its own.
    static let taskPriorityWords: Set<String> = ["urgent", "urgently", "asap", "priority", "important", "critical", "crucial"]
    /// For other templates' task lines, where "important" is too ordinary to check.
    static let listPriorityWords: Set<String> = ["urgent", "urgently", "asap", "priority", "critical"]

    static func priorities(_ lines: [String], words: Set<String>, source: GroundingSource) -> [GroundingFinding] {
        var out: [GroundingFinding] = []
        let saysASAP = source.lines.contains { $0.text.lowercased().contains("soon as possible") }
        for line in lines {
            for t in GroundingText.tokenize(line) where words.contains(t.norm) {
                if t.norm == "asap", saysASAP { continue }
                if !source.supportsName(t.norm) { out.append(GroundingFinding(kind: .priority, text: t.raw.lowercased() == "asap" ? "ASAP" : t.raw.lowercased())) }
            }
        }
        return out
    }

    // MARK: Ask

    /// What an answer says that its cited passages don't: numbers, names, quotes, and days against the passages (the
    /// question and the recordings' titles and dates support names and days), each sentence against its own
    /// passages, and each citation's time against its recording's length (`duration`, nil when unknown).
    static func answer(_ a: AskAnswer, question: String, duration: (UUID) -> Double? = { _ in nil }) -> [GroundingFinding] {
        var sentences: [Grounding.CitedSentence] = []
        for b in a.blocks {
            switch b {
            case .paragraph(let s), .bullet(let s): sentences += s.map { Grounding.CitedSentence(text: $0.text, cites: $0.cites) }
            case .heading: break
            }
        }
        let citations = a.citations.map { c in
            // The model read each passage under "Title, Tue, Oct 20, at 12:40" (AskPrompt.source).
            Grounding.Citation(number: c.number, text: "\(c.title), \(day.string(from: c.createdAt)), at \(AskFormat.time(c.start))\n\(c.text)",
                               start: c.start, recordingDuration: duration(c.transcriptId))
        }
        var h = Hasher()
        h.combine(5); h.combine(question); h.combine(a.plainText)
        for c in citations { h.combine(c.text); h.combine(c.recordingDuration) }
        return GroundingMemo.shared.findings(h.finalize()) {
            Grounding.checkAnswer(sentences, citations: citations, context: [question] + a.citations.map(\.title))
        }
    }

    static func answerNote(_ a: AskAnswer, question: String, duration: (UUID) -> Double? = { _ in nil }) -> String? {
        GroundingNote.text(answer(a, question: question, duration: duration), source: "the passages it cites")
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE, MMMM d, yyyy"; return f
    }()

    // MARK: Memo keys

    /// A key for one output against one recording: the output, the recording's lines, its speakers and title, and
    /// About me. Any change to the transcript checks again.
    private static func key(_ salt: Int, _ text: String, _ t: Transcript, _ aboutMe: String?) -> Int {
        var h = Hasher()
        h.combine(salt); h.combine(text); h.combine(t.id); h.combine(t.title); h.combine(t.duration); h.combine(aboutMe)
        for s in t.segments { h.combine(s.text); h.combine(s.start) }
        for s in t.speakers { h.combine(s.label) }
        return h.finalize()
    }
}
