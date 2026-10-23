import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Home, shared by the Mac (HomeView) and iPhone (HomeScreen) apps (approved mockup Home D, October 22, 2026): the
// greeting and counts (pure, self-tested), the brand icons that draw themselves on, the Record panel's meter and its
// level monitor, the start tiles, This week, the Method band, and the Recent rows. Everything is drawn from BrandArt;
// nothing here uses SF Symbols.
//
// Motion (DESIGN.md §7): every card tilts toward the pointer, lifts 2 pt, and catches a sheen and an edge light on
// hover (Mac), and presses in on click or touch (`HomeCard`). Icons draw on when they appear and again on hover. Two
// things loop, slowly and evenly, and only while on screen: the Method diagrams and the Record meter's breath at
// rest; the meter shows the real microphone level on hover, touch, and while recording. Springs never bounce. With
// Reduce Motion or Limit animation everything is still, and the screenshot tour (VERBATIM_UITEST=1) keeps it still
// so captures repeat.

enum HomeMotion {
    /// Off in the screenshot tour, so Home captures are the same every run.
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1"
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

    /// The newest finished transcript with text, for Refine.
    static func latestRefinable(_ items: [Transcript]) -> Transcript? {
        items.filter { $0.status == .ready && !$0.segments.isEmpty && !$0.isDictation }.max { $0.createdAt < $1.createdAt }
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
            tint = Ink.butterTint; onTint = Ink.butterText; art = .iconDictations; chip = "Dictation"; source = "Dictation"
        } else if LibrarySource.isLink(t) {
            let platform = Platform.of(t)
            tint = Ink.sageTint; onTint = Ink.sageText; art = .iconLinks
            chip = t.kind?.label ?? (platform.map { Platform.video.contains($0) } == true ? "Video" : (platform == Platform.applePodcasts || platform == Platform.spotify ? "Podcast" : "Link"))
            source = (platform == nil || platform == Platform.otherWeb) ? "Link" : platform!
        } else {
            switch t.source {
            case .app:
                tint = Ink.petalTint; onTint = Ink.ink; art = .iconVoice; chip = t.kind?.label ?? "App audio"
                source = t.sourceLabel.isEmpty ? "App audio" : t.sourceLabel
            case .file:
                tint = Ink.sageTint; onTint = Ink.sageText; art = .document
                chip = t.kind?.label ?? (LibrarySource.isVideoFile(t) ? "Video" : "File")
                source = LibrarySource.isVideoFile(t) ? "Video file" : "Audio file"
            default:
                tint = Ink.persimmonTint; onTint = Ink.accentText; art = .capture; chip = t.kind?.label ?? "Voice note"; source = "Voice note"
            }
        }
    }

    /// One piece of the meta line; `failed` pieces show in `Ink.danger`.
    struct MetaPart: Equatable { var text: String; var failed = false }

    /// "Voice note · 7:50 · Today". `compact` leaves out "Voice note" (iPhone).
    static func metaParts(_ t: Transcript, style: HomeRecentStyle, compact: Bool, now: Date = Date(), calendar: Calendar = .current) -> [MetaPart] {
        var parts: [MetaPart] = []
        if !(compact && style.source == "Voice note") { parts.append(MetaPart(text: style.source)) }
        switch t.status {
        case .processing: parts.append(MetaPart(text: t.stage ?? "Transcribing"))
        case .failed: parts.append(MetaPart(text: "Didn't finish", failed: true))
        case .ready: if t.duration > 0 { parts.append(MetaPart(text: length(t.duration))) }
        }
        parts.append(MetaPart(text: day(t.createdAt, now: now, calendar: calendar)))
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
    /// "10:16 AM · Keyboard", sentence case.
    static func overline(_ t: Transcript, place: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let d = t.createdAt
        let when = calendar.isDate(d, inSameDayAs: now) ? Formats.style(date: .none, time: .short).string(from: d) : HomeRecentStyle.day(d, now: now, calendar: calendar)
        guard let place, !place.isEmpty else { return when }
        return "\(when) · \(place)"
    }
    static func body(_ t: Transcript) -> String {
        if t.status == .failed { return t.error ?? "Transcription failed" }
        let text = pasted(t).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(only filler words)" : text
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
        check("home: the meter breathes evenly", abs(HomeMeter.breathScale(t: 0, bar: 0) - 0.42) < 0.0001
              && abs(HomeMeter.breathScale(t: 2.6, bar: 0) - 0.92) < 0.0001
              && abs(HomeMeter.breathScale(t: 7.8, bar: 0) - HomeMeter.breathScale(t: 2.6, bar: 0)) < 0.0001
              && HomeMeter.breathScale(t: 1, bar: 3) < HomeMeter.breathScale(t: 1, bar: 0))
    }
}

