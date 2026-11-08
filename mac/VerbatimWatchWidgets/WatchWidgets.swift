import WidgetKit
import SwiftUI

// The watch's complications and Smart Stack card (mockup "Library features", section 4b; DESIGN.md §20). They draw
// only, from what the watch app keeps in the App Group (the iPhone's thought count and last capture, and the thoughts
// still waiting to go), and open the watch app to its recorder. Persimmon means record; tinted faces draw them in one
// color. Record is circular or a corner, Today's thoughts rectangular or inline (SF-10), so the faces whose slots are
// corners or inline can host them too.

struct WatchEntry: TimelineEntry {
    let date: Date
    let thoughts: Int
    let context: WatchContext?
    var relevance: TimelineEntryRelevance? = nil
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(context.isPreview ? Self.sample : Self.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let now = Date()
        let entry = Self.current(now: now)
        // Again when today's page ends (the count goes back to none), and every half hour for the Smart Stack's score.
        var next = now.addingTimeInterval(30 * 60)
        if let ends = entry.context?.pageEnds, ends > now, ends < next { next = ends }
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static let sample = WatchEntry(date: Date(), thoughts: 6,
                                   context: WatchContext(thoughtsToday: 6, pageEnds: Date().addingTimeInterval(3600), lastTitle: "Errands after work",
                                                         lastKind: "Thought", lastDuration: 42, lastAt: Date()))

    static func current(now: Date = Date()) -> WatchEntry {
        let d = UserDefaults(suiteName: WatchRules.appGroup) ?? .standard
        let context = d.data(forKey: WatchRules.contextKey).flatMap(WatchContext.decode)
        let unsent = (d.array(forKey: WatchRules.unsentThoughtsKey) as? [Date]) ?? []
        let n = WatchRules.thoughtsToday(context: context, unsent: unsent, now: now)
        return WatchEntry(date: now, thoughts: n, context: context, relevance: relevance(context, thoughts: n, now: now))
    }

    /// The Smart Stack puts the card forward right after a capture and on days with thoughts.
    static func relevance(_ c: WatchContext?, thoughts: Int, now: Date) -> TimelineEntryRelevance {
        if let at = c?.lastAt, now.timeIntervalSince(at) < 2 * 3600 { return TimelineEntryRelevance(score: 60, duration: 2 * 3600) }
        return TimelineEntryRelevance(score: thoughts > 0 ? 30 : 10, duration: 30 * 60)
    }
}

/// "Verbose" with the bars mark, in persimmon: the rectangular cards' first line.
private struct WatchCardHeader: View {
    var body: some View {
        HStack(spacing: 5) {
            BarsMark(color: WatchColor.record).frame(width: 11, height: 11)
            Text("Verbose").scaledFont(12, weight: .bold).foregroundStyle(WatchColor.record)
        }
        .widgetAccentable()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Record (circular and corner)

/// The record disc (SF-13), the same Record as Home's card and the iPhone's widgets: in full color, the persimmon
/// plate with the ink disc and the system red dot; in tinted faces (accented or vibrant), a white ring around a dot,
/// accentable, so the face's tint draws the glyph and never a dark mark on a tinted plate (SF-17).
private struct WatchRecordGlyph: View {
    var full: Bool
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                if full {
                    Circle().fill(WatchColor.record)
                    Circle().fill(WatchColor.onRecord).frame(width: d * 0.62, height: d * 0.62)
                    Circle().fill(Refined.recordRed).frame(width: d * 0.24, height: d * 0.24)
                } else {
                    ZStack {
                        Circle().strokeBorder(Color.white, lineWidth: max(1.5, d * 0.1))
                        Circle().fill(Color.white).frame(width: d * 0.4, height: d * 0.4)
                    }
                    .widgetAccentable()
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// Circular: the disc on its plate. Corner (SF-10): the disc with "Record" along the face's edge.
private struct WatchRecordView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let full = mode == .fullColor
        Group {
            if family == .accessoryCorner {
                WatchRecordGlyph(full: full).padding(3)
                    .widgetLabel("Record")
            } else if full {
                WatchRecordGlyph(full: true)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    WatchRecordGlyph(full: false).padding(13)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Record")
    }
}

struct WatchRecordComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "co.stumpandroot.verbatim.watch.record", provider: WatchProvider()) { _ in
            WatchRecordView()
                .widgetURL(WatchRules.recordLink)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // text grows with Dynamic Type, within the widget (SF-11)
                .containerBackground(WatchColor.card, for: .widget)
        }
        .configurationDisplayName("Record")
        .description("Start a voice note from your watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

// MARK: Today's thoughts (rectangular and inline)

/// Rectangular: "Verbose", "6 thoughts today", and "Tap to add one". Inline (SF-10): "6 thoughts today" alone.
private struct WatchThoughtsView: View {
    var entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryInline {
            Text(WatchRules.complicationTitle(entry.thoughts)).monospacedDigit()
        } else {
            VStack(alignment: .leading, spacing: 1) {
                WatchCardHeader()
                Text(WatchRules.complicationTitle(entry.thoughts))
                    .scaledFont(14, weight: .semibold).foregroundStyle(WatchColor.text).monospacedDigit()
                Text(WatchRules.complicationDetail).scaledFont(12).foregroundStyle(WatchColor.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

struct WatchThoughtsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "co.stumpandroot.verbatim.watch.thoughts", provider: WatchProvider()) { entry in
            WatchThoughtsView(entry: entry)
                .widgetURL(WatchRules.thoughtLink)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // text grows with Dynamic Type, within the widget (SF-11)
                .containerBackground(WatchColor.card, for: .widget)
        }
        .configurationDisplayName("Today's thoughts")
        .description("See how many thoughts you have today, and tap to add one.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

// MARK: Smart Stack

/// The Smart Stack's card: your last capture and Tap to record, put forward right after a capture.
struct WatchSmartStackCard: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "co.stumpandroot.verbatim.watch.last", provider: WatchProvider()) { entry in
            VStack(alignment: .leading, spacing: 1) {
                WatchCardHeader()
                if let c = entry.context, let title = c.lastTitle {
                    Text(title).scaledFont(15, weight: .semibold).foregroundStyle(WatchColor.text).lineLimit(1).privacySensitive()
                    if let line = WatchRules.lastLine(c, time: { $0.formatted(date: .omitted, time: .shortened) }) {
                        Text(line).scaledFont(12).foregroundStyle(WatchColor.dim).lineLimit(1)
                    }
                } else {
                    Text(WatchRules.complicationTitle(entry.thoughts)).scaledFont(15, weight: .semibold).foregroundStyle(WatchColor.text)
                }
                Text("Tap to record").scaledFont(12, weight: .semibold).foregroundStyle(WatchColor.record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .widgetURL(WatchRules.recordLink)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // text grows with Dynamic Type, within the widget (SF-11)
            .containerBackground(WatchColor.card, for: .widget)
        }
        .configurationDisplayName("Last capture")
        .description("Your last recording, with Record, in the Smart Stack.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct VerboseWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchRecordComplication()
        WatchThoughtsComplication()
        WatchSmartStackCard()
    }
}
