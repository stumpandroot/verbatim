import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Home, shared by the Mac (HomeView) and iPhone (HomeScreen) apps: the greeting and counts (pure, self-tested), This
// week's numbers and bars, the Recent rows' styles, the refined Home's tile colors and kinds (DESIGN.md §6, §13), the
// journal's week dots, and Edit Home's probe for the self-tests. Home's own drawing is the refined kit
// (RefinedKit.swift); its Record meter and the hover and touch listening retired with the old Home.
//
// Motion (DESIGN.md §7): springs never bounce. With Reduce Motion or Limit animation everything is still.

enum HomeMotion {
    /// The copied dictation row's label morph: a quick crossfade and slide.
    static let morph = Animation.easeOut(duration: 0.18)
}

// MARK: - Greeting

enum HomeGreeting {
    enum PartOfDay: String { case morning, afternoon, evening }

    /// Morning from 5:00 to 11:59, afternoon from 12:00 to 16:59, evening from 17:00 through the night.
    static func partOfDay(hour: Int) -> PartOfDay {
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        default: return .evening
        }
    }

    /// "Tim" from "Tim Medina"; nil for an empty name or the "You" placeholder.
    static func firstName(_ full: String) -> String? {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "You" else { return nil }
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    /// "Good afternoon, Tim." or "Good afternoon." without a name.
    static func line(name: String?, hour: Int) -> String {
        let part = partOfDay(hour: hour).rawValue
        if let name, !name.isEmpty { return "Good \(part), \(name)." }
        return "Good \(part)."
    }

    /// The date line above the greeting, sentence case: "Thursday, October 22".
    static func dateLine(_ date: Date) -> String {
        Formats.pattern("EEEE, MMMM d").string(from: date)
    }
}

// MARK: - Counts

/// One dictation's contribution to This week: when, how many words, and how long you spoke.
struct HomeWordEntry: Equatable {
    var date: Date
    var words: Int
    var seconds: Double
}

/// This week's dictation: total words, time saved against typing, and one bar per day of the calendar week.
struct HomeWeek: Equatable {
    struct Day: Equatable {
        var start: Date
        var words: Int
        var isToday: Bool
        var isFuture: Bool
    }
    var words = 0
    var seconds = 0.0
    var days: [Day] = []

    init(_ entries: [HomeWordEntry], now: Date = Date(), calendar: Calendar = .current) {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: Int] = [:]
        for e in entries where e.date >= week.start && e.date < week.end {
            words += e.words
            seconds += e.seconds
            byDay[calendar.startOfDay(for: e.date), default: 0] += e.words
        }
        var d = calendar.startOfDay(for: week.start)
        while d < week.end, days.count < 7 {
            days.append(Day(start: d, words: byDay[d] ?? 0, isToday: d == today, isFuture: d > today))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
    }

    /// Typing the same words at `wpm`, minus the time spent talking (the same rule as You).
    func secondsSaved(typingWPM wpm: Int) -> Double {
        max(0, Double(words) / Double(max(wpm, 1)) * 60 - seconds)
    }

    /// "42 s", "18 m", "1 h", "1 h 22 m".
    static func durationLabel(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m) m" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) m"
    }

    var peak: Int { days.map(\.words).max() ?? 0 }

    /// The time saved in This week's words (the refined look): "42 sec", "25 min", "1 hr", "2 hr 14 min".
    static func savedText(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded())) sec" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min"
    }

    /// The seven bars This week's card draws: each day's words as a share of the busiest day.
    var cardDays: [WeekCard.Day] {
        let top = Double(max(1, peak))
        return days.map { WeekCard.Day(share: Double($0.words) / top, isToday: $0.isToday, isFuture: $0.isFuture) }
    }
}

enum HomeCounts {
    /// Recordings, imports, and links made today (dictations count on their own).
    static func recordingsToday(_ items: [Transcript], now: Date = Date(), calendar: Calendar = .current) -> Int {
        items.filter { !$0.isDictation && calendar.isDate($0.createdAt, inSameDayAs: now) }.count
    }