// MARK: - Drawing helpers

/// One element of a BrandArt, fitted to the view like BrandGlyph, so it can be trimmed (drawn on).
struct BrandArtShape: Shape {
    var box: CGRect
    var elements: [BrandArt.Element]
    func path(in rect: CGRect) -> Path {
        let space = ArtSpace(box: box, size: rect.size)
        return Path(BrandArt.cgPath(elements)).applying(space.transform).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// A brand icon or diagram whose strokes draw on (1.1 s by default, ease-out, all strokes at once) when it appears
/// and each time `replay` changes. Fills, dashed construction lines, and the Understand diagram's hatch fade in with
/// the line. Never loops. Still, fully drawn, with motion limited.
struct DrawOnGlyph: View {
    var art: BrandArt
    var color: Color
    var lineWidth: CGFloat
    var replay: Int = 0
    /// Seconds to draw. Hover replays on the tiles, the Record panel, and the sidebar use 0.55.
    var duration: Double = 1.1
    @Environment(\.limitMotion) private var limitMotion
    @State private var progress: CGFloat = HomeMotion.enabled ? 0 : 1

    var body: some View {
        let p: CGFloat = (limitMotion || !HomeMotion.enabled) ? 1 : progress
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        ZStack {
            ForEach(Array(art.strokes.enumerated()), id: \.offset) { _, element in
                BrandArtShape(box: art.box, elements: [element]).trim(from: 0, to: p).stroke(color, style: style)
            }
            if !art.fills.isEmpty {
                BrandArtShape(box: art.box, elements: art.fills).fill(color).opacity(Double(p))
            }
            if !art.clipped.isEmpty {
                BrandGlyph(art: BrandArt(box: art.box, strokeWidth: art.strokeWidth, clipped: art.clipped, clip: art.clip, clippedWidth: art.clippedWidth),
                           color: color, minLineWidth: lineWidth * 0.75)
                    .opacity(Double(p))
            }
            if !art.dashes.isEmpty {
                BrandGlyph(art: BrandArt(box: art.box, strokeWidth: art.strokeWidth, dashes: art.dashes), color: color, minLineWidth: lineWidth)
                    .opacity(Double(p))
            }
        }
        .onAppear { play(delay: 0.2) }
        .onChange(of: replay) { _, _ in play(delay: 0) }
        .accessibilityHidden(true)
    }

    private func play(delay: Double) {
        guard HomeMotion.enabled, !limitMotion else { progress = 1; return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 0 }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: duration).delay(delay)) { progress = 1 }
        }
    }
}

// MARK: - Record meter

