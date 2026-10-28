import Foundation
#if canImport(Combine)
import Combine
#endif

// Edit Home (mockup "premium", section 03): which sections Home shows, in what order, at what size, and which four
// shortcut tiles it offers. Each app keeps one layout per look, per device: the iPhone in the App Group (so widgets
// can read it), the Mac in its own defaults. Nothing syncs.
//
// The model is plain Foundation, so mac/tools/test-home-layout.sh runs it on Linux: each app's defaults (one Home in
// both looks since the refined look), the tolerant decoding (unknown sections and tiles are ignored, missing ones are added
// where they belong), the move rules the editor uses, and how the Mac pairs sections side by side.

/// Which app a layout is for. Some sections and tiles exist on one app only.
enum HomePlatform: String, Sendable {
    case mac, phone
    #if os(macOS)
    static let current = HomePlatform.mac
    #else
    static let current = HomePlatform.phone
    #endif
}

/// The look a layout belongs to (AppLook's raw values; each look keeps its own layout).
enum HomeLook: String, CaseIterable, Sendable {
    case verbose, native
}

/// Compact is one slim row or strip; Large is the full card.
enum HomeCardSize: String, CaseIterable, Sendable {
    case compact, large
    var title: String { self == .compact ? "Compact" : "Large" }
}

/// A section of Home. The header (greeting and date) and the What's new note aren't sections: they always lead.
///
/// The consolidation (October 28, 2026) took Home from eleven sections to these six. Queue (the sidebar's Queue row on
/// the Mac, the tab badge on iPhone), Projects (the sidebar and the Library), Moments (the Library's Marked filter),
/// Last dictation (Dictations and Recall), and the Mac Native's Stats (This week and You) left. A stored layout that
/// names them is read without them (`HomeLayout.from` skips what it doesn't know), so nothing else changes.
enum HomeSection: String, CaseIterable, Sendable {
    case record, tiles, week, recent, thoughts, journal

    /// The raw values of the sections that left, for the tests and for reading an older layout.
    static let retired: Set<String> = ["stats", "lastDictation", "projects", "moments", "queue"]

    var title: String {
        switch self {
        case .record: return "Record"
        case .tiles: return "Tiles"
        case .week: return "This week"
        case .recent: return "Recent recordings"
        case .thoughts: return "Today's thoughts"
        case .journal: return "Journal"
        }
    }

    /// The app this section is limited to, if any: every section is on both apps.
    var platformOnly: HomePlatform? { nil }

    func isAvailable(on platform: HomePlatform, look: HomeLook) -> Bool { true }

    /// Edit Home's second line for the section (the tiles row names its tiles instead).
    func detail(on platform: HomePlatform, look: HomeLook) -> String {
        switch self {
        // One Home in both looks (the refined look, DESIGN.md §13): the Record card, which turns into the recording.
        case .record: return platform == .mac ? "The Record card, and the recording while you record" : "The Record card"
        case .tiles: return "Four shortcuts"
        case .week: return "Words, time saved, and recordings"
        case .recent: return "Your latest recordings"
        case .thoughts: return "Today's last few thoughts, with New thought"
        case .journal: return "Your latest entry and this week's days"
        }
    }
}

/// A shortcut tile. Home shows exactly four, in the order picked. The consolidation (October 28, 2026) dropped Search
/// (⌘K, or the Library's field), Moments (the Library's Marked filter), Queue, and Paste a link (Import takes a link);
/// a stored pick of one is replaced from the defaults (`HomeLayout.from`).
enum HomeTile: String, CaseIterable, Sendable {
    case dictate
    case importMedia = "import"
    case whatsPlaying, appAudio, captions, thoughtPad, dictations, dictionary, projects
    case newThought, journal
    /// Brain dump (October 27, 2026): records one on iPhone, opens the Brain dump window on the Mac. Offered in Edit
    /// Home, never picked by default.
    case brainDump

