import Foundation

// Plan my day (approved mockup "Verbose Brain Dump", sections 5 to 9, October 27, 2026): the ninth Scenario template
// (Templates.swift), Brain dump's template from the start. Its result is drawn as a plan, not as plain sections: your
// top three first, then tasks under the day you said (Today, Tomorrow, This week, Someday), and ideas kept apart. Each
// task links back to the line it came from (a recording's moment, a thought, or a paragraph of the Mac's brain dump
// note), and Send to Reminders adds the tasks to a Reminders list with a due date only where you said a day.
//
// Relative days resolve from the recording's date, never the day you open it: "Tomorrow" in a brain dump recorded on
// Tuesday is Wednesday, whenever you read it.
//
// Pure Foundation, so mac/tools/test-templates.sh checks the parsing, the dates, and the reminders on Linux.

struct DayPlan: Equatable {
    enum Section: String, CaseIterable, Equatable {
        case top, today, tomorrow, week, someday, ideas

        /// The section's title, as the template names it.
        var title: String {
            switch self {
            case .top: return "Top three"
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            case .week: return "This week"
            case .someday: return "Someday"
            case .ideas: return "Ideas"
            }
        }

        /// Reads a heading the model wrote ("Top three", "Top 3", "Tomorrow, Wed, Oct 28", "Some day").
        static func from(heading h: String) -> Section? {
            let s = h.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("top") { return .top }
            if s.hasPrefix("today") { return .today }
            if s.hasPrefix("tomorrow") { return .tomorrow }
            if s.hasPrefix("this week") || s.hasPrefix("later this week") || s == "week" { return .week }
            if s.hasPrefix("someday") || s.hasPrefix("some day") || s.hasPrefix("later") || s.hasPrefix("no day") { return .someday }
            if s.hasPrefix("idea") { return .ideas }
            return nil
        }
    }

    /// One task or idea: its words, the line it came from (the [mm:ss] the model wrote, in seconds), and, under This
    /// week, the weekday it names (Calendar's 1 = Sunday … 7 = Saturday).
    struct Item: Equatable, Identifiable {
        var text: String
        var anchor: Double?
        var weekday: Int?
        var section: Section
        var id: String { key }
        var isIdea: Bool { section == .ideas }

        /// Matches a task across Run again and a second send: its words, folded, and its line.
        var key: String { DayPlan.key(text, anchor) }
    }

    var top: [Item] = []
    var today: [Item] = []
    var tomorrow: [Item] = []
    var week: [Item] = []
    var someday: [Item] = []
    var ideas: [Item] = []
    /// Top three wasn't named: these are today's first three in the order said, and the section says so.
    var topInferred = false

    /// "You didn't name three, so these are today's first three, in the order you said them."
    static let topInferredLine = "You didn\u{2019}t name three, so these are today\u{2019}s first three, in the order you said them."
    /// Someday's line (decision 6).
    static let somedayLine = "And anything you didn\u{2019}t give a day"
    /// A brain dump with no tasks.
    static let noTasksLine = "No tasks or ideas in what you said."

    func items(_ s: Section) -> [Item] {
        switch s {
        case .top: return top
        case .today: return today
        case .tomorrow: return tomorrow
        case .week: return week
        case .someday: return someday
        case .ideas: return ideas
        }
    }

    /// Every task, in the plan's order (Top three first); ideas aren't tasks.
    var tasks: [Item] { top + today + tomorrow + week + someday }
    var isEmpty: Bool { tasks.isEmpty && ideas.isEmpty }
    /// The sections with something in them, in order: empty sections don't show.
    var shownSections: [Section] { Section.allCases.filter { !items($0).isEmpty } }

    static func isPlan(_ r: TemplateResult) -> Bool { r.templateId == TemplateLibrary.planMyDayID }

    // MARK: Reading the result

