import Foundation
import EventKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Send to Reminders (approved mockup "Verbose Brain Dump", sections 7 and 9, October 27, 2026), shared by the iPhone and
// the Mac. EventKit with full access to reminders (iOS 17 and macOS 14 have no add-only access for reminders; the
// usage strings are NSRemindersFullAccessUsageDescription and NSRemindersUsageDescription in project.yml), asked the
// first time you add. Due dates are date components with no time (all day), only where you said a day; each reminder's
// identifier is kept with the plan, so a second send adds only what's new. The default list is Reminders' own default
// the first time, then the last list you picked on that device (decision 5).
//
// `RemindersBridge.service` is a protocol so the self-tests use `MockReminders` and never touch your Reminders.

/// A Reminders list.
struct ReminderList: Identifiable, Hashable {
    var id: String
    var title: String
}

enum RemindersAccess: Equatable { case notAsked, granted, denied }

protocol ReminderService: AnyObject {
    var access: RemindersAccess { get }
    func requestAccess() async -> Bool
    func lists() -> [ReminderList]
    /// Reminders' own default list for new reminders.
    func defaultListID() -> String?
    /// Adds the reminders to the list; returns each draft's key with its reminder's identifier.
    func add(_ drafts: [DayPlan.ReminderDraft], to list: String) throws -> [String: String]
}

enum RemindersBridge {
    /// What adds the reminders: EventKit, or the self-tests' stand-in.
    @MainActor static var service: ReminderService = EventKitReminders()

    /// The last list picked on this device (never synced).
    static let lastListKey = "reminders.lastList"

    /// The list the sheet starts on: the last one picked here while it still exists, else Reminders' default, else the
    /// first. Pure, so the self-tests check it.
    static func startingList(_ lists: [ReminderList], last: String?, defaultID: String?) -> ReminderList? {
        if let last, let l = lists.first(where: { $0.id == last }) { return l }
        if let d = defaultID, let l = lists.first(where: { $0.id == d }) { return l }
        return lists.first
    }

    static func rememberList(_ id: String, defaults: UserDefaults = .standard) { defaults.set(id, forKey: lastListKey) }
    static func lastList(defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: lastListKey) }

    /// "Verbose can't add to Reminders. Turn on access in Settings › Privacy & Security › Reminders."
    #if os(iOS)
    static let deniedText = "Verbose can\u{2019}t add to Reminders. Turn on access in Settings \u{203A} Privacy & Security \u{203A} Reminders."
    #else
    static let deniedText = "Verbose can\u{2019}t add to Reminders. Turn on access in System Settings \u{203A} Privacy & Security \u{203A} Reminders."
    #endif

    /// Opens the Reminders app.
    @MainActor static func openReminders() {
        #if os(iOS)
        if let u = URL(string: "x-apple-reminderkit://") { UIApplication.shared.open(u) }
        #else
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
        #endif
    }

    /// Opens Verbose's privacy settings for Reminders.
    @MainActor static func openSettings() {
        #if os(iOS)
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        #else
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(u) }
        #endif
    }
}

/// EventKit's reminders.
final class EventKitReminders: ReminderService {
    private let store = EKEventStore()

    var access: RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notAsked
        case .denied, .restricted, .writeOnly: return .denied
        default: return .granted
        }
    }

    func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToReminders() } catch {
            Log.note("reminders: access request failed: \(error.localizedDescription)")
            return false
        }
    }

    func lists() -> [ReminderList] {
        guard access == .granted else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func defaultListID() -> String? { access == .granted ? store.defaultCalendarForNewReminders()?.calendarIdentifier : nil }

    func add(_ drafts: [DayPlan.ReminderDraft], to list: String) throws -> [String: String] {
        guard let cal = store.calendar(withIdentifier: list) ?? store.defaultCalendarForNewReminders() else {
            throw NSError(domain: "Verbose", code: 41, userInfo: [NSLocalizedDescriptionKey: "That Reminders list isn\u{2019}t there anymore."])
        }
        var made: [(String, EKReminder)] = []
        for d in drafts {
            let r = EKReminder(eventStore: store)
            r.title = d.title
            r.notes = d.notes
            r.calendar = cal
            if var due = d.due {
                // A date with no time: an all-day due date.
                due.calendar = Calendar.current
                due.timeZone = nil
                r.dueDateComponents = due
            }
            try store.save(r, commit: false)
            made.append((d.key, r))
        }
        try store.commit()
        var out: [String: String] = [:]
        for (k, r) in made { out[k] = r.calendarItemIdentifier }
        return out
    }
}