    var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .importMedia: return "Import"
        case .whatsPlaying: return "What's playing"
        case .appAudio: return "App audio"
        case .captions: return "Live captions"
        case .thoughtPad: return "Today's page"
        case .dictations: return "Dictations"
        case .dictionary: return "Dictionary"
        case .projects: return "Projects"
        case .newThought: return "New thought"
        case .journal: return "Journal"
        case .brainDump: return "Brain dump"
        }
    }

    /// One line under the name, where a tile has room for it.
    var detail: String {
        switch self {
        case .dictate: return "Talk into any app"
        case .importMedia: return "A file or a link"
        case .whatsPlaying: return "Sound from any app"
        case .appAudio: return "Another app's sound"
        case .captions: return "Words as they're said"
        case .thoughtPad: return "Your thoughts, floating"
        case .dictations: return "Everything you dictated"
        case .dictionary: return "Words to spell your way"
        case .projects: return "Your projects"
        case .newThought: return "Record one now"
        case .journal: return "Your journal, by day"
        case .brainDump: return "Talk through your day"
        }
    }

    /// What's playing is the iPhone's (a broadcast of another app's sound); App audio and the floating Today's page are
    /// the Mac's. New thought and Journal are on both.
    var platformOnly: HomePlatform? {
        switch self {
        case .whatsPlaying: return .phone
        case .appAudio, .thoughtPad: return .mac
        default: return nil
        }
    }

    func isAvailable(on platform: HomePlatform) -> Bool { platformOnly.map { $0 == platform } ?? true }

    /// The picker's tiles for an app, in the picker's order.
    static func available(on platform: HomePlatform) -> [HomeTile] { allCases.filter { $0.isAvailable(on: platform) } }

    /// The capture mode's hue a tile wears in Verbose style, by what it does, never by its slot (DESIGN.md §1, review
    /// P-14): Dictate butter, Import sage, What's playing and App audio petal. Everything else (Live captions, New
    /// thought, Journal, the tools) is a card with an ink outline.
    var hue: HomeTileHue? {
        switch self {
        case .dictate: return .butter
        case .importMedia: return .sage
        case .whatsPlaying, .appAudio: return .petal
        default: return nil
        }
    }

    /// Each pick's hue, in slot order. At most three tiles are colored, so the row never outweighs Record; a fourth
    /// colored pick is a card.
    static func hues(_ picks: [HomeTile]) -> [HomeTileHue?] {
        var colored = 0
        return picks.map { t in
            guard let h = t.hue, colored < 3 else { return nil }
            colored += 1
            return h
        }
    }
}

/// A Home tile's capture-mode hue in Verbose style (`HomeTile.hue`).
enum HomeTileHue: Sendable { case butter, sage, petal }

/// A picked tile and its slot (0 to 3). Home's tiles are identified by the tile, so a new pick appears as a new tile.
struct HomeTileSlot: Hashable, Sendable {
    var slot: Int
    var tile: HomeTile
    static func slots(_ picks: [HomeTile], _ range: Range<Int>) -> [HomeTileSlot] {
        range.filter { $0 < picks.count }.map { HomeTileSlot(slot: $0, tile: picks[$0]) }
    }
}

/// One app's Home layout in one look.
struct HomeLayout: Equatable, Sendable {
    static let currentVersion = 1
    static let tileCount = 4

    struct Item: Equatable, Hashable, Sendable {
        var section: HomeSection
        var visible: Bool
        var size: HomeCardSize
    }

    /// Every section the app offers in this look, shown ones in Home's order; hidden ones keep a place too.
    var items: [Item]
    /// Exactly `tileCount` tiles, in order.
    var tiles: [HomeTile]

    // MARK: Defaults

    /// Home as a new install (or Reset) starts it: one Home in both looks since the refined look (DESIGN.md §13,
    /// October 28, 2026), as its mockup draws it. iPhone: the Record card, the four tiles, a slim This week, and Recent
    /// recordings. Mac: the Record card, the four tiles in a row, then Recent recordings beside This week. Today's
    /// thoughts and Journal start hidden. A layout a device already stored keeps its sections, order, and sizes; the
    /// look is still a key (each look keeps its own layout until the look switch goes).
    static func defaults(_ platform: HomePlatform, _ look: HomeLook) -> HomeLayout {
        func on(_ s: HomeSection, _ size: HomeCardSize) -> Item { Item(section: s, visible: true, size: size) }
        func off(_ s: HomeSection, _ size: HomeCardSize) -> Item { Item(section: s, visible: false, size: size) }
        let items: [Item]
        switch platform {
        case .phone:
            items = [on(.record, .large), on(.tiles, .large), on(.week, .compact), on(.recent, .large),
                     off(.thoughts, .large), off(.journal, .large)]
        case .mac:
            items = [on(.record, .large), on(.tiles, .large), on(.recent, .large), on(.week, .large),
                     off(.thoughts, .large), off(.journal, .large)]
        }
        return HomeLayout(items: items, tiles: defaultTiles(platform))
    }

    /// The four tiles a new install starts with (consolidation, October 28, 2026): Dictate, Import, What's playing (iPhone)
    /// or App audio (Mac), and New thought. Live captions left the four and stays in the catalog, the menus, and the
    /// shortcuts.
    static func defaultTiles(_ platform: HomePlatform) -> [HomeTile] {
        platform == .phone ? [.dictate, .importMedia, .whatsPlaying, .newThought] : [.dictate, .importMedia, .appAudio, .newThought]
    }

