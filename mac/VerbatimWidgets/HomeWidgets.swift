import SwiftUI
import WidgetKit
import AppIntents
#if os(macOS)
import AppKit
#endif

// The Home Screen and desktop widgets, shared by the iPhone widget extension (VerbatimWidgets) and the Mac's
// (VerbatimMacWidgets):
//
// 1. Record and dictate. iPhone: small (Record), medium (both), Lock Screen circular (Record) and rectangular (both),
//    and StandBy (small). Mac: small and medium.
// 2. Recent recordings: medium (three) and large (five, with This week at the foot). Each row opens its transcript.
// 3. This week: small and medium. A card with the serif number and the week's bars, today's in persimmon.
// 4. New thought (the Quick capture widget's kind): small. Starts a thought (`NewThoughtIntent`): on iPhone it records in
//    place behind a Live Activity when iOS allows it; on the Mac it starts in the running app without bringing it
//    forward.
// 5. Today's thoughts: medium. Today's Thoughts page, its last two thoughts (marked `privacySensitive()`), and New
//    thought. Tap a thought to open today's page.
// 6. Thoughts on the Lock Screen (iPhone): circular, New thought; rectangular, today's count only, never the words.
//
// Gallery names are sentence case and unique. Mono labels are 12 pt or larger at full strength, and a label on the
// persimmon fill is SF Pro semibold 14 in the fill's ink (DESIGN.md §1.5, §2).
//
// The widgets draw from the refined tokens (DESIGN.md §13): cards on paper, ink text, the kind colors as full fills,
// and the system's red only in the record disc's dot. Data comes from the snapshot the app writes
// (WidgetSnapshot.swift). Tinted and clear Home Screens, the Lock Screen, and StandBy at night draw one color: the
// record disc, the bars, and today's bar are `widgetAccentable()`, and shape and type carry the design.
//
// iPhone buttons run App Intents: Record is `RecordVoiceNoteIntent` (records in place behind the recording's Live
// Activity when iOS allows, else opens Verbose to record) and Dictate is `StartKeyboardSessionIntent`. Mac widgets
// open verbatim:// links in the app (WidgetLink).

// MARK: - Data

struct HomeEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

enum HomeData {
    /// Now, read from the App Group. The widget gallery shows sample rows until there's something of your own.
    static func entry(now: Date = Date(), preview: Bool = false) -> HomeEntry {
        var snap = WidgetSnapshotStore.read()
        if preview, snap?.recent.isEmpty ?? true { snap = sample(now: now) }
        return HomeEntry(date: now, snapshot: snap)
    }

    /// Now, and again at midnight (Today and Yesterday move on, today's bar moves, and a new week starts at 0). The app
    /// reloads the widgets whenever a recording or a dictation changes.
    static func timeline(calendar: Calendar = .current) -> Timeline<HomeEntry> {
        let now = Date()
        let first = entry(now: now)
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86_400)
        var next = first
        next.date = midnight
        return Timeline(entries: [first, next], policy: .after(midnight.addingTimeInterval(60)))
    }

    /// The widget gallery's rows: made-up, neutral examples.
    static func sample(now: Date = Date()) -> WidgetSnapshot {
        let rows: [(String, Double, Double, WidgetSnapshot.Item.Source, String)] = [
            ("Weekly planning call", -1.2, 939, .app, "Meeting"),
            ("App feature ideas", -2.4, 470, .voice, "Voice note"),
            ("Errands and a long walk", -21, 1531, .voice, "Journal"),
            ("Product walkthrough", -26, 412, .link, "Video"),
            ("Notes for the newsletter", -30, 95, .dictation, "Dictation"),
        ]
        let items = rows.map { r in
            WidgetSnapshot.Item(id: UUID(), title: r.0, date: now.addingTimeInterval(r.1 * 3600), duration: r.2, source: r.3, label: r.4)
        }
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let words = [420, 610, 380, 900, 1310, 0, 0]
        let entries = words.enumerated().compactMap { i, w -> (date: Date, words: Int)? in
            guard let d = cal.date(byAdding: .hour, value: i * 24 + 12, to: start), d <= now else { return nil }
            return (d, w)
        }
        return WidgetSnapshot.make(items: items, kept: 46, entries: entries, now: now, calendar: cal)
    }
}