    /// Reads Plan my day's result: "## Section" headings, then "- [ ] " tasks (or "- " bullets) each ending with its
    /// [mm:ss]. "None stated." lines are dropped; a paragraph under Top three is the model saying it chose them. When
    /// Top three is empty, today's first three move up and the section says so (decision 7).
    static func parse(_ text: String) -> DayPlan {
        var plan = DayPlan()
        var current: Section? = nil
        func add(_ raw: String) {
            guard let sec = current else { return }
            var item = item(raw, section: sec)
            guard !item.text.isEmpty, !isNoneStated(item.text) else { return }
            if sec != .week { item.weekday = nil }
            switch sec {
            case .top: plan.top.append(item)
            case .today: plan.today.append(item)
            case .tomorrow: plan.tomorrow.append(item)
            case .week: plan.week.append(item)
            case .someday: plan.someday.append(item)
            case .ideas: plan.ideas.append(item)
            }
        }
        for b in TemplateResultText.blocks(text) {
            switch b {
            case .heading(let h): current = Section.from(heading: h) ?? current
            case .check(let s, _): add(s)
            case .bullet(let s): add(s)
            case .paragraph(let p):
                // Under Top three, a sentence is the model saying it chose them; elsewhere only a line with a time is
                // an item it wrote without a dash.
                if current == .top, !looksLikeItem(p) { if !isNoneStated(p) { plan.topInferred = true } }
                else if current != nil, looksLikeItem(p) { add(p) }
            }
        }
        // A task the model listed twice (in Top three and again under its day) shows once, in Top three.
        let topKeys = Set(plan.top.map { fold($0.text) })
        plan.today.removeAll { topKeys.contains(fold($0.text)) }
        plan.tomorrow.removeAll { topKeys.contains(fold($0.text)) }
        plan.week.removeAll { topKeys.contains(fold($0.text)) }
        plan.someday.removeAll { topKeys.contains(fold($0.text)) }
        if plan.top.isEmpty, !plan.today.isEmpty {
            let n = min(3, plan.today.count)
            plan.top = plan.today.prefix(n).map { var x = $0; x.section = .top; return x }
            plan.today.removeFirst(n)
            plan.topInferred = true
        }
        if plan.top.count > 3 {
            // More than three named: the rest are still today's.
            let extra = plan.top.dropFirst(3).map { var x = $0; x.section = .today; return x }
            plan.top = Array(plan.top.prefix(3))
            plan.today = extra + plan.today
        }
        return plan
    }

    private static func isNoneStated(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t == "none stated" || t == "none" || t.isEmpty
    }

    /// A paragraph line under a task section that's really an item the model wrote without a dash (it has a time).
    private static func looksLikeItem(_ p: String) -> Bool { anchorRange(in: p) != nil }