/// The self-tests' Reminders: lists you set, and every reminder "added", never EventKit.
final class MockReminders: ReminderService {
    var access: RemindersAccess = .granted
    var grantOnRequest = true
    var stored: [ReminderList] = [ReminderList(id: "studio", title: "Studio"), ReminderList(id: "home", title: "Home")]
    var defaultID: String? = "home"
    private(set) var added: [(draft: DayPlan.ReminderDraft, list: String)] = []

    func requestAccess() async -> Bool { access = grantOnRequest ? .granted : .denied; return grantOnRequest }
    func lists() -> [ReminderList] { access == .granted ? stored : [] }
    func defaultListID() -> String? { access == .granted ? defaultID : nil }
    func add(_ drafts: [DayPlan.ReminderDraft], to list: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for d in drafts { added.append((d, list)); out[d.key] = "mock-\(added.count)" }
        return out
    }
}

/// The Send to Reminders sheet's state (iPhone and Mac): the list, what's checked, and the send.
@MainActor
final class SendToReminders: ObservableObject {
    let plan: DayPlan
    let recordedAt: Date
    /// "Brain dump", "Thoughts", or the recording's title, for each reminder's notes.
    let source: String
    let anchorLabel: (DayPlan.Item) -> String?
    @Published private(set) var sent: [String: String]
    @Published var selection: Set<String>
    @Published private(set) var lists: [ReminderList] = []
    @Published var list: ReminderList? = nil
    @Published private(set) var access: RemindersAccess
    @Published private(set) var sending = false
    @Published private(set) var problem: String? = nil

    init(plan: DayPlan, sent: [String: String], recordedAt: Date, source: String, anchorLabel: @escaping (DayPlan.Item) -> String?) {
        self.plan = plan; self.sent = sent; self.recordedAt = recordedAt; self.source = source; self.anchorLabel = anchorLabel
        selection = DayPlan.defaultSelection(plan, sent: sent)
        access = RemindersBridge.service.access
        loadLists()
    }

    var checkedCount: Int { (plan.tasks + plan.ideas).filter { selection.contains($0.key) && sent[$0.key] == nil }.count }
    /// "Add 9 to Reminders".
    var addTitle: String { checkedCount == 0 ? "Add to Reminders" : "Add \(checkedCount) to Reminders" }
    /// The list row's value before access is given: Reminders' own default.
    var listTitle: String { list?.title ?? "Reminders\u{2019} default list" }

    func isSent(_ item: DayPlan.Item) -> Bool { sent[item.key] != nil }
    func toggle(_ item: DayPlan.Item) {
        guard !isSent(item) else { return }
        if selection.contains(item.key) { selection.remove(item.key) } else { selection.insert(item.key) }
    }
    func dueLabel(_ item: DayPlan.Item) -> String {
        item.isIdea && !selection.contains(item.key) ? "No date" : DayPlan.dueLabel(DayPlan.due(item, recordedAt: recordedAt))
    }

    func loadLists() {
        let svc = RemindersBridge.service
        access = svc.access
        lists = svc.lists()
        list = RemindersBridge.startingList(lists, last: RemindersBridge.lastList(), defaultID: svc.defaultListID())
    }

    func pick(_ l: ReminderList) { list = l }

