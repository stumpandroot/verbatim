import SwiftUI
import WidgetKit
import AppIntents
#if os(macOS)
import AppKit
#endif

// The Home Screen and desktop widgets (approved mockup "Premium", section 04), shared by the iPhone widget extension
// (VerbatimWidgets) and the Mac's (VerbatimMacWidgets):
//
// 1. Record and Dictate. iPhone: small (Record), medium (both), Lock Screen circular (Record) and rectangular (both),
//    and StandBy (small). Mac: small and medium.
// 2. Recent recordings: medium (three) and large (five, with This week at the foot). Each row opens its transcript.
// 3. This week: small and medium. Native draws a gradient card (the color is the widget's one option); Verbose style
//    an outlined paper card with the serif number.
// 4. New thought (the Quick capture widget's kind): small. Starts a thought (`NewThoughtIntent`): on iPhone it records in
//    place behind a Live Activity when iOS allows it; on the Mac it starts in the running app without bringing it
//    forward.
// 5. Today's thoughts: medium. Today's Thoughts page, its last two thoughts (marked `privacySensitive()`), and New
//    thought. Tap a thought to open today's page.
// 6. Thoughts on the Lock Screen (iPhone): circular, New thought; rectangular, today's count only, never the words.
//
// Widgets follow the look chosen in Verbose (DESIGN.md §13, item 8): iPhone reads `AppLook` from the App Group; the Mac reads
// the look from the snapshot, since the Mac keeps it in the app's own defaults. Data comes from the snapshot the app
// writes (WidgetSnapshot.swift). Tinted and clear Home Screens, the Lock Screen, and StandBy at night draw one color:
// the record disc, the bars, and today's bar are `widgetAccentable()`, and shape and type carry the look.
//
// iPhone buttons run App Intents: Record is `RecordVoiceNoteIntent` (records in place behind the recording's Live
// Activity when iOS allows, else opens Verbose to record) and Dictate is `StartKeyboardSessionIntent`. Mac widgets
// open verbatim:// links in the app (WidgetLink).

// MARK: - Data

struct HomeEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var look: AppLook
    var tint: WidgetTint = .persimmon
}

enum HomeData {
    /// The look a widget draws: the App Group's live value on iPhone, the snapshot's on Mac.
    static func look(_ snapshot: WidgetSnapshot?) -> AppLook {
        #if os(iOS)
        return AppLook.current
        #else
        return snapshot.flatMap { AppLook(rawValue: $0.look) } ?? .verbose
        #endif
    }

    /// Now, read from the App Group. The widget gallery shows sample rows until there's something of your own.
    static func entry(now: Date = Date(), preview: Bool = false, tint: WidgetTint = .persimmon) -> HomeEntry {
        var snap = WidgetSnapshotStore.read()
        if preview, snap?.recent.isEmpty ?? true { snap = sample(look: look(snap).rawValue, now: now) }
        return HomeEntry(date: now, snapshot: snap, look: look(snap), tint: tint)
    }

    /// Now, and again at midnight (Today and Yesterday move on, today's bar moves, and a new week starts at 0). The app
    /// reloads the widgets whenever a recording, a dictation, or the look changes.
    static func timeline(tint: WidgetTint = .persimmon, calendar: Calendar = .current) -> Timeline<HomeEntry> {
        let now = Date()
        let first = entry(now: now, tint: tint)
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86_400)
        var next = first
        next.date = midnight
        return Timeline(entries: [first, next], policy: .after(midnight.addingTimeInterval(60)))
    }

    /// The widget gallery's rows: made-up, neutral examples.
    static func sample(look: String, now: Date = Date()) -> WidgetSnapshot {
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
        return WidgetSnapshot.make(items: items, kept: 46, entries: entries, look: look, now: now, calendar: cal)
    }
}

