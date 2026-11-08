import SwiftUI
import UIKit

// Record in the tab bar (DESIGN.md §13 and §16; mockup "Verbose Refined Look"): the
// tab bar's bottom accessory, the slot Apple Music uses for its player, on every tab but Home's own screen, where the
// refined Record card stands in for it while it's shown (HomeSpacing.hidesRecordChrome). A tap records a voice note
// (a thought on Thoughts, a journal entry on Journal, and a kind's tab its kind, a meeting on Meetings: `TabRecordDefault`);
// touch and hold opens Record as, the same tray Home's Record card opens (RecordTray.swift), with its light tap and its
// rows. While a recording runs,
// the accessory is the minimized recorder (`PhoneMiniRecorder`, the refined kit's design: the persimmon dot, the time,
// your newest words or the kind, Pause, and Stop), and a tap brings the recorder back. The tab bar shrinks when you
// scroll down, with Record beside it. Before iOS 26 there's no accessory, so the same content sits in an opaque bar
// above the tab bar (`RecordBar`, MiniRecorder.swift).
//
// Record, its tray, and VoiceOver's actions call the same entry points as Home's Record card (RecordTray's `tap` and
// `PhoneState.startRecordChoice`, which run `requestRecord`), so their haptics and checks are the same. The accessory
// sits on the system's glass, where Apple puts text (§13's layer rule); its text is the refined ink.

/// The soft scroll edge at the bottom on iOS 26 (SF-28): rows scrolling under the tab bar and Record's accessory fade
/// before they reach its glass, so the accessory's time, words, and Stop never sit over a row's text. On a tab's scroll
/// view (Home's, `HomeScreen.scroller`).
struct AccessoryScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.scrollEdgeEffectStyle(.soft, for: .bottom) } else { content }
    }
}

/// The accessory's content: Record at rest, the live recording while one runs.
struct RecordAccessory: View {
    @Environment(PhoneState.self) var app
    /// Watched directly (PhoneState doesn't pass its changes on): Record, or the live recording (`recordingActive`).
    @EnvironmentObject private var recorder: Recorder
    /// How many accessories are on screen (expanded and inline copies count once each), for the self-test.
    static var onScreen = 0
    /// True when the accessory shows Record at rest (false while a recording runs), for the self-test.
    static var showsRecord = false

    var body: some View {
        AccessoryPlacement { inline in
            Group {
                if app.recordingActive {
                    // The minimized recorder (the refined kit).
                    PhoneMiniRecorder(inline: inline).accessibilityIdentifier("accessory.recording")
                } else {
                    AccessoryRecordButton(inline: inline)
                }
            }
        }
        .onAppear { Self.onScreen += 1; Self.showsRecord = !app.recordingActive }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
        .onChange(of: app.recordingActive) { _, on in Self.showsRecord = !on }
    }
}

/// Reads where the accessory sits (iOS 26): above the tab bar (expanded) or inline beside the shrunk tab bar.
private struct AccessoryPlacement<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    var body: some View {
        if #available(iOS 26, *) {
            PlacementReader(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 26, *)
private struct PlacementReader<Content: View>: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @ViewBuilder var content: (Bool) -> Content
    var body: some View { content(placement == .inline) }
}

// MARK: - Record at rest

