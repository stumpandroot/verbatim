import SwiftUI
import UIKit
import AVFoundation
import Combine

// The recorder (DESIGN.md §6.10; approved mockup "Verbose Refined Look", PhoneRecorder, October 28, 2026): one sheet,
// built from the refined kit (§13). Apple draws the sheet and its grabber; Verbose draws the page:
// Minimize (a glass circle) and the microphone, the kind in the serif (Voice note, Meeting, Thought, Brain dump, Audio
// only) over when it started and "Saved as you go", what runs when you stop, the persimmon clock panel
// (`RecorderClockPanel`: Recording or Paused, the clock with hundredths, the waveform under its ink playhead with the
// moments as dots), your words in the serif (older words in mute, the newest in ink; none for Audio only), the moments
// line, and the thumb row: Mark moment, Stop (the system red square in a ring), and Pause, with Discard under it.
//
// Swipe the sheet down, tap Minimize, or use VoiceOver's escape, and the recording goes on: the tab bar's accessory
// (iOS 26) or the bar above the tab bar (before it) shows it, and a tap brings the sheet back (MiniRecorder.swift).
// Stop saves, and says so in a toast for Audio only. Haptics, the Live Activity, route changes, automatic pauses, and
// crash safety live in PhoneState and Recorder.

/// A moment marked while recording: when, where from, and the name you gave it (empty until you name it). The same
/// mark as the Dynamic Island's, the Lock Screen's, and the Action button's (Model/Marks.swift); saved as bookmarks
/// with the recording (`RecordingMark.notes`), each on the line being said once the words are in.
typealias RecordingMoment = RecordingMark

struct RecorderSheet: View {
    /// Whether the recorder is on screen, for the self-test.
    static var visible = false
    /// How many recorders are on screen (one), for the self-test.
    static var onScreen = 0
    /// Stop's fill as drawn, for the self-test (persimmon, as on the Lock Screen and the watch; SF-04).
    static var stopColor: Color? = nil
    /// Started from the Record as tray: the next recorder appears with no system transition and its page slides up
    /// 12 pt over 150 ms, opaque from its first frame (PhoneState.presentRecorder sets it; never under Limit animation).
    static var slideInNext = false

    @Environment(PhoneState.self) var app
    /// Watched directly (PhoneState doesn't pass its changes on): paused or running, the muted mic, and whether the
    /// kind can switch.
    @EnvironmentObject private var recorder: Recorder
    @ObservedObject private var auto = TemplateSettingsModel.shared
    /// The stop ring after a tap on Stop (DESIGN.md §7, Celebrations).
    @ObservedObject private var celebrations = CelebrationCenter.shared
    @State private var naming: RecordingMoment.ID? = nil
    @State private var nameDraft = ""
    /// Discard asks first: the recording moves to Recently Deleted.
    @State private var confirmDiscard = false
    @State private var discardLength = ""
    @State private var startedAt = Date()
    /// The input the recording hears, named again when the route changes (AirPods in, a headset out).
    @State private var mic = HomeScreen.currentMic()
    /// The inputs the microphone menu lists, read again when the route changes.
    @State private var inputs: [RecordingInput] = RecordingInputRules.menu(RecordingRoute.knownInputs())
    @State private var arrive: CGFloat = RecorderSheet.slideInNext ? 12 : 0

