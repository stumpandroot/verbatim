import Foundation
#if canImport(Combine)
import Combine
#endif

// The iPhone's tab bar (Settings › Personalization and preferences › Tab bar): Home first and Settings last, and up to
// three tabs between them that you pick and order. The default is Library and Thoughts: Moments left the bar in the
// consolidation (October 28, 2026) and became the Library's Marked filter, so a stored Moments tab becomes Library, or
// Thoughts when Library is already there (`PhoneTabBar.replacingMoments`).
// Kept per device in the App Group, like the palette (`appearance.tabBar`); nothing syncs.
//
// Plain Foundation, so mac/tools/test-home-layout.sh runs it on Linux: the default, tolerant decoding, picking and
// ordering, where a removed tab's selection goes, and where a screen opens when its tab isn't in the bar.

/// A tab the iPhone's bar can show.
enum PhoneTab: String, CaseIterable, Hashable, Sendable {
    case home, library, thoughts, journal, dictations, projects, settings

    /// The Moments tab's stored value, from builds before the consolidation.
    static let retiredMoments = "moments"

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .thoughts: return "Thoughts"
        case .journal: return "Journal"
        case .dictations: return "Dictations"
        case .projects: return "Projects"
        case .settings: return "Settings"
        }
    }

    /// The picker's second line for a tab.
    var detail: String {
        switch self {
        case .home: return "Always first"
        case .library: return "Everything you've kept"
        case .thoughts: return "Today's page, and By day"
        case .journal: return "Your journal, by day"
        case .dictations: return "Everything you dictated"
        case .projects: return "Each project and what's in it"
        case .settings: return "Always last"
        }
    }

    /// The tabs you can pick for the middle of the bar, in the picker's order.
    static let pickable: [PhoneTab] = [.library, .thoughts, .journal, .dictations, .projects]

    /// The tabs the picker offers: Journal only once Journal entry is on in Record as or there's a journal entry
    /// (consolidation, October 28, 2026; `RecordAsRows.showsJournal`), or while it's already in the bar.
    static func offered(showJournal: Bool, in bar: [PhoneTab]) -> [PhoneTab] {
        pickable.filter { $0 != .journal || showJournal || bar.contains(.journal) }
    }
}

/// The bar: Home, the picked tabs in order, and Settings.
struct PhoneTabBar: Equatable, Sendable {
    /// How many tabs fit between Home and Settings.
    static let maxMiddle = 3
    /// The bar a new install starts with, and one that never picked its tabs (Library and Moments before the
    /// consolidation).
    static let defaultMiddle: [PhoneTab] = [.library, .thoughts]
    static let `default` = PhoneTabBar(middle: defaultMiddle)
    /// The App Group key (a list of raw values for the middle tabs).
    static let key = "appearance.tabBar"

    /// The picked tabs, in order: pickable ones only, each once, at most `maxMiddle`.
    private(set) var middle: [PhoneTab]

    init(middle: [PhoneTab]) { self.middle = Self.clean(middle) }

    /// Every tab in the bar, left to right.
    var tabs: [PhoneTab] { [.home] + middle + [.settings] }

    func contains(_ t: PhoneTab) -> Bool { tabs.contains(t) }

    /// A tab's place in the bar, left to right (nil when it isn't in the bar).
    func position(_ t: PhoneTab) -> Int? { tabs.firstIndex(of: t) }

    /// The tab to show after a change: the one selected while it's still in the bar, otherwise Home.
    func selection(keeping selected: PhoneTab) -> PhoneTab { contains(selected) ? selected : .home }

    /// Where a screen opens when it's asked for: its own tab when it's in the bar; otherwise pushed inside Library, or
    /// inside Home when Library isn't in the bar either.
    func host(for t: PhoneTab) -> PhoneTab {
        if contains(t) { return t }
        return contains(.library) ? .library : .home
    }

    // MARK: Editing (the picker)

    /// Picks or unpicks a tab: a picked tab comes off; an unpicked one goes on the end while there's room.
    static func toggle(_ t: PhoneTab, in picks: [PhoneTab]) -> [PhoneTab] {
        guard PhoneTab.pickable.contains(t) else { return picks }
        if let i = picks.firstIndex(of: t) { var p = picks; p.remove(at: i); return p }
        return picks.count < maxMiddle ? picks + [t] : picks
    }

