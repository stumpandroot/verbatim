import SwiftUI
import AVFoundation

/// The welcome tour on iPhone: what Verbatim does, the microphone, the ways to record, the keyboard, and transcription
/// quality with iCloud status (the two middle steps: mockup "Verbose Tour Steps", October 30, 2026). Drawn
/// on the refined kit (DESIGN.md §13): the step count, the large serif title, cards, and the kit's strong action.
struct PhoneOnboarding: View {
    @EnvironmentObject var app: PhoneState
    @State private var step: Int
    @State private var micAllowed = AVAudioApplication.shared.recordPermission == .granted
    /// The last step's iCloud sync switch (off on a new install; `Cloud.settleSyncDefault`).
    @State private var syncWanted = Cloud.wantsSync
    /// The keyboard step's Open Settings was tapped, so its button reads Continue.
    @State private var openedSettings = false
    @Environment(\.limitMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    private let total = 5

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Step \(step + 1) of \(total)").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                .frame(maxWidth: .infinity).padding(.top, 16)
            Group {
                switch step {
                case 0: welcome
                case 1: microphone
                case 2: ways
                case 3: keyboard
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

    /// The ways to record. They only show; nothing here starts a recording.
    private var ways: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Catch it however it comes.")
            para("Tap Record on Home for a voice note. Touch and hold it for the other kinds.")
            VStack(spacing: 0) {
                wayRow(.capture, .persimmon, "Record", "Keeps going with the screen locked. Touch and hold for:") {
                    FlowRow(spacing: 6, lineSpacing: 6) {
                        kindChip("Meeting", .persimmon); kindChip("Thought", .butter); kindChip("Brain dump", .butter); kindChip("Audio only", .petal)
                    }
                    .padding(.top, 6)
                    .accessibilityElement(children: .combine)
                }
                PaperDivider(leading: 66)
                wayRow(.iconShare, .sage, "Share to Verbose", "From Voice Memos, Files, or a podcast app.") { EmptyView() }
                PaperDivider(leading: 66)
                wayRow(.iconWidgets, .petal, "Widgets and the Action button", "Start a recording without opening the app. Set them up in Settings.") { EmptyView() }
            }
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .padding(.top, 24)
        }
    }

    /// Adding the Verbose keyboard: Open Settings goes to Verbose's page in the Settings app, where Keyboards is.
    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Dictate in any app.")
            para("Add the Verbose keyboard, then tap Start a session in any app. Verbose turns on the mic and sends you back to talk.")
            VStack(spacing: 0) {
                numberRow(1, "Open Settings", "The button below opens Verbose's page in Settings.")
                PaperDivider(leading: 16)
                numberRow(2, "Keyboards", "Turn on Verbose and Allow Full Access.")
                PaperDivider(leading: 16)
                numberRow(3, "In any app", "Touch and hold the globe key, then choose Verbose.")
            }
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .padding(.top, 24)
            Text("Full Access lets the keyboard open Verbose and receive your words. Listening happens in the app.")
                .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        }
    }

    private func wayRow<Extra: View>(_ art: BrandArt, _ hue: RefinedHue, _ name: String, _ note: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconSquare(art: art, hue: hue)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(note).refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private func kindChip(_ name: String, _ hue: RefinedHue) -> some View {
        Text(name).refinedFont(.chip, weight: .semibold).foregroundStyle(Refined.onBadge(hue)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Refined.badge(hue), in: Capsule())
    }

    private func numberRow(_ n: Int, _ name: String, _ note: String) -> some View {
        HStack(spacing: 14) {
            Text("\(n)").refinedFont(.chip, weight: .semibold).monospacedDigit().foregroundStyle(Refined.ink)
                .frame(width: 24, height: 24).background(Refined.neutral, in: Circle())
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(note).refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
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
                // A neutral Continue that always leads to the system's own question, where you decide (guideline
                // 5.1.1(iv), App Review AR-07). No "Allow" wording and no way past it that skips the question.
                bigButton("Continue") {
                    AVAudioApplication.requestRecordPermission { ok in
                        DispatchQueue.main.async { micAllowed = ok; step = 2 }
                    }
                }
            }
        case 2: bigButton("Continue") { step = 3 }
        case 3:
            if openedSettings { bigButton("Continue") { step = 4 } }
            else {
                bigButton("Open Settings") {
                    openedSettings = true
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        default: bigButton("Start using Verbose") { done() }
        }
    }

    @ViewBuilder private var secondary: some View {
        switch step {
        case 0: quiet("Skip the tour") { done() }
        case 1: quiet("Back") { step = 0 }
        case 2: quiet("Back") { step = 1 }
        case 3: quiet(openedSettings ? "Back" : "Later") { step = openedSettings ? 2 : 4 }
        default: quiet("Back") { step = 3 }
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
