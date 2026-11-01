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

    /// Whether Open Reminders shows. iPhone App Store builds leave it out: iOS has no documented way to open Reminders,
    /// and an undocumented scheme risks guideline 2.5.1 (App Review AR-14). The confirmation says where the tasks went.
    #if os(iOS) && APP_STORE
    static let canOpenReminders = false
    #else
    static let canOpenReminders = true
    #endif

    /// Opens the Reminders app.
    @MainActor static func openReminders() {
        #if os(iOS)
        #if !APP_STORE
        if let u = URL(string: "x-apple-reminderkit://") { UIApplication.shared.open(u) }
        #endif
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

    /// The recording the plan came from, for Verbose Tasks' link back to it. Nil for today's thoughts.
    var recordID: UUID? = nil
    var checkedCount: Int { (plan.tasks + plan.ideas).filter { selection.contains($0.key) && sent[$0.key] == nil }.count }
    /// The checked items as Verbose Tasks' transfer (TaskSend.swift), or nil with nothing checked.
    func handoffTransfer(id: UUID, now: Date = Date()) -> Data? {
        TaskSend.handoffTransfer(id: id, sentAt: now, tasks: TaskSend.handoffTasks(plan, selected: selection, sent: sent, recordedAt: recordedAt),
                                 recordID: recordID, capturedAt: recordedAt, sourceTitle: source)
    }
    /// The checked items as drafts, for Things, OmniFocus, and the share sheet (Send tasks, TaskSend.swift).
    var checkedDrafts: [DayPlan.ReminderDraft] {
        DayPlan.drafts(plan, selected: selection, sent: sent, recordedAt: recordedAt, source: source, anchorLabel: anchorLabel)
    }
    /// The share sheet's first line: "Plan from Brain dump, Tue, Nov 3".
    var checklistTitle: String { "Plan from \(source), \(DayPlan.shortDay(recordedAt))" }
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

/// Send tasks' other apps (TaskSend.swift): which are installed, where you sent last, and opening their links.
enum TaskApps {
    /// Installed: its scheme opens something. iPhone asks with `canOpenURL` (the schemes are in project.yml's
    /// LSApplicationQueriesSchemes); the Mac asks Launch Services. Reminders and the share sheet are always there.
    @MainActor static func isInstalled(_ d: TaskDestination) -> Bool {
        guard let s = d.scheme, let u = URL(string: s + "://") else { return true }
        #if os(iOS)
        // Verbose Tasks also needs the App Group both apps share; a build signed without it leaves it out.
        if d == .verboseTasks, !VerboseTasksHandoff.available { return false }
        return UIApplication.shared.canOpenURL(u)
        #else
        // Verbose Tasks on the Mac isn't released, and the Mac app doesn't share its App Group.
        if d == .verboseTasks { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: u) != nil
        #endif
    }

    /// The To menu's choices.
    @MainActor static var offered: [TaskDestination] { TaskDestination.offered(installed: isInstalled) }

    /// Where you sent last.
    static var last: TaskDestination? {
        get { UserDefaults.standard.string(forKey: TaskDestination.lastKey).flatMap(TaskDestination.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: TaskDestination.lastKey) }
    }

    /// The plan's button: "Send to Things" after a send there, otherwise "Send tasks".
    @MainActor static var buttonTitle: String { TaskDestination.buttonTitle(last: last, offered: offered) }

    /// Opens Things' or OmniFocus's link. False when nothing opened it.
    @MainActor static func open(_ url: URL) async -> Bool {
        #if os(iOS)
        return await UIApplication.shared.open(url)
        #else
        return NSWorkspace.shared.open(url)
        #endif
    }
}

#if os(iOS)
/// Send tasks to Verbose Tasks (TaskSend.swift): the transfer goes into the App Group both apps share
/// (`group.co.stumpandroot.handoff`, mac/project.yml) as `Transfers/<id>.json`, then Verbose Tasks opens and imports it
/// once. When you come back, Verbose reads `Receipts/<id>.json` and says what was saved; until then it says nothing,
/// since the tasks aren't saved until Verbose Tasks has read them.
enum VerboseTasksHandoff {
    static let groupID = "group.co.stumpandroot.handoff"
    /// Sends waiting for a receipt: transfer ID to when it was sent (seconds since 1970).
    static let pendingKey = "verboseTasks.pending"
    /// For the self-test: a folder in place of the App Group.
    nonisolated(unsafe) static var testRoot: URL? = nil

    static var root: URL? { testRoot ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    /// This build was signed with the App Group (a TestFlight build falls back to signing without it; build-swift.yml).
    static var available: Bool { root != nil }

    /// Writes the transfer where Verbose Tasks looks, last and in one step, and remembers it until its receipt.
    static func write(_ data: Data, id: UUID) -> Bool {
        guard let root else { return false }
        let dir = root.appendingPathComponent("Transfers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        } catch {
            Log.note("verbose tasks: couldn't write the transfer (\(error.localizedDescription))")
            return false
        }
        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Double] ?? [:]
        pending[id.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(pending, forKey: pendingKey)
        return true
    }

    /// Takes back a transfer Verbose Tasks couldn't be opened for: its file and its wait for a receipt.
    static func cancel(_ id: UUID) {
        if let root { try? FileManager.default.removeItem(at: root.appendingPathComponent("Transfers/\(id.uuidString).json")) }
        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Double] ?? [:]
        pending[id.uuidString] = nil
        UserDefaults.standard.set(pending, forKey: pendingKey)
    }

    /// Opens Verbose Tasks on Today, where it imports the transfer.
    static let openURL = URL(string: "verbosetasks://today")!

    /// The receipts that arrived since the last look, as the lines to show, oldest first. Each receipt is read once and
    /// removed with its transfer. A send with no receipt after a day is forgotten, and its transfer removed if Verbose
    /// Tasks never read it. A receipt nothing waits for (its send was forgotten) goes after a day too.
    static func takeReceipts(now: Date = Date()) -> [String] {
        guard let root else { return [] }
        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Double] ?? [:]
        let fm = FileManager.default
        let receipts = root.appendingPathComponent("Receipts", isDirectory: true)
        for f in (try? fm.contentsOfDirectory(at: receipts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.pathExtension == "json" && pending[f.deletingPathExtension().lastPathComponent] == nil {
            let made = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(made) > 86_400 { try? fm.removeItem(at: f) }
        }
        guard !pending.isEmpty else { return [] }
        var lines: [String] = []
        for (id, sent) in pending.sorted(by: { $0.value < $1.value }) {
            let receipt = root.appendingPathComponent("Receipts/\(id).json")
            if let data = try? Data(contentsOf: receipt) {
                if let line = TaskSend.handoffMessage(receipt: data) { lines.append(line) }
                try? fm.removeItem(at: receipt)
                try? fm.removeItem(at: root.appendingPathComponent("Transfers/\(id).json"))
                pending[id] = nil
            } else if now.timeIntervalSince1970 - sent > 86_400 {
                try? fm.removeItem(at: root.appendingPathComponent("Transfers/\(id).json"))
                pending[id] = nil
            }
        }
        UserDefaults.standard.set(pending, forKey: pendingKey)
        return lines
    }
}
#endif

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
        #if os(iOS)
        // Verbose Tasks, with a folder in place of the App Group: the transfer is written, nothing is said until its
        // receipt, then the receipt's line once.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-check-\(UUID().uuidString)", isDirectory: true)
        let savedRoot = VerboseTasksHandoff.testRoot
        let savedPending = UserDefaults.standard.dictionary(forKey: VerboseTasksHandoff.pendingKey)
        VerboseTasksHandoff.testRoot = root
        UserDefaults.standard.removeObject(forKey: VerboseTasksHandoff.pendingKey)
        defer {
            VerboseTasksHandoff.testRoot = savedRoot
            UserDefaults.standard.set(savedPending, forKey: VerboseTasksHandoff.pendingKey)
            try? FileManager.default.removeItem(at: root)
        }
        let vt = SendToReminders(plan: plan, sent: [:], recordedAt: recorded, source: "Brain dump", anchorLabel: { _ in nil })
        vt.recordID = UUID()
        let tid = UUID()
        let wrote = vt.handoffTransfer(id: tid).map { VerboseTasksHandoff.write($0, id: tid) } ?? false
        let file = root.appendingPathComponent("Transfers/\(tid.uuidString).json")
        check("verbose tasks: Send writes the transfer where Verbose Tasks reads it", wrote && FileManager.default.fileExists(atPath: file.path))
        check("verbose tasks: nothing is said before Verbose Tasks writes its receipt", VerboseTasksHandoff.takeReceipts().isEmpty)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Receipts"), withIntermediateDirectories: true)
        let receipt = try? JSONSerialization.data(withJSONObject: ["transferID": tid.uuidString, "status": "saved",
                                                                   "taskIDs": (0..<9).map { _ in UUID().uuidString }, "alreadyHad": 0, "savedAt": "2026-10-31T12:00:00Z"])
        try? receipt?.write(to: root.appendingPathComponent("Receipts/\(tid.uuidString).json"))
        check("verbose tasks: its receipt says what was saved, once", VerboseTasksHandoff.takeReceipts() == ["Saved 9 tasks to Verbose Tasks"]
              && VerboseTasksHandoff.takeReceipts().isEmpty)
        check("verbose tasks: a receipt takes its transfer with it", !FileManager.default.fileExists(atPath: file.path))
        let gone = UUID()
        let goneWrote = vt.handoffTransfer(id: gone).map { VerboseTasksHandoff.write($0, id: gone) } ?? false
        VerboseTasksHandoff.cancel(gone)
        check("verbose tasks: a send Verbose Tasks couldn't open for is taken back", goneWrote
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Transfers/\(gone.uuidString).json").path)
              && (UserDefaults.standard.dictionary(forKey: VerboseTasksHandoff.pendingKey) ?? [:]).isEmpty)
        let stray = root.appendingPathComponent("Receipts/\(UUID().uuidString).json")
        try? Data("{}".utf8).write(to: stray)
        _ = VerboseTasksHandoff.takeReceipts(now: Date().addingTimeInterval(2 * 86_400))
        check("verbose tasks: a receipt nothing waits for goes after a day", !FileManager.default.fileExists(atPath: stray.path))
        #endif
    }
}