struct HomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry {
        HomeEntry(date: Date(), snapshot: HomeData.sample(look: AppLook.verbose.rawValue), look: .verbose)
    }
    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        completion(HomeData.entry(preview: context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        completion(HomeData.timeline())
    }
}

// MARK: - This week's color

/// The Native look's gradient for This week: the four warm brand colors.
enum WidgetTint: String, AppEnum {
    case persimmon, inkGreen, sage, rose

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Color"
    static var caseDisplayRepresentations: [WidgetTint: DisplayRepresentation] = [
        .persimmon: "Persimmon", .inkGreen: "Ink green", .sage: "Sage", .rose: "Rose",
    ]

    /// The Premium Native gradients the iPhone's cards use (`PremiumInk` in Tokens.swift), following light and dark.
    var colors: [Color] {
        switch self {
        case .persimmon: return PremiumInk.stops(PremiumInk.persimmonLight, PremiumInk.persimmonDark)
        case .inkGreen: return PremiumInk.stops(PremiumInk.inkLight, PremiumInk.inkDark)
        case .sage: return PremiumInk.stops(PremiumInk.sageLight, PremiumInk.sageDark)
        case .rose: return PremiumInk.stops(PremiumInk.roseLight, PremiumInk.roseDark)
        }
    }
    /// Solid white on all four, as on the iPhone's gradient cards (mac/tools/test-premium-phone.sh checks the contrast).
    var text: Color { .white }
}

struct WeekWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "This week"
    static var description = IntentDescription("Words you dictated this week, day by day.")

    @Parameter(title: "Color in the Native look", default: .persimmon)
    var tint: WidgetTint

    init() {}
}

struct WeekProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HomeEntry {
        HomeEntry(date: Date(), snapshot: HomeData.sample(look: AppLook.verbose.rawValue), look: .verbose)
    }
    func snapshot(for configuration: WeekWidgetIntent, in context: Context) async -> HomeEntry {
        HomeData.entry(preview: context.isPreview, tint: configuration.tint)
    }
    func timeline(for configuration: WeekWidgetIntent, in context: Context) async -> Timeline<HomeEntry> {
        HomeData.timeline(tint: configuration.tint)
    }
}

// MARK: - Widgets

struct RecordDictateWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.widget.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HomeProvider()) { entry in
            RecordDictateView(entry: entry)
        }
        .configurationDisplayName("Record and Dictate")
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

// MARK: - Look helpers

/// What a widget view needs to pick its colors: the look, whether the system draws full color (not tinted, clear,
/// vibrant, or dimmed), and whether its background shows (not in StandBy or on the Lock Screen).
private struct Skin {
    var look: AppLook
    var mode: WidgetRenderingMode
    var showsBackground: Bool

    var full: Bool { mode == .fullColor }
    var native: Bool { look == .native }
    /// Text on a Verbose style color panel: ink, or the system's primary when the panel isn't drawn.
    var onPanel: Color { full && showsBackground ? Ink.inkFixed : .primary }
}

private struct SkinReader<Content: View>: View {
    var look: AppLook
    @ViewBuilder var content: (Skin) -> Content
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    var body: some View { content(Skin(look: look, mode: mode, showsBackground: showsBackground)) }
}

// brand: native begin
/// Native look surfaces: the system's card, and a tile tinted with the accent.
private enum NativeWidget {
    static var card: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }
    static let tile = Ink.nativeAccent.opacity(0.12)
    static let secondary = Color.secondary
}
// brand: native end

