import SwiftUI
import UIKit

// Record in the tab bar (DESIGN.md §13 and §16; mockup "Verbose Refined Look"): the
// tab bar's bottom accessory, the slot Apple Music uses for its player, on every tab but Home's own screen, where the
// refined Record card stands in for it while it's shown (HomeSpacing.hidesRecordChrome). A tap records a voice note;
// touch and hold opens Record as, a system Menu built like Books' reading menu (an icon row for Dictate, Live
// captions, and Import, then the ways to record, each with the line that says what it does). While a recording runs,
// the accessory is the minimized recorder (`PhoneMiniRecorder`, the refined kit's design: the persimmon dot, the time,
// your newest words or the kind, Pause, and Stop), and a tap brings the recorder back. The tab bar shrinks when you
// scroll down, with Record beside it. Before iOS 26 there's no accessory, so the same content sits in an opaque bar
// above the tab bar (`RecordBar`, MiniRecorder.swift).
//
// Record, its menu, and VoiceOver's actions call the same entry points as Home's Record card (RecordTray's `tap` and
// `PhoneState.startRecordChoice`, which run `requestRecord`), so their haptics and checks are the same. The accessory
// sits on the system's glass, where Apple puts text (§13's layer rule); its text is the refined ink.

/// The accessory's content: Record at rest, the live recording while one runs.
struct RecordAccessory: View {
    @EnvironmentObject var app: PhoneState
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

/// The record disc, "Record" over "Voice note", and Dictate at the trailing end. A tap is the plain Record; touch and
/// hold opens Record as (the system menu, with its own haptic on each row).
struct AccessoryRecordButton: View {
    @EnvironmentObject var app: PhoneState
    var inline = false
    @ObservedObject private var auto = TemplateSettingsModel.shared
    /// At accessibility text sizes the accessory drops its subtitle, so "Record" keeps its room.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                RecordAsMenu(settings: auto.settings, templates: app.store.allTemplates)
            } label: {
                HStack(spacing: 12) {
                    AccessoryRecordDisc(size: inline ? 22 : 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Record").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        if !inline, !typeSize.isAccessibilitySize {
                            Text("Voice note").refinedFont(.meta).foregroundStyle(Refined.dim)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, inline ? 8 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            } primaryAction: {
                if RecordTray.shared.app == nil { RecordTray.shared.app = app }
                RecordTray.shared.tap()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Record")
            .accessibilityHint("Starts a voice note. Touch and hold for more ways to record, and for Dictate, Live captions, and Import.")
            .recordChoiceActions(app)
            .accessibilityIdentifier("accessory.record")
            if !inline {
                Button { app.go(.dictations) } label: {
                    IconGlyph(art: .iconDictations, size: 20, color: Refined.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dictate")
                .accessibilityHint(HomeTileAction.hint(.dictate))
                .padding(.trailing, 4)
            }
        }
    }
}

/// Record as, as a system menu: Dictate, Live captions, and Import as an icon row (a ControlGroup, as Books draws Line
/// Guide and Share), then the ways to record with what each one does. A menu is system chrome, so its items carry SF
/// Symbols in the label color, like every item in Apple's menus; the system's highlight shows where a lift lands.
struct RecordAsMenu: View {
    @EnvironmentObject var app: PhoneState
    var settings: AutoRunSettings
    var templates: [TranscriptTemplate]
    @ObservedObject private var rows = RecordAsStore.shared

    var body: some View {
        ControlGroup {
            Button { app.go(.dictations) } label: { Label("Dictate", systemImage: "mic") }   // brand: system surface
            Button { app.requestCaptions() } label: { Label("Live captions", systemImage: "captions.bubble") }   // brand: system surface
            Button { app.showImportChoices = true } label: { Label("Import", systemImage: "square.and.arrow.down") }   // brand: system surface
        }
        Section("Record as") {
            ForEach(rows.visible) { c in
                // A menu item's second Text is its subtitle.
                Button { app.startRecordChoice(c) } label: {
                    Label(c.name, systemImage: c.menuSymbol)
                    Text(RecordAsMenu.hint(c, settings: settings, templates: templates))
                }
            }
        }
        // The rows you hid (Interview, Journal entry, and Talk start hidden) come back here.
        Button { app.showRecordAsEditor = true } label: { Label("Edit Record as", systemImage: "slider.horizontal.3") }   // brand: system surface
    }

    /// The line under a kind: what runs when it finishes, or what it does (`RecordChoice.hint`). Voice note says that
    /// Verbose picks the kind.
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
    @EnvironmentObject var app: PhoneState
    var hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.2, *) {
            content
                .tabViewBottomAccessory(isEnabled: !hidden) { RecordAccessory().environmentObject(app) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else if #available(iOS 26, *) {
            // Before 26.2 the accessory can't be turned off; an empty one hides on 26.0.
            content
                .tabViewBottomAccessory { if !hidden { RecordAccessory().environmentObject(app) } }
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
