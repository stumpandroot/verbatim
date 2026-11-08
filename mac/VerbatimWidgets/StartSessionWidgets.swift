import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Control Center

// Every control's glyph is one of ours, exported as a custom symbol (Assets' symbol sets, `mac/tools/gen_symbol.py`), so
// Control Center shows one family: `dictate` (the Dictations icon: the session and Dictate, both butter, SF-05),
// `record` (BrandArt's capture), `thought`, `mark`, `captions`, and the bars mark (the app's, for the Action button's
// control before the app names it).

/// Control Center (and the Lock Screen's control slots and the Action button, iOS 18): "Verbose · Session on", or
/// "Start a session" while off (`Ribbon.sessionOnTitle`, `Ribbon.startSessionTitle`; SF-16). A switch that shows
/// whether a session holds the microphone. Turning it on with no session opens Verbose for a
/// moment and starts one; turning it off ends the session without opening Verbose (`SetSessionIntent`). Keeps the
/// old Start dictation session control's kind, so a control you already added becomes the switch. Dictation's look
/// (SF-05, Tim, November 8, 2026): the dictate glyph, tinted butter.
@available(iOS 18.0, *)
struct StartSessionControl: ControlWidget {
    static let kind = "co.stumpandroot.verbatim.ios.control.startSession"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: SessionControlValue()) { isOn in
            ControlWidgetToggle("Verbose", isOn: isOn, action: SetSessionIntent()) { on in
                Label(on ? Ribbon.sessionOnTitle : Ribbon.startSessionTitle, image: "dictate")
            }
            .tint(Refined.butter)
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

/// Control Center (iOS 18): Record voice note, a switch (SF-18). On while a recording other than a thought runs
/// ("Recording"), from the App Group mirror (`RecordingMirror`), which the app reloads on start, pause, and stop. Turned
/// on it records in place behind the recording's Live Activity when iOS allows, else opens Verbose to record; turned
/// off it stops and saves (`SetRecordingIntent`). Keeps the button's kind, so a control you already added becomes the
/// switch.
@available(iOS 18.0, *)
struct RecordVoiceNoteControl: ControlWidget {
    static let kind = RecordingMirror.recordControlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: RecordingSwitchValue()) { isOn in
            ControlWidgetToggle("Record", isOn: isOn, action: SetRecordingIntent()) { on in
                Label(on ? "Recording" : "Voice note", image: "record")
            }
            .tint(Refined.persimmon)
        }
        .displayName("Record voice note")
        .description("Starts a Verbose voice note, in place when iOS allows it. Shows Recording while one runs; turn it off to stop and save.")
    }
}

/// Whether a recording other than a thought runs, from the App Group mirror.
@available(iOS 18.0, *)
struct RecordingSwitchValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { RecordingMirror.recordingOn(RecordingMirror.read()) }
}

/// Control Center (iOS 18): Dictate, a switch for a take (SF-16): on while one listens ("Listening"), its own job beside
/// the session switch, which turns the microphone on or off. Turned on it starts a take (with no session, Verbose opens
/// for a moment to start one and listen); turned off it stops and delivers your words (`SetTakeIntent`). Keeps the
/// button's kind, so a control you already added becomes the switch. Tinted butter, dictation's hue (SF-05).
@available(iOS 18.0, *)
struct DictateControl: ControlWidget {
    static let kind = Ribbon.dictateControlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: TakeSwitchValue()) { isOn in
            ControlWidgetToggle("Dictate", isOn: isOn, action: SetTakeIntent()) { on in
                Label(on ? "Listening" : "Dictate", image: "dictate")
            }
            .tint(Refined.butter)
        }
        .displayName("Dictate")
        .description("Starts listening, or stops and puts your words in. With no session on, Verbose opens for a moment to start one.")
    }
}

/// Whether a take listens, from the App Group (`KeyboardBridge.takeListening`).
@available(iOS 18.0, *)
struct TakeSwitchValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { KeyboardBridge.takeListening }
}

