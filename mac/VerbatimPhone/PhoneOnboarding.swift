import SwiftUI
import AVFoundation

/// The welcome tour on iPhone: what Verbatim does, the microphone, and transcription quality with iCloud status. Drawn
/// on the refined kit (DESIGN.md §13): the step count, the large serif title, cards, and the kit's strong action.
struct PhoneOnboarding: View {
    @EnvironmentObject var app: PhoneState
    @State private var step: Int
    @State private var micAllowed = AVAudioApplication.shared.recordPermission == .granted
    /// The last step's iCloud sync switch (off on a new install; `Cloud.settleSyncDefault`).
    @State private var syncWanted = Cloud.wantsSync
    @Environment(\.limitMotion) private var reduceMotion
    private let total = 3

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Step \(step + 1) of \(total)").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                .frame(maxWidth: .infinity).padding(.top, 16)
            Group {
                switch step {
                case 0: welcome
                case 1: microphone
                default: quality
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule().fill(i <= step ? Refined.accentText : Refined.track).frame(width: 22, height: 4)
                }
            }
            .frame(maxWidth: .infinity).padding(.bottom, 18)
            .accessibilityHidden(true)
            primary
            secondary.frame(maxWidth: .infinity).padding(.top, 14).padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .background(Refined.paper.ignoresSafeArea())
        .animation(Motion.settle, value: step)
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The lockup (DESIGN.md §4) and the tagline in the serif.
            HStack(spacing: 10) {
                BarsMark(color: Refined.persimmon).frame(width: 19, height: 20)
                Text("\(Text("verbose").foregroundStyle(Refined.ink))\(Text(".").foregroundStyle(Refined.accentText))")
                    .font(.system(size: 22, design: .serif))
            }
            .padding(.top, 22)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")
            title(Refined.tagline)
            para("Record a thought, an interview, or a call, or paste a link to a video or podcast. Verbose writes it down on this iPhone. Everything stays on this iPhone unless you turn on iCloud sync.")
            BrandGlyph(art: .diagramCapture, color: Refined.ink, minLineWidth: 1.2)
                .frame(width: 170, height: 220).frame(maxWidth: .infinity).padding(.top, 50)
                .accessibilityHidden(true)
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Let Verbose hear you.")
            para("Only while you record. Audio is transcribed on this iPhone and isn't uploaded anywhere except your own iCloud, when sync is on.")
            HStack(spacing: 14) {
                IconSquare(art: .capture, hue: .persimmon)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text("Keeps recording with the screen locked").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                Spacer()
                if micAllowed { RefinedCheckbox(on: true, size: 22).accessibilityLabel("Allowed") }
            }
            .padding(16)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
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
                                Text(p.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(app.preset == p ? Refined.accentText : Refined.ink)
                                Text(p == .defaultPreset ? "Default · " + p.pitch : p.pitch)
                                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                            }
                            Spacer()
                            if app.preset == p { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Refined.accentText) }
                        }
                        .padding(16)
                        .background(app.preset == p ? Refined.persimmonTint : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RefinedRowPress())
                    .accessibilityAddTraits(app.preset == p ? .isSelected : [])
                    if p != .accurate { PaperDivider(leading: 16) }
                }
            }
            .background(Refined.card)
            .clipShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
            .padding(.top, 22)
            sync.padding(.top, 16)
        }
    }

    /// iCloud sync, offered here and off unless you turn it on. Already syncing (the tour again from Settings): the
    /// status only, since turning it off copies your library down first (Settings › Sync and storage).
    @ViewBuilder private var sync: some View {
        if Cloud.enabled {
            Label { Text("Syncing with iCloud. Turn it off in Settings › Sync and storage.") } icon: { ArtIcon(art: .iconSync, size: 14) }
                .refinedFont(.hint).foregroundStyle(Refined.dim)
        } else if Cloud.available {
            Toggle(isOn: Binding(get: { syncWanted }, set: { on in syncWanted = on; Cloud.setWantsSync(on) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud sync").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(syncWanted
                         ? "Your recordings, transcripts, Dictionary, and snippets go to your own iCloud Drive, so they show on your Mac too. Starts the next time you open Verbose."
                         : "Off: everything stays on this iPhone. Turn it on to see your transcripts on your Mac too. Audio and transcripts go to your own iCloud Drive.")
                        .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).refinedSwitchTint()
        } else {
            Label { Text("iCloud is off, so everything stays on this iPhone") } icon: { ArtIcon(art: .iconSyncOff, size: 14) }
                .refinedFont(.hint).foregroundStyle(Refined.dim)
        }
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case 0: bigButton("Get started") { step = 1 }
        case 1:
            if micAllowed { bigButton("Continue") { step = 2 } }
            else {
                bigButton("Allow microphone") {
                    AVAudioApplication.requestRecordPermission { ok in
                        DispatchQueue.main.async { micAllowed = ok; step = 2 }
                    }
                }
            }
        default: bigButton("Start using Verbose") { done() }
        }
    }

    @ViewBuilder private var secondary: some View {
        switch step {
        case 0: quiet("Skip the tour") { done() }
        case 1: quiet(micAllowed ? "Back" : "Not now") { if micAllowed { step = 0 } else { step = 2 } }
        default: quiet("Back") { step = 1 }
        }
    }

    /// The step's action: the kit's strong action, full width.
    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).frame(minHeight: 50) }
            .buttonStyle(RefinedActionStyle(kind: .strong))
    }

    /// Skip, Back, or Not now: plain text in `dim`, 44 pt to tap.
    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .refinedFont(.hint, weight: .medium).foregroundStyle(Refined.dim)
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
    }

    private func title(_ s: String) -> some View {
        Text(s).refinedFont(.largeTitle).foregroundStyle(Refined.ink).padding(.top, 18).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
    private func para(_ s: String) -> some View {
        Text(s).refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
    }

    private func done() {
        Onboarding.finish()
        app.showOnboarding = false
    }
}
