import SwiftUI

// Home, shared by the Mac (HomeView) and iPhone (HomeScreen) apps: the greeting and counts (pure, self-tested),
// the brand icons that draw themselves on, the Record panel's meter, the start tiles, This week, the compact Method
// cards, and the Recent rows. Everything is drawn from BrandArt; nothing here uses SF Symbols.
//
// Motion (design system rules): draw-ons play once on appear and again on hover (Mac); rings, meter bars, and the
// sparkle loop slowly; tiles lift 2 pt on hover. Springs never bounce. With Reduce Motion or Limit animation
// everything is still, and the screenshot tour (VERBATIM_UITEST=1) keeps it still so captures repeat.

extension Ink {
    /// Butter's text color: small text and glyphs on butter tint (6.3:1 on #FCF0D2), from the approved Home mockup.
    static let butterText = dyn(0x6B5320, 0xE5C77F)
}

enum HomeMotion {
    /// Off in the screenshot tour, so Home captures are the same every run.
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1"
    /// Tile hover lift and press: a 180 ms spring with no bounce.
    static let lift = Animation.spring(duration: 0.18, bounce: 0)
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

    /// The overline: "WEDNESDAY, OCT 21".
    static func dateLine(_ date: Date) -> String {
        Formats.pattern("EEEE, MMM d").string(from: date).uppercased()
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

/// How a recent recording looks: a tinted tile with its brand icon, a chip, and a mono meta line.
/// Voice notes persimmon, links and imported files sage, app audio petal, dictation butter.
struct HomeRecentStyle {
    var tint: Color
    var onTint: Color
    var art: BrandArt
    var chip: String
    var source: String

    init(_ t: Transcript) {
        if t.isDictation {
            tint = Ink.butterTint; onTint = Ink.butterText; art = .iconDictations; chip = "Dictation"; source = "Dictation"
        } else if LibrarySource.isLink(t) {
            let platform = Platform.of(t)
            tint = Ink.sageTint; onTint = Ink.sageText; art = .iconLinks
            chip = platform.map { Platform.video.contains($0) } == true ? "Video" : (platform == Platform.applePodcasts || platform == Platform.spotify ? "Podcast" : "Link")
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

    /// "VOICE NOTE · 07:27 · TODAY". `compact` leaves out "VOICE NOTE" (iPhone).
    static func meta(_ t: Transcript, style: HomeRecentStyle, compact: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if !(compact && style.source == "Voice note") { parts.append(style.source) }
        switch t.status {
        case .processing: parts.append(t.stage ?? "Transcribing")
        case .failed: parts.append("Didn't finish")
        case .ready: if t.duration > 0 { parts.append(t.duration.timecode) }
        }
        parts.append(day(t.createdAt, now: now, calendar: calendar))
        return parts.joined(separator: " · ").uppercased()
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
    static func overline(_ t: Transcript, place: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let d = t.createdAt
        let when = calendar.isDate(d, inSameDayAs: now) ? Formats.style(date: .none, time: .short).string(from: d) : HomeRecentStyle.day(d, now: now, calendar: calendar)
        guard let place, !place.isEmpty else { return when.uppercased() }
        return "\(when) · \(place)".uppercased()
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
        check("home: voice note row", style.chip == "Voice note" && HomeRecentStyle.meta(memo, style: style, compact: false, now: wed, calendar: cal) == "VOICE NOTE · 01:07 · TODAY"
              && HomeRecentStyle.meta(memo, style: style, compact: true, now: wed, calendar: cal) == "01:07 · TODAY")
        var tiktok = Transcript(title: "t", source: .link, sourceLabel: "tiktok.com", duration: 64, audioFileName: nil, model: "")
        tiktok.sourceURL = "https://www.tiktok.com/@a/video/1"
        check("home: video link row", HomeRecentStyle(tiktok).chip == "Video" && HomeRecentStyle(tiktok).source == "TikTok")
        check("home: dictation row", HomeRecentStyle(dict).chip == "Dictation")
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

/// A brand icon whose strokes draw on (1.1 s, ease-out, all strokes at once) when it appears and each time
/// `replay` changes. Fills fade in with the line. Still, fully drawn, with motion limited.
struct DrawOnGlyph: View {
    var art: BrandArt
    var color: Color
    var lineWidth: CGFloat
    var replay: Int = 0
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
            withAnimation(.easeOut(duration: 1.1).delay(delay)) { progress = 1 }
        }
    }
}

/// Runs a clock for ambient loops only while on screen, the app is active, and motion isn't limited.
private struct AmbientClock<Content: View>: View {
    var interval: Double = 1.0 / 30
    @ViewBuilder var content: (_ t: Double?) -> Content
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    var body: some View {
        Group {
            if limitMotion || !HomeMotion.enabled {
                content(nil)
            } else {
                TimelineView(.animation(minimumInterval: interval, paused: !onScreen || scenePhase == .background)) { timeline in
                    content(timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }
}

/// The Voice icon (three nested rings) breathing: each ring's opacity goes .35 → 1 → .35 over 2.4 s, 0.3 s apart.
struct PulsingRingsGlyph: View {
    var color: Color
    var lineWidth: CGFloat
    private static let rings: [(CGFloat, CGFloat, CGFloat)] = [(12, 12, 8), (15, 12, 5), (18, 12, 2)]

    var body: some View {
        AmbientClock { t in
            Canvas { ctx, size in
                let sp = ArtSpace(box: BrandArt.iconVoice.box, size: size)
                for (i, r) in Self.rings.enumerated() {
                    ctx.stroke(sp.circle(r.0, r.1, r.2), with: .color(color.opacity(Self.opacity(t, delay: 0.3 * Double(i)))), lineWidth: lineWidth)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Ease-out up to full at 40% of the cycle, then back down.
    static func opacity(_ t: Double?, delay: Double) -> Double {
        guard let t else { return 1 }
        var f = (t - delay).truncatingRemainder(dividingBy: 2.4) / 2.4
        if f < 0 { f += 1 }
        if f < 0.4 { return 0.35 + 0.65 * CubicEase.value(0, 0, 0.58, 1, f / 0.4) }
        return 1 - 0.65 * CubicEase.value(0, 0, 0.58, 1, (f - 0.4) / 0.6)
    }
}

/// Live captions: the Refine icon's lines draw on, and its sparkle twinkles (1.25× and 20° at 80% of 2.8 s).
struct TwinkleRefineGlyph: View {
    var color: Color
    var lineWidth: CGFloat
    var replay: Int = 0
    private static let lines = BrandArt(box: BrandArt.iconBox, strokes: [.path("M24 83h49 M24 69h59 M24 55h39 M27 41h54")])
    private static let spark = BrandArt(box: BrandArt.iconBox, strokes: [.path("M92 16l5.1 15.9L113 37l-15.9 5.1L92 58l-5.1-15.9L71 37l15.9-5.1z")])
    /// The sparkle's center (92, 37) as a unit point of the icon box.
    private static let center = UnitPoint(x: (92 - 8) / 112.0, y: (37 - 8) / 112.0)

    var body: some View {
        ZStack {
            DrawOnGlyph(art: Self.lines, color: color, lineWidth: lineWidth, replay: replay)
            AmbientClock { t in
                let k = Self.twinkle(t)
                BrandArtShape(box: Self.spark.box, elements: Self.spark.strokes)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .rotationEffect(.degrees(k.angle), anchor: Self.center)
                    .scaleEffect(k.scale, anchor: Self.center)
            }
        }
        .accessibilityHidden(true)
    }

    static func twinkle(_ t: Double?) -> (scale: CGFloat, angle: Double) {
        guard let t else { return (1, 0) }
        let f = t.truncatingRemainder(dividingBy: 2.8) / 2.8
        let amount: Double
        if f < 0.7 { amount = 0 }
        else if f < 0.8 { amount = CubicEase.inOut((f - 0.7) / 0.1) }
        else { amount = 1 - CubicEase.inOut((f - 0.8) / 0.2) }
        return (1 + 0.25 * CGFloat(amount), 20 * amount)
    }
}

/// The Record panel's level bars. Live levels while recording; otherwise a gentle idle sway (the microphone is
/// never opened just to animate). Still bars with motion limited.
struct HomeMeter: View {
    var bars: Int
    var barWidth: CGFloat
    var gap: CGFloat
    /// Resting heights, 0…1 of the meter's height, repeated across the bars.
    var heights: [CGFloat]
    var color: Color = Ink.readerFixed
    var levels: [Float]? = nil

    var body: some View {
        Group {
            if let levels {
                canvas(t: nil, levels: levels)
                    .animation(.easeOut(duration: 0.12), value: levels)
            } else {
                AmbientClock { t in canvas(t: t, levels: nil) }
            }
        }
        .accessibilityHidden(true)
    }

    private func canvas(t: Double?, levels: [Float]?) -> some View {
        Canvas { ctx, size in
            let h = size.height
            for i in 0..<bars {
                let v: CGFloat
                if let levels, !levels.isEmpty {
                    let l = levels[max(0, levels.count - bars + i) % levels.count]
                    v = max(0.1, min(1, CGFloat(l) * 1.6))
                } else {
                    v = heights[i % heights.count] * Self.sway(t, index: i)
                }
                let bh = max(barWidth, v * h)
                let x = CGFloat(i) * (barWidth + gap)
                guard x + barWidth <= size.width + 0.5 else { break }
                let rect = CGRect(x: x, y: (h - bh) / 2, width: barWidth, height: bh)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.85)))
            }
        }
    }

    /// 0.3 → 1 → 0.3: odd bars every 0.9 s, the rest every 1.2 s; every third bar 0.3 s late, every fourth 0.6 s.
    static func sway(_ t: Double?, index i: Int) -> CGFloat {
        guard let t else { return 1 }
        let n = i + 1
        let period = n % 2 == 1 ? 0.9 : 1.2
        let delay = n % 4 == 0 ? 0.6 : (n % 3 == 0 ? 0.3 : 0)
        let phase = (t - delay) / period * 2 * .pi
        return CGFloat(0.3 + 0.7 * (0.5 - 0.5 * cos(phase)))
    }

    static let macHeights: [CGFloat] = [8, 20, 40, 24, 52, 28, 12, 36, 16, 8, 22, 44, 18, 30, 10, 26, 48, 20, 12, 34, 8, 18, 40, 14, 28, 6, 20, 36].map { $0 / 64 }
    static let phoneHeights: [CGFloat] = [6, 14, 28, 16, 36, 20, 8, 24, 12, 6, 16, 30, 12, 22, 8, 18, 32, 14, 8, 24, 6, 12, 28, 10].map { $0 / 44 }
}

/// Live levels for the meter, observed on their own so only the meter re-renders while recording.
struct LiveHomeMeter: View {
    @ObservedObject var live: LiveMeter
    var bars: Int
    var barWidth: CGFloat
    var gap: CGFloat
    var body: some View {
        HomeMeter(bars: bars, barWidth: barWidth, gap: gap, heights: HomeMeter.macHeights, levels: live.levels)
    }
}

// MARK: - Tiles

/// Press: 0.98 over a no-bounce spring; a brief dim instead with motion limited.
struct HomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PressBody(configuration: configuration) }
    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.98 : 1)
                .opacity(configuration.isPressed && limitMotion ? 0.75 : 1)
                .animation(limitMotion ? Motion.fade : HomeMotion.lift, value: configuration.isPressed)
        }
    }
}

/// Sizes for the start tiles: the Mac's two-line tiles and the iPhone's slim 54-pt tiles.
struct HomeTileMetrics {
    var minHeight: CGFloat
    var radius: CGFloat
    var hPad: CGFloat
    var vPad: CGFloat
    var gap: CGFloat
    var disc: CGFloat
    var icon: CGFloat
    var title: CGFloat
    static let mac = HomeTileMetrics(minHeight: 72, radius: 18, hPad: 16, vPad: 14, gap: 12, disc: 44, icon: 30, title: 15)
    static let macCompact = HomeTileMetrics(minHeight: 72, radius: 18, hPad: 12, vPad: 12, gap: 10, disc: 36, icon: 24, title: 14.5)
    static let phone = HomeTileMetrics(minHeight: 54, radius: 16, hPad: 12, vPad: 8, gap: 10, disc: 32, icon: 20, title: 14.5)
}

/// A start tile: a flat brand color, the icon on a soft disc, a title, and (Mac) a mono detail line.
/// Lifts 2 pt on hover and replays its icon's draw-on. `icon` gets the replay count.
struct HomeTile<Icon: View>: View {
    var title: String
    var detail: String? = nil
    var fill: Color
    var onFill: Color = Ink.inkFixed
    /// The disc behind the icon: reader white at 60% on light fills, a faint light disc on ink.
    var disc: Color = Ink.readerFixed.opacity(0.6)
    /// A hairline for fills that sit close to the page (the ink tile in dark mode).
    var edge: Color = .clear
    var metrics: HomeTileMetrics
    var hint: String
    var action: () -> Void
    @ViewBuilder var icon: (_ replay: Int) -> Icon
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1
    @State private var hover = false
    @State private var replay = 0
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: metrics.gap) {
                ZStack {
                    Circle().fill(disc)
                    icon(replay).frame(width: metrics.icon, height: metrics.icon)
                }
                .frame(width: metrics.disc, height: metrics.disc)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: metrics.title * k, weight: .semibold))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail.uppercased()).font(Ink.mono(10.5 * k)).tracking(1).opacity(0.85)
                            .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(onFill)
            .padding(.horizontal, metrics.hPad).padding(.vertical, metrics.vPad)
            .frame(maxWidth: .infinity, minHeight: metrics.minHeight * max(1, k), alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous).strokeBorder(edge))
            .contentShape(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
        .offset(y: hover && !limitMotion ? -2 : 0)
        .onHover { h in
            hover = h
            if h { replay += 1 }
        }
        .animation(HomeMotion.lift, value: hover)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: taps)
        #endif
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityHint(hint)
    }
}