    /// Moves picks the way `List.onMove` reports it.
    static func move(_ picks: [PhoneTab], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [PhoneTab] {
        var order = picks
        let moving = offsets.sorted().filter { $0 < order.count }.map { order[$0] }
        guard !moving.isEmpty else { return picks }
        let before = offsets.filter { $0 < destination }.count
        for i in offsets.sorted(by: >) where i < order.count { order.remove(at: i) }
        order.insert(contentsOf: moving, at: max(0, min(order.count, destination - before)))
        return order
    }

    // MARK: Storage

    /// Pickable tabs only, each once, at most `maxMiddle`, in the order given.
    static func clean(_ picks: [PhoneTab]) -> [PhoneTab] {
        var out: [PhoneTab] = []
        for t in picks where PhoneTab.pickable.contains(t) && !out.contains(t) && out.count < maxMiddle { out.append(t) }
        return out
    }

    /// What's stored: the middle tabs' raw values.
    var stored: [String] { middle.map(\.rawValue) }

    /// The bar from what was stored, ignoring what this build doesn't know. Nothing stored is the default bar; a stored
    /// empty list is a bar with only Home and Settings.
    static func decode(_ stored: Any?) -> PhoneTabBar {
        guard let raw = stored as? [String] else { return .default }
        return PhoneTabBar(middle: replacingMoments(raw).compactMap(PhoneTab.init(rawValue:)))
    }

    /// A stored bar with the retired Moments tab in its place replaced: by Library when the bar lacks it, else by
    /// Thoughts when the bar lacks that, else dropped.
    static func replacingMoments(_ raw: [String]) -> [String] {
        guard let i = raw.firstIndex(of: PhoneTab.retiredMoments) else { return raw }
        var out = raw
        if !raw.contains(PhoneTab.library.rawValue) { out[i] = PhoneTab.library.rawValue }
        else if !raw.contains(PhoneTab.thoughts.rawValue) { out[i] = PhoneTab.thoughts.rawValue }
        else { out.remove(at: i) }
        return out.filter { $0 != PhoneTab.retiredMoments }
    }
}

/// Where Record's tab bar accessory (iOS 26, RecordAccessory.swift) and the opaque bar before iOS 26 (`RecordBar`)
/// show. While a recording exists (running, paused, or saving), they carry the minimized recorder on every screen,
/// transcripts and Audio only included, so you can always get back to it. With nothing recording, Record steps aside
/// while you read a transcript or an Audio only recording, and on Home's own screen while its Record card is there.
enum RecordChromeRule {
    static func hidden(tab: PhoneTab, homeAtRoot: Bool, recordCardShown: Bool, readingTranscript: Bool,
                       recording: Bool) -> Bool {
        if recording { return false }
        if readingTranscript { return true }
        return tab == .home && homeAtRoot && recordCardShown
    }

    /// Whether a transcript or an Audio only recording hides the tab bar while you read. From iOS 26 the minimized
    /// recorder lives in the tab bar's accessory, which goes with the tab bar, so the tab bar stays while a recording
    /// exists. Before iOS 26 the opaque bar sits on the screen's content, so the tab bar can go.
    static func readingHidesTabBar(recording: Bool, systemAccessory: Bool) -> Bool {
        !(recording && systemAccessory)
    }
}

/// What a tap on Record in the tab bar's accessory starts: on Thoughts a thought and on Journal a journal entry, since
/// you're already there; a voice note on every other tab. Touch and hold still opens Record as everywhere.
enum TabRecordDefault: String, CaseIterable, Sendable {
    case voiceNote, thought, journal

    static func forTab(_ tab: PhoneTab) -> TabRecordDefault {
        switch tab {
        case .thoughts: return .thought
        case .journal: return .journal
        default: return .voiceNote
        }
    }

    /// The accessory's second line under "Record".
    var subtitle: String {
        switch self {
        case .voiceNote: return "Voice note"
        case .thought: return "Thought"
        case .journal: return "Journal entry"
        }
    }

    /// VoiceOver's hint for Record.
    var hint: String {
        "Starts a \(subtitle.lowercased()). Touch and hold for more ways to record, and for Dictate, Live captions, and Import."
    }
}

#if canImport(Combine)
/// This iPhone's bar, read once and written on each change. PhoneRoot builds its TabView from it.
@MainActor
final class PhoneTabBarStore: ObservableObject {
    static let shared: PhoneTabBarStore = {
        let defaults = UserDefaults(suiteName: "group.co.stumpandroot.verbatim.ios") ?? .standard
        // The self-test and the screenshot tour start from the default bar every run and never write the person's bar.
        let test = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1"
        return PhoneTabBarStore(defaults: defaults, persist: !test)
    }()

    private let defaults: UserDefaults
    private let persist: Bool
    @Published private(set) var bar: PhoneTabBar

    init(defaults: UserDefaults, persist: Bool) {
        self.defaults = defaults
        self.persist = persist
        bar = persist ? PhoneTabBar.decode(defaults.object(forKey: PhoneTabBar.key)) : .default
    }

    /// Saves a new middle (cleaned). Publishes only when something changed.
    func set(_ middle: [PhoneTab]) {
        let next = PhoneTabBar(middle: middle)
        guard next != bar else { return }
        bar = next
        if persist { defaults.set(next.stored, forKey: PhoneTabBar.key) }
    }

    func reset() { set(PhoneTabBar.defaultMiddle) }
}
#endif