    /// One line: the [mm:ss] (or [h:mm:ss]) comes off as its anchor, a trailing "(Friday)" off as its weekday, and
    /// "1. " numbering off the front.
    static func item(_ raw: String, section: Section) -> Item {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var anchor: Double? = nil
        while let r = anchorRange(in: text) {
            let inside = text[r].trimmingCharacters(in: CharacterSet(charactersIn: "[]() "))
            if anchor == nil { anchor = seconds(inside) }
            text.removeSubrange(r)
        }
        // "1. Send the invoice", "1) Send the invoice".
        if let m = text.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) { text.removeSubrange(m) }
        text = text.trimmingCharacters(in: .whitespaces)
        var weekday = Self.weekday(in: text)
        if let m = text.range(of: #"\s*\((mon|tues?|wed(nes)?|thu(rs)?|fri|sat(ur)?|sun)(day)?\.?\)$"#, options: [.regularExpression, .caseInsensitive]) {
            weekday = Self.weekday(in: String(text[m])) ?? weekday
            text.removeSubrange(m)
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "–—-:;,")))
        return Item(text: text, anchor: anchor, weekday: weekday, section: section)
    }

    /// "0:04", "1:06", "1:02:14": a line's time, as the plan shows it.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Where a time sits in a line: "[00:04]", "[1:02:14]", or "(00:04)".
    static func anchorRange(in s: String) -> Range<String.Index>? {
        s.range(of: #"\s*[\[(]\s*(\d{1,2}:)?\d{1,3}:\d{2}\s*[\])]"#, options: .regularExpression)
    }

    /// "00:04" → 4, "1:02:14" → 3734.
    static func seconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return Double(parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }

    /// The weekday a line names, as Calendar counts it (1 = Sunday), or nil.
    static func weekday(in s: String) -> Int? {
        let names: [(String, Int)] = [("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
                                      ("sun", 1), ("mon", 2), ("tues", 3), ("tue", 3), ("wed", 4), ("thurs", 5), ("thu", 5), ("fri", 6), ("sat", 7)]
        let words = s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        for w in words {
            let base = w.hasSuffix("s") && w.count > 4 && names.contains(where: { $0.0 == String(w.dropLast()) }) ? String(w.dropLast()) : w
            if let hit = names.first(where: { $0.0 == base }) { return hit.1 }
        }
        return nil
    }

    /// Words folded for matching: lowercase letters and digits, single spaces.
    static func fold(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func key(_ text: String, _ anchor: Double?) -> String {
        fold(text) + "|" + (anchor.map { String(Int($0.rounded())) } ?? "")
    }

    // MARK: Days

    /// The day a task is due, from the recording's date: Top three and Today on that day, Tomorrow the day after, a
    /// named day under This week on its next date (that day or later), and nothing for This week without a day,
    /// Someday, and ideas. A date with no time (all day).
    static func due(_ item: Item, recordedAt: Date, calendar: Calendar = .current) -> DateComponents? {
        let day = calendar.startOfDay(for: recordedAt)
        let date: Date?
        switch item.section {
        case .top, .today: date = day
        case .tomorrow: date = calendar.date(byAdding: .day, value: 1, to: day)
        case .week:
            if let w = item.weekday {
                let now = calendar.component(.weekday, from: day)
                date = calendar.date(byAdding: .day, value: (w - now + 7) % 7, to: day)
            } else { date = nil }
        case .someday, .ideas: date = nil
        }
        return date.map { calendar.dateComponents([.year, .month, .day], from: $0) }
    }

    /// "Today", "Wed, Oct 28", or "No date", for the Send to Reminders sheet.
    static func dueLabel(_ c: DateComponents?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let c, let d = calendar.date(from: c) else { return "No date" }
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        return shortDay(d, calendar: calendar, locale: locale)
    }

    /// "Wed, Oct 28".
    static func shortDay(_ d: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: d)
    }

    /// "Fri": a This week task's day, beside it.
    static func weekdayShort(_ w: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var cal = calendar; cal.locale = locale
        let names = cal.shortWeekdaySymbols
        return w >= 1 && w <= names.count ? names[w - 1] : ""
    }

    /// The Tomorrow section's date ("Wed, Oct 28"), from the recording's date.
    static func tomorrowLabel(recordedAt: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let d = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: recordedAt)) ?? recordedAt
        return shortDay(d, calendar: calendar, locale: locale)
    }

    // MARK: Send to Reminders

    struct ReminderDraft: Equatable {
        var key: String
        var title: String
        /// Year, month, and day only: an all-day due date. nil: no date.
        var due: DateComponents?
        var notes: String
    }

    /// What the sheet starts with checked: every task not sent yet; ideas unchecked (decision 8).
    static func defaultSelection(_ plan: DayPlan, sent: [String: String]) -> Set<String> {
        Set(plan.tasks.filter { sent[$0.key] == nil }.map(\.key))
    }

    /// The reminders to add for the checked items, in the plan's order, leaving out anything already sent. Each one's
    /// notes say where it came from: "From Verbose · Brain dump, Tue, Oct 27, 0:04".
    static func drafts(_ plan: DayPlan, selected: Set<String>, sent: [String: String], recordedAt: Date, source: String,
                       anchorLabel: (Item) -> String?, calendar: Calendar = .current, locale: Locale = .current) -> [ReminderDraft] {
        let day = shortDay(recordedAt, calendar: calendar, locale: locale)
        return (plan.tasks + plan.ideas).compactMap { item in
            guard selected.contains(item.key), sent[item.key] == nil else { return nil }
            var where_ = "From Verbose \u{00B7} \(source), \(day)"
            if let a = anchorLabel(item) { where_ += ", \(a)" }
            return ReminderDraft(key: item.key, title: item.text, due: due(item, recordedAt: recordedAt, calendar: calendar), notes: where_)
        }
    }

    /// "Added 9 to Studio", or "Added 2. 9 were already in Reminders." after a second send.
    static func sentMessage(added: Int, already: Int, list: String) -> String {
        let n = added == 1 ? "1 reminder" : "\(added) reminders"
        if already == 0 { return "Added \(n) to \(list)" }
        return "Added \(added). \(already == 1 ? "1 was" : "\(already) were") already in Reminders."
    }

    /// "9 in Reminders": how many of the plan's items were sent.
    static func sentStatus(_ plan: DayPlan, sent: [String: String]) -> String? {
        let n = (plan.tasks + plan.ideas).filter { sent[$0.key] != nil }.count
        return n == 0 ? nil : "\(n) in Reminders"
    }

    /// Every task is in Reminders: Send to Reminders reads "Sent to Reminders" and dims until there's something new.
    static func allSent(_ plan: DayPlan, sent: [String: String]) -> Bool {
        !plan.tasks.isEmpty && plan.tasks.allSatisfy { sent[$0.key] != nil }
    }

    // MARK: Input from thoughts and notes

    /// Today's thoughts (or a Mac note's paragraphs) as one transcript for Plan my day: one line a minute ("[00:00]",
    /// "[01:00]", …), so the [mm:ss] after a task names the thought or paragraph it came from (`index(of:)`).
    static func input(_ lines: [String], title: String, createdAt: Date) -> Transcript {
        var t = Transcript(title: title, source: .voiceMemo, sourceLabel: "Plan my day", duration: Double(max(lines.count, 1)) * 60, audioFileName: nil, model: "")
        t.createdAt = createdAt
        t.segments = lines.enumerated().map { i, line in Segment(start: Double(i) * 60, end: Double(i) * 60 + 59, text: line) }
        t.original = t.segments
        t.kind = .brainDump; t.kindIsAuto = false
        return t
    }

    /// The thought or paragraph a task's [mm:ss] names, by position in `input`'s lines.
    static func index(of item: Item, count: Int) -> Int? {
        guard let a = item.anchor else { return nil }
        let i = Int((a / 60).rounded(.down))
        return i >= 0 && i < count ? i : nil
    }

    /// A note's paragraphs: the blocks between blank lines, trimmed, empty ones left out.
    static func paragraphs(_ note: String) -> [String] {
        note.components(separatedBy: "\n").reduce(into: [[String]]([[]])) { acc, line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { if !(acc.last ?? []).isEmpty { acc.append([]) } }
            else { acc[acc.count - 1].append(line.trimmingCharacters(in: .whitespaces)) }
        }
        .map { $0.joined(separator: " ") }.filter { !$0.isEmpty }
    }
}

