// brand: native file
import SwiftUI
import UIKit

// Record in the Native look (DESIGN.md §13.3; mockup "Verbose Native Redesign", sections 1, 4, and 5): the tab bar's
// bottom accessory, the slot Apple Music uses for its player, on every tab. A tap records a voice note; touch and hold
// opens Record as, a system Menu built like Books' reading menu (an icon row for Dictate, Live captions, and Import,
// then the six ways to record, each with the line that says what it does). While a recording runs, the accessory is
// the live recording (the time, the kind, Pause, and Stop), and a tap brings the recorder back. The tab bar shrinks
// when you scroll down, with Record beside it. Before iOS 26 there's no accessory, so the same content sits in an
// opaque bar above the tab bar (MiniRecorder.swift).
//
// Record, its menu, and VoiceOver's actions call the same entry points as Verbose style's Record (RecordTray's `tap`
// and `PhoneState.startRecordChoice`, which run `requestRecord`), so their haptics and checks are the same.

/// The accessory's content: Record at rest, the live recording while one runs.
struct NativeRecordAccessory: View {
    @EnvironmentObject var app: PhoneState
    /// How many accessories are on screen (expanded and inline copies count once each), for the self-test.
    static var onScreen = 0
    /// True when the accessory shows Record at rest (false while a recording runs), for the self-test.
    static var showsRecord = false