/// The record button. Verbose style: an ink disc with a persimmon dot. Native: the persimmon sphere. In one-color
/// modes: a ring around a dot (Verbose) or a solid disc (Native), both accentable.
private struct RecordDisc: View {
    var look: AppLook
    var size: CGFloat
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        Group {
            if mode != .fullColor {
                if look == .native {
                    Circle().widgetAccentable()
                } else {
                    ZStack {
                        Circle().strokeBorder(lineWidth: size * 0.16)
                        Circle().frame(width: size * 0.36, height: size * 0.36)
                    }
                    .widgetAccentable()
                }
            } else if look == .native {
                // The iPhone's Premium record disc (`PremiumInk.disc`: highlight, brand persimmon, shade).
                Circle().fill(RadialGradient(colors: PremiumInk.discColors, center: UnitPoint(x: 0.34, y: 0.28),
                                             startRadius: 0, endRadius: size * 0.69))
                    .shadow(color: Ink.persimmonFixed.opacity(0.35), radius: size * 0.1, y: size * 0.05)
            } else {
                Circle().fill(Ink.inkFixed)
                    .overlay(Circle().fill(Ink.persimmonFixed).frame(width: size * 0.36, height: size * 0.36))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Dictate's mark. Verbose style: the dictation waves. Native: a microphone on an accent disc.
private struct DictateMark: View {
    var skin: Skin
    var size: CGFloat
    var body: some View {
        Group {
            if skin.native {
                ZStack {
                    if skin.full {
                        Circle().fill(Ink.nativeAccent)
                    } else {
                        Circle().strokeBorder(lineWidth: max(1.5, size * 0.05)).widgetAccentable()
                    }
                    Image(systemName: "mic.fill").font(.system(size: size * 0.42, weight: .semibold))   // brand: native
                        .foregroundStyle(skin.full ? Color.white : Color.primary)
                }
                .frame(width: size, height: size)
            } else {
                BrandGlyph(art: .iconDictations, color: skin.onPanel, minLineWidth: 1.4).frame(width: size, height: size)
            }
        }
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

/// S M T W T F S, from the calendar's first weekday.
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

// MARK: - Record and Dictate

private struct RecordDictateView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        SkinReader(look: entry.look) { skin in
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
    @ViewBuilder private func small(_ skin: Skin) -> some View {
        if skin.native {
            RecordTap {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    RecordDisc(look: .native, size: 66)
                    Text("Record").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Text("Voice note").font(.system(size: 12)).foregroundStyle(NativeWidget.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .containerBackground(for: .widget) { NativeWidget.card }
            .accessibilityLabel("Record a voice note")
        } else {
            RecordTap { VerboseRecordPanel(skin: skin) }
                .containerBackground(for: .widget) { Ink.panelRecord }
                .accessibilityLabel("Record a voice note")
        }
    }

    // Medium: Record and Dictate side by side.
    @ViewBuilder private func medium(_ skin: Skin) -> some View {
        HStack(spacing: 10) {
            RecordTap { tile(skin, record: true) }.accessibilityLabel("Record a voice note")
            DictateTap { tile(skin, record: false) }
                #if os(iOS)
                .accessibilityLabel("Start a dictation session")
                #else
                .accessibilityLabel("Start dictating")
                #endif
        }
        .containerBackground(for: .widget) { skin.native ? NativeWidget.card : Ink.paper }
    }

    @ViewBuilder private func tile(_ skin: Skin, record: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if skin.native {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if record { RecordDisc(look: .native, size: 50) } else { DictateMark(skin: skin, size: 50) }
                Text(record ? "Record" : "Dictate").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(skin.full ? NativeWidget.tile : Color.primary.opacity(0.1), in: shape)
        } else {
            let fill = skin.full ? (record ? Ink.panelRecord : Ink.panelButter) : Color.primary.opacity(0.1)
            VStack(alignment: .leading, spacing: 0) {
                if record {
                    Text("Voice note").font(Ink.mono(11)).foregroundStyle(skin.onPanel.opacity(0.75))
                } else {
                    DictateMark(skin: skin, size: 18)
                }
                Spacer(minLength: 4)
                HStack(alignment: .bottom, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record ? "Record" : "Dictate").font(Ink.serif(23)).foregroundStyle(skin.onPanel).lineLimit(1).minimumScaleFactor(0.8)
                        if !record {
                            #if os(iOS)
                            Text("Into any app").font(.system(size: 11)).foregroundStyle(skin.onPanel.opacity(0.75)).lineLimit(1)
                            #else
                            Text("Into the app in front").font(.system(size: 11)).foregroundStyle(skin.onPanel.opacity(0.75)).lineLimit(1)
                            #endif
                        }
                    }
                    Spacer(minLength: 0)
                    if record { RecordDisc(look: .verbose, size: 34) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill, in: shape)
        }
    }

    #if os(iOS)
    // Lock Screen circular: the record disc.
    private func circular(_ skin: Skin) -> some View {
        RecordTap {
            ZStack {
                AccessoryWidgetBackground()
                RecordDisc(look: skin.look, size: 28)
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

/// Verbose style's Record panel: Ready, the signal rings, "Record a thought" in the serif, and the ink disc.
private struct VerboseRecordPanel: View {
    var skin: Skin
    var body: some View {
        ZStack(alignment: .topTrailing) {
            SignalRings(color: skin.onPanel.opacity(0.55))
                .frame(width: 92, height: 92)
                .offset(x: 26, y: -30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Ready").font(Ink.mono(11)).foregroundStyle(skin.onPanel.opacity(0.75))
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 4) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Record").font(Ink.serif(26)).foregroundStyle(skin.onPanel).lineLimit(1).minimumScaleFactor(0.8)
                        Text("a voice note").font(Ink.serif(13)).italic().foregroundStyle(skin.onPanel.opacity(0.85))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    RecordDisc(look: .verbose, size: 40)
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
        SkinReader(look: entry.look) { skin in
            VStack(alignment: .leading, spacing: 0) {
                header(skin)
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    Text("Your recordings and dictations show up here.")
                        .font(skin.native ? .system(size: 13) : Ink.serif(15)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
                        Link(destination: WidgetLink.transcript(item.id).url) { row(item, skin) }
                    }
                    Spacer(minLength: 0)
                    if family == .systemLarge, let snap = entry.snapshot { footer(snap, skin) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                if skin.native { NativeWidget.card } else { Ink.card }
            }
        }
    }

    @ViewBuilder private func header(_ skin: Skin) -> some View {
        let kept = entry.snapshot?.kept ?? 0
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if skin.native {
                BarsMark(color: skin.full ? Ink.nativeAccent : .primary).frame(width: 11, height: 11).widgetAccentable()
                Text("Recent recordings").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(skin.full ? Ink.nativeAccent : .primary).widgetAccentable()
                Spacer(minLength: 4)
                if kept > 0 { Text(kept, format: .number).font(.system(size: 12)).monospacedDigit().foregroundStyle(NativeWidget.secondary) }
            } else {
                Text("Recent \(Text("recordings").italic())").font(Ink.serif(16)).foregroundStyle(Ink.ink)
                Spacer(minLength: 4)
                if kept > 0 { Text("\(kept.formatted()) kept").font(Ink.mono(11)).foregroundStyle(Ink.mute) }
            }
        }
        .lineLimit(1)
        .padding(.bottom, 6)
    }

    @ViewBuilder private func row(_ item: WidgetSnapshot.Item, _ skin: Skin) -> some View {
        let day = WidgetSnapshot.dayLabel(item.date, now: entry.date)
        let length = WidgetSnapshot.lengthLabel(item.duration)
        if skin.native {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).privacySensitive()
                Text(nativeMeta(item, day: day, length: length))
                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(NativeWidget.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        } else {
            HStack(spacing: 8) {
                SourceChip(source: item.source, skin: skin).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(Ink.serif(15)).foregroundStyle(Ink.ink).lineLimit(1).privacySensitive()
                    Text("\(item.label) · \(day)").font(.system(size: 11)).foregroundStyle(Ink.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !length.isEmpty { Text(length).font(Ink.mono(11.5)).foregroundStyle(Ink.ink) }
            }
            .padding(.vertical, 4)
        }
    }

    /// The persimmon gradient's deeper half in full color (small white text reads at 4.5:1 across it, as on the
    /// iPhone's Summary card); a quiet wash in one color.
    private func footerFill(_ skin: Skin) -> AnyShapeStyle {
        guard skin.full else { return AnyShapeStyle(Color.primary.opacity(0.12)) }
        let deep = Array(PremiumInk.stops(PremiumInk.persimmonLight, PremiumInk.persimmonDark).dropFirst())
        return AnyShapeStyle(LinearGradient(colors: deep, startPoint: .leading, endPoint: .trailing))
    }

    /// "Today · 9:12 AM · 1:04:12".
    private func nativeMeta(_ item: WidgetSnapshot.Item, day: String, length: String) -> String {
        let time = item.date.formatted(date: .omitted, time: .shortened)
        return [day, time, length].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func footer(_ snap: WidgetSnapshot, _ skin: Skin) -> some View {
        let week = snap.week(at: entry.date)
        if skin.native {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(week.words, format: .number).font(.system(size: 19, weight: .bold, design: .rounded))
                Text(week.words == 1 ? "word this week" : "words this week").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(skin.full ? Color.white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(footerFill(skin), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(spacing: 6) {
                Rectangle().fill(Ink.hairline).frame(height: 1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                    Text("This week").font(Ink.mono(11)).foregroundStyle(Ink.ink)
                    Text("\(week.words.formatted()) \(Text(week.words == 1 ? "word" : "words").italic())").font(Ink.serif(17)).foregroundStyle(Ink.ink)
                    Spacer(minLength: 4)
                    WeekBars(week: week, today: WidgetSnapshot.todayIndex(in: week, now: entry.date), bar: Ink.ink,
                             todayColor: skin.full ? Ink.persimmon : .primary, spacing: 2)
                        .frame(width: 44, height: 14)
                }
            }
        }
    }
}

/// Verbose style's source chip: persimmon for voice notes, an outline for links, sage for files, petal for app
/// audio, butter for dictation (DESIGN.md §1: colored by source only). One color in tinted and clear modes.
private struct SourceChip: View {
    var source: WidgetSnapshot.Item.Source
    var skin: Skin

    /// Nil for a link: an ink outline instead of a fill.
    private var fill: Color? {
        switch source {
        case .voice: return Ink.persimmon
        case .link: return nil
        case .file: return Ink.sage
        case .app: return Ink.petal
        case .dictation: return Ink.butter
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

    /// Ink on a fill (both modes), the theme's ink inside a link's outline, the system's primary in one color.
    private var glyphColor: Color {
        guard skin.full else { return .primary }
        return fill == nil ? Ink.ink : Ink.inkFixed
    }

    var body: some View {
        ZStack {
            if !skin.full {
                Circle().fill(Color.primary.opacity(0.18))
            } else if let fill {
                Circle().fill(fill)
            } else {
                Circle().strokeBorder(Ink.ink, lineWidth: 1.2)
            }
            BrandGlyph(art: art, color: glyphColor, minLineWidth: 1.1)
                .padding(5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - This week

private struct WeekView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let week = entry.snapshot?.week(at: entry.date) ?? WidgetSnapshot.week(entries: [], now: entry.date)
        let today = WidgetSnapshot.todayIndex(in: week, now: entry.date)
        SkinReader(look: entry.look) { skin in
            Group {
                if skin.native { native(week, today, skin) } else { verbose(week, today, skin) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // Native: the Journal-style gradient, a big rounded number, and the mini chart.
    @ViewBuilder private func native(_ week: WidgetSnapshot.Week, _ today: Int?, _ skin: Skin) -> some View {
        let ink: Color = skin.full && skin.showsBackground ? entry.tint.text : .primary
        let lead = VStack(alignment: .leading, spacing: 0) {
            Text("This week").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 2)
            Text(week.words, format: .number).font(.system(size: 34, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(week.words == 1 ? "word" : "words").font(.system(size: 12, weight: .semibold)).opacity(0.85)
        }
        let chart = VStack(spacing: 3) {
            WeekBars(week: week, today: today, bar: ink.opacity(0.55), todayColor: ink)
            DayLetters(count: week.days.count, color: ink.opacity(0.75))
        }
        Group {
            if family == .systemMedium {
                HStack(alignment: .bottom, spacing: 18) {
                    lead.frame(maxHeight: .infinity, alignment: .topLeading)
                    chart.frame(maxWidth: .infinity, maxHeight: 76)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    lead
                    chart.frame(height: 32)
                }
            }
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            LinearGradient(colors: entry.tint.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // Verbose style: a paper card with an ink outline, the serif number, ink bars with today in persimmon.
    @ViewBuilder private func verbose(_ week: WidgetSnapshot.Week, _ today: Int?, _ skin: Skin) -> some View {
        let lead = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 8, height: 8)
                Text("This week").font(Ink.mono(11))
            }
            Spacer(minLength: 4)
            Text(week.words, format: .number).font(Ink.serif(30)).lineLimit(1).minimumScaleFactor(0.5)
            Text(week.words == 1 ? "word" : "words").font(Ink.serif(28)).italic().lineLimit(1)
        }
        let bars = WeekBars(week: week, today: today, bar: Ink.ink, todayColor: skin.full ? Ink.persimmon : .primary)
        Group {
            if family == .systemMedium {
                HStack(alignment: .bottom, spacing: 18) {
                    lead.frame(maxHeight: .infinity, alignment: .topLeading)
                    VStack(spacing: 3) {
                        bars
                        DayLetters(count: week.days.count, color: Ink.mute)
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
        .foregroundStyle(Ink.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            ZStack {
                Ink.card
                ContainerRelativeShape().strokeBorder(Ink.ink, lineWidth: 2)
            }
        }
    }
}

// MARK: - Quick capture

private struct QuickCaptureView: View {
    var entry: HomeEntry

    var body: some View {
        SkinReader(look: entry.look) { skin in
            Button(intent: NewThoughtIntent()) { content(skin) }
                .buttonStyle(.plain)
                .accessibilityLabel("New thought")
                .containerBackground(for: .widget) { background(skin) }
        }
    }

    private let title = ("New", "thought"), detail = "Starts recording at once"

    @ViewBuilder private func background(_ skin: Skin) -> some View {
        if skin.native { NativeWidget.card } else { Ink.persimmonTint }
    }

    @ViewBuilder private func content(_ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            mark(skin)
            Spacer(minLength: 4)
            if skin.native {
                Text("\(title.0) \(title.1)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 12)).foregroundStyle(NativeWidget.secondary)
            } else {
                Text("\(title.0) \(Text(title.1).italic())").font(Ink.serif(22)).foregroundStyle(ink(skin)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(ink(skin).opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The theme's ink on the persimmon tint.
    private func ink(_ skin: Skin) -> Color { skin.full ? Ink.ink : .primary }

    @ViewBuilder private func mark(_ skin: Skin) -> some View {
        let disc: Color = skin.full ? (skin.native ? NativeWidget.tile : Ink.persimmon) : Color.primary.opacity(0.18)
        ZStack {
            Circle().fill(disc)
            BrandGlyph(art: .iconThought, color: skin.full ? (skin.native ? Ink.nativeAccent : Ink.inkFixed) : .primary, minLineWidth: 1.3)
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
        completion(context.isPreview && (e.snapshot?.today?.count ?? 0) == 0 ? sample(look: e.look) : e)
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
    private func sample(look: AppLook = .verbose) -> HomeEntry {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        var snap = HomeData.sample(look: look.rawValue, now: now)
        snap.today = WidgetSnapshot.todayThoughts(start: start, end: start.addingTimeInterval(86_400), thoughts: [
            (UUID(), now.addingTimeInterval(-3_600), "Ask whether the onboarding video can drop to sixty seconds.", false),
            (UUID(), now.addingTimeInterval(-1_200), "Day headers could use the mono date, like the website.", false),
            (UUID(), now.addingTimeInterval(-60), "", true),
        ])
        return HomeEntry(date: now, snapshot: snap, look: look)
    }
}

private struct TodayThoughtsView: View {
    var entry: HomeEntry

    var body: some View {
        let today = entry.snapshot?.thoughts(at: entry.date)
        SkinReader(look: entry.look) { skin in
            VStack(alignment: .leading, spacing: 6) {
                header(today, skin)
                let lines = (today?.latest ?? []).filter { !$0.text.isEmpty }
                if lines.isEmpty {
                    Spacer(minLength: 0)
                    Text("Nothing on today's page yet.").font(skin.native ? .system(size: 13) : Ink.serif(15)).foregroundStyle(.secondary)
                } else {
                    ForEach(lines) { line in
                        Link(destination: WidgetLink.thought.url) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.date, format: .dateTime.hour().minute())
                                    .font(skin.native ? .system(size: 12).monospacedDigit() : Ink.mono(11.5)).foregroundStyle(skin.native ? NativeWidget.secondary : Ink.mute)
                                Text(line.text).font(.system(size: 13)).foregroundStyle(skin.native ? Color.primary : Ink.ink).lineLimit(1).privacySensitive()
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    let n = today?.transcribing ?? 0
                    Text(n == 0 ? "" : (n == 1 ? "One transcribing" : "\(n) transcribing")).font(.system(size: 11.5)).foregroundStyle(skin.native ? NativeWidget.secondary : Ink.mute)
                    Spacer(minLength: 4)
                    Button(intent: NewThoughtIntent()) { newThought(skin) }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                if skin.native { NativeWidget.card } else {
                    ZStack {
                        Ink.card
                        ContainerRelativeShape().strokeBorder(Ink.ink, lineWidth: 2)
                    }
                }
            }
        }
    }

    @ViewBuilder private func header(_ today: WidgetSnapshot.TodayThoughts?, _ skin: Skin) -> some View {
        let count = today?.count ?? 0
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if skin.native {
                Text("Today's thoughts").font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.full ? Ink.nativeAccent : .primary).widgetAccentable()
                if count > 0 { Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(NativeWidget.secondary) }
                Spacer(minLength: 4)
                Text(entry.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(.system(size: 12)).foregroundStyle(NativeWidget.secondary)
            } else {
                Text("Today's \(Text("thoughts").italic())").font(Ink.serif(16)).foregroundStyle(Ink.ink)
                if count > 0 { Text("\(count)").font(Ink.mono(11.5)).foregroundStyle(Ink.mute) }
                Spacer(minLength: 4)
                Text(entry.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(Ink.mono(11.5)).foregroundStyle(Ink.mute)
            }
        }
        .lineLimit(1)
    }

    /// The persimmon pill: the record action, so it may carry the brand's one saturated fill.
    private func newThought(_ skin: Skin) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(skin.full ? Ink.inkFixed : Color.primary.opacity(0.2))
                BrandGlyph(art: .iconThought, color: skin.full ? Ink.persimmonFixed : .primary, minLineWidth: 1.1).padding(3)
            }
            .frame(width: 18, height: 18)
            Text(skin.native ? "New Thought" : "New thought").font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(skin.full ? (skin.native ? Color.white : Ink.inkFixed) : .primary)
        }
        .padding(.leading, 5).padding(.trailing, 11).frame(height: 28)
        .background(Capsule().fill(skin.full ? (skin.native ? Ink.nativeAccent : Ink.persimmon) : Color.primary.opacity(0.12)))
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
        .configurationDisplayName("New thought")
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