    /// The four every install had before, which an install from before keeps when it never picked its own.
    static func earlierTiles(_ platform: HomePlatform) -> [HomeTile] {
        platform == .phone ? [.dictate, .importMedia, .whatsPlaying, .captions] : [.dictate, .importMedia, .appAudio, .captions]
    }

    /// The settings Edit Home replaced, read once when a look has no stored layout yet.
    struct Legacy: Equatable, Sendable {
        /// Mac: Settings › General › Show This week on Home (`home.showWeek`).
        var showWeek: Bool? = nil
        /// iPhone, Native: Settings › Appearance › Show the Record card (`home.premium.recordCard`).
        var nativeRecordCard: Bool? = nil
        /// An install from before the consolidation (`Consolidation.wasExistingInstall`): it keeps the four tiles it had.
        var keepsEarlierTiles = false
    }

    /// The first layout for a look: the defaults, with the older settings carried over.
    static func initial(_ platform: HomePlatform, _ look: HomeLook, legacy: Legacy) -> HomeLayout {
        var l = defaults(platform, look)
        // In place: the Record card comes back where it used to sit, under This week.
        if legacy.showWeek == false { l.setVisible(.week, false, inPlace: true) }
        if platform == .phone, look == .native, legacy.nativeRecordCard == true { l.setVisible(.record, true, inPlace: true) }
        if legacy.keepsEarlierTiles { l.tiles = earlierTiles(platform) }
        return l
    }

    // MARK: Reading

    var shown: [Item] { items.filter(\.visible) }
    var hidden: [Item] { items.filter { !$0.visible } }
    func item(_ s: HomeSection) -> Item? { items.first { $0.section == s } }
    func isVisible(_ s: HomeSection) -> Bool { item(s)?.visible ?? false }
    func size(_ s: HomeSection) -> HomeCardSize { item(s)?.size ?? .large }

    // MARK: Editing

    /// Showing a section puts it at the end of Home; hiding one leaves it where it was, among the hidden. `inPlace`
    /// shows it where it sits in the list instead (a switch elsewhere, such as Settings › Appearance's Record card).
    mutating func setVisible(_ s: HomeSection, _ on: Bool, inPlace: Bool = false) {
        guard let i = items.firstIndex(where: { $0.section == s }), items[i].visible != on else { return }
        if inPlace { items[i].visible = on; return }
        var it = items.remove(at: i)
        it.visible = on
        if on {
            let lastShown = items.lastIndex(where: \.visible).map { $0 + 1 } ?? 0
            items.insert(it, at: lastShown)
        } else {
            items.insert(it, at: i)
        }
    }

    mutating func setSize(_ s: HomeSection, _ size: HomeCardSize) {
        guard let i = items.firstIndex(where: { $0.section == s }) else { return }
        items[i].size = size
    }

    /// Moves shown sections the way `List.onMove` reports it: `offsets` and `destination` index `shown`.
    mutating func moveShown(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var order = shown
        let moving = offsets.sorted().filter { $0 < order.count }.map { order[$0] }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        for i in offsets.sorted(by: >) where i < order.count { order.remove(at: i) }
        let at = max(0, min(order.count, destination - before))
        order.insert(contentsOf: moving, at: at)
        items = order + hidden
    }

    /// Moves a shown section to sit just before another (nil: to the end), for drags onto a section on the Mac.
    mutating func moveShown(_ s: HomeSection, before target: HomeSection?) {
        var order = shown
        guard let from = order.firstIndex(where: { $0.section == s }), s != target else { return }
        let it = order.remove(at: from)
        let at = target.flatMap { t in order.firstIndex { $0.section == t } } ?? order.count
        order.insert(it, at: at)
        items = order + hidden
    }

    /// Picks or unpicks a tile in a draft of picks: a picked tile comes off; an unpicked one goes on the end while
    /// there's room. The picker saves only four.
    static func toggle(_ tile: HomeTile, in picks: [HomeTile]) -> [HomeTile] {
        if let i = picks.firstIndex(of: tile) { var p = picks; p.remove(at: i); return p }
        return picks.count < tileCount ? picks + [tile] : picks
    }

    /// Moves a pick to another slot (dragging the numbered slots).
    static func move(_ tile: HomeTile, to slot: Int, in picks: [HomeTile]) -> [HomeTile] {
        guard let from = picks.firstIndex(of: tile) else { return picks }
        var p = picks
        p.remove(at: from)
        p.insert(tile, at: max(0, min(p.count, slot)))
        return p
    }