/// Control Center, the Action button, and the Lock Screen's bottom corners (iOS 18): New thought, a switch (SF-16). On
/// while a thought records ("Recording a thought"), so you can see that pressing it stops it. Turned on it records in
/// place behind its Live Activity when iOS allows, else opens Verbose to the recorder; turned off it stops the thought
/// and adds it to today's page (`SetThoughtIntent`). Its glyph is the Thoughts icon, exported as a custom symbol. Keeps
/// the button's kind, so a control you already added becomes the switch.
@available(iOS 18.0, *)
struct NewThoughtControl: ControlWidget {
    static let kind = ThoughtRules.controlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: ThoughtSwitchValue()) { isOn in
            ControlWidgetToggle("New thought", isOn: isOn, action: SetThoughtIntent()) { on in
                Label(on ? "Recording a thought" : "New thought", image: "thought")
            }
            .tint(Refined.persimmon)
        }
        .displayName("New thought")
        .description("Starts a thought that lands on today's Thoughts page. Shows Recording a thought while one records; turn it off to stop.")
    }
}

/// Whether a thought records, from the App Group mirror.
@available(iOS 18.0, *)
struct ThoughtSwitchValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { RecordingMirror.thoughtOn(RecordingMirror.read()) }
}

// MARK: - Lock Screen widget

/// A Lock Screen widget (circular, rectangular, or inline): "Start a session", or "Session on · 12 min" while one is on
/// (SF-30), read from the App Group (`KeyboardBridge.sessionLive`, `sessionStartedAt`). The app reloads it when a
/// session starts or ends; while one is on, it also looks again every `Ribbon.sessionWidgetRecheck`. A tap opens
/// `verbatim://session?start=1&from=widget` (with a session on, Verbose opens to it). Keeps its kind. Every family
/// shows the dictate glyph (the waves), dictation's glyph everywhere (SF-05); the Lock Screen draws it in one color.
struct StartSessionWidget: Widget {
    static let kind = Ribbon.sessionWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StartSessionProvider()) { entry in
            StartSessionAccessoryView(entry: entry)
                .widgetURL(URL(string: "verbatim://session?start=1&from=widget"))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // text grows with Dynamic Type, within the widget (SF-11)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Verbose session")
        .description("Shows whether a session is on, and starts one: the microphone for the Verbose keyboard.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StartSessionEntry: TimelineEntry {
    let date: Date
    /// When the session that's on started; nil while none is on.
    var startedAt: Date? = nil
    var on: Bool { startedAt != nil }
}

/// Off: one entry that holds until the app reloads it. On: the session's start, and a look again after
/// `Ribbon.sessionWidgetRecheck`, so one iOS ended goes back to Start a session.
struct StartSessionProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartSessionEntry { StartSessionEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (StartSessionEntry) -> Void) {
        completion(context.isPreview ? StartSessionEntry(date: Date()) : Self.current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StartSessionEntry>) -> Void) {
        let entry = Self.current()
        let policy: TimelineReloadPolicy = entry.on ? .after(entry.date.addingTimeInterval(Ribbon.sessionWidgetRecheck)) : .never
        completion(Timeline(entries: [entry], policy: policy))
    }
    static func current(now: Date = Date()) -> StartSessionEntry {
        StartSessionEntry(date: now, startedAt: KeyboardBridge.sessionLive ? (KeyboardBridge.sessionStartedAt ?? now) : nil)
    }
}

private struct StartSessionAccessoryView: View {
    var entry: StartSessionEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                SessionGlyph().padding(12).widgetAccentable()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.on ? Ribbon.sessionOnTitle : Ribbon.startSessionTitle)
        case .accessoryInline:
            Label(entry.on ? Ribbon.sessionOnTitle : Ribbon.startSessionTitle, image: "dictate")
        default:
            HStack(spacing: 8) {
                SessionGlyph().frame(width: 26, height: 26).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Verbose").scaledFont(15, weight: .semibold).widgetAccentable()
                    if let started = entry.startedAt {
                        // "Session on · 12 min", counting on its own.
                        Text("\(Ribbon.sessionOnTitle) · \(Text(started, style: .relative))").scaledFont(13).monospacedDigit().lineLimit(2)
                    } else {
                        Text(Ribbon.startSessionTitle).scaledFont(13).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The Lock Screen session widget's glyph: the dictate glyph (the waves, `BrandArt.iconDictations`, the `dictate`
/// symbol), in white for the Lock Screen's one color. Decorative: the widget's label names it.
private struct SessionGlyph: View {
    var body: some View {
        BrandGlyph(art: .iconDictations, color: .white, minLineWidth: 1.6).aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}