    private var paused: Bool { recorder.isPaused }
    private var saving: Bool { app.savingRecording }
    private var adding: Transcript? { app.continuing.flatMap { app.store.transcript($0) } }
    /// Audio only: no live words, and Stop keeps the sound with no transcript (AudioOnly.swift).
    private var audioOnly: Bool { adding == nil && !app.recordingThought && app.recordKind == .audio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.top, 14)
                    RecorderLivePanel(live: recorder.live, status: status, moments: app.recordingMoments)
                        .padding(.top, 16)
                    // A free recording from 9:00: where the free transcript ends; the recording keeps going (UnlockViews.swift).
                    RecordingLimitChip().padding(.top, 8)
                    if paused, let reason = app.autoPauseReason { autoPause(reason).padding(.top, 12) }
                    if !paused, let w = recorder.micWarning, let note = PhoneState.mutedNote(w) { mutedMic(note).padding(.top, 12) }
                    if !audioOnly { RecorderLiveWords(text: app.recordingWords).padding(.top, 14) }
                    momentsLine.padding(.top, 6)
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            controls.padding(.top, 4).padding(.bottom, 6)
        }
        // A tap anywhere on the recorder while the stop ring fills jumps it to the end (the controls are disabled
        // while saving, so this sits outside them).
        .celebrationTapSkips(celebrations.ring?.id)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Refined.paper.ignoresSafeArea())
        .offset(y: arrive)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .presentationBackground(Refined.paper)
        .onAppear {
            Self.visible = true
            Self.onScreen += 1
            startedAt = Date().addingTimeInterval(-app.recorder.live.elapsed)
            mic = HomeScreen.currentMic()
            inputs = RecordingInputRules.menu(RecordingRoute.knownInputs())
            guard Self.slideInNext else { return }
            Self.slideInNext = false
            withAnimation(.easeOut(duration: 0.15)) { arrive = 0 }
        }
        .onDisappear {
            Self.visible = false
            Self.onScreen = max(0, Self.onScreen - 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            mic = HomeScreen.currentMic()
            inputs = RecordingInputRules.menu(RecordingRoute.knownInputs())
        }
        .accessibilityAction(.escape) { app.minimizeRecorder() }
        // The chip's unlock sheet opens over the recorder; the recording goes on under it.
        .unlockSheetHost()
        .alert("Name this moment", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Moment", text: $nameDraft)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") {
                if let id = naming, let i = app.recordingMoments.firstIndex(where: { $0.id == id }) {
                    app.recordingMoments[i].name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                naming = nil
            }
        }
        .confirmationDialog("Move this recording to Recently Deleted?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { app.discardRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("\(discardLength) recorded. You can restore it for 30 days.")
        }
    }

    // MARK: Top

    /// Minimize on the leading side (the sheet's swipe does the same), the microphone on the trailing side.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { app.minimizeRecorder() } label: {
                ChevronDownMark()
                    .stroke(Refined.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
                    .frame(width: 44, height: 44)
                    .modifier(RecorderGlassCircle())
                    .contentShape(Circle())
            }
            .buttonStyle(RefinedPress())
            .accessibilityLabel("Minimize")
            .accessibilityHint(RecordPlacement.systemAccessory ? "Keeps recording. Record in the tab bar brings it back." : "Keeps recording. Use the bar above the tab bar to come back.")
            Spacer(minLength: 8)
            micMenu
        }
    }

    /// The microphone capsule is a menu of the inputs there are (the iPhone microphone, AirPods, a wired headset, a
    /// USB microphone): picking one records from it for the rest of this recording (`Recorder.useInput`). With only
    /// the iPhone microphone there's nothing to pick, and the menu says so.
    private var micMenu: some View {
        Menu {
            Section("Record from") {
                ForEach(inputs, id: \.uid) { input in
                    let name = RecordingInputRules.displayName(input)
                    Button {
                        // The capsule names what the route says after the move; a failed move keeps the old name.
                        if app.recorder.useInput(input.uid) != nil { mic = HomeScreen.currentMic() }
                    } label: {
                        if name == mic { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                    .disabled(input.uid == RecordingInputRules.builtInPlaceholder)
                }
            }
            if inputs.count < 2 {
                Text("Connect AirPods or a headset to record from it.")
            }
        } label: {
            HStack(spacing: 6) {
                IconGlyph(art: .iconMic, size: 15, color: Refined.ink).accessibilityHidden(true)
                Text(mic).refinedFont(.hint).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Refined.ink).accessibilityHidden(true)
            }
            .foregroundStyle(Refined.ink)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(Refined.neutral, in: Capsule())
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityLabel("Recording from \(mic)")
        .accessibilityHint("Opens a menu to record from another microphone.")
        .accessibilityIdentifier("recorder.microphone")
    }

    // MARK: Header

    /// The kind in the serif, then when it started and "Saved as you go", then what happens when you stop: the template
    /// Run automatically will run, or what the kind does.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            if adding == nil && app.canSwitchRecordingKind {
                kindMenu
            } else {
                Text(title).refinedFont(.transcriptTitle).foregroundStyle(Refined.ink)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(metaLine).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(metaLine + ". The recording is written to this iPhone while you talk, and keeps going with the screen locked.")
            if adding == nil {
                let runs = app.recordingChoice.template(settings: auto.settings, templates: app.store.allTemplates) != nil
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if runs { IconGlyph(art: .iconRecent, size: 13, color: Refined.mute).accessibilityHidden(true) }
                    Text(app.recordingChoice.recorderLine(settings: auto.settings, templates: app.store.allTemplates))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .refinedFont(.meta).foregroundStyle(Refined.mute)
                .padding(.top, 1)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The kind as a menu (DESIGN.md §6.10, Change kind while recording): the title with a chevron opens Record as,
    /// the rows you show with what each does and a check on the one it is, then More kinds for the rows you hid. Picking
    /// one changes the whole recording and it keeps going (`PhoneState.switchRecordingKind`). A system menu, like the
    /// microphone's, so its items carry SF Symbols.
    private var kindMenu: some View {
        let current = app.recordingChoice
        let shown = RecordAsStore.shared.visible
        let hidden = RecordChoice.all.filter { !shown.contains($0) }
        return Menu {
            Section("Record as") {
                ForEach(shown) { c in kindItem(c, current: current) }
            }
            if !hidden.isEmpty {
                Menu("More kinds") {
                    ForEach(hidden) { c in kindItem(c, current: current) }
                }
            }
            Text("The recording keeps going.")
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(title).refinedFont(.transcriptTitle).foregroundStyle(Refined.ink)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(Refined.mute)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Opens a menu to change what this recording is filed as. The recording keeps going.")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("recorder.kind")
    }

    private func kindItem(_ c: RecordChoice, current: RecordChoice) -> some View {
        Button { app.switchRecordingKind(to: c) } label: {
            // A menu item's second Text is its subtitle.
            // Each way's own glyph, as the Record as tray shows it, not an SF Symbol (IP-15).
            if c == current { Label(c.name, systemImage: "checkmark") } else { Label(c.name, menuArt: c.art, key: "rec-\(c.name)") }
            Text(c.recorderLine(settings: auto.settings, templates: app.store.allTemplates))
        }
    }

    /// "Voice note", "Meeting", "Thought", "Brain dump", "Audio only", or the transcript it adds to.
    private var title: String {
        if let adding { return "Adding to \u{201C}\(adding.title)\u{201D}" }
        return app.recordingChoice.name
    }

    /// "Today, 9:41 PM · Saved as you go", or "Saving…".
    private var metaLine: String {
        if saving { return "Saving\u{2026}" }
        return "\(RefinedRules.transcriptWhen(startedAt)) \u{00B7} Saved as you go"
    }

    private var status: String { saving ? "Saving\u{2026}" : paused ? "Paused" : "Recording" }

    /// Paused by an interruption (a call, a microphone change, audio it couldn't save): why, and Resume right here.
    private func autoPause(_ reason: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconGlyph(art: .iconAttention, size: 20, color: Refined.ink).accessibilityHidden(true)
            Text(reason).refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Resume") { app.togglePause() }.buttonStyle(RefinedActionStyle(kind: .strong))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .combine)
    }

    /// A wired or USB mic went silent and the recording moved to the iPhone's microphone (DESIGN.md §6.10, A muted microphone): what
    /// happened, and Switch back once you've unmuted it. The iPhone can't hear the muted mic while recording from its
    /// own, so it can't tell when you unmute; switching back is yours.
    private func mutedMic(_ note: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconGlyph(art: .iconAttention, size: 20, color: Refined.ink).accessibilityHidden(true)
            Text(note + " Unmute it, then switch back.").refinedFont(.body).foregroundStyle(Refined.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Switch back") {
                if app.recorder.switchBackFromMute() != nil { mic = HomeScreen.currentMic() }
            }
            .buttonStyle(RefinedActionStyle(kind: .strong))
            .accessibilityIdentifier("recorder.switchBack")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .combine)
    }

    // MARK: Moments

    /// "2 moments · 0:31 · 0:58", or "Marked 4:12 · 3 moments" for two seconds after a mark. A tap names the newest.
    @ViewBuilder private var momentsLine: some View {
        let list = app.recordingMoments
        if !list.isEmpty || app.lastMark != nil {
            Button {
                guard let m = list.last else { return }
                nameDraft = m.name; naming = m.id
            } label: {
                HStack(spacing: 6) {
                    IconGlyph(art: .iconMarked, size: 14, color: Refined.accentText).accessibilityHidden(true)
                    // The count changes in place as you mark (DESIGN.md §7); the moments' times never tick.
                    Text(app.lastMark.map { Marks.confirmation($0) } ?? RefinedRules.momentsLine(list.map(\.at)))
                        .refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1)
                        .countChange(list.count)
                }
                .frame(minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Marks.count(list.count))
            .accessibilityValue(list.map { RefinedRules.time($0.at) }.joined(separator: ", "))
            .accessibilityHint("Names the newest moment.")
        }
    }

    // MARK: Thumb row

    /// Mark moment, Stop, and Pause or Resume, with Discard under them, away from Stop. Discard asks first.
    private var controls: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 0) {
                RecorderControl(label: "Mark moment", action: { app.markMoment() }) {
                    IconGlyph(art: .iconMark, size: 22, color: Refined.ink)
                }
                .disabled(paused || saving)
                .accessibilityHint("Saves this point in the recording as a moment.")
                .frame(maxWidth: .infinity)
                CelebrationBurst(ticket: celebrations.ring, script: .ring) { ring in
                    RecorderStopButton(saving: saving, ring: ring, ringColor: celebrations.ring?.tone.fill ?? Refined.persimmon) {
                        app.stopRecording(from: .recorderButton)
                    }
                }
                    .accessibilityHint(stopHint)
                    .accessibilityIdentifier("native.recorder.stop")
                    .onAppear { RecorderSheet.stopColor = Refined.persimmon }
                    .frame(maxWidth: .infinity)
                RecorderControl(label: paused ? "Resume" : "Pause", action: { app.togglePause() }) {
                    if paused { RecorderPlayGlyph().fill(Refined.ink).frame(width: 15, height: 18).offset(x: 2) }
                    else { RecorderPauseGlyph().fill(Refined.ink).frame(width: 15, height: 18) }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(saving)
            Button("Discard") {
                discardLength = app.recorder.elapsed.timecode
                confirmDiscard = true
            }
            .refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.dim)
            .frame(minWidth: 88, minHeight: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityHint("Asks before it moves the recording to Recently Deleted.")
        }
    }

    private var stopHint: String {
        if audioOnly { return "Stops and saves the sound, with no transcript." }
        return adding == nil && !app.recordingThought ? "Stops and transcribes the recording." : "Stops and adds the recording."
    }
}

/// The clock panel, on its own so only it redraws as the meter moves.
private struct RecorderLivePanel: View {
    @ObservedObject var live: LiveMeter
    var status: String
    var moments: [RecordingMoment]
    var body: some View {
        RecorderClockPanel(status: status, elapsed: live.elapsed, levels: live.levels,
                           momentsAgo: moments.map { live.elapsed - $0.at })
    }
}

/// Minimize's circle: the system's glass on iOS 26 (a glyph only, no text), the neutral wash before it and under
/// Reduce Transparency.
private struct RecorderGlassCircle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Refined.neutral, in: Circle())
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())   // brand: glass ok (no text)
        } else {
            content.background(Refined.neutral, in: Circle())
        }
    }
}