    // MARK: Cleaning up

    /// The layout with every rule applied: only sections the app and look offer, each once; any it lacks added after
    /// the section that comes before it in the defaults; exactly four tiles the app offers, each once.
    func normalized(_ platform: HomePlatform, _ look: HomeLook) -> HomeLayout {
        HomeLayout.from(Record(self), platform, look)
    }

    /// Builds a layout from what was stored, ignoring what this build doesn't know.
    static func from(_ record: Record, _ platform: HomePlatform, _ look: HomeLook) -> HomeLayout {
        let base = defaults(platform, look)
        var items: [Item] = []
        for raw in record.items ?? [] {
            guard let s = HomeSection(rawValue: raw.section), s.isAvailable(on: platform, look: look),
                  !items.contains(where: { $0.section == s }), let d = base.item(s) else { continue }
            items.append(Item(section: s, visible: raw.visible ?? d.visible, size: raw.size.flatMap(HomeCardSize.init(rawValue:)) ?? d.size))
        }
        // A section this layout lacks (new in this build) goes after its neighbor from the defaults, with the
        // defaults' visibility and size.
        for (i, d) in base.items.enumerated() where !items.contains(where: { $0.section == d.section }) {
            let after = base.items[..<i].reversed().lazy.compactMap { p in items.firstIndex { $0.section == p.section } }.first
            items.insert(d, at: after.map { $0 + 1 } ?? 0)
        }
        var tiles: [HomeTile] = []
        for raw in record.tiles ?? [] {
            guard let t = HomeTile(rawValue: raw), t.isAvailable(on: platform), !tiles.contains(t) else { continue }
            if tiles.count < tileCount { tiles.append(t) }
        }
        for t in base.tiles + HomeTile.available(on: platform) where tiles.count < tileCount && !tiles.contains(t) { tiles.append(t) }
        return HomeLayout(items: items, tiles: tiles)
    }

    // MARK: Storage

    /// The stored form: strings, so a newer or older build's sections and tiles decode without failing. Version 1 is
    /// the first; a record without one (or from a newer build) is read the same tolerant way.
    struct Record: Codable, Equatable, Sendable {
        struct RawItem: Codable, Equatable, Sendable {
            var section: String
            var visible: Bool?
            var size: String?
        }
        var version: Int?
        var items: [RawItem]?
        var tiles: [String]?

        init(version: Int? = HomeLayout.currentVersion, items: [RawItem]?, tiles: [String]?) {
            self.version = version; self.items = items; self.tiles = tiles
        }

        init(_ layout: HomeLayout) {
            self.init(items: layout.items.map { RawItem(section: $0.section.rawValue, visible: $0.visible, size: $0.size.rawValue) },
                      tiles: layout.tiles.map(\.rawValue))
        }
    }

    func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(Record(self))
    }

    /// Nil when the data isn't a layout at all (the caller starts from the defaults).
    static func decode(_ data: Data, _ platform: HomePlatform, _ look: HomeLook) -> HomeLayout? {
        guard let r = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return from(r, platform, look)
    }

    /// The defaults key for a look's layout.
    static func key(_ look: HomeLook) -> String { "home.layout.\(look.rawValue)" }
}

// MARK: - Today's thoughts and Journal

/// What Home's Today's thoughts section shows (both apps): Large lists the latest few of today's thoughts in the order
/// they started; Compact is one row with the count and the latest.
enum HomeThoughts {
    static let largeCount = 4

    /// The latest `count` of a page that's in time order, still in time order.
    static func latest<T>(_ page: [T], count: Int = largeCount) -> [T] { Array(page.suffix(max(0, count))) }

    /// "6 thoughts today", "1 thought today", or "No thoughts yet today".
    static func countLine(_ n: Int) -> String {
        n == 0 ? "No thoughts yet today" : n == 1 ? "1 thought today" : "\(n) thoughts today"
    }
}

/// This week's days on Home's Journal section: a dot for each, filled where a page has an entry.
enum HomeJournalWeek {
    struct Day: Equatable, Sendable {
        var start: Date
        var hasEntry: Bool
        var isToday: Bool
        var isFuture: Bool
    }

    /// The seven days of the week `today` is in (the calendar's first weekday first). `entryDays` are page days (the
    /// start of each day with an entry); `today` is today's page.
    static func days(entryDays: [Date], today: Date, calendar: Calendar = .current) -> [Day] {
        let todayStart = calendar.startOfDay(for: today)
        let start = calendar.dateInterval(of: .weekOfYear, for: todayStart)?.start ?? todayStart
        let have = Set(entryDays.map { calendar.startOfDay(for: $0) })
        return (0..<7).compactMap { i in
            guard let d = calendar.date(byAdding: .day, value: i, to: start) else { return nil }
            return Day(start: d, hasEntry: have.contains(d), isToday: d == todayStart, isFuture: d > todayStart)
        }
    }