/// The Record panel's level bars. With `levels` they show the real microphone level, newest on the right: while
/// recording, and while the level monitor listens (hover on Mac, touch on iPhone). Otherwise they rest on the
/// `heights` pattern: breathing slowly and evenly with a `breath` clock (`BreathingHomeMeter`), still without one.
/// Bars fill the width at `barWidth` with at least `gap` between them.
struct HomeMeter: View {
    var barWidth: CGFloat
    var gap: CGFloat
    /// Resting heights, 0…1 of the meter's height, repeated across the bars.
    var heights: [CGFloat]
    var color: Color = Ink.inkFixed
    var levels: [Float]? = nil
    /// The breath's clock in seconds; nil holds the bars still.
    var breath: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let n = max(1, Int((size.width + gap) / (barWidth + gap)))
            let step = n > 1 ? (size.width - barWidth) / CGFloat(n - 1) : 0
            let h = size.height
            for i in 0..<n {
                var v = heights[i % heights.count]
                if let levels, !levels.isEmpty {
                    let l = levels[min(levels.count - 1, i * levels.count / n)]
                    v = max(0.1, min(1, CGFloat(l) * 1.6))
                } else if let breath {
                    v *= CGFloat(Self.breathScale(t: breath, bar: i))
                } else {
                    v *= Self.stillScale
                }
                let bh = max(barWidth, v * h)
                let rect = CGRect(x: CGFloat(i) * step, y: (h - bh) / 2, width: barWidth, height: bh)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.8)))
            }
        }
        .accessibilityHidden(true)
    }

    /// The breath (DESIGN.md §7): each bar is its resting height × (0.42 + 0.5 × breath), with
    /// breath = 0.5 − 0.5 cos(2π t / 5.2 − 0.09 i). A 5.2-second cycle that rolls gently from left to right; never random.
    static func breathScale(t: Double, bar i: Int) -> Double {
        let breath = 0.5 - 0.5 * cos(2 * Double.pi * t / 5.2 - Double(i) * 0.09)
        return 0.42 + 0.5 * breath
    }
    /// The still bars (Limit animation, the screenshot tour): the middle of the breath.
    static let stillScale: CGFloat = 0.7

    /// Home D's resting shape (72-pt meter, 35 bars).
    static let macHeights: [CGFloat] = [8, 24, 48, 28, 60, 32, 16, 44, 20, 8, 28, 52, 22, 36, 12, 32, 56, 24, 14, 40, 8, 22, 48, 18, 34, 6, 24, 44, 18, 32, 12, 40, 20, 28, 10].map { $0 / 72 }
    static let phoneHeights: [CGFloat] = [6, 14, 28, 16, 36, 20, 8, 24, 12, 6, 16, 30, 12, 22, 8, 18, 32, 14, 8, 24, 6, 12, 28, 10].map { $0 / 44 }
}

/// The meter at rest: breathing on a `LoopTimeline` (30 fps at most, paused off screen and while the app is
/// inactive), still with motion limited.
struct BreathingHomeMeter: View {
    var barWidth: CGFloat
    var gap: CGFloat
    var heights: [CGFloat]
    var color: Color = Ink.inkFixed
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        if limitMotion || !HomeMotion.enabled {
            HomeMeter(barWidth: barWidth, gap: gap, heights: heights, color: color)
        } else {
            LoopTimeline(running: true) { now in
                HomeMeter(barWidth: barWidth, gap: gap, heights: heights, color: color, breath: now.timeIntervalSinceReferenceDate)
            }
            .accessibilityHidden(true)
        }
    }
}

/// Live levels for the meter, observed on their own so only the meter re-renders while it listens.
struct LiveHomeMeter: View {
    @ObservedObject var live: LiveMeter
    var barWidth: CGFloat
    var gap: CGFloat
    var heights: [CGFloat]
    var color: Color = Ink.inkFixed
    var body: some View {
        HomeMeter(barWidth: barWidth, gap: gap, heights: heights, color: color, levels: live.levels)
    }
}

/// The level as the recorder shows it (`RecordingWriter.write`): the first channel's RMS, mapped so speech fills
/// most of the bar height.
enum HomeLevel {
    static func of(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, (max(0, rms - 0.004) * 6).squareRoot())
    }
}

/// Listens to the microphone for the Record panel's meter while the pointer is over it (Mac) or a finger is on it
/// (iPhone). Levels only: nothing is written to disk, and the mic closes within a second of leaving. It never asks
/// for permission: without it, the meter stays still. The system's mic indicator shows while it listens.
@MainActor
final class HomeLevelMonitor: ObservableObject {
    let live = LiveMeter()
    @Published private(set) var listening = false
    private let tap = HomeMicTap()
    private var pending: Task<Void, Never>?