    /// Notes pinned to a moment in a recording, across the library.
    static func momentsSaved(_ items: [Transcript]) -> Int {
        items.reduce(0) { $0 + $1.notes.filter { $0.at != nil }.count }
    }

    /// Words in a dictation as it was pasted (or its transcript when nothing was pasted).
    static func words(_ t: Transcript) -> Int {
        let text = t.flow?.pasted ?? t.text
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// This week's entries from dictation transcripts (the iPhone, which keeps no separate activity log).
    static func entries(fromDictations items: [Transcript]) -> [HomeWordEntry] {
        items.filter { $0.isDictation && $0.status == .ready }.map { HomeWordEntry(date: $0.createdAt, words: words($0), seconds: $0.duration) }
    }

    static func countLabel(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(many)" }
}

// MARK: - Recent rows

/// How a recent recording looks: its source's tinted chip and brand icon, a neutral tag, and a sentence-case meta
/// line. Colored by source only (DESIGN.md §1): voice notes persimmon, links and imported files sage, app audio
/// petal, dictation butter. Kinds and tags stay neutral.
struct HomeRecentStyle {
    var tint: Color
    var onTint: Color
    var art: BrandArt
    /// The neutral tag at the end of the row: the kind ("Idea") or what it is ("Video").
    var chip: String
    var source: String

    init(_ t: Transcript) {
        if t.isDictation {
            tint = Refined.butterTint; onTint = Refined.ink; art = .iconDictations; chip = "Dictation"; source = "Dictation"
        } else if LibrarySource.isLink(t) {
            let platform = Platform.of(t)
            tint = Refined.sageTint; onTint = Refined.sageText; art = .iconLinks
            chip = t.kind?.label ?? (platform.map { Platform.video.contains($0) } == true ? "Video" : (platform == Platform.applePodcasts || platform == Platform.spotify ? "Podcast" : "Link"))
            source = (platform == nil || platform == Platform.otherWeb) ? "Link" : platform!
        } else {
            switch t.source {
            case .app:
                tint = Refined.petalTint; onTint = Refined.ink; art = .iconVoice; chip = t.kind?.label ?? "App audio"
                source = t.sourceLabel.isEmpty ? "App audio" : t.sourceLabel
            case .file:
                tint = Refined.sageTint; onTint = Refined.sageText; art = .document
                chip = t.kind?.label ?? (LibrarySource.isVideoFile(t) ? "Video" : "File")
                source = LibrarySource.isVideoFile(t) ? "Video file" : "Audio file"
            default:
                tint = Refined.persimmonTint; onTint = Refined.accentText; art = .capture; chip = t.kind?.label ?? "Voice note"; source = "Voice note"
            }
        }
    }

    /// One piece of the meta line; `failed` pieces show in `Refined.danger`.
    struct MetaPart: Equatable { var text: String; var failed = false }

    /// "Voice note · 7:50 · Today". `compact` leaves out "Voice note" (iPhone).
    /// `day: false` leaves the day out, for items whose date line already says it (review M-09).
    static func metaParts(_ t: Transcript, style: HomeRecentStyle, compact: Bool, day showDay: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> [MetaPart] {
        var parts: [MetaPart] = []
        if !(compact && style.source == "Voice note") { parts.append(MetaPart(text: style.source)) }
        switch t.status {
        case .processing: parts.append(MetaPart(text: t.stage ?? "Transcribing"))
        case .failed: parts.append(MetaPart(text: "Didn't finish", failed: true))
        case .ready: if t.duration > 0 { parts.append(MetaPart(text: length(t.duration))) }
        }
        if showDay { parts.append(MetaPart(text: day(t.createdAt, now: now, calendar: calendar))) }
        return parts
    }

    static func meta(_ t: Transcript, style: HomeRecentStyle, compact: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        metaParts(t, style: style, compact: compact, now: now, calendar: calendar).map(\.text).joined(separator: " · ")
    }

    /// "7:50", "1:02:05": a length without a leading zero (metadata is sans, DESIGN.md §2.2).
    static func length(_ s: Double) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func day(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return Formats.pattern(calendar.isDate(d, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy").string(from: d)
    }
}

/// A dictation on Home: time and where it went, and the words as pasted.
enum HomeDictationText {
    static func pasted(_ t: Transcript) -> String { t.flow?.pasted ?? t.text }
    static func body(_ t: Transcript) -> String {
        if t.status == .failed { return t.error ?? "Transcription failed" }
        let text = pasted(t).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(only filler words)" : text
    }
    /// `body` for a preview: runs of line breaks and spaces become one space, so a greeting's blank line ("Hi
    /// Jonathan,\n\nI think…") doesn't end the preview after one line. Copy still takes the words as pasted.
    static func preview(_ t: Transcript) -> String { oneLine(body(t)) }
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

// MARK: - Self-test

enum HomeSelfTest {
    /// Greeting time of day, names, This week, and the counts. No UI; shared by both apps' self-tests.
    static func run(_ check: (String, Bool) -> Void) {
        check("home: 4:59 is evening, 5:00 morning", HomeGreeting.partOfDay(hour: 4) == .evening && HomeGreeting.partOfDay(hour: 5) == .morning)
        check("home: 11 is morning, 12 afternoon", HomeGreeting.partOfDay(hour: 11) == .morning && HomeGreeting.partOfDay(hour: 12) == .afternoon)
        check("home: 16 is afternoon, 17 evening, 23 evening", HomeGreeting.partOfDay(hour: 16) == .afternoon
              && HomeGreeting.partOfDay(hour: 17) == .evening && HomeGreeting.partOfDay(hour: 23) == .evening && HomeGreeting.partOfDay(hour: 0) == .evening)
        check("home: greeting with and without a name", HomeGreeting.line(name: "Tim", hour: 14) == "Good afternoon, Tim."
              && HomeGreeting.line(name: nil, hour: 8) == "Good morning." && HomeGreeting.line(name: "", hour: 20) == "Good evening.")
        check("home: first name", HomeGreeting.firstName("Tim Medina") == "Tim" && HomeGreeting.firstName("  Ana ") == "Ana"
              && HomeGreeting.firstName("") == nil && HomeGreeting.firstName("You") == nil)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        cal.firstWeekday = 1
        let wed = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14))!
        func at(_ day: Int, _ hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let entries = [HomeWordEntry(date: at(18, 9), words: 100, seconds: 30),     // Sunday
                       HomeWordEntry(date: at(20, 10), words: 250, seconds: 60),    // Tuesday
                       HomeWordEntry(date: at(21, 8), words: 50, seconds: 15),      // Wednesday (today)
                       HomeWordEntry(date: at(21, 13), words: 30, seconds: 10),
                       HomeWordEntry(date: at(17, 23), words: 999, seconds: 300)]  // last Saturday: not this week
        let week = HomeWeek(entries, now: wed, calendar: cal)
        check("home: week totals leave out last week", week.words == 430 && week.seconds == 115)
        check("home: week has seven days from Sunday", week.days.count == 7 && cal.component(.weekday, from: week.days[0].start) == 1)
        check("home: today and days to come", week.days[3].isToday && week.days[3].words == 80 && !week.days[2].isToday
              && week.days[4].isFuture && !week.days[3].isFuture && week.days[2].words == 250 && week.peak == 250)
        check("home: time saved at 40 wpm", abs(week.secondsSaved(typingWPM: 40) - (430.0 / 40 * 60 - 115)) < 0.001
              && HomeWeek([], now: wed, calendar: cal).secondsSaved(typingWPM: 40) == 0)
        check("home: duration labels", HomeWeek.durationLabel(42) == "42 s" && HomeWeek.durationLabel(18 * 60) == "18 m"
              && HomeWeek.durationLabel(3600) == "1 h" && HomeWeek.durationLabel(82 * 60) == "1 h 22 m")
        check("home: This week's time saved", HomeWeek.savedText(42) == "42 sec" && HomeWeek.savedText(25 * 60) == "25 min"
              && HomeWeek.savedText(3600) == "1 hr" && HomeWeek.savedText(134 * 60) == "2 hr 14 min")
        check("home: This week's bars: today, days to come, and shares of the busiest day",
              week.cardDays.count == 7 && week.cardDays[3].isToday && week.cardDays[4].isFuture
              && week.cardDays[2].share == 1 && abs(week.cardDays[3].share - 80.0 / 250) < 0.0001)

        var memo = Transcript(title: "m", source: .voiceMemo, sourceLabel: "Voice memo", duration: 67, audioFileName: nil, model: "")
        memo.createdAt = at(21, 9)
        memo.notes = [Note(text: "a", at: 4), Note(text: "b"), Note(text: "c", at: 9)]
        var old = memo; old.id = UUID(); old.createdAt = at(19, 9); old.notes = []
        var dict = Transcript(title: "d", source: .dictation, sourceLabel: "Dictation", duration: 4, audioFileName: nil, model: "")
        dict.createdAt = at(21, 10)
        dict.segments = [Segment(start: 0, end: 4, text: "Running ten minutes late, save me a seat.")]
        check("home: recordings today leave out dictations and other days", HomeCounts.recordingsToday([memo, old, dict], now: wed, calendar: cal) == 1)
        check("home: moments count only pinned notes", HomeCounts.momentsSaved([memo, old, dict]) == 2)
        check("home: dictation words", HomeCounts.words(dict) == 8 && HomeCounts.entries(fromDictations: [memo, dict]).map(\.words) == [8])
        check("home: count labels", HomeCounts.countLabel(1, "transcript", "transcripts") == "1 transcript"
              && HomeCounts.countLabel(81, "transcript", "transcripts") == "81 transcripts")
        let style = HomeRecentStyle(memo)
        check("home: voice note row", style.chip == "Voice note" && HomeRecentStyle.meta(memo, style: style, compact: false, now: wed, calendar: cal) == "Voice note · 1:07 · Today"
              && HomeRecentStyle.meta(memo, style: style, compact: true, now: wed, calendar: cal) == "1:07 · Today")
        check("home: lengths", HomeRecentStyle.length(470) == "7:50" && HomeRecentStyle.length(3725) == "1:02:05" && HomeRecentStyle.length(9) == "0:09")
        var tiktok = Transcript(title: "t", source: .link, sourceLabel: "tiktok.com", duration: 64, audioFileName: nil, model: "")
        tiktok.sourceURL = "https://www.tiktok.com/@a/video/1"
        check("home: video link row", HomeRecentStyle(tiktok).chip == "Video" && HomeRecentStyle(tiktok).source == "TikTok")
        check("home: dictation row", HomeRecentStyle(dict).chip == "Dictation")
        check("home: a recent row's kind: its own, a dictation's, or a voice note's", dict.refinedKind == .dictation && memo.refinedKind == nil
              && tiktok.refinedKind == .video)
        check("home: tiles are colored by what they do, three at most",
              HomeTile.refinedHues([.newThought, .journal, .dictate, .importMedia]) == [.neutral, .neutral, .butter, .sage]
              && HomeTile.refinedHues([.dictate, .importMedia, .whatsPlaying, .appAudio]) == [.butter, .sage, .petal, .neutral])
    }
}

extension BrandArt {
    /// The check in "Copied" (24-unit grid, 1.5 stroke), drawn on when a dictation is copied.
    static let homeCheck = BrandArt(box: iconGrid, strokes: [.path("M5 12.5L10 17.5L19 7")], strokeWidth: 1.5)
}

/// Spoken confirmations for VoiceOver ("Copied").
enum HomeAnnounce {
    @MainActor static func say(_ text: String) {
        #if os(macOS)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #else
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }
}

// MARK: - The refined look's Home (DESIGN.md §6, §13)

extension HomeTile {
    /// Each pick's color on Home in the refined look, by what it does (`hues`): Dictate butter, Import sage, What's
    /// playing and App audio petal, and everything else the card; never more than three colored.
    static func refinedHues(_ picks: [HomeTile]) -> [RefinedHue] {
        hues(picks).map { h in
            switch h {
            case .butter?: return .butter
            case .sage?: return .sage
            case .petal?: return .petal
            case nil: return .neutral
            }
        }
    }
}

extension Transcript {
    /// The kind a recent row's badge shows: the recording's own, else what it is (a dictation, a video or podcast
    /// link, a video file, another app's sound). Nil is a voice note.
    var refinedKind: RecordingKind? {
        if let kind { return kind }
        if isDictation { return .dictation }
        if LibrarySource.isLink(self) {
            let p = Platform.of(self)
            return p == Platform.applePodcasts || p == Platform.spotify ? .podcast : .video
        }
        if source == .file { return LibrarySource.isVideoFile(self) ? .video : .audio }
        if source == .app { return .audio }
        return nil
    }
}

/// This week's seven days as dots on Home's Journal: filled where there's an entry, today ringed, days to come
/// faint, in ink. Optional weekday letters under them. Decorative: the section says the count.
struct HomeWeekDots: View {
    var week: [HomeJournalWeek.Day]
    var size: CGFloat
    var letters = false

    var body: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(spacing: size * 0.9) {
            ForEach(week, id: \.start) { d in
                VStack(spacing: 4) {
                    Circle().fill(d.hasEntry ? Refined.ink : Color.clear)
                        .overlay(Circle().strokeBorder(d.hasEntry ? Refined.ink : d.isFuture ? Refined.faint.opacity(0.5) : Refined.faint,
                                                       lineWidth: d.isToday ? 1.6 : 1))
                        .frame(width: size, height: size)
                    if letters {
                        Text(symbols[(Calendar.current.component(.weekday, from: d.start) - 1) % symbols.count])
                            .refinedFont(.caption, weight: d.isToday ? .semibold : .regular)
                            .foregroundStyle(d.isToday ? Refined.ink : Refined.mute)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Edit Home (HomeLayout.swift)

extension HomeTile {
    /// The tile's line icon.
    var art: BrandArt {
        switch self {
        case .dictate, .dictations: return .iconDictations
        case .importMedia: return .iconDownload
        case .whatsPlaying, .appAudio: return .iconVoice
        case .captions: return .iconCaptions
        case .thoughtPad: return .iconThought
        case .dictionary: return .iconDictionary
        case .projects: return .iconProject
        case .newThought: return .iconThought
        case .journal: return .iconNotes
        case .brainDump: return .iconBrainDump
        }
    }
}

/// What Home has on screen, by section and size, and which tiles: the self-test checks an edit reaches Home. Counted,
/// because a section (or a tile) that moves to another band can appear again before its old place disappears. Tiles
/// weren't: closing Edit Home's inspector widened Home so two sections paired into one band, every tile
/// appeared in its new band before leaving the old one, and leaving took it off the list (build 213's "a new tile
/// reaches Home" failure, with Search drawn on Home).
@MainActor
enum HomeProbe {
    private static var counts: [HomeSection: Int] = [:]
    private static var sizes: [HomeSection: HomeCardSize] = [:]
    private static var tileCounts: [HomeTile: Int] = [:]
    static var tiles: [HomeTile] { tileCounts.filter { $0.value > 0 }.map(\.key) }
    static func tileAppeared(_ t: HomeTile) { tileCounts[t, default: 0] += 1 }
    static func tileDisappeared(_ t: HomeTile) { tileCounts[t] = max(0, (tileCounts[t] ?? 0) - 1) }
    static var sections: [HomeSection: HomeCardSize] { sizes.filter { (counts[$0.key] ?? 0) > 0 } }
    static func appeared(_ item: HomeLayout.Item) { counts[item.section, default: 0] += 1; sizes[item.section] = item.size }
    static func resized(_ s: HomeSection, _ size: HomeCardSize) { sizes[s] = size }
    static func disappeared(_ s: HomeSection) { counts[s] = max(0, (counts[s] ?? 0) - 1) }
}

extension View {
    /// Records the tile on screen while it is (HomeProbe).
    func homeTileProbe(_ tile: HomeTile) -> some View {
        onAppear { HomeProbe.tileAppeared(tile) }
            .onDisappear { HomeProbe.tileDisappeared(tile) }
    }

    /// Records the section on screen while it is (HomeProbe). Adds no state and no identity.
    func homeProbe(_ item: HomeLayout.Item) -> some View {
        onAppear { HomeProbe.appeared(item) }
            .onChange(of: item.size) { _, size in HomeProbe.resized(item.section, size) }
            .onDisappear { HomeProbe.disappeared(item.section) }
    }
}
