import SwiftUI
import AVFoundation

/// The welcome tour on the Mac, on the refined kit (DESIGN.md §13): what Verbatim does, permissions, a first dictation,
/// where the Ribbon lives, and transcription quality. Shown once after an update and whenever Settings asks for it.
/// Steps are `OnboardingStep` (below).
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var flow = FlowSettings.shared
    @State private var step: Int
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var trusted = false
    @State private var practice = ""
    @State private var edge: BarEdge = .bottom
    @FocusState private var practiceFocused: Bool
    @Environment(\.limitMotion) private var reduceMotion
    private let total = OnboardingStep.count
    private var current: OnboardingStep { OnboardingStep.at(step) }

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The step's name and where you are, in sentence case.
            HStack(spacing: 10) {
                Text(label).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                Spacer(minLength: 8)
                Text("\(step + 1) of \(total)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
            }
            Group {
                switch current {
                case .welcome: welcome
                case .permissions: permissions
                case .tryIt: tryIt
                case .placement: placement
                case .quality: quality
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 26)
        .frame(width: 640, height: 460)
        .background(Refined.paper)
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: step)
        .tint(Refined.accentText)
        .onAppear { refresh(); edge = currentEdge }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .interactiveDismissDisabled()
    }

    private var label: String { current.label }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The lockup (DESIGN.md §4) and the tagline in the serif.
            HStack(spacing: 10) {
                BarsMark(color: Refined.persimmon).frame(width: 19, height: 20)
                Text("\(Text("verbose").foregroundStyle(Refined.ink))\(Text(".").foregroundStyle(Refined.accentText))")
                    .font(.system(size: 22, design: .serif))
            }
            .padding(.top, 18)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")
            title(Refined.tagline)
            para("Record, import, or dictate. Verbose turns it into text you can use, and it all stays on your Mac.")
            HStack(spacing: 12) {
                pillar("Capture", "Record, import, a link", .capture, .persimmon)
                pillar("Refine", "Clean up, original kept", .refine, .petal)
                pillar("Dictate", "Talk into any app", .document, .butter)
            }
            .padding(.top, 22)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Two switches, then you're set")
            para("macOS asks you to allow these once. Nothing you say leaves this Mac.")
            PaperCard {
                permissionRow(art: .iconMic, hue: .persimmon, name: "Microphone", why: "To record and dictate",
                              ok: micStatus == .authorized, action: micStatus == .notDetermined ? "Allow…" : "Open Settings") {
                    if micStatus == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refresh() } }
                    } else { DictationController.openMicrophoneSettings() }
                }
                PaperDivider(leading: 52, trailing: 16)
                permissionRow(art: .iconAccessibility, hue: .sage, name: "Accessibility", why: "To hear your hotkey and paste into other apps",
                              ok: trusted, action: "Allow…") { app.dictation.openAccessibilitySettings() }
            }
            .padding(.top, 18)
            Text("This page notices when you switch them on. No restart needed.")
                .refinedFont(.meta).foregroundStyle(Refined.mute).padding(.top, 10)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Hold").refinedFont(.largeTitle)
                Text(app.dictation.hotkey.title).refinedFont(.rowTitle, weight: .semibold)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Refined.neutral, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("and say hello").refinedFont(.largeTitle)
            }
            .foregroundStyle(Refined.ink).padding(.top, 14).padding(.bottom, 6)
            para(trusted ? "Let go, and your words land here. Tap the key once to keep listening hands-free; tap again to finish."
                         : "Dictation needs Accessibility first. Go back a step to allow it, or skip this for now.")
            TextEditor(text: $practice)
                .refinedFont(.body).foregroundStyle(Refined.ink).scrollContentBackground(.hidden).padding(10)
                .frame(height: 104)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                .overlay { if practiceFocused { RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous).strokeBorder(Refined.separator, lineWidth: 1.5) } }
                .focused($practiceFocused)
                .padding(.top, 16)
                .accessibilityLabel("Practice dictation")
            if !practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("That's it. Every dictation is also kept in Dictations.", systemImage: "checkmark.circle.fill")
                    .refinedFont(.hint).foregroundStyle(Refined.ink).padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .onAppear { practiceFocused = true }
    }

    private var placement: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Where should it live?")
            para("A sliver at the edge of your screen. Click it to dictate, right-click for options. Drag it anytime.")
            HStack(spacing: 14) {
                edgeChoice(.bottom, "Bottom"); edgeChoice(.left, "Left"); edgeChoice(.right, "Right")
            }
            .padding(.top, 20)
            .opacity(flow.showBar ? 1 : 0.45)
            Toggle("Hide the Ribbon; I'll use the hotkey", isOn: Binding(get: { !flow.showBar }, set: { flow.showBar = !$0 }))
                .toggleStyle(.checkbox).refinedFont(.hint).foregroundStyle(Refined.dim).padding(.top, 14)
        }
    }

    /// The last step asks two things, one axis each (build 228 review, M-48): which languages, then (for many) speed
    /// or accuracy. Each choice says what it trades. The pick takes the persimmon tint with a check.
    private var quality: some View {
        let many = app.preset != .english
        return VStack(alignment: .leading, spacing: 0) {
            title("Ready when you are")
            para("Two quick choices. You can change either one in Settings.")
            questionLabel("Languages").padding(.top, 14)
            RefinedSegmented(label: "Languages", options: [(false, "English only"), (true, "Many languages")],
                             selection: Binding(get: { many }, set: { m in app.presetRaw = (m ? QualityPreset.balanced : .english).rawValue }))
                .fixedSize()
                .background {
                    // The self-test's handles on each half.
                    HStack(spacing: 0) {
                        Color.clear.uiTarget("onboarding-languages-english")
                        Color.clear.uiTarget("onboarding-languages-many")
                    }
                    .allowsHitTesting(false)
                }
                .padding(.top, 8)
            if many {
                questionLabel("Speed or accuracy").padding(.top, 16)
                PaperCard {
                    ForEach(Array([QualityPreset.fast, .balanced, .accurate].enumerated()), id: \.element) { i, p in
                        if i > 0 { PaperDivider(leading: 14, trailing: 14) }
                        qualityRow(p)
                    }
                }
                .padding(.top, 8)
            } else {
                Text("Fast and accurate for English, with Parakeet v2. The default; pick Many languages for anything else.")
                    .refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            HStack(spacing: 8) {
                IconGlyph(art: Cloud.enabled ? .iconSync : .iconSyncOff, size: 15, color: Refined.dim)
                Text(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off, so everything stays on this Mac")
            }
            .refinedFont(.hint).foregroundStyle(Refined.dim).padding(.top, 12)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if current == .welcome {
                Button("Skip the tour") { done() }.buttonStyle(.plain).refinedFont(.hint).foregroundStyle(Refined.dim)
            } else {
                Button("Back") { step -= 1 }.controlSize(.large)
                if current == .permissions && !(trusted && micStatus == .authorized) {
                    Button("Do this later") { step += 1 }.buttonStyle(.plain).refinedFont(.hint).foregroundStyle(Refined.mute).padding(.leading, 14)
                }
                if current == .tryIt && practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Skip this step") { step += 1 }.buttonStyle(.plain).refinedFont(.hint).foregroundStyle(Refined.mute).padding(.leading, 14)
                }
            }
            Spacer()
            primaryButton
                .disabled(current == .permissions && !(trusted && micStatus == .authorized))
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Continue: the system's prominent button in the accent.
    private var primaryButton: some View {
        Button(primaryTitle) { if step == total - 1 { done() } else { step += 1 } }
            .buttonStyle(.borderedProminent).controlSize(.large)
    }

    private var primaryTitle: String {
        switch current {
        case .welcome: return "Get started"
        case .tryIt: return practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Continue" : "Nice, continue"
        case .quality: return "Start using Verbose"
        default: return "Continue"
        }
    }

    private func done() {
        Onboarding.finish()
        app.showOnboarding = false
    }

    // MARK: Pieces

    private func questionLabel(_ s: String) -> some View {
        Text(s).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
    }

    /// One speed-or-accuracy choice: its name, what it trades, and a check when it's the one.
    private func qualityRow(_ p: QualityPreset) -> some View {
        let on = app.preset == p
        return PaperRowButton(selected: on, action: { app.presetRaw = p.rawValue }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(Self.tradeOff(p)).refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Refined.accentText).opacity(on ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .uiTarget("onboarding-quality-\(p.rawValue)")
    }

    /// What each choice trades, said against the others.
    static func tradeOff(_ p: QualityPreset) -> String {
        switch p {
        case .fast: return Engines.reduxSupported ? "Quickest, with the smallest download (about 220 MB)." : "Needs \(Engines.newerOS); uses Balanced here."
        case .balanced: return "Good for most recordings, in 25 languages (about 480 MB)."
        case .accurate: return "Most accurate. About as fast as Balanced (595 MB)."
        case .english, .advanced: return p.pitch
        }
    }

    private func title(_ s: String) -> some View {
        Text(s).refinedFont(.largeTitle).foregroundStyle(Refined.ink).padding(.top, 14).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
    private func para(_ s: String) -> some View {
        Text(s).refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
    }

    /// One of the three ideas on a tile in its hue (the kit's Full fills, with their ink).
    private func pillar(_ name: String, _ note: String, _ art: BrandArt, _ hue: RefinedHue) -> some View {
        let ink = Refined.onBadge(hue)
        return VStack(alignment: .leading, spacing: 2) {
            IconGlyph(art: art, size: 30, color: ink)
            Spacer(minLength: 8)
            Text(name).refinedFont(.sectionTitle).foregroundStyle(ink)
            Text(note).refinedFont(.meta, weight: .semibold).foregroundStyle(ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .leading)
        .refinedSurface(Refined.badge(hue), radius: RefinedPlatform.radius(.tile))
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(art: BrandArt, hue: RefinedHue, name: String, why: String, ok: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            IconSquare(art: art, hue: hue)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(why).refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            Spacer()
            if ok {
                Label("Allowed", systemImage: "checkmark").refinedFont(.chip, weight: .semibold).foregroundStyle(Refined.ink)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Refined.badge(.sage), in: Capsule())
                    .transition(.opacity)
            } else {
                Button(action, action: perform).buttonStyle(RefinedActionStyle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .animation(Motion.settle, value: ok)
    }

    private func edgeChoice(_ e: BarEdge, _ name: String) -> some View {
        Button { edge = e; app.dictation.bar?.moveTo(edge: e) } label: {
            VStack(spacing: 8) {
                ZStack(alignment: e == .bottom ? .bottom : (e == .left ? .leading : .trailing)) {
                    RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous).fill(edge == e ? Refined.persimmonTint : Refined.card)
                    UnevenRoundedRectangle(topLeadingRadius: e == .right ? 3 : (e == .bottom ? 3 : 0), bottomLeadingRadius: e == .right ? 3 : 0,
                                           bottomTrailingRadius: e == .left ? 3 : 0, topTrailingRadius: e == .left || e == .bottom ? 3 : 0, style: .continuous)
                        .fill(Refined.ink)
                        .frame(width: e == .bottom ? 34 : 5, height: e == .bottom ? 5 : 34)
                        .padding(e == .bottom ? .bottom : (e == .left ? .leading : .trailing), 1)
                }
                .frame(height: 104)
                Text(name).refinedFont(.rowTitle, weight: edge == e ? .semibold : .regular).foregroundStyle(edge == e ? Refined.accentText : Refined.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(edge == e ? .isSelected : [])
    }

    private var currentEdge: BarEdge { FlowSettings.shared.positions.values.first?.edge ?? .bottom }

    private func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        trusted = app.dictation.accessibilityTrusted
    }
}

/// The Mac welcome tour's steps, in order.
enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, tryIt, placement, quality

    /// The header's label for the step.
    var label: String {
        switch self {
        case .welcome: return "Welcome to Verbose"
        case .permissions: return "Permissions"
        case .tryIt: return "Try it"
        case .placement: return "The Ribbon"
        case .quality: return "Last step"
        }
    }

    static var count: Int { allCases.count }

    /// The step for an index, clamped to the tour (the self-test opens the tour on a given step).
    static func at(_ index: Int) -> OnboardingStep { OnboardingStep(rawValue: max(0, min(count - 1, index))) ?? .welcome }
}