// MARK: - This week

/// Words this week, time saved, and seven daily bars (today persimmon, days to come as short hairlines).
struct HomeWeekCard<Trailing: View>: View {
    var week: HomeWeek
    var saved: Double
    var compact: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("THIS WEEK").font(Ink.mono(10.5)).tracking(1.6).foregroundStyle(Ink.mute)
                Text(HomeCounts.countLabel(week.words, "word", "words")).font(Ink.serif((compact ? 26 : 30) * k)).foregroundStyle(Ink.ink)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 6)
                HStack(spacing: 4) {
                    Text("\(HomeWeek.durationLabel(saved)) saved").foregroundStyle(Ink.mute)
                    trailing()
                }
                .font(.system(size: 12 * k)).padding(.top, 4)
            }
            .accessibilityElement(children: .contain)
            Spacer(minLength: 8)
            bars
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.hairline))
    }

    private var bars: some View {
        let w: CGFloat = compact ? 14 : 18
        let maxH: CGFloat = compact ? 44 : 62
        let peak = max(1, week.peak)
        return HStack(alignment: .bottom, spacing: compact ? 5 : 6) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                let empty = day.isFuture || day.words == 0
                VStack(spacing: compact ? 4 : 5) {
                    UnevenRoundedRectangle(topLeadingRadius: empty ? 1.5 : (compact ? 4 : 5), bottomLeadingRadius: 2, bottomTrailingRadius: 2,
                                           topTrailingRadius: empty ? 1.5 : (compact ? 4 : 5), style: .continuous)
                        .fill(empty ? Ink.hairline : (day.isToday ? Ink.persimmon : Ink.ink))
                        .frame(width: w, height: empty ? 3 : max(6, maxH * CGFloat(day.words) / CGFloat(peak)))
                    Text(Formats.pattern("EEEEE").string(from: day.start)).font(Ink.mono(compact ? 9.5 : 10))
                        .foregroundStyle(day.isToday ? Ink.ink : Ink.dim)
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

/// A compact Method card: index and illustration on top, the serif title right under it, one line, and a live
/// count. Flat brand fill with ink text in both appearances (ink on persimmon 4.4:1 at 24 pt, petal 7.5:1, sage 6.8:1).
struct CompactMethodCard: View {
    var feature: BrandFeature
    var line: String
    var meta: String
    var enabled = true
    var animated: Bool
    var hint: String
    var action: () -> Void
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(feature.index).font(Ink.mono(11, weight: .medium))
                        Rectangle().fill(Ink.inkFixed).frame(width: 16, height: 1)
                    }
                    Spacer(minLength: 8)
                    Group {
                        if animated && HomeMotion.enabled { AnimatedFeatureArt(feature: feature, color: Ink.inkFixed, minLineWidth: 0.9) }
                        else { BrandGlyph(art: feature.art, color: Ink.inkFixed, minLineWidth: 0.9) }
                    }
                    .frame(width: 52, height: 52)
                    .padding(.top, -4)
                }
                Text(feature.title).font(Ink.serif(24 * k)).lineLimit(1).minimumScaleFactor(0.8)
                Text(line).font(.system(size: 12.5 * k, weight: .semibold)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                Text(meta.uppercased()).font(Ink.mono(10.5 * k, weight: .medium)).tracking(1.2)
                    .lineLimit(1).truncationMode(.tail).padding(.top, 6)
            }
            .foregroundStyle(Ink.inkFixed)
            .padding(.horizontal, 14).padding(.vertical, 12)
            // Fills the row's height, so cards side by side line up (callers fix the row's height to its tallest card).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(feature.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .offset(y: hover && !limitMotion ? -2 : 0)
        .onHover { hover = $0 }
        .animation(HomeMotion.lift, value: hover)
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

/// A recent recording: its kind's tinted tile and brand icon, the title, a mono meta line, and a kind chip.
struct HomeRecentRow: View {
    var transcript: Transcript
    var compact: Bool
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1
    @State private var hover = false

    var body: some View {
        let style = HomeRecentStyle(transcript)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.tint)
                BrandGlyph(art: style.art, color: style.onTint, minLineWidth: 1.3).frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(transcript.title).font(.system(size: (compact ? 15 : 14) * k, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(HomeRecentStyle.meta(transcript, style: style, compact: compact)).font(Ink.mono(11 * k)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(style.chip).font(.system(size: 11.5 * k)).foregroundStyle(style.onTint)
                .padding(.horizontal, compact ? 8 : 9).padding(.vertical, 3)
                .background(style.tint, in: Capsule())
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: compact ? 16 : 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 16 : 14, style: .continuous).strokeBorder(Ink.hairline.opacity(0.7)))
        .contentShape(RoundedRectangle(cornerRadius: compact ? 16 : 14, style: .continuous))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .accessibilityElement(children: .combine)
    }
}

/// Recent dictations on a butter-tint panel: time and where it went, two lines of what you said, and Copy.
struct HomeDictationsPanel: View {
    var items: [Transcript]
    var compact: Bool
    var place: (Transcript) -> String?
    var copy: (String) -> Void
    var empty: String

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                HStack(spacing: 10) {
                    IconGlyph(art: .iconDictations, size: 18, color: Ink.butterText)
                    Text(empty).font(.system(size: 13.5)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                HomeDictationItem(transcript: t, compact: compact, place: place(t), copy: copy)
                if i < items.count - 1 { Rectangle().fill(Ink.hairline.opacity(0.6)).frame(height: 1) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, compact ? 4 : 6)
        .background(Ink.butterTint, in: RoundedRectangle(cornerRadius: compact ? 18 : 16, style: .continuous))
    }
}

struct HomeDictationItem: View {
    var transcript: Transcript
    var compact: Bool
    var place: String?
    var copy: (String) -> Void
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .body) private var k: CGFloat = 1
    @State private var copied = false

    var body: some View {
        let failed = transcript.status == .failed
        let text = HomeDictationText.pasted(transcript)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(HomeDictationText.overline(transcript, place: place)).font(Ink.mono(10.5 * k)).tracking(compact ? 0.8 : 1)
                    .foregroundStyle(Ink.butterText).lineLimit(1)
                Text(HomeDictationText.body(transcript)).font(.system(size: (compact ? 14 : 13.5) * k))
                    .foregroundStyle(failed ? Ink.accentText : Ink.ink)
                    .lineLimit(2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button {
                copy(text)
                withAnimation(limitMotion ? nil : Motion.snap) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(limitMotion ? nil : Motion.snap) { copied = false } }
            } label: {
                Text(copied ? "Copied" : "Copy").font(.system(size: (compact ? 12.5 : 12) * k, weight: copied ? .semibold : .regular))
                    .foregroundStyle(Ink.butterText)
                    .padding(.vertical, 6).padding(.leading, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(failed || text.isEmpty)
            .opacity(failed || text.isEmpty ? 0.4 : 1)
            .accessibilityLabel(copied ? "Copied" : "Copy dictation")
        }
        .padding(.vertical, 10)
    }
}