    /// Adds the checked items. Asks for access the first time. Returns what was added (key → identifier) and the line
    /// to show, or nil when nothing was added (`problem` says why).
    func send() async -> (added: [String: String], message: String, list: String)? {
        problem = nil
        let svc = RemindersBridge.service
        if svc.access == .notAsked {
            _ = await svc.requestAccess()
            loadLists()
        }
        access = svc.access
        guard access == .granted else { problem = RemindersBridge.deniedText; return nil }
        guard let target = list ?? RemindersBridge.startingList(svc.lists(), last: nil, defaultID: svc.defaultListID()) else {
            problem = "Reminders has no list to add to."; return nil
        }
        let drafts = DayPlan.drafts(plan, selected: selection, sent: sent, recordedAt: recordedAt, source: source, anchorLabel: anchorLabel)
        guard !drafts.isEmpty else { problem = "Check a task to add it."; return nil }
        sending = true
        defer { sending = false }
        do {
            let added = try svc.add(drafts, to: target.id)
            let already = (plan.tasks + plan.ideas).filter { sent[$0.key] != nil }.count
            sent.merge(added) { _, new in new }
            selection.subtract(added.keys)
            RemindersBridge.rememberList(target.id)
            return (added, DayPlan.sentMessage(added: added.count, already: already, list: target.title), target.title)
        } catch {
            problem = "Couldn\u{2019}t add to Reminders: \(error.localizedDescription)"
            return nil
        }
    }
}

/// Send to Reminders with the stand-in (`MockReminders`), for both self-tests: never touches your Reminders.
enum RemindersChecks {
    @MainActor static func run(_ check: (String, Bool) -> Void) async {
        let saved = RemindersBridge.service
        let savedList = RemindersBridge.lastList()
        defer {
            RemindersBridge.service = saved
            if let savedList { RemindersBridge.rememberList(savedList) } else { UserDefaults.standard.removeObject(forKey: RemindersBridge.lastListKey) }
        }
        UserDefaults.standard.removeObject(forKey: RemindersBridge.lastListKey)
        let mock = MockReminders()
        mock.access = .notAsked
        RemindersBridge.service = mock
        let recorded = Calendar.current.date(bySettingHour: 7, minute: 42, second: 0, of: Date()) ?? Date()
        let plan = DayPlan.parse(PlanChecks.samplePlan)
        let model = SendToReminders(plan: plan, sent: [:], recordedAt: recorded, source: "Brain dump", anchorLabel: { $0.anchor.map(DayPlan.clock) })
        check("reminders: every task checked, ideas unchecked", model.checkedCount == 9 && model.addTitle == "Add 9 to Reminders")
        guard let first = await model.send() else { check("reminders: the first send asks for access, then adds", false); return }
        let notes = mock.added.map(\.draft.notes)
        check("reminders: the first send asks for access, then adds nine to Reminders' default list", mock.access == .granted && mock.added.count == 9
              && mock.added.allSatisfy { $0.list == "home" } && first.message == "Added 9 reminders to Home")
        check("reminders: due dates only where a day was said, with no time", mock.added.filter { $0.draft.due != nil }.count == 7
              && mock.added.allSatisfy { $0.draft.due?.hour == nil })
        check("reminders: each says where it came from", notes.first?.hasPrefix("From Verbose \u{00B7} Brain dump, ") == true && notes.first?.hasSuffix(", 0:04") == true)
        check("reminders: the list picked is remembered on this device", RemindersBridge.lastList() == "home")
        let again = SendToReminders(plan: plan, sent: first.added, recordedAt: recorded, source: "Brain dump", anchorLabel: { _ in nil })
        check("reminders: never twice; nothing is checked once all are sent", again.checkedCount == 0 && DayPlan.allSent(plan, sent: first.added))
        again.toggle(plan.ideas[0])
        let idea = await again.send()
        check("reminders: a checked idea goes in with no date, and the message counts what was there",
              idea?.added.count == 1 && mock.added.last?.draft.due == nil && idea?.message == "Added 1. 9 were already in Reminders.")
        check("reminders: the next sheet starts on the last list", RemindersBridge.startingList(mock.lists(), last: RemindersBridge.lastList(), defaultID: "studio")?.id == "home")
        mock.access = .notAsked; mock.grantOnRequest = false
        let denied = SendToReminders(plan: plan, sent: [:], recordedAt: recorded, source: "Brain dump", anchorLabel: { _ in nil })
        let none = await denied.send()
        check("reminders: without access, nothing is added and the sheet says how to turn it on", none == nil && denied.problem == RemindersBridge.deniedText)
    }
}
