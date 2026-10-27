import WidgetKit
import SwiftUI

// The watch's complications and Smart Stack card (mockup "Library features", section 4b; DESIGN.md §20). They draw
// only, from what the watch app keeps in the App Group (the iPhone's thought count and last capture, and the thoughts
// still waiting to go), and open the watch app to its recorder. Persimmon means record; tinted faces draw them in one
// color.

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
            BarsMark(color: WatchInk.record).frame(width: 11, height: 11)
            Text("Verbose").font(.system(size: 12, weight: .bold)).foregroundStyle(WatchInk.record)
        }
        .widgetAccentable()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Record (circular)

struct WatchRecordComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "co.stumpandroot.verbatim.watch.record", provider: WatchProvider()) { _ in
            ZStack {
                Circle().fill(WatchInk.record).widgetAccentable()
                BarsMark(color: WatchInk.onRecord).padding(13)
            }
            .accessibilityLabel("Record")
            .widgetURL(WatchRules.recordLink)
            .containerBackground(WatchInk.card, for: .widget)
        }
        .configurationDisplayName("Record")
        .description("Start a voice note from your watch face.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: Today's thoughts (rectangular)

struct WatchThoughtsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "co.stumpandroot.verbatim.watch.thoughts", provider: WatchProvider()) { entry in
            VStack(alignment: .leading, spacing: 1) {
                WatchCardHeader()
                Text(WatchRules.complicationTitle(entry.thoughts))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(WatchInk.text).monospacedDigit()
                Text(WatchRules.complicationDetail).font(.system(size: 12)).foregroundStyle(WatchInk.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .widgetURL(WatchRules.thoughtLink)
            .containerBackground(WatchInk.card, for: .widget)
        }
        .configurationDisplayName("Today's thoughts")
        .description("See how many thoughts you have today, and tap to add one.")
        .supportedFamilies([.accessoryRectangular])
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
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(WatchInk.text).lineLimit(1).privacySensitive()
                    if let line = WatchRules.lastLine(c, time: { $0.formatted(date: .omitted, time: .shortened) }) {
                        Text(line).font(.system(size: 12)).foregroundStyle(WatchInk.dim).lineLimit(1)
                    }
                } else {
                    Text(WatchRules.complicationTitle(entry.thoughts)).font(.system(size: 15, weight: .semibold)).foregroundStyle(WatchInk.text)
                }
                Text("Tap to record").font(.system(size: 12, weight: .semibold)).foregroundStyle(WatchInk.record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .widgetURL(WatchRules.recordLink)
            .containerBackground(WatchInk.card, for: .widget)
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