    /// Opens the mic after `delay` (so a pointer passing over, or a quick tap, doesn't open it).
    func listen(after delay: TimeInterval) {
        pending?.cancel(); pending = nil
        guard !listening, HomeMotion.enabled, HomeMicTap.permitted else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    /// Closes the mic after `delay` (well under a second), unless `listen` is called again first.
    func stop(after delay: TimeInterval = 0) {
        pending?.cancel(); pending = nil
        guard listening else { return }
        guard delay > 0 else { close(); return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func open() {
        pending = nil
        listening = true
        live.reset()
        let live = self.live
        let start = Date()
        tap.open { v in
            Task { @MainActor in live.push(v, seconds: Date().timeIntervalSince(start), paused: false) }
        }
    }

    private func close() {
        pending = nil
        listening = false
        tap.close()
        live.reset()
    }
}

/// The monitor's microphone, opened and closed on its own queue. Mac: the chosen input through `InputUnit`, the
/// same unit recording uses, so no other device is ever opened. iPhone: an `AVAudioEngine` input tap that mixes
/// with other audio.
final class HomeMicTap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.home-level")
    #if os(macOS)
    private var unit: InputUnit?

    /// Only when access is already granted; hover never prompts.
    static var permitted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func open(_ onLevel: @escaping @Sendable (Float) -> Void) {
        queue.async {
            guard self.unit == nil, let device = AudioDevices.current() else { return }
            do {
                let u = try InputUnit(device: device.id) { buffer in onLevel(HomeLevel.of(buffer)) }
                try u.start()
                self.unit = u
            } catch {
                Log.note("home meter: couldn't open the microphone: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        queue.async {
            self.unit?.dispose()
            self.unit = nil
        }
    }
    #else
    private var engine: AVAudioEngine?

    /// Only when access is already granted; a touch never prompts.
    static var permitted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    func open(_ onLevel: @escaping @Sendable (Float) -> Void) {
        queue.async {
            guard self.engine == nil else { return }
            let s = AVAudioSession.sharedInstance()
            do {
                // Mixes with whatever is playing; the recorder sets its own category when it starts.
                if s.category != .playAndRecord && s.category != .record {
                    try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
                }
                try s.setActive(true)
                let e = AVAudioEngine()
                let format = e.inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { return }
                e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in onLevel(HomeLevel.of(buffer)) }
                try e.start()
                self.engine = e
            } catch {
                Log.note("home meter: couldn't open the microphone: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        queue.async {
            guard let e = self.engine else { return }
            e.inputNode.removeTap(onBus: 0)
            e.stop()
            self.engine = nil
        }
    }
    #endif
}

// MARK: - Cards

/// Every card on Home (DESIGN.md §7): the Record panel, the start tiles, This week, the Method cards, and the recent
/// recordings. On Mac it tilts toward the pointer, lifts 2 pt, and catches a sheen and an edge light (`CardMotion`),
/// and presses in on click. On iPhone, where there's no hover, it presses in on touch. With motion limited it only
/// dims while pressed.
///
/// Mac: the visuals move underneath and a flat, untransformed layer on top takes the pointer, as `CardButton` does,
/// because a 3D-rotated view, or a Button competing with a gesture, loses clicks on macOS 26. Because that layer
/// takes the pointer, `content` hears hover through its `hovering` argument rather than its own `onHover`.
struct HomeCard<Content: View>: View {
    var tilt: Double = 3
    var lift: Double = 2
    var radius: CGFloat
    var enabled = true
    /// The pointer arrived (true) or left (false). Mac only.
    var onHover: ((Bool) -> Void)? = nil
    /// The pointer or finger went down (true) or came up (false).
    var onPress: ((Bool) -> Void)? = nil
    var action: () -> Void
    @ViewBuilder var content: (_ hovering: Bool) -> Content

    #if os(macOS)
    @Environment(\.limitMotion) private var limitMotion
    @State private var hover: CGPoint? = nil
    @State private var down = false
    @State private var size: CGSize = .zero

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content(hover != nil && enabled)
            .cardMotion(hover: enabled ? hover : nil, size: size, pressed: down && enabled, radius: radius, tilt: tilt, lift: lift)
            .opacity(down && enabled && limitMotion ? 0.8 : 1)
            .allowsHitTesting(false)
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
            .overlay {
                // The hit layer: flat, on top, and the only thing that receives the pointer.
                shape.fill(Color.white.opacity(0.001))
                    .contentShape(shape)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            if hover == nil { onHover?(true) }
                            hover = p
                        case .ended:
                            hover = nil
                            if down { down = false; onPress?(false) }
                            onHover?(false)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !down { down = true; onPress?(true) } }
                        .onEnded { v in
                            down = false
                            onPress?(false)
                            if enabled && CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(v.location) { action() }
                        })
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { action() } }
    }
    #else
    var body: some View {
        Button { if enabled { action() } } label: { content(false) }
            .buttonStyle(HomeCardPressStyle(radius: radius, tilt: tilt, lift: lift, onPress: onPress))
            .disabled(!enabled)
    }
    #endif
}

#if os(iOS)
/// iPhone: the card presses in (scale 0.98) while a finger is on it; a brief dim instead with motion limited.
private struct HomeCardPressStyle: ButtonStyle {
    var radius: CGFloat
    var tilt: Double
    var lift: Double
    var onPress: ((Bool) -> Void)?
    func makeBody(configuration: Configuration) -> some View { PressBody(configuration: configuration, style: self) }
    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let style: HomeCardPressStyle
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .cardMotion(hover: nil, size: .zero, pressed: configuration.isPressed, radius: style.radius, tilt: style.tilt, lift: style.lift)
                .opacity(configuration.isPressed && limitMotion ? 0.75 : 1)
                .animation(Motion.fade, value: configuration.isPressed && limitMotion)
                .onChange(of: configuration.isPressed) { _, pressed in style.onPress?(pressed) }
        }
    }
}
#endif