    /// "3 days this week" (VoiceOver and the Compact line).
    static func countLine(_ days: [Day]) -> String {
        let n = days.filter(\.hasEntry).count
        return n == 1 ? "1 day this week" : "\(n) days this week"
    }
}

// MARK: - The Mac's grid

/// A band of the Mac's Home: one section across the grid, or two side by side (two thirds and one third).
struct HomeRow: Identifiable, Equatable, Sendable {
    var items: [HomeLayout.Item]
    var id: HomeSection { items[0].section }
}

enum HomeRows {
    /// Large sections that make sense beside another: Recent recordings, This week, Today's thoughts, and Journal. The
    /// Record card and the tiles always run across the column, and a Compact section is a strip across it.
    static func pairable(_ item: HomeLayout.Item) -> Bool {
        item.size == .large && item.section != .record && item.section != .tiles
    }

    /// Pairs neighbors that can share a band, left to right, when the window is wide enough; otherwise one per band.
    static func rows(_ shown: [HomeLayout.Item], wide: Bool) -> [HomeRow] {
        var out: [HomeRow] = []
        var i = 0
        while i < shown.count {
            if wide, i + 1 < shown.count, pairable(shown[i]), pairable(shown[i + 1]) {
                out.append(HomeRow(items: [shown[i], shown[i + 1]]))
                i += 2
            } else {
                out.append(HomeRow(items: [shown[i]]))
                i += 1
            }
        }
        return out
    }
}

// MARK: - The store

#if canImport(Combine)
extension AppLook {
    var homeLook: HomeLook { self == .native ? .native : .verbose }
}

/// Both looks' layouts for this device, read once and written on each change. Home and Edit Home observe it; a change
/// re-renders Home in place (sections keep their identity, nothing animates in).
@MainActor
final class HomeLayoutStore: ObservableObject {
    static let shared: HomeLayoutStore = {
        #if os(iOS)
        let defaults = UserDefaults(suiteName: "group.co.stumpandroot.verbatim.ios") ?? .standard
        #else
        let defaults = UserDefaults.standard
        #endif
        // The self-test and the screenshot tour start from the defaults every run and never write the person's layout.
        let test = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1"
        return HomeLayoutStore(platform: .current, defaults: defaults, legacy: .standard, persist: !test)
    }()

    let platform: HomePlatform
    private let defaults: UserDefaults
    private let persist: Bool
    @Published private(set) var verbose: HomeLayout
    @Published private(set) var native: HomeLayout

    init(platform: HomePlatform, defaults: UserDefaults, legacy: UserDefaults, persist: Bool) {
        self.platform = platform
        self.defaults = defaults
        self.persist = persist
        let old = HomeLayout.Legacy(showWeek: legacy.object(forKey: "home.showWeek") as? Bool,
                                    nativeRecordCard: legacy.object(forKey: "home.premium.recordCard") as? Bool,
                                    keepsEarlierTiles: Consolidation.wasExistingInstall(legacy))
        func load(_ look: HomeLook) -> HomeLayout {
            if persist, let data = defaults.data(forKey: HomeLayout.key(look)), let l = HomeLayout.decode(data, platform, look) { return l }
            guard persist else { return HomeLayout.defaults(platform, look) }
            // Saved at once, so the tiles an install starts with stay its tiles (the consolidation's new defaults
            // reach only installs that start from them).
            let first = HomeLayout.initial(platform, look, legacy: old)
            if let data = first.encoded() { defaults.set(data, forKey: HomeLayout.key(look)) }
            return first
        }
        verbose = load(.verbose)
        native = load(.native)
    }

    func layout(_ look: HomeLook) -> HomeLayout { look == .native ? native : verbose }

    /// Applies a change, cleans it up, and saves it. Publishes only when something changed.
    func update(_ look: HomeLook, _ change: (inout HomeLayout) -> Void) {
        var l = layout(look)
        change(&l)
        set(l.normalized(platform, look), for: look)
    }

    /// Back to the look's defaults (the older settings aren't read again).
    func reset(_ look: HomeLook) { set(HomeLayout.defaults(platform, look), for: look) }

    private func set(_ l: HomeLayout, for look: HomeLook) {
        guard l != layout(look) else { return }
        if look == .native { native = l } else { verbose = l }
        if persist, let data = l.encoded() { defaults.set(data, forKey: HomeLayout.key(look)) }
    }
}
#endif
