import Foundation
import AppKit
import EventKit

/// Calls from Calendar (November 3, 2026, mockup "Verbose Call Recording", boards 1, 4, 5, and 7): reads today's
/// calendar events on this Mac and keeps the ones with a Zoom, Meet, Teams, Webex, or FaceTime link (CallLinks), with
/// their titles, times, and attendee names, for Home's Next call card and the menu bar. Off until you turn it on: Home's
/// first-time card (Show my calls) or Settings › Meetings › Calls from Calendar asks for access then. macOS offers only
/// full access for reading events (NSCalendarsFullAccessUsageDescription in project.yml). Nothing is written to your
/// calendars, nothing is stored or synced, and nothing leaves the Mac; the log gets counts only. Nothing here records:
/// Record when it starts is a click (App/MeetingCoordinator.swift).
@MainActor
final class CallCalendar: ObservableObject {
    static let shared = CallCalendar()

    /// Settings › Meetings › Calls from Calendar. Off by default.
    static let enabledKey = "meetings.calendar"
    /// Home's first-time card was answered (Not now or Show my calls), so it doesn't come back.
    static let cardKey = "meetings.calendar.cardDone"
    /// Settings › Meetings › Calendars: the calendars left out (their identifiers), so a new calendar shows.
    static let hiddenKey = "meetings.calendar.hidden"

    enum Access: Equatable { case notAsked, granted, denied }

    struct CalendarInfo: Identifiable, Equatable {
        var id: String
        var title: String
    }

    /// Today's and tomorrow's calls, in start order.
    @Published private(set) var events: [CallEvent] = []
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var access: Access = .notAsked
    @Published private(set) var enabled: Bool
    @Published private(set) var cardDone: Bool
    @Published private(set) var hidden: Set<String>

    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Self.enabledKey)
        cardDone = d.bool(forKey: Self.cardKey)
        hidden = Set(d.stringArray(forKey: Self.hiddenKey) ?? [])
        access = Self.currentAccess()
    }

    /// Starts reading when it's on (at launch, from MeetingCoordinator.attach). The self-test never reads a calendar.
    func start() {
        guard !UITest.enabled, !Bench.isRequested else { return }
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    /// The call for Home's Next call card and the menu bar, now.
    func next(now: Date = Date()) -> CallEvent? { showing ? CallSchedule.next(events, now: now) : nil }

    /// The rest of today's calls after the one shown.
    func laterToday(now: Date = Date()) -> [CallEvent] {
        showing ? CallSchedule.laterToday(events, shown: next(now: now), now: now) : []
    }

    /// On, and allowed.
    var showing: Bool { enabled && access == .granted }

    /// Home's first-time card: never answered, never asked, and not on yet.
    var offersCard: Bool { !cardDone && !enabled && access == .notAsked && !UITest.enabled }

    // MARK: Turning it on and off

    /// Show my calls (Home) or the switch in Settings: asks for access the first time; on when it's allowed. Returns
    /// whether it's on.
    @discardableResult
    func turnOn() async -> Bool {
        markCardDone()
        if Self.currentAccess() == .notAsked {
            Log.note("calendar: asking for access to read events")
            do { _ = try await store.requestFullAccessToEvents() } catch {
                Log.note("calendar: access request failed: \(error.localizedDescription)")
            }
        }
        access = Self.currentAccess()
        setEnabled(access == .granted)
        Log.note("calendar: calls from Calendar \(enabled ? "on" : "not allowed")")
        return enabled
    }

    func turnOff() { setEnabled(false) }

    /// Not now on Home's first-time card. Settings › Meetings turns it on later.
    func markCardDone() {
        cardDone = true
        UserDefaults.standard.set(true, forKey: Self.cardKey)
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { events = []; timer?.invalidate(); timer = nil }
    }

    /// Settings › Meetings › Calendars: show or leave out one calendar.
    func setShown(_ id: String, _ shown: Bool) {
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        UserDefaults.standard.set(Array(hidden).sorted(), forKey: Self.hiddenKey)
        refresh()
    }

    /// "Work, Personal" for the Calendars row; "All calendars" when none is left out.
    var shownSummary: String {
        let shown = calendars.filter { !hidden.contains($0.id) }
        if shown.count == calendars.count { return "All calendars" }
        if shown.isEmpty { return "None" }
        return shown.map(\.title).joined(separator: ", ")
    }

    // MARK: Reading

    /// Reads today's and tomorrow's events again (the store changed, Verbose came forward, every 10 minutes while on).
    func refresh() {
        access = Self.currentAccess()
        guard enabled, access == .granted, !UITest.enabled else { if !events.isEmpty { events = [] }; return }
        let all = store.calendars(for: .event)
        calendars = all.map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let shown = all.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { if !events.isEmpty { events = [] }; return }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        guard let to = cal.date(byAdding: .day, value: 2, to: from) else { return }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: shown)
        let found = store.events(matching: predicate).compactMap(Self.call(from:)).sorted { $0.start < $1.start }
        if found != events { events = found }
        Log.note("calendar: \(found.count) call\(found.count == 1 ? "" : "s") with a link today and tomorrow")
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    /// An event with a call link, or nil (all-day events and events without one).
    private static func call(from e: EKEvent) -> CallEvent? {
        guard !e.isAllDay, let start = e.startDate, let end = e.endDate, end > start,
              let hit = CallLinks.find(in: [e.url?.absoluteString, e.location, e.notes]) else { return nil }
        let people = (e.attendees ?? []).filter { $0.participantType == .person || $0.participantType == .unknown }
        // A name from the email when the calendar gives none, and you left out by name too: a calendar that doesn't
        // mark you as the current user would make a one-on-one look like a group call (MeetingNames.others).
        let named = people.filter { !$0.isCurrentUser }.map { CallSchedule.displayName(name: $0.name, email: $0.url.absoluteString) }
        let names = MeetingNames.others(CallSchedule.attendeeNames(named), selfNames: MeetingNames.selfNames())
        let title = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CallEvent(id: "\(e.calendarItemIdentifier)|\(Int(start.timeIntervalSince1970))", title: title.isEmpty ? "Untitled call" : title,
                         start: start, end: end, service: hit.service, link: hit.link, attendees: names, people: people.count)
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notAsked
        case .fullAccess: return .granted
        default: return .denied
        }
    }
}