// MARK: - Tiles

/// Sizes for the start tiles: the Mac's 92-pt tiles (Home D) and the iPhone's slim 54-pt tiles.
struct HomeTileMetrics {
    var minHeight: CGFloat
    var radius: CGFloat
    var hPad: CGFloat
    var vPad: CGFloat
    var gap: CGFloat
    var icon: CGFloat
    var title: CGFloat
    /// Mac ("Stacked", Tim's pick): the icon top left, the shortcut top right, the name and detail at the foot.
    /// iPhone: the icon beside the name, so the slim tiles stay one line tall.
    var stacked: Bool
    static let mac = HomeTileMetrics(minHeight: 92, radius: Radius.tile, hPad: 14, vPad: 13, gap: 11, icon: 26, title: 15, stacked: true)
    static let macCompact = HomeTileMetrics(minHeight: 92, radius: Radius.tile, hPad: 12, vPad: 12, gap: 9, icon: 22, title: 14.5, stacked: true)
    static let phone = HomeTileMetrics(minHeight: 54, radius: Radius.tile, hPad: 14, vPad: 8, gap: 10, icon: 22, title: 14.5, stacked: false)
}

/// A start tile: a flat brand color, a bare brand icon (no disc behind it), a semibold name, and a sentence-case
/// detail, with a keycap where the action has a shortcut. Card motion (`HomeCard`); the icon draws on when it
/// appears and again on hover.
struct HomeTile<Icon: View>: View {
    var title: String
    var detail: String? = nil
    var keycap: String? = nil
    var fill: Color
    var onFill: Color = Ink.inkFixed
    /// An outline: Live captions is a paper tile with a 1.5 pt ink edge.
    var edge: Color = .clear
    var edgeWidth: CGFloat = 1
    var metrics: HomeTileMetrics
    var hint: String
    var action: () -> Void
    @ViewBuilder var icon: (_ replay: Int) -> Icon
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1
    @State private var replay = 0
    @State private var taps = 0

