import SwiftUI
import AVFoundation

/// The welcome tour on iPhone: what Verbatim does, Pick a look (Verbose style or Native; tapping one switches the tour
/// itself live), the microphone, and transcription quality with iCloud status. New installs start in Verbose style;
/// skipping the tour keeps it.
struct PhoneOnboarding: View {
    @EnvironmentObject var app: PhoneState
    @State private var step: Int
    @State private var micAllowed = AVAudioApplication.shared.recordPermission == .granted
    /// The last step's iCloud sync switch (off on a new install; `Cloud.settleSyncDefault`).
    @State private var syncWanted = Cloud.wantsSync
    @Environment(\.limitMotion) private var reduceMotion
    @Environment(\.look) private var look
    /// The look, chosen on step 2 (`AppLook`, per device in the App Group).
    @AppStorage(AppLook.key, store: AppLook.store) private var lookRaw = AppLook.verbose.rawValue
    private let total = 4
    /// The step indexes, for the screenshot tour.
    static let lookStep = 1

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if look.isNative {
                Text("Step \(step + 1) of \(total)").font(.footnote.weight(.semibold)).foregroundStyle(.lookMute)
                    .frame(maxWidth: .infinity).padding(.top, 16)
            } else {
                HStack(spacing: 10) {
                    Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                    Overline(text: ["Verbose", "Look", "Microphone", "Last step"][step], color: Ink.dim)
                    DottedRule().frame(height: 1)
                    Text(String(format: "%02d / %02d", step + 1, total)).lookMono(11).foregroundStyle(.lookMute)
                }
                .padding(.top, 16)
            }
            Group {
                switch step {
                case 0: welcome
                case Self.lookStep: lookPicker
                case 2: microphone
                default: quality
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule().fill(i <= step ? (look.isNative ? NativeInk.accent : Ink.ink) : (look.isNative ? NativeInk.fillStrong : Ink.track)).frame(width: 22, height: 4)
                }
            }
            .frame(maxWidth: .infinity).padding(.bottom, 18)
            .accessibilityHidden(true)
            primary
            secondary.frame(maxWidth: .infinity).padding(.top, 14).padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .phonePage()
        .animation(Motion.settle, value: step)
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The lockup (DESIGN.md §4) and the tagline in the serif.
            HStack(spacing: 10) {
                BarsMark(color: Ink.persimmon).frame(width: 19, height: 20)
                Ink.wordmark(22)
            }
            .padding(.top, 22)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")
            title(Ink.tagline)
            para("Record a thought, an interview, or a call, or paste a link to a video or podcast. Verbose writes it down on this iPhone. Everything stays on this iPhone unless you turn on iCloud sync.")
            BrandGlyph(art: .diagramCapture, color: Ink.ink, minLineWidth: 1.2)
                .frame(width: 170, height: 220).frame(maxWidth: .infinity).padding(.top, 50)
                .accessibilityHidden(true)
        }
    }

    /// Both looks side by side; tapping one switches the look at once, so this step itself shows it.
    private var lookPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(look.isNative ? "Pick a look" : "Pick a look.")
            para("Both work the same. Choose the one you'd rather look at.")
            LookPicker(selection: Binding(get: { AppLook(rawValue: lookRaw) ?? .verbose }, set: { LookSwitch.shared.pick($0) }), thumbWidth: 112)
                .padding(.top, 28)
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Let Verbose hear you.")
            para("Only while you record. Audio is transcribed on this iPhone and isn't uploaded anywhere except your own iCloud, when sync is on.")
            HStack(spacing: 14) {
                IconGlyph(art: .capture, size: 22, color: Ink.ink)
                    .frame(width: 44, height: 44).background(Ink.persimmonTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone").font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk)
                    Text("Keeps recording with the screen locked").font(.system(size: 13)).foregroundStyle(.lookMute)
                }
                Spacer()
                if micAllowed { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Ink.sageText) }
            }
            .padding(16)
            .background(.lookReader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(.lookHairline))
            .padding(.top, 28)
        }
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Ready when you are.")
            para("Pick how careful transcription should be. The model downloads once.")
            VStack(spacing: 0) {
                ForEach([QualityPreset.english, .fast, .balanced, .accurate], id: \.self) { p in
                    Button { app.presetRaw = p.rawValue } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk)
                                Text(p == .defaultPreset ? "Default · " + p.pitch : p.pitch)
                                    .font(.system(size: 13)).foregroundStyle(.lookMute)
                            }
                            Spacer()
                            if app.preset == p { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.sageText) }
                        }
                        .padding(16)
                        .background(app.preset == p ? Ink.sageTint : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(app.preset == p ? .isSelected : [])
                    if p != .accurate { Divider().overlay(Ink.hairline) }
                }
            }
            .background(.lookReader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(.lookHairline))
            .padding(.top, 22)
            sync.padding(.top, 16)
        }
    }

    /// iCloud sync, offered here and off unless you turn it on. Already syncing (the tour again from Settings): the
    /// status only, since turning it off copies your library down first (Settings › Sync and storage).
    @ViewBuilder private var sync: some View {
        if Cloud.enabled {
            Label { Text("Syncing with iCloud. Turn it off in Settings › Sync and storage.") } icon: { ArtIcon(art: .iconSync, size: 14) }
                .font(.system(size: 14)).foregroundStyle(.lookDim)
        } else if Cloud.available {
            Toggle(isOn: Binding(get: { syncWanted }, set: { on in syncWanted = on; Cloud.setWantsSync(on) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud sync").font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk)
                    Text(syncWanted
                         ? "Your recordings, transcripts, Dictionary, and snippets go to your own iCloud Drive, so they show on your Mac too. Starts the next time you open Verbose."
                         : "Off: everything stays on this iPhone. Turn it on to see your transcripts on your Mac too. Audio and transcripts go to your own iCloud Drive.")
                        .font(.system(size: 13)).foregroundStyle(.lookMute).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(PhoneInk.switchOn)
        } else {
            Label { Text("iCloud is off, so everything stays on this iPhone") } icon: { ArtIcon(art: .iconSyncOff, size: 14) }
                .font(.system(size: 14)).foregroundStyle(.lookDim)
        }
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case 0: bigButton("Get started", fill: Ink.interactive, text: Ink.onInteractive) { step = 1 }
        case Self.lookStep: bigButton("Continue", fill: Ink.interactive, text: Ink.onInteractive) { step = 2 }
        case 2:
            if micAllowed { bigButton("Continue", fill: Ink.interactive, text: Ink.onInteractive) { step = 3 } }
            else {
                bigButton("Allow microphone", fill: Ink.persimmon, text: Ink.inkFixed) {
                    AVAudioApplication.requestRecordPermission { ok in
                        DispatchQueue.main.async { micAllowed = ok; step = 3 }
                    }
                }
            }
        default: bigButton("Start using Verbose", fill: Ink.interactive, text: Ink.onInteractive) { done() }
        }
    }

    @ViewBuilder private var secondary: some View {
        switch step {
        case 0: Button("Skip the tour") { done() }.font(.system(size: 15, weight: .medium)).foregroundStyle(.lookDim)
        case Self.lookStep:
            Text("You can change this anytime in Settings › Appearance.").font(.system(size: 13.5)).foregroundStyle(.lookMute)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        case 2: Button(micAllowed ? "Back" : "Not now") { if micAllowed { step = 1 } else { step = 3 } }.font(.system(size: 15, weight: .medium)).foregroundStyle(.lookDim)
        default: Button("Back") { step = 2 }.font(.system(size: 15, weight: .medium)).foregroundStyle(.lookDim)
        }
    }

    /// Native: a full-width persimmon capsule with a white label (black in dark, `PremiumInk.onAccent`), whatever the
    /// Verbose style fill.
    private func bigButton(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(look.isNative ? PremiumInk.onAccent : text)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(look.isNative ? NativeInk.accent : fill, in: RoundedRectangle(cornerRadius: look.isNative ? 26 : Radius.tile, style: .continuous))
        }
        .buttonStyle(PressScale())
    }

    private func title(_ s: String) -> some View {
        Text(s).font(look.isNative ? .largeTitle.bold() : Ink.serif(36)).foregroundStyle(.lookInk).padding(.top, 18).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
    }
    private func para(_ s: String) -> some View {
        Text(s).font(.system(size: 16)).foregroundStyle(.lookDim).fixedSize(horizontal: false, vertical: true)
    }

    private func done() {
        Onboarding.finish()
        app.showOnboarding = false
    }
}
