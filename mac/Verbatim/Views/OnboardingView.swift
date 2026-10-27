import SwiftUI
import AVFoundation

/// The welcome tour on the Mac: what Verbatim does, the look (Verbose style or Native), permissions, a first
/// dictation, where the Ribbon lives, and transcription quality. Shown once after an update and whenever Settings asks
/// for it. Steps are `OnboardingStep` (LookRules.swift). Choosing a look crossfades the tour itself into it.
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
    @Environment(\.look) private var look
    private let total = OnboardingStep.count
    private var current: OnboardingStep { OnboardingStep.at(step) }

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if look == .native {
                Text(current.counter).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: current == .look ? .center : .leading)
            } else {
                // The step's eyebrow in sentence case (mono 12.5 with its diamond), never an uppercase overline.
                HStack(spacing: 10) {
                    Eyebrow(text: label, color: Ink.dim)
                    DottedRule().frame(height: 1)
                    Text(String(format: "%02d / %02d", step + 1, total)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                }
            }
            Group {
                switch current {
                case .welcome: welcome
                case .look: pickLook
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
        .background(Ink.paper)
        .animation(Motion.settle, value: step)
        // Choosing a look redraws the tour in it, with a crossfade (the step stays).
        .lookRebuild()
        .lookTint(look)
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
                BarsMark(color: Ink.persimmon).frame(width: 19, height: 20)
                Ink.wordmark(22)
            }
            .padding(.top, 18)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")
            title(Ink.tagline)
            para("Record, import, or dictate. Verbose turns it into text you can use, and it all stays on your Mac.")
            HStack(spacing: 12) {
                pillar("01", "Capture", "Record, import, a link", .capture, Ink.persimmon)
                pillar("02", "Refine", "Clean up, original kept", .refine, Ink.petal)
                pillar("03", "Dictate", "Talk into any app", .document, Ink.butter)
            }
            .padding(.top, 22)
        }
    }

    /// "Pick a look": the two looks side by side; choosing one applies it at once, so the tour itself is the preview.
    /// New installs start in Verbose style, so this opens with it chosen; Continue keeps whichever is chosen.
    private var pickLook: some View {
        let native = look == .native
        return VStack(alignment: native ? .center : .leading, spacing: 0) {
            title(native ? "Pick a look" : "Pick a look.")
            para("Both work the same. Choose the one you'd rather look at.")
            LookPicker(thumbnail: 210)
                .padding(.top, 24)
            Text("You can change this anytime in Settings › Personalization and preferences.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.top, 20)
        }
        .multilineTextAlignment(native ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: native ? .center : .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Two switches, then you're set.")
            para("macOS asks you to allow these once. Nothing you say leaves this Mac.")
            VStack(spacing: 0) {
                permissionRow(symbol: "mic", tint: Ink.persimmonTint, name: "Microphone", why: "To record and dictate",
                              ok: micStatus == .authorized, action: micStatus == .notDetermined ? "Allow…" : "Open Settings") {
                    if micStatus == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refresh() } }
                    } else { DictationController.openMicrophoneSettings() }
                }
                Divider().overlay(Ink.hairline)
                permissionRow(symbol: "accessibility", tint: Ink.sageTint, name: "Accessibility", why: "To hear your hotkey and paste into other apps",
                              ok: trusted, action: "Allow…") { app.dictation.openAccessibilitySettings() }
            }
            .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline))
            .padding(.top, 18)
            Text("This page notices when you switch them on. No restart needed.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.top, 10)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Hold").font(Ink.serif(32))
                Text(app.dictation.hotkey.title).font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Ink.reader, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Ink.hairline))
                    .shadow(color: Ink.inkFixed.opacity(0.12), radius: 0, y: 2)
                Text("and say hello.").font(Ink.serif(32))
            }
            .foregroundStyle(Ink.ink).padding(.top, 14).padding(.bottom, 6)
            para(trusted ? "Let go, and your words land here. Tap the key once to keep listening hands-free; tap again to finish."
                         : "Dictation needs Accessibility first. Go back a step to allow it, or skip this for now.")
            TextEditor(text: $practice)
                .font(.system(size: 15)).scrollContentBackground(.hidden).padding(10)
                .frame(height: 104)
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(practiceFocused ? Ink.outlineStrong : Ink.hairline))
                .focused($practiceFocused)
                .padding(.top, 16)
                .accessibilityLabel("Practice dictation")
            if !practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("That's it. Every dictation is also kept in Dictations.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Ink.sageText).padding(.top, 10)
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
                .toggleStyle(.checkbox).font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 14)
        }
    }

    /// The last step asks two things, one axis each (build 228 review, M-48): which languages, then (for many) speed
    /// or accuracy. Each choice says what it trades. The pick is a card with the ink outline and a check (DESIGN.md
    /// §11.3), never a colored wash.
    private var quality: some View {
        let many = app.preset != .english
        return VStack(alignment: .leading, spacing: 0) {
            title("Ready when you are.")
            para("Two quick choices. You can change either one in Settings.")
            questionLabel("Languages").padding(.top, 14)
            SegmentedCapsule(label: "Languages", options: [false, true],
                             selection: Binding(get: { many }, set: { m in app.presetRaw = (m ? QualityPreset.balanced : .english).rawValue }),
                             title: { $0 ? "Many languages" : "English only" },
                             target: { $0 ? "onboarding-languages-many" : "onboarding-languages-english" })
                .padding(.top, 8)
            if many {
                questionLabel("Speed or accuracy").padding(.top, 16)
                VStack(spacing: 6) {
                    ForEach([QualityPreset.fast, .balanced, .accurate], id: \.self) { p in qualityRow(p) }
                }
                .padding(.top, 8)
            } else {
                Text("Fast and accurate for English, with Parakeet v2. The default; pick Many languages for anything else.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            Label(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off, so everything stays on this Mac",
                  systemImage: Cloud.enabled ? "icloud" : "icloud.slash")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 12)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if current == .welcome {
                Button("Skip the tour") { done() }.buttonStyle(.plain).foregroundStyle(Ink.dim)
            } else {
                if look == .native {
                    Button("Back") { step -= 1 }.buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button("Back") { step -= 1 }.buttonStyle(.pillLine(large: true))
                }
                if current == .permissions && !(trusted && micStatus == .authorized) {
                    Button("Do this later") { step += 1 }.buttonStyle(.plain).foregroundStyle(Ink.mute).padding(.leading, 14)
                }
                if current == .tryIt && practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Skip this step") { step += 1 }.buttonStyle(.plain).foregroundStyle(Ink.mute).padding(.leading, 14)
                }
            }
            Spacer()
            primaryButton
                .disabled(current == .permissions && !(trusted && micStatus == .authorized))
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13.5, weight: .medium))
    }

    /// Continue: the ink button in Verbose style, `.borderedProminent` with the accent in Native.
    @ViewBuilder private var primaryButton: some View {
        let action = { if step == total - 1 { done() } else { step += 1 } }
        if look == .native {
            Button(NativeText.titleCase(primaryTitle), action: action).buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            Button(primaryTitle, action: action).buttonStyle(.pillDark(large: true))
        }
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
        Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
    }

    /// One speed-or-accuracy choice: its name, what it trades, and a check when it's the one.
    private func qualityRow(_ p: QualityPreset) -> some View {
        let on = app.preset == p
        return FlatRowButton(selected: on, action: { app.presetRaw = p.rawValue }) { _ in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(Self.tradeOff(p)).font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.ink).opacity(on ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .accessibilityAddTraits(on ? .isSelected : [])
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
        Text(s).font(Ink.serif(32)).foregroundStyle(Ink.ink).padding(.top, 14).padding(.bottom, 6)
    }
    private func para(_ s: String) -> some View {
        Text(s).font(.system(size: 14.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
    }

    private func pillar(_ n: String, _ name: String, _ note: String, _ art: BrandArt, _ fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text(n).font(Ink.mono(11)).foregroundStyle(Ink.inkFixed)
                Spacer()
                BrandGlyph(art: art, color: Ink.inkFixed, minLineWidth: 1).frame(width: 34, height: 34)
            }
            Spacer()
            Text(name).font(Ink.serif(22)).foregroundStyle(Ink.inkFixed)
            Text(note).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFixed)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(symbol: String, tint: Color, name: String, why: String, ok: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Ink.ink)
                .frame(width: 36, height: 36).background(tint, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(why).font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
            Spacer()
            if ok {
                Label("Allowed", systemImage: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.sageText)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Ink.sageTint, in: Capsule())
                    .transition(.opacity)
            } else {
                Button(action, action: perform).buttonStyle(.pillLine())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .animation(Motion.settle, value: ok)
    }

    private func edgeChoice(_ e: BarEdge, _ name: String) -> some View {
        Button { edge = e; app.dictation.bar?.moveTo(edge: e) } label: {
            VStack(spacing: 8) {
                ZStack(alignment: e == .bottom ? .bottom : (e == .left ? .leading : .trailing)) {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(Ink.reader)
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(edge == e ? Ink.ink : Ink.hairline, lineWidth: edge == e ? 2 : 1)
                    UnevenRoundedRectangle(topLeadingRadius: e == .right ? 3 : (e == .bottom ? 3 : 0), bottomLeadingRadius: e == .right ? 3 : 0,
                                           bottomTrailingRadius: e == .left ? 3 : 0, topTrailingRadius: e == .left || e == .bottom ? 3 : 0, style: .continuous)
                        .fill(Ink.inkFixed)
                        .frame(width: e == .bottom ? 34 : 5, height: e == .bottom ? 5 : 34)
                        .padding(e == .bottom ? .bottom : (e == .left ? .leading : .trailing), 1)
                }
                .frame(height: 104)
                Text(name).font(.system(size: 13, weight: edge == e ? .semibold : .regular)).foregroundStyle(edge == e ? Ink.ink : Ink.dim)
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