    var body: some View {
        HomeCard(tilt: 3, radius: metrics.radius, onHover: { h in if h { replay += 1 } }, action: {
            taps += 1
            action()
        }) { _ in
            face
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: taps)
        #endif
        .accessibilityLabel(title)
        .accessibilityValue([detail, keycap.map(Keycap.spoken)].compactMap { $0 }.joined(separator: " "))
        .accessibilityHint(hint)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: metrics.radius, style: .continuous) }

    @ViewBuilder private var face: some View {
        if metrics.stacked {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    icon(replay).frame(width: metrics.icon, height: metrics.icon)
                    Spacer(minLength: 0)
                    if let keycap { Keycap(keys: keycap, size: 10.5).opacity(0.8) }
                }
                Spacer(minLength: 6)
                Text(title).font(.system(size: metrics.title, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                if let detail {
                    Text(detail).font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.85).opacity(0.78).padding(.top, 2)
                }
            }
            .foregroundStyle(onFill)
            .padding(.horizontal, metrics.hPad).padding(.vertical, metrics.vPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.minHeight)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: edgeWidth))
        } else {
            HStack(spacing: metrics.gap) {
                icon(replay).frame(width: metrics.icon, height: metrics.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: metrics.title * k, weight: .semibold))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if detail != nil || keycap != nil {
                        HStack(spacing: 5) {
                            if let detail { Text(detail).font(.system(size: 12.5 * k)).lineLimit(1).minimumScaleFactor(0.85) }
                            if let keycap { Keycap(keys: keycap, size: 10.5 * k) }
                        }
                        .opacity(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(onFill)
            .padding(.horizontal, metrics.hPad).padding(.vertical, metrics.vPad)
            .frame(maxWidth: .infinity, minHeight: metrics.minHeight * max(1, k), alignment: .leading)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: edgeWidth))
        }
    }
}

// MARK: - This week

/// The only stats on Home: words this week, today's recordings, and seven daily bars (today butter, because the
/// bars count dictated words; days to come as short hairlines).
struct HomeWeekCard<Trailing: View>: View {
    var week: HomeWeek
    var recordingsToday: Int
    var compact: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("This week").font(.system(size: 12.5 * k, weight: .medium)).foregroundStyle(Ink.mute)
                Text(HomeCounts.countLabel(week.words, "word", "words")).font(Ink.serif((compact ? 26 : 28) * k)).monospacedDigit()
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 4)
                HStack(spacing: 4) {
                    Text("Today: \(HomeCounts.countLabel(recordingsToday, "recording", "recordings"))").foregroundStyle(Ink.mute)
                    trailing()
                }
                .font(.system(size: 12 * k)).lineLimit(1).padding(.top, 5)
            }
            .accessibilityElement(children: .contain)
            Spacer(minLength: 8)
            bars
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.tile)
    }

    private var bars: some View {
        let w: CGFloat = compact ? 12 : 11
        let maxH: CGFloat = compact ? 44 : 52
        let peak = max(1, week.peak)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                let empty = day.isFuture || day.words == 0
                VStack(spacing: 4) {
                    UnevenRoundedRectangle(topLeadingRadius: empty ? 1.5 : 4, bottomLeadingRadius: 2, bottomTrailingRadius: 2,
                                           topTrailingRadius: empty ? 1.5 : 4, style: .continuous)
                        .fill(empty ? Ink.hairline : (day.isToday ? Ink.butter : Ink.ink))
                        .frame(width: w, height: empty ? 3 : max(4, maxH * CGFloat(day.words) / CGFloat(peak)))
                    Text(Formats.pattern("EEEEE").string(from: day.start)).font(.system(size: 10.5, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? Ink.ink : Ink.mute)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Formats.pattern("EEEE").string(from: day.start))
                .accessibilityValue(day.isFuture ? "Still to come" : HomeCounts.countLabel(day.words, "word", "words"))
            }
        }
        .frame(height: maxH + 18, alignment: .bottom)
    }
}

// MARK: - Method

/// One Method card (DESIGN.md §6.4): full color (Capture persimmon, Refine petal, Understand sage) with ink text in
/// both modes; the mono index top left, the looping diagram top right, the serif title, a semibold line, and a live
/// count in sentence-case sans. Card motion (`HomeCard`). Mac: 196 pt tall, three across all 12 columns. iPhone
/// (`compact`): a narrower card for the carousel, as tall as its row.
struct MethodCard: View {
    var feature: BrandFeature
    var line: String
    var meta: String
    var enabled = true
    var compact = false
    var hint: String
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1

