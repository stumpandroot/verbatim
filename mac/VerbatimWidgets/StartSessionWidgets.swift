import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Control Center

// Every control's glyph is one of ours, exported as a custom symbol (Assets' symbol sets, `mac/tools/gen_symbol.py`), so
// Control Center shows one family: the bars mark (the session), `record` (BrandArt's capture), `dictate` (the
// Dictations icon), `thought`, `mark`, and `captions`.

/// Control Center (and the Lock Screen's control slots and the Action button, iOS 18): "Verbose · Session on". A
/// switch that shows whether a session holds the microphone. Turning it on with no session opens Verbose for a
/// moment and starts one; turning it off ends the session without opening Verbose (`SetSessionIntent`). Keeps the
/// old Start dictation session control's kind, so a control you already added becomes the switch.
@available(iOS 18.0, *)
struct StartSessionControl: ControlWidget {
    static let kind = "co.stumpandroot.verbatim.ios.control.startSession"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: SessionControlValue()) { isOn in
            ControlWidgetToggle("Verbose", isOn: isOn, action: SetSessionIntent()) { on in
                Label(on ? "Session on" : "Session off", image: "bars")
            }
            .tint(Ink.persimmon)
        }
        .displayName("Verbose session")
        .description("Turns the microphone on for dictation in any app, or off.")
    }
}

/// Reads whether a session is on from the App Group heartbeat (`KeyboardBridge.sessionLive`). The app reloads the
/// control when a session starts or ends (`ControlCenter.reloadControls`).
@available(iOS 18.0, *)
struct SessionControlValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { KeyboardBridge.sessionLive }
}

/// The Action button's control (iOS 18): does what you chose in Verbose › Settings › Action button. Dictate a
/// take unless you change it. It's named for that choice ("Record or mark", with its symbol), which the app mirrors
/// into the App Group (`ActionChoiceMirror`); the gallery, and a control the app hasn't named yet, say Verbose action.
@available(iOS 18.0, *)
struct ActionButtonControl: ControlWidget {
    static let kind = Ribbon.actionControlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: ActionChoiceValue()) { raw in
            ControlWidgetButton(action: ActionButtonIntent()) {
                Label(Ribbon.actionControl(raw).title, image: Ribbon.actionControl(raw).symbol)
            }
        }
        .displayName("Verbose action")   // Ribbon.actionControlName; Settings › Action button's steps name it
        .description("Does what you chose in Verbose › Settings › Action button: dictate, record a voice note, record or mark, live captions, what's playing, or a new thought.")
    }
}

/// The Action button choice the app mirrored into the App Group; empty until it has.
@available(iOS 18.0, *)
struct ActionChoiceValue: ControlValueProvider {
    var previewValue: String { "" }
    func currentValue() async throws -> String {
        KeyboardBridge.defaults?.string(forKey: Ribbon.actionChoiceKey) ?? ""
    }
}

/// Control Center (iOS 18): Record voice note. Records in place behind the recording's Live Activity when iOS allows,
/// else opens Verbose to record (`RecordVoiceNoteIntent`).
@available(iOS 18.0, *)
struct RecordVoiceNoteControl: ControlWidget {
    static let kind = "co.stumpandroot.verbatim.ios.control.record"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: RecordVoiceNoteIntent()) {
                Label("Record", image: "record")
            }
            .tint(Ink.persimmon)
        }
        .displayName("Record voice note")
        .description("Starts a Verbose voice note, in place when iOS allows it.")
    }
}

/// Control Center (iOS 18): Dictate. Opens Verbose for a moment and turns on the microphone for the Verbose keyboard
/// (`StartKeyboardSessionIntent`, the same as Shortcuts' Start dictation session).
@available(iOS 18.0, *)
struct DictateControl: ControlWidget {
    static let kind = "co.stumpandroot.verbatim.ios.control.dictate"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartKeyboardSessionIntent()) {
                Label("Dictate", image: "dictate")
            }
            .tint(Ink.persimmon)
        }
        .displayName("Dictate")
        .description("Starts a Verbose dictation session, so you can dictate in any app.")
    }
}

/// Control Center, the Action button, and the Lock Screen's bottom corners (iOS 18): New thought. Records in place behind
/// its Live Activity when iOS allows, else opens Verbose to the recorder; pressed again while a thought records, it
/// stops and saves it (`NewThoughtIntent`). Its glyph is the Thoughts icon, exported as a custom symbol.
@available(iOS 18.0, *)
struct NewThoughtControl: ControlWidget {
    static let kind = ThoughtRules.controlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: NewThoughtIntent()) {
                Label("New thought", image: "thought")
            }
            .tint(Ink.persimmon)
        }
        .displayName("New thought")
        .description("Starts a thought that lands on today's Thoughts page. Press it again to stop.")
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
        .description("Opens Verbose and turns on the microphone for the Verbose keyboard.")
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
            .accessibilityLabel("Start a Verbose dictation session")
        case .accessoryInline:
            Label("Start dictating", image: "dictate")
        default:
            HStack(spacing: 8) {
                BarsMark(color: .white).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Verbose").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                    Text("Start dictation session").font(.system(size: 13)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