extension Transcript {
    /// Send to Reminders finished: the reminders it added go on the result (`TemplateResult.sent`) and, for Plan my
    /// day, beside the results (`remindersSent`), which older builds keep when they save the file.
    mutating func recordSentReminders(_ added: [String: String], result id: UUID) {
        guard !added.isEmpty, let i = templateResults?.firstIndex(where: { $0.id == id }) else { return }
        let had = templateResults?[i].sent ?? [:]
        templateResults?[i].sent = had.merging(added) { _, new in new }
        if templateResults?[i].templateId == TemplateLibrary.planMyDayID {
            let kept = remindersSent ?? [:]
            remindersSent = kept.merging(added) { _, new in new }
        }
    }
}

// MARK: - A plan kept with a day

/// A plan made from a day's thoughts (Organize today's thoughts) or from the Mac's brain dump note: kept with the day,
/// synced as `plans.json` like templates (SyncMerge). One per day and source, so two devices never make two: its ID is
/// made from the day and the source (`id(day:source:)`). Every field decodes with a default.
struct DayPlanRecord: Codable, Equatable, Identifiable, SyncEntry {
    enum Source: String, Codable, TolerantEnum {
        /// Organize today's thoughts.
        case thoughts
        /// The Mac's brain dump window.
        case note
        static var fallback: Source { .thoughts }
        init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    }

    var id: UUID
    /// The page's day, "2026-10-27".
    var day: String
    var source: Source
    /// Plan my day's result ("" until a plan is made).
    var text: String = ""
    var madeAt: Date? = nil
    /// "Mac" or "iPhone".
    var madeOn: String = ""
    /// The thoughts it was made from, in order: a task's [mm:ss] names one by position (`DayPlan.index`).
    var thoughtIDs: [UUID] = []
    /// The Mac's brain dump note.
    var note: String = ""
    /// The note's paragraphs when the plan was made: a task's [mm:ss] names one by position.
    var paragraphs: [String] = []
    /// Send to Reminders: each sent task's key and the reminder's identifier.
    var sent: [String: String] = [:]
    var updatedAt: Date? = nil

    init(day: String, source: Source) {
        self.id = Self.id(day: day, source: source); self.day = day; self.source = source
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case id, day, source, text, madeAt, madeOn, thoughtIDs, note, paragraphs, sent, updatedAt }
        let c = try d.container(keyedBy: K.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .thoughts
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? Self.id(day: day, source: source)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        madeAt = (try? c.decodeIfPresent(Date.self, forKey: .madeAt)) ?? nil
        madeOn = (try? c.decodeIfPresent(String.self, forKey: .madeOn)) ?? ""
        thoughtIDs = (try? c.decodeIfPresent([UUID].self, forKey: .thoughtIDs)) ?? []
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        paragraphs = (try? c.decodeIfPresent([String].self, forKey: .paragraphs)) ?? []
        sent = (try? c.decodeIfPresent([String: String].self, forKey: .sent)) ?? [:]
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil
    }

    /// "2026-10-27" for a page's day.
    static func dayKey(_ day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day back from its key, at the start of that day.
    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// One ID per day and source, the same on every device.
    static func id(day: String, source: Source) -> UUID {
        let digits = day.filter(\.isNumber)
        let n = Int(digits) ?? 0
        let s = source == .thoughts ? 1 : 2
        return UUID(uuidString: String(format: "DA7E0000-0000-4000-8%03d-%012d", s, n)) ?? UUID()
    }

    var plan: DayPlan { DayPlan.parse(text) }
    var hasPlan: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Thoughts added to the day since the plan was made ("2 new thoughts since 3:20 PM").
    func newThoughts(in page: [UUID]) -> Int { hasPlan ? page.filter { !thoughtIDs.contains($0) }.count : 0 }
}