    var body: some View {
        HomeCard(tilt: 3, radius: Radius.tile, enabled: enabled, action: action) { _ in
            VStack(alignment: .leading, spacing: 0) {
                Text(feature.index).font(Ink.mono(compact ? 11 : 12, weight: .medium))
                // The diagram sits top right (overlay); the words gather at the foot.
                Spacer(minLength: compact ? 50 : 8)
                Text(feature.title).font(Ink.serif((compact ? 26 : 30) * k)).lineLimit(1).minimumScaleFactor(0.8)
                Text(line).font(.system(size: 13 * k, weight: .semibold)).lineLimit(compact ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                Text(meta).font(.system(size: 12 * k)).monospacedDigit().opacity(0.8)
                    .lineLimit(1).truncationMode(.tail).padding(.top, 4)
            }
            // Fills the row's height, so cards side by side line up.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                AnimatedFeatureArt(feature: feature, color: Ink.inkFixed, minLineWidth: 1)
                    .frame(width: compact ? 64 : 100, height: compact ? 64 : 100)
                    .padding(.top, -4)
            }
            .foregroundStyle(Ink.inkFixed)
            .padding(.horizontal, compact ? 14 : 18).padding(.vertical, compact ? 12 : 16)
            .frame(height: compact ? nil : 196)
            .background(feature.fill, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel("\(feature.title). \(line)")
        .accessibilityValue(meta)
        .accessibilityHint(hint)
    }
}

// MARK: - Recent

/// "Recent recordings  ·  Library →": a serif section title with a text link.
struct HomeSectionTitle: View {
    var title: String
    var link: String
    /// What VoiceOver says for the link, when the visible text is short ("All").
    var linkLabel: String? = nil
    var size: CGFloat = 24
    var linkHint: String
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Ink.serif(size * k)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button(action: action) {
                Text("\(link) →").font(.system(size: (size > 23.5 ? 13 : 14) * k, weight: .semibold)).foregroundStyle(Ink.ink)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(linkLabel ?? link)
            .accessibilityHint(linkHint)
        }
    }
}

/// A recent recording, 60 pt tall: its source's tinted chip and brand icon, the title, a sentence-case meta line,
/// and a neutral tag. `hovering` comes from the card around it (Mac), which takes the pointer.
struct HomeRecentRow: View {
    var transcript: Transcript
    var compact: Bool
    var hovering = false
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1

    var body: some View {
        let style = HomeRecentStyle(transcript)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(style.tint)
                BrandGlyph(art: style.art, color: style.onTint, minLineWidth: 1.4).frame(width: 18, height: 18)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title).font(.system(size: (compact ? 15 : 14) * k, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                metaText(style).font(.system(size: 12 * k)).monospacedDigit().foregroundStyle(Ink.mute).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(style.chip).font(.system(size: 11.5 * k)).foregroundStyle(Ink.dim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 60 * max(1, k))
        .background(hovering ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline.opacity(0.7)))
        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .animation(Motion.touch, value: hovering)
        .accessibilityElement(children: .combine)
    }

    private func metaText(_ style: HomeRecentStyle) -> Text {
        var out = Text(verbatim: "")
        for (i, part) in HomeRecentStyle.metaParts(transcript, style: style, compact: compact).enumerated() {
            if i > 0 { out = out + Text(verbatim: " · ") }
            out = out + (part.failed ? Text(part.text).foregroundStyle(Ink.danger).fontWeight(.semibold) : Text(part.text))
        }
        return out
    }
}

/// Recent dictations on a butter-tint panel (butter means Dictate). Each row is one button: click or tap anywhere on
/// it to copy what you said. On Mac each row is 62.5 pt, so four of them (with the panel's inset and gaps) end level
/// with four 60-pt recording rows and their gaps.
struct HomeDictationsPanel: View {
    var items: [Transcript]
    var compact: Bool
    var place: (Transcript) -> String?
    var copy: (String) -> Void
    var empty: String