// MARK: - Live words

/// "Show words while you record": the newest three lines of your words in the serif, older words in `mute` and the
/// newest sentence in ink (`RefinedRules.liveWords`), whole words only. A preview: the saved transcript comes from the
/// full engine after Stop. Nothing at all when live words are off or haven't heard anything.
struct RecorderLiveWords: View {
    @ObservedObject var text: RecordingLiveText
    @AppStorage(RecordingLiveText.enabledKey) private var showWords = true
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = CGFloat(RefinedRules.TextRole.reading.size(mac: false))

    var body: some View {
        let w = text.shown.tail(260)
        if showWords && !w.isEmpty {
            let changing = w.volatile.split(whereSeparator: { $0.isWhitespace }).count
            let base = CGFloat(RefinedRules.TextRole.reading.size(mac: false))
            let spacing = CGFloat(RefinedRules.lineSpacing(.reading, mac: false)) * size / base
            TailWords(text: w.text, lines: 3, lineHeight: Self.serifLineHeight(size) + spacing) { tail in
                let parts = RefinedRules.liveWords(tail, changing: changing)
                (Text(parts.older).foregroundStyle(Refined.mute)
                    + Text(parts.older.isEmpty || parts.newest.isEmpty ? "" : " ")
                    + Text(parts.newest).foregroundStyle(Refined.ink))
                    .font(.system(size: size, design: .serif))   // type: scaled (@ScaledMetric)
                    .lineSpacing(spacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live text")
            .accessibilityValue(w.text)
        }
    }

    /// One line of the system serif at this size.
    static func serifLineHeight(_ size: CGFloat) -> CGFloat {
        let sans = UIFont.systemFont(ofSize: size)
        guard let serif = sans.fontDescriptor.withDesign(.serif) else { return sans.lineHeight }
        return UIFont(descriptor: serif, size: size).lineHeight
    }
}
