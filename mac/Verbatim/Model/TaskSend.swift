import Foundation

// Send tasks (approved mockup "Verbose Send Tasks", October 31, 2026): where a plan's checked tasks go. Send to
// Reminders became Send tasks, with one sheet that picks the app:
// - Reminders, built in (RemindersBridge.swift), which remembers what it sent.
// - Things, every checked task in one `things:///json` link (Things' documented URL scheme; adding needs no token).
//   Each lands in the Inbox, with When set to Today for a task due today and a deadline when you said a day.
// - OmniFocus, every checked task as TaskPaper in one `omnifocus:///paste` link, into the Inbox, with due dates.
// - Another app: a checklist through the share sheet (Todoist, TickTick, Notes, Drafts, and others read it with their
//   share extensions). Their own links add one task at a time, so the share sheet is the way to send several.
// Things and OmniFocus are offered only when they're installed. Verbose can't confirm the other app saved anything, so
// only Reminders marks tasks as sent. Plain Foundation, so tools/test-templates.sh checks it on Linux.

/// Where Send tasks sends.
enum TaskDestination: String, CaseIterable, Identifiable, Sendable {
    case reminders, things, omnifocus, share

    var id: String { rawValue }

    /// The To menu's name.
    var title: String {
        switch self {
        case .reminders: return "Reminders"
        case .things: return "Things"
        case .omnifocus: return "OmniFocus"
        case .share: return "Another app\u{2026}"
        }
    }

    /// The To menu's second line, where it helps.
    var subtitle: String? { self == .share ? "Todoist, TickTick, Notes, and more" : nil }

    /// The scheme that shows the app is installed (`canOpenURL` on iPhone, LSApplicationQueriesSchemes in
    /// project.yml). Nil: always offered.
    var scheme: String? {
        switch self {
        case .things: return "things"
        case .omnifocus: return "omnifocus"
        case .reminders, .share: return nil
        }
    }

    /// The last place you sent to (UserDefaults), so the plan's button can name it.
    static let lastKey = "plan.sendTo"

    /// The plan's button: "Send to Things" after a send there while it's still offered; otherwise "Send tasks". Another
    /// app keeps "Send tasks", since it isn't one app.
    static func buttonTitle(last: TaskDestination?, offered: [TaskDestination]) -> String {
        guard let last, last != .share, offered.contains(last) else { return "Send tasks" }
        return "Send to \(last.title)"
    }

    /// The menu's choices, in order, given which apps are installed.
    static func offered(installed: (TaskDestination) -> Bool) -> [TaskDestination] {
        allCases.filter { $0.scheme == nil || installed($0) }
    }

    /// Where the sheet starts: the last place you sent to while it's still offered, otherwise Reminders.
    static func starting(last: TaskDestination?, offered: [TaskDestination]) -> TaskDestination {
        if let last, offered.contains(last) { return last }
        return .reminders
    }

    /// The sheet's confirm button: "Add 4 to Reminders", "Add 4 to Things", "Share 4".
    func actionTitle(count: Int) -> String {
        switch self {
        case .reminders: return count == 0 ? "Add to Reminders" : "Add \(count) to Reminders"
        case .things, .omnifocus: return count == 0 ? "Add to \(title)" : "Add \(count) to \(title)"
        case .share: return count == 0 ? "Share" : "Share \(count)"
        }
    }

    /// The sheet's footer line.
    var footer: String {
        switch self {
        case .reminders: return "A task gets a due date only when you said a day."
        case .things: return "Things opens and adds them to your Inbox, with Today for a task due today and a deadline when you said a day. Each one notes the recording it came from."
        case .omnifocus: return "OmniFocus opens and adds them to your Inbox, with a due date when you said a day."
        case .share: return "Opens the share sheet with the checked tasks as a checklist, one per line, for apps like Todoist and TickTick."
        }
    }

    /// The line after a send to Things or OmniFocus: "Sent 4 tasks to Things".
    func sentMessage(count: Int) -> String {
        "Sent \(count == 1 ? "1 task" : "\(count) tasks") to \(title)"
    }
}

/// The links and the checklist Send tasks hands to other apps, from the same drafts Reminders gets
/// (`DayPlan.drafts`).
enum TaskSend {
    /// Only letters, digits, and `-._~` stay as they are in a link's value; everything else is percent-encoded, so `&`,
    /// `=`, `+`, and `#` in a task can't break the link.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// "2026-11-05", from a draft's all-day due date.
    static func day(_ c: DateComponents?) -> String? {
        guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// The Things JSON: one to-do per draft, with its notes, Today when it's due today, and a deadline when it has a
    /// date.
    static func thingsItems(_ drafts: [DayPlan.ReminderDraft], today: Date, calendar: Calendar = .current) -> [[String: Any]] {
        let todayString = day(calendar.dateComponents([.year, .month, .day], from: today))
        return drafts.map { d in
            var attributes: [String: Any] = ["title": d.title, "notes": d.notes]
            if let due = day(d.due) {
                attributes["deadline"] = due
                if due == todayString { attributes["when"] = "today" }
            }
            return ["type": "to-do", "attributes": attributes]
        }
    }

    /// `things:///json?data=…&reveal=true`, or nil with nothing to send.
    static func thingsURL(_ drafts: [DayPlan.ReminderDraft], today: Date, calendar: Calendar = .current) -> URL? {
        guard !drafts.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: thingsItems(drafts, today: today, calendar: calendar), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: "things:///json?data=\(encode(json))&reveal=true")
    }

    /// The TaskPaper OmniFocus pastes: "- Send the invoice @due(2026-11-05)", with the notes on an indented line. A
    /// task's own "@" becomes " at ", so it isn't read as a tag.
    static func taskPaper(_ drafts: [DayPlan.ReminderDraft]) -> String {
        drafts.map { d in
            let title = d.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "@", with: " at ")
                .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            var line = "- \(title)"
            if let due = day(d.due) { line += " @due(\(due))" }
            if !d.notes.isEmpty { line += "\n\t\(d.notes.replacingOccurrences(of: "\n", with: " "))" }
            return line
        }.joined(separator: "\n")
    }

    /// `omnifocus:///paste?target=inbox&content=…`, or nil with nothing to send.
    static func omniFocusURL(_ drafts: [DayPlan.ReminderDraft]) -> URL? {
        guard !drafts.isEmpty else { return nil }
        return URL(string: "omnifocus:///paste?target=inbox&content=\(encode(taskPaper(drafts)))")
    }

    /// The share sheet's checklist: a title line, then "- [ ] Send the invoice (Today)" per task, with the day when
    /// it has one.
    static func checklist(_ drafts: [DayPlan.ReminderDraft], title: String, now: Date, calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        let lines = drafts.map { d -> String in
            let label = d.due.map { DayPlan.dueLabel($0, now: now, calendar: calendar, locale: locale) }
            return "- [ ] \(d.title)" + (label.map { " (\($0))" } ?? "")
        }
        return ([title] + lines).joined(separator: "\n")
    }

    /// The link for Things or OmniFocus; nil for Reminders and the share sheet.
    static func url(for destination: TaskDestination, drafts: [DayPlan.ReminderDraft], today: Date, calendar: Calendar = .current) -> URL? {
        switch destination {
        case .things: return thingsURL(drafts, today: today, calendar: calendar)
        case .omnifocus: return omniFocusURL(drafts)
        case .reminders, .share: return nil
        }
    }
}