    var body: some View {
        VStack(spacing: 2) {
            if items.isEmpty {
                HStack(spacing: 10) {
                    IconGlyph(art: .iconDictations, size: 18, color: Ink.butterText)
                    Text(empty).font(.system(size: 13.5)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                HomeDictationItem(transcript: t, compact: compact, place: place(t), copy: copy)
                    .overlay(alignment: .top) {
                        if i > 0 {
                            Rectangle().fill(Ink.hairline.opacity(0.6)).frame(height: 1)
                                .padding(.leading, 12).padding(.trailing, 10).offset(y: -1.5)
                                .allowsHitTesting(false)
                        }
                    }
                    #if os(macOS)
                    .uiTarget("home-dictation-\(i)")
                    #endif
            }
        }
        .padding(4)
        .background(Ink.butterTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}

/// One recent dictation: time and where it went, the words as pasted, and Copy. The whole row copies. Hover tints it;
/// a copy washes it butter while "Copy" turns into a drawn check and "Copied" (a quick crossfade and slide), and
/// after 1.6 s it goes back. VoiceOver hears "Copied"; iPhone taps add a success haptic. No tilt: rows sit in a panel.
struct HomeDictationItem: View {
    var transcript: Transcript
    var compact: Bool
    var place: String?
    var copy: (String) -> Void
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1
    @State private var copied = false
    @State private var copies = 0
    @State private var hover = false

    var body: some View {
        let failed = transcript.status == .failed
        let text = HomeDictationText.pasted(transcript)
        let canCopy = !failed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let overline = HomeDictationText.overline(transcript, place: place)
        Button { copyNow(text) } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(overline).font(.system(size: 12 * k)).monospacedDigit()
                        .foregroundStyle(Ink.butterText).lineLimit(1)
                    Text(HomeDictationText.body(transcript)).font(.system(size: (compact ? 14 : 13.5) * k))
                        .foregroundStyle(failed ? Ink.danger : Ink.ink)
                        .lineLimit(compact ? 2 : 1).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if canCopy { HomeCopyLabel(copied: copied, replay: copies, size: 12.5 * k) }
            }
            .padding(.leading, compact ? 10 : 12).padding(.trailing, 10)
            .padding(.vertical, compact ? 10 : 0)
            .frame(minHeight: compact ? 0 : 62.5 * max(1, k))
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeDictationRowStyle(copied: copied, hover: hover && canCopy))
        .disabled(!canCopy)
        .onHover { hover = $0 }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: copies)
        #endif
        .accessibilityLabel(HomeDictationText.body(transcript))
        .accessibilityValue(copied ? "Copied" : overline)
        .accessibilityHint(canCopy ? "Copies the dictation." : "")
    }

    private func copyNow(_ text: String) {
        copy(text)
        copies += 1
        let token = copies
        withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = true }
        HomeAnnounce.say("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copies == token else { return }
            withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = false }
        }
    }
}

/// The dictation row's wash: butter at 70% under the pointer, full while pressed and once copied.
private struct HomeDictationRowStyle: ButtonStyle {
    var copied: Bool
    var hover: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Ink.butterWash.opacity(copied || configuration.isPressed ? 1 : hover ? 0.7 : 0),
                        in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .animation(Motion.touch, value: hover)
            .animation(Motion.touch, value: configuration.isPressed)
    }
}

/// "Copy" with the brand copy icon, which turns into a drawn check and "Copied". With motion limited it crossfades
/// in place.
struct HomeCopyLabel: View {
    var copied: Bool
    var replay: Int
    var size: CGFloat
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 6) {
                ArtIcon(art: .iconCopy, size: 16)
                Text("Copy")
            }
            .opacity(copied ? 0 : 1)
            .offset(y: copied && !limitMotion ? -4 : 0)
            HStack(spacing: 6) {
                DrawOnGlyph(art: .homeCheck, color: Ink.butterText, lineWidth: 1.5, replay: replay, duration: 0.35)
                    .frame(width: 16, height: 16)
                Text("Copied")
            }
            .opacity(copied ? 1 : 0)
            .offset(y: copied || limitMotion ? 0 : 4)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(Ink.butterText)
        .fixedSize()
        .accessibilityHidden(true)
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
