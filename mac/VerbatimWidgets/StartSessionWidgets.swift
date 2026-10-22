import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Control Center

/// Control Center (and the Lock Screen's control slots, iOS 18): "Start dictation session". Opens Verbatim for a
/// moment, turns on the microphone for the keyboard, and shows how to go back to your app.
@available(iOS 18.0, *)
struct StartSessionControl: ControlWidget {
    static let kind = "co.stumpandroot.verbatim.ios.control.startSession"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartKeyboardSessionIntent()) {
                Label("Start dictation session", systemImage: "mic.fill")
            }
        }
        .displayName("Start dictation session")
        .description("Opens Verbatim and turns on the microphone for the Verbatim keyboard.")
    }
}

// MARK: - Lock Screen widget

/// A Lock Screen widget (circular, rectangular, or inline) that opens `verbatim://session?start=1&from=widget`.
struct StartSessionWidget: Widget {
    static let kind = "co.stumpandroot.verbatim.ios.widget.startSession"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StartSessionProvider()) { _ in
            StartSessionAccessoryView()
                .widgetURL(URL(string: "verbatim://session?start=1&from=widget"))
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Start dictation session")
        .description("Opens Verbatim and turns on the microphone for the Verbatim keyboard.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StartSessionEntry: TimelineEntry { let date: Date }

/// One entry that never changes: the widget is a button.
struct StartSessionProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartSessionEntry { StartSessionEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (StartSessionEntry) -> Void) { completion(StartSessionEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StartSessionEntry>) -> Void) {
        completion(Timeline(entries: [StartSessionEntry(date: Date())], policy: .never))
    }
}

private struct StartSessionAccessoryView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                BarsMark(color: .white).padding(12)
            }
            .accessibilityLabel("Start a Verbatim dictation session")
        case .accessoryInline:
            Label("Start dictating", systemImage: "mic.fill")
        default:
            HStack(spacing: 8) {
                BarsMark(color: .white).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Verbatim").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                    Text("Start dictation session").font(.system(size: 13)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