    var body: some View {
        AccessoryPlacement { inline in
            Group {
                if app.recordingActive {
                    NativeLiveAccessory(live: app.recorder.live, inline: inline)
                } else {
                    NativeRecordButton(inline: inline)
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

/// The red record disc, "Record" over "Voice note", and Dictate at the trailing end. A tap is the plain Record; touch
/// and hold opens Record as (the system menu, with its own haptic on each row).
struct NativeRecordButton: View {
    @EnvironmentObject var app: PhoneState
    var inline = false
    @ObservedObject private var auto = TemplateSettingsModel.shared
    /// At accessibility text sizes the accessory drops its subtitle, so "Record" keeps its room.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                NativeRecordMenu(settings: auto.settings, templates: app.store.allTemplates)
            } label: {
                HStack(spacing: 12) {
                    NativeRecordDisc(size: inline ? 22 : 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Record").font(.subheadline.weight(.semibold)).foregroundStyle(NativeInk.label)
                        if !inline, !typeSize.isAccessibilitySize {
                            Text("Voice note").font(.caption).foregroundStyle(NativeInk.secondary)
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
            .accessibilityIdentifier("native.record")
            if !inline {
                Button { app.go(.dictations) } label: {
                    Image(systemName: "mic").font(.system(size: 17, weight: .regular)).foregroundStyle(NativeInk.label)
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
/// Guide and Share), then the six ways to record with what each one does. Kind symbols are label colored, like every
/// item in Apple's menus; the system's highlight shows where a lift lands.
struct NativeRecordMenu: View {
    @EnvironmentObject var app: PhoneState
    var settings: AutoRunSettings
    var templates: [TranscriptTemplate]
    @ObservedObject private var rows = RecordAsStore.shared

    var body: some View {
        ControlGroup {
            Button { app.go(.dictations) } label: { Label("Dictate", systemImage: "mic") }
            Button { app.requestCaptions() } label: { Label("Live captions", systemImage: "captions.bubble") }
            Button { app.showImportChoices = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
        }
        Section("Record as") {
            ForEach(rows.visible) { c in
                // A menu item's second Text is its subtitle.
                Button { app.startRecordChoice(c) } label: {
                    Label(c.name, systemImage: c.nativeSymbol)
                    Text(NativeRecordMenu.hint(c, settings: settings, templates: templates))
                }
            }
        }
        // The rows you hid (Interview, Journal entry, and Talk start hidden) come back here.
        Button { app.showRecordAsEditor = true } label: { Label("Edit Record as", systemImage: "slider.horizontal.3") }
    }

    /// The line under a kind: what runs when it finishes, or what it does (`RecordChoice.hint`). Voice note says that
    /// Verbose picks the kind.
    static func hint(_ c: RecordChoice, settings: AutoRunSettings, templates: [TranscriptTemplate]) -> String {
        if case .voiceNote = c { return "Verbose picks the kind" }
        return c.hint(settings: settings, templates: templates)
    }
}

/// The record disc: flat system red in a thin gray ring, like Voice Memos'. It carries no text.
struct NativeRecordDisc: View {
    var size: CGFloat
    var body: some View {
        Circle().fill(NativeInk.record)
            .frame(width: size * 0.78, height: size * 0.78)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(NativeInk.gray, lineWidth: max(1.5, size * 0.08)))
            .accessibilityHidden(true)
    }
}

// MARK: - The live recording

/// While a recording runs: a red level glyph, "Recording · 2:14" over the kind, then Pause or Resume and the red Stop
/// square. A tap on the text brings the recorder back.
struct NativeLiveAccessory: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject var live: LiveMeter
    var inline = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var paused: Bool { app.recorder.isPaused }
    private var saving: Bool { app.savingRecording }
    private var status: String { saving ? "Saving…" : paused ? "Paused" : "Recording" }

    var body: some View {
        HStack(spacing: 4) {
            Button { app.openRecorder() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(paused || saving ? NativeInk.secondary : NativeInk.record)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(status) · \(RecorderPresentation.clock(live.elapsed))")
                            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(NativeInk.label)
                        if !inline, !typeSize.isAccessibilitySize {
                            Text(app.recordingChoice.name).font(.caption).foregroundStyle(NativeInk.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, inline ? 8 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { app.togglePause() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 17)).foregroundStyle(NativeInk.label)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "Resume" : "Pause")
            Button { app.stopRecording() } label: {
                Group {
                    if saving { ProgressView().controlSize(.small) }
                    else { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(NativeInk.record).frame(width: 16, height: 16) }
                }
                .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .padding(.trailing, 4)
        }
        .disabled(saving)
        // One element for VoiceOver, as the Verbose bar: "Recording, 4 minutes 12 seconds", with Pause or Resume,
        // Stop, and Open.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RecorderPresentation.accessibilityLabel(paused: paused, saving: saving, elapsed: live.elapsed))
        .accessibilityValue(app.recordingChoice.name)
        .accessibilityHint("Opens the recorder.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.openRecorder() }
        .accessibilityAction(named: Text(paused ? "Resume" : "Pause")) { app.togglePause() }
        .accessibilityAction(named: "Stop") { app.stopRecording() }
        .accessibilityAction(named: "Open") { app.openRecorder() }
        .accessibilityIdentifier("native.recording")
    }
}

// MARK: - On the tab view

extension View {
    /// The Native look's tab bar: Record in the bottom accessory and a tab bar that shrinks on scroll down. Applied in
    /// both looks so the tab view keeps its identity when the look changes; Verbose style turns the accessory off.
    /// `hidden` turns it off while you read a transcript (the tab bar hides then, and the player takes the bottom).
    func nativeTabChrome(native: Bool, hidden: Bool) -> some View {
        modifier(NativeTabChrome(native: native, hidden: hidden))
    }
}

private struct NativeTabChrome: ViewModifier {
    @EnvironmentObject var app: PhoneState
    var native: Bool
    var hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.2, *) {
            content
                .tabViewBottomAccessory(isEnabled: native && !hidden) { NativeRecordAccessory().environmentObject(app) }
                .tabBarMinimizeBehavior(native ? .onScrollDown : .automatic)
        } else if #available(iOS 26, *) {
            // Before 26.2 the accessory can't be turned off; an empty one hides on 26.0.
            content
                .tabViewBottomAccessory { if native && !hidden { NativeRecordAccessory().environmentObject(app) } }
                .tabBarMinimizeBehavior(native ? .onScrollDown : .automatic)
        } else {
            content
        }
    }
}

enum NativeRecordPlacement {
    /// True when the tab bar's bottom accessory carries Record (iOS 26 and later); before it, an opaque bar above the
    /// tab bar does (MiniRecorder.swift).
    static var systemAccessory: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

/// Before iOS 26: Record (or the live recording) in an opaque bar above the tab bar, on every tab. No glass behind
/// its text.
struct NativeRecordBar: View {
    var body: some View {
        NativeRecordAccessory()
            .frame(height: 52)
            .background(NativeInk.card, in: Capsule())
            .overlay(Capsule().strokeBorder(NativeInk.separator, lineWidth: 0.5))
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }
}