struct HomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry {
        HomeEntry(date: Date(), snapshot: HomeData.sample())
    }
    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        completion(HomeData.entry(preview: context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        completion(HomeData.timeline())
    }
}

/// This week's configuration. It has no options now: the Color option belonged to a design that's gone. The widget
/// keeps its intent configuration so widgets already placed keep working.
struct WeekWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "This week"
    static var description = IntentDescription("Words you dictated this week, day by day.")

    init() {}
}

struct WeekProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HomeEntry {
        HomeEntry(date: Date(), snapshot: HomeData.sample())
    }
    func snapshot(for configuration: WeekWidgetIntent, in context: Context) async -> HomeEntry {
        HomeData.entry(preview: context.isPreview)
    }
    func timeline(for configuration: WeekWidgetIntent, in context: Context) async -> Timeline<HomeEntry> {
        HomeData.timeline()
    }
}

// MARK: - Widgets

struct RecordDictateWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.widget.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HomeProvider()) { entry in
            RecordDictateView(entry: entry)
        }
        .configurationDisplayName("Record and dictate")
        #if os(iOS)
        .description("Start a voice note or a dictation session with one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        #else
        .description("Start a voice note or a dictation on this Mac with one click.")
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}

struct RecentRecordingsWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.widget.recent"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HomeProvider()) { entry in
            RecentView(entry: entry)
        }
        .configurationDisplayName("Recent recordings")
        .description("Your latest recordings and dictations. Open one to read its transcript.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct WeekWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.widget.week"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: WeekWidgetIntent.self, provider: WeekProvider()) { entry in
            WeekView(entry: entry)
        }
        .configurationDisplayName("This week")
        .description("Words you dictated this week, day by day.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickCaptureWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.widget.capture"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HomeProvider()) { entry in
            QuickCaptureView(entry: entry)
        }
        .configurationDisplayName("New thought")
        #if os(iOS)
        .description("Starts a thought at once, behind a Live Activity, without opening Verbose. It lands on today's Thoughts page.")
        #else
        .description("Starts a thought at once, without leaving the app you're in. It lands on today's Thoughts page.")
        #endif
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Taps

/// Record: an App Intent on iPhone; a link on the Mac (`widgetURL` for a small widget, which is one tap target).
private struct RecordTap<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var body: some View {
        #if os(iOS)
        Button(intent: RecordVoiceNoteIntent()) { label() }.buttonStyle(.plain)
        #else
        MacTap(link: .record) { label() }
        #endif
    }
}

/// Dictate: starts a keyboard session on iPhone; starts a dictation on the Mac.
private struct DictateTap<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var body: some View {
        #if os(iOS)
        Button(intent: StartKeyboardSessionIntent()) { label() }.buttonStyle(.plain)
        #else
        MacTap(link: .dictate) { label() }
        #endif
    }
}

#if os(macOS)
/// A small widget is one tap target (`widgetURL`); medium and large ones hold links.
private struct MacTap<Label: View>: View {
    var link: WidgetLink
    @ViewBuilder var label: () -> Label
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family == .systemSmall {
            label().widgetURL(link.url)
        } else {
            Link(destination: link.url) { label() }
        }
    }
}
#endif

// MARK: - Rendering helpers

/// What a widget view needs to pick its colors: whether the system draws full color (not tinted, clear, vibrant, or
/// dimmed), and whether its background shows (not in StandBy or on the Lock Screen).
private struct Skin {
    var mode: WidgetRenderingMode
    var showsBackground: Bool