/// The record disc, "Record" over "Voice note", and Dictations at the trailing end. A tap is the plain Record (the
/// tab's kind); touch and hold opens the same Record as tray as Home's Record card, with its light tap on open and its
/// rows (IP-08).
struct AccessoryRecordButton: View {
    @Environment(PhoneState.self) var app
    var inline = false
    /// At accessibility text sizes the accessory drops its subtitle, so "Record" keeps its room.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // On Thoughts a tap records a thought, on Journal a journal entry, on a kind's tab that kind; elsewhere a voice note.
        let quick = TabRecordDefault.forTab(app.tab)
        HStack(spacing: 4) {
            HStack(spacing: 12) {
                AccessoryRecordDisc(size: inline ? 22 : 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Record").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    if !inline, !typeSize.isAccessibilitySize {
                        Text(quick.subtitle).refinedFont(.meta).foregroundStyle(Refined.dim)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, inline ? 8 : 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .recordTrayPress(.card) { Self.start(quick, app) }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Record")
            .accessibilityHint(quick.hint)
            .accessibilityAction { Self.start(quick, app) }
            .recordChoiceActions(app)
            .accessibilityIdentifier("accessory.record")
            if !inline {
                // It opens Dictations (the list and how to use the keyboard), so it's named for that (IP-29).
                Button { app.go(.dictations) } label: {
                    IconGlyph(art: .iconDictations, size: 20, color: Refined.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dictations")
                .accessibilityHint("Opens your dictations and how to use the Verbose keyboard.")
                .padding(.trailing, 4)
            }
        }
    }
}

extension AccessoryRecordButton {
    /// What a tap on Record starts on the tab you're on (`TabRecordDefault`), through Record as's entry points
    /// (RecordTray's `tap` and `perform`, which run `PhoneState.startRecordChoice`), so the checks and haptics are Record
    /// as's and the self-test's stand-in sees the choice.
    @MainActor static func start(_ quick: TabRecordDefault, _ app: PhoneState) {
        let tray = RecordTray.shared
        if tray.app == nil { tray.app = app }
        switch quick {
        case .voiceNote: tray.tap()
        case .thought: tray.perform(.thought)
        case .journal, .meeting, .interview, .talk, .brainDump, .audio:
            if let k = quick.kindRaw.flatMap(RecordingKind.init(rawValue:)) { tray.perform(.kind(k)) }
        }
    }
}

/// The line under each way to record in Record as (the tray and its VoiceOver actions): what runs when it finishes, or
/// what it does (`RecordChoice.hint`). Voice note says that Verbose picks the kind. (Record as was a system menu on
/// the tab bar's Record until November 7, 2026; it opens the tray now, as Home's Record card does.)
enum RecordAsMenu {
    static func hint(_ c: RecordChoice, settings: AutoRunSettings, templates: [TranscriptTemplate]) -> String {
        if case .voiceNote = c { return "Verbose picks the kind" }
        return c.hint(settings: settings, templates: templates)
    }
}

/// The record disc on the accessory: an ink circle with the system's red dot, the Record card's disc in the refined ink
/// so it shows on the glass in light and dark. It carries no text.
struct AccessoryRecordDisc: View {
    var size: CGFloat
    var body: some View {
        Circle().fill(Refined.ink)
            .frame(width: size, height: size)
            .overlay(Circle().fill(Refined.recordRed).frame(width: size * 0.42, height: size * 0.42))
            .accessibilityHidden(true)
    }
}

// MARK: - On the tab view

extension View {
    /// The tab bar's chrome: Record in the bottom accessory and a tab bar that shrinks on scroll down.
    /// `hidden` turns the accessory off while you read a transcript (the tab bar hides then, and the player
    /// takes the bottom), and on Home's own screen while its Record card is there.
    func recordTabChrome(hidden: Bool) -> some View {
        modifier(RecordTabChrome(hidden: hidden))
    }
}

private struct RecordTabChrome: ViewModifier {
    @Environment(PhoneState.self) var app
    var hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.2, *) {
            content
                .tabViewBottomAccessory(isEnabled: !hidden) { RecordAccessory().phoneState(app) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else if #available(iOS 26, *) {
            // Before 26.2 the accessory can't be turned off; an empty one hides on 26.0.
            content
                .tabViewBottomAccessory { if !hidden { RecordAccessory().phoneState(app) } }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

enum RecordPlacement {
    /// True when the tab bar's bottom accessory carries Record (iOS 26 and later); before it, an opaque bar above the
    /// tab bar does (`RecordBar`).
    static var systemAccessory: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

/// Before iOS 26: Record (or the live recording) in an opaque bar above the tab bar, on every tab: the card with a
/// hairline, so no text sits on a blur.
struct RecordBar: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous)
        RecordAccessory()
            .frame(height: 56)
            .background(Refined.card, in: shape)
            .overlay(shape.strokeBorder(Refined.separator, lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }
}