    var full: Bool { mode == .fullColor }
    /// Text on a kind color's fill: the fill's ink, or the system's primary when the fill isn't drawn.
    var onPanel: Color { full && showsBackground ? Refined.onFill : .primary }
    /// Text on the card: the reading ink, or the system's primary in one-color modes.
    var text: Color { full ? Refined.ink : .primary }
    /// Secondary text on the card.
    var meta: Color { full ? Refined.mute : .secondary }
}

private struct SkinReader<Content: View>: View {
    @ViewBuilder var content: (Skin) -> Content
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    var body: some View { content(Skin(mode: mode, showsBackground: showsBackground)) }
}

/// The record button: an ink disc with the system's red dot, as in the app. In one-color modes, a ring around a dot,
/// accentable.
private struct RecordDisc: View {
    var size: CGFloat
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        Group {
            if mode != .fullColor {
                ZStack {
                    Circle().strokeBorder(lineWidth: size * 0.16)
                    Circle().frame(width: size * 0.36, height: size * 0.36)
                }
                .widgetAccentable()
            } else {
                Circle().fill(Refined.onFill)
                    .overlay(Circle().fill(Refined.recordRed).frame(width: size * 0.39, height: size * 0.39))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Dictate's mark: the dictation waves.
private struct DictateMark: View {
    var skin: Skin
    var size: CGFloat
    var body: some View {
        BrandGlyph(art: .iconDictations, color: skin.onPanel, minLineWidth: 1.4).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Mon to Sun (or Sun to Sat): bars scaled to the week's busiest day, today in the accent, days to come as short dashes.
private struct WeekBars: View {
    var week: WidgetSnapshot.Week
    var today: Int?
    var bar: Color
    var todayColor: Color
    var spacing: CGFloat = 3

    var body: some View {
        let peak = max(1, week.days.max() ?? 0)
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(week.days.enumerated()), id: \.offset) { i, words in
                    let future = today.map { i > $0 } ?? false
                    let h = future ? 2.5 : max(3, g.size.height * CGFloat(words) / CGFloat(peak))
                    let shape = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    if i == today {
                        shape.fill(todayColor).frame(height: h).widgetAccentable()
                    } else {
                        shape.fill(bar.opacity(future ? 0.35 : (words == 0 ? 0.45 : 1))).frame(height: h)
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(barsLabel)
    }

    private var barsLabel: String {
        let busiest = week.days.max() ?? 0
        return busiest == 0 ? "No dictation this week yet" : "Busiest day: \(busiest.formatted()) words"
    }
}

/// S M T W T F S, from the calendar's first weekday, in SF Pro Rounded.
private struct DayLetters: View {
    var count: Int
    var color: Color
    var spacing: CGFloat = 3
    var body: some View {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                Text(symbols[(cal.firstWeekday - 1 + i) % symbols.count])
                    .font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(color)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Record and dictate

private struct RecordDictateView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        SkinReader { skin in
            #if os(iOS)
            switch family {
            case .accessoryCircular: circular(skin)
            case .accessoryRectangular: rectangular(skin)
            case .systemMedium: medium(skin)
            default: small(skin)
            }
            #else
            if family == .systemMedium { medium(skin) } else { small(skin) }
            #endif
        }
    }

    // Small: the Record button alone (and StandBy).
    private func small(_ skin: Skin) -> some View {
        RecordTap { RecordPanel(skin: skin) }
            .containerBackground(for: .widget) { Refined.persimmon }
            .accessibilityLabel("Record a voice note")
    }

    // Medium: Record and Dictate side by side.
    private func medium(_ skin: Skin) -> some View {
        HStack(spacing: 10) {
            RecordTap { tile(skin, record: true) }.accessibilityLabel("Record a voice note")
            DictateTap { tile(skin, record: false) }
                #if os(iOS)
                .accessibilityLabel("Start a dictation session")
                #else
                .accessibilityLabel("Start dictating")
                #endif
        }
        .containerBackground(for: .widget) { Refined.paper }
    }

    private func tile(_ skin: Skin, record: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let fill = skin.full ? (record ? Refined.persimmon : Refined.butter) : Color.primary.opacity(0.1)
        return VStack(alignment: .leading, spacing: 0) {
            if record {
                // On persimmon, ink text is semibold 14 or larger (DESIGN.md §1.5).
                Text("Voice note").font(.system(size: 14, weight: .semibold)).foregroundStyle(skin.onPanel).lineLimit(1)
            } else {
                DictateMark(skin: skin, size: 18)
            }
            Spacer(minLength: 4)
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(record ? "Record" : "Dictate").font(Refined.serif(23)).foregroundStyle(skin.onPanel).lineLimit(1).minimumScaleFactor(0.8)
                    if !record {
                        #if os(iOS)
                        Text("Into any app").font(.system(size: 12)).foregroundStyle(skin.onPanel).lineLimit(1)
                        #else
                        Text("Into the app in front").font(.system(size: 12)).foregroundStyle(skin.onPanel).lineLimit(1)
                        #endif
                    }
                }
                Spacer(minLength: 0)
                if record { RecordDisc(size: 34) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: shape)
    }

    #if os(iOS)
    // Lock Screen circular: the record disc.
    private func circular(_ skin: Skin) -> some View {
        RecordTap {
            ZStack {
                AccessoryWidgetBackground()
                RecordDisc(size: 28)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel("Record a voice note")
    }

    // Lock Screen rectangular: Record and Dictate.
    private func rectangular(_ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                BarsMark(color: .primary).frame(width: 12, height: 12).widgetAccentable()
                Text("Verbose").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            HStack(spacing: 6) {
                RecordTap { lockPill("Record", record: true) }.accessibilityLabel("Record a voice note")
                DictateTap { lockPill("Dictate", record: false) }.accessibilityLabel("Start a dictation session")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }

    private func lockPill(_ title: String, record: Bool) -> some View {
        HStack(spacing: 4) {
            if record {
                Circle().frame(width: 7, height: 7).widgetAccentable()
            } else {
                BrandGlyph(art: .iconDictations, color: .primary, minLineWidth: 1.2).frame(width: 10, height: 10)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(AccessoryWidgetBackground().clipShape(Capsule()))
    }
    #endif
}

/// The Record panel: "Voice note" (what Record makes, as on the medium widget's tile and Home's recorder), the signal
/// rings, "Record" in the serif, and the record disc. Not "Record a thought": a thought is its own kind with its own
/// widget (New thought), and this button records a voice note. The label is SF Pro semibold 14 in the fill's ink, the
/// smallest ink text that reads on persimmon (DESIGN.md §1.5).
private struct RecordPanel: View {
    var skin: Skin
    var body: some View {
        ZStack(alignment: .topTrailing) {
            SignalRings(color: skin.onPanel.opacity(0.55))
                .frame(width: 92, height: 92)
                .offset(x: 26, y: -30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Voice note").font(.system(size: 14, weight: .semibold)).foregroundStyle(skin.onPanel).lineLimit(1)
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 4) {
                    Text("Record").font(Refined.serif(26)).foregroundStyle(skin.onPanel).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    RecordDisc(size: 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Recent recordings

private struct RecentView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    private var rows: [WidgetSnapshot.Item] {
        Array((entry.snapshot?.recent ?? []).prefix(family == .systemLarge ? 5 : 3))
    }

    var body: some View {
        SkinReader { skin in
            VStack(alignment: .leading, spacing: 0) {
                header(skin)
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    Text("Your recordings and dictations show up here.")
                        .font(Refined.serif(15)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Rectangle().fill(skin.full ? Refined.separator : Color.primary.opacity(0.1)).frame(height: 0.5) }
                        Link(destination: WidgetLink.transcript(item.id).url) { row(item, skin) }
                    }
                    Spacer(minLength: 0)
                    if family == .systemLarge, let snap = entry.snapshot { footer(snap, skin) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) { Refined.card }
        }
    }

    private func header(_ skin: Skin) -> some View {
        let kept = entry.snapshot?.kept ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("Recent recordings").font(Refined.serif(16)).foregroundStyle(skin.text)
            Spacer(minLength: 4)
            if kept > 0 { Text("\(kept.formatted()) kept").font(Refined.mono(12)).foregroundStyle(skin.meta) }
        }
        .lineLimit(1)
        .padding(.bottom, 6)
    }

    private func row(_ item: WidgetSnapshot.Item, _ skin: Skin) -> some View {
        let day = WidgetSnapshot.dayLabel(item.date, now: entry.date)
        let length = WidgetSnapshot.lengthLabel(item.duration)
        return HStack(spacing: 8) {
            SourceChip(source: item.source, skin: skin).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(Refined.serif(15)).foregroundStyle(skin.text).lineLimit(1).privacySensitive()
                Text("\(item.label) · \(day)").font(.system(size: 11)).foregroundStyle(skin.meta).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !length.isEmpty { Text(length).font(Refined.mono(12)).foregroundStyle(skin.text) }
        }
        .padding(.vertical, 4)
    }

    private func footer(_ snap: WidgetSnapshot, _ skin: Skin) -> some View {
        let week = snap.week(at: entry.date)
        return VStack(spacing: 6) {
            Rectangle().fill(skin.full ? Refined.separator : Color.primary.opacity(0.1)).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("This week").font(Refined.mono(12)).foregroundStyle(skin.meta)
                Text("\(week.words.formatted()) \(week.words == 1 ? "word" : "words")").font(Refined.serif(17)).foregroundStyle(skin.text)
                Spacer(minLength: 4)
                WeekBars(week: week, today: WidgetSnapshot.todayIndex(in: week, now: entry.date),
                         bar: skin.full ? Refined.waveRest : Color.primary.opacity(0.5),
                         todayColor: skin.full ? Refined.persimmon : .primary, spacing: 2)
                    .frame(width: 44, height: 14)
            }
        }
    }
}

/// The source chip: persimmon for voice notes, a quiet square for links, sage for files, petal for app audio, butter
/// for dictation (DESIGN.md §1: colored by source only). One color in tinted and clear modes.
private struct SourceChip: View {
    var source: WidgetSnapshot.Item.Source
    var skin: Skin

    private var fill: Color {
        switch source {
        case .voice: return Refined.persimmon
        case .link: return Refined.neutralSquare
        case .file: return Refined.sage
        case .app: return Refined.petal
        case .dictation: return Refined.butter
        }
    }
    private var art: BrandArt {
        switch source {
        case .voice, .app: return .iconVoice
        case .link: return .iconLinks
        case .file: return .document
        case .dictation: return .iconDictations
        }
    }

    /// The fill's ink on a kind color, the reading ink on a link's quiet square, the system's primary in one color.
    private var glyphColor: Color {
        guard skin.full else { return .primary }
        return source == .link ? Refined.ink : Refined.onFill
    }

    var body: some View {
        ZStack {
            Circle().fill(skin.full ? fill : Color.primary.opacity(0.18))
            BrandGlyph(art: art, color: glyphColor, minLineWidth: 1.1)
                .padding(5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - This week

/// A card with "This week", the serif number, and the bars, today's in persimmon.
private struct WeekView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let week = entry.snapshot?.week(at: entry.date) ?? WidgetSnapshot.week(entries: [], now: entry.date)
        let today = WidgetSnapshot.todayIndex(in: week, now: entry.date)
        SkinReader { skin in
            content(week, today, skin)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func content(_ week: WidgetSnapshot.Week, _ today: Int?, _ skin: Skin) -> some View {
        let lead = VStack(alignment: .leading, spacing: 0) {
            Text("This week").font(Refined.mono(12)).foregroundStyle(skin.meta)
            Spacer(minLength: 4)
            Text(week.words, format: .number).font(Refined.serif(30)).foregroundStyle(skin.text).lineLimit(1).minimumScaleFactor(0.5)
            Text(week.words == 1 ? "word" : "words").font(Refined.serif(22)).foregroundStyle(skin.text).lineLimit(1)
        }
        let bars = WeekBars(week: week, today: today, bar: skin.full ? Refined.waveRest : Color.primary.opacity(0.5),
                            todayColor: skin.full ? Refined.persimmon : .primary)
        Group {
            if family == .systemMedium {
                HStack(alignment: .bottom, spacing: 18) {
                    lead.frame(maxHeight: .infinity, alignment: .topLeading)
                    VStack(spacing: 3) {
                        bars
                        DayLetters(count: week.days.count, color: skin.meta)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 76)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    lead
                    bars.frame(width: 64, height: 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { Refined.card }
    }
}

// MARK: - Quick capture

private struct QuickCaptureView: View {
    var entry: HomeEntry

    var body: some View {
        SkinReader { skin in
            Button(intent: NewThoughtIntent()) { content(skin) }
                .buttonStyle(.plain)
                .accessibilityLabel("New thought")
                .containerBackground(for: .widget) { Refined.persimmonTint }
        }
    }

    private func content(_ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            mark(skin)
            Spacer(minLength: 4)
            Text("New thought").font(Refined.serif(22)).foregroundStyle(skin.text).lineLimit(1)
            Text("Starts recording at once").font(.system(size: 12)).foregroundStyle(skin.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mark(_ skin: Skin) -> some View {
        ZStack {
            Circle().fill(skin.full ? Refined.persimmon : Color.primary.opacity(0.18))
            BrandGlyph(art: .iconThought, color: skin.full ? Refined.onFill : .primary, minLineWidth: 1.3)
                .padding(8).widgetAccentable()
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
// MARK: - Thoughts (Mac)

/// New thought from a desktop widget: asks the running app to start a thought, so the app you're in stays in front
/// (Flow/Thoughts.swift listens). When Verbose isn't running, it opens with verbatim://newthought instead.
struct NewThoughtIntent: AppIntent {
    static var title: LocalizedStringResource = "New thought"
    static var description = IntentDescription("Starts a thought in Verbose without bringing it forward.")
    static var openAppWhenRun = false
    static let appBundleID = "co.stumpandroot.verbatim"
    static let request = Notification.Name("co.stumpandroot.verbatim.newThought")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.appBundleID).isEmpty {
                _ = NSWorkspace.shared.open(WidgetLink.newThought.url)
            } else {
                DistributedNotificationCenter.default().postNotificationName(Self.request, object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
        return .result()
    }
}
#endif

// MARK: - Thoughts

struct TodayThoughtsWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.widget.thoughts"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ThoughtsProvider()) { entry in
            TodayThoughtsView(entry: entry)
        }
        .configurationDisplayName("Today's thoughts")
        .description("Today's Thoughts page: the last two thoughts, and New thought. Tap a thought to open the page.")
        .supportedFamilies([.systemMedium])
    }
}

/// Now, and again when today's page ends (the app writes a fresh snapshot as thoughts come in).
struct ThoughtsProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry { sample() }
    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        let e = HomeData.entry()
        completion(context.isPreview && (e.snapshot?.today?.count ?? 0) == 0 ? sample() : e)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        let first = HomeData.entry()
        let end = first.snapshot?.thoughts(at: first.date)?.end
            ?? Calendar.current.nextDate(after: first.date, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? first.date.addingTimeInterval(86_400)
        var next = first
        next.date = end
        completion(Timeline(entries: [first, next], policy: .after(end.addingTimeInterval(60))))
    }

    /// The gallery's page: made-up, neutral thoughts.
    private func sample() -> HomeEntry {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        var snap = HomeData.sample(now: now)
        snap.today = WidgetSnapshot.todayThoughts(start: start, end: start.addingTimeInterval(86_400), thoughts: [
            (UUID(), now.addingTimeInterval(-3_600), "Ask whether the onboarding video can drop to sixty seconds.", false),
            (UUID(), now.addingTimeInterval(-1_200), "Day headers could use the mono date, like the website.", false),
            (UUID(), now.addingTimeInterval(-60), "", true),
        ])
        return HomeEntry(date: now, snapshot: snap)
    }
}

private struct TodayThoughtsView: View {
    var entry: HomeEntry

    var body: some View {
        let today = entry.snapshot?.thoughts(at: entry.date)
        SkinReader { skin in
            VStack(alignment: .leading, spacing: 6) {
                header(today, skin)
                let lines = (today?.latest ?? []).filter { !$0.text.isEmpty }
                if lines.isEmpty {
                    Spacer(minLength: 0)
                    Text("Nothing on today's page yet.").font(Refined.serif(15)).foregroundStyle(.secondary)
                } else {
                    ForEach(lines) { line in
                        Link(destination: WidgetLink.thought.url) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.date, format: .dateTime.hour().minute())
                                    .font(Refined.mono(12)).foregroundStyle(skin.meta)
                                Text(line.text).font(.system(size: 13)).foregroundStyle(skin.text).lineLimit(1).privacySensitive()
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    let n = today?.transcribing ?? 0
                    Text(n == 0 ? "" : (n == 1 ? "One transcribing" : "\(n) transcribing")).font(.system(size: 11.5)).foregroundStyle(skin.meta)
                    Spacer(minLength: 4)
                    Button(intent: NewThoughtIntent()) { newThought(skin) }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) { Refined.card }
        }
    }

    private func header(_ today: WidgetSnapshot.TodayThoughts?, _ skin: Skin) -> some View {
        let count = today?.count ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Today's thoughts").font(Refined.serif(16)).foregroundStyle(skin.text)
            if count > 0 { Text("\(count)").font(Refined.mono(12)).foregroundStyle(skin.meta) }
            Spacer(minLength: 4)
            Text(entry.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(Refined.mono(12)).foregroundStyle(skin.meta)
        }
        .lineLimit(1)
    }

    /// The New thought pill: persimmon (the record action may carry the one saturated fill), with the fill's ink.
    private func newThought(_ skin: Skin) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(skin.full ? Refined.onFill : Color.primary.opacity(0.2))
                BrandGlyph(art: .iconThought, color: skin.full ? Refined.persimmon : .primary, minLineWidth: 1.1).padding(3)
            }
            .frame(width: 18, height: 18)
            Text("New thought").font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(skin.full ? Refined.onFill : .primary)
        }
        .padding(.leading, 5).padding(.trailing, 11).frame(height: 28)
        .background(Capsule().fill(skin.full ? Refined.persimmon : Color.primary.opacity(0.12)))
        .widgetAccentable()
        .accessibilityLabel("New thought")
    }
}

#if os(iOS)
/// Thoughts on the Lock Screen: the circular widget starts a thought; the rectangular one shows how many thoughts
/// today's page has, never the words, because anyone can read a Lock Screen. Both run `NewThoughtIntent`.
struct ThoughtsLockWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.ios.widget.thoughtsLock"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ThoughtsProvider()) { entry in
            ThoughtsLockView(entry: entry)
        }
        // Not "New thought": the Home Screen's small widget has that name (QuickCaptureWidget).
        .configurationDisplayName("Thoughts")
        .description("Starts a thought from the Lock Screen. The rectangular widget shows today's count, never your words.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

private struct ThoughtsLockView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let count = entry.snapshot?.thoughts(at: entry.date)?.count ?? 0
        Button(intent: NewThoughtIntent()) {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image("thought").font(.system(size: 24, weight: .medium)).widgetAccentable()
                }
                .accessibilityLabel("New thought")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image("thought").font(.system(size: 13, weight: .semibold))
                        Text("Thoughts").font(.system(size: 14, weight: .semibold))
                    }
                    .widgetAccentable()
                    Text(ThoughtRules.lockCount(count)).font(.system(size: 17, weight: .semibold)).monospacedDigit().lineLimit(1)
                    Text("Tap to add one").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Starts a thought")
            }
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
    }
}
#endif
