import SwiftUI
import AVFoundation

/// The welcome tour on the Mac: what Verbatim does, permissions, a first dictation, where the floating button
/// lives, and transcription quality. Shown once after an update and whenever Settings asks for it.
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
    private let total = 5

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                Overline(text: label, color: Ink.dim)
                DottedRule().frame(height: 1)
                Overline(text: String(format: "%02d / %02d", step + 1, total), color: Ink.mute)
            }
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: tryIt
                case 3: placement
                default: quality
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
        .onAppear { refresh(); edge = currentEdge }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .interactiveDismissDisabled()
    }

    private var label: String {
        ["Welcome to Verbatim", "Permissions", "Try it", "The floating button", "Last step"][step]
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Words worth keeping.")
            para("Record, import, or dictate. Verbatim turns it into text you can use, and it all stays on your Mac.")
            HStack(spacing: 12) {
                pillar("01", "Capture", "Record, import, a link", .capture, Ink.persimmon)
                pillar("02", "Refine", "Clean up, original kept", .refine, Ink.petal)
                pillar("03", "Dictate", "Talk into any app", .document, Ink.butter)
            }
            .padding(.top, 22)
        }
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
            .background(Ink.reader, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.hairline))
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
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(practiceFocused ? Ink.outlineStrong : Ink.hairline))
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
            Toggle("Hide the button; I'll use the hotkey", isOn: Binding(get: { !flow.showBar }, set: { flow.showBar = !$0 }))
                .toggleStyle(.checkbox).font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 14)
        }
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Ready when you are.")
            para("Pick how careful transcription should be. You can change any of this in Settings.")
            VStack(spacing: 0) {
                ForEach([QualityPreset.english, .fast, .balanced, .accurate], id: \.self) { p in
                    Button { app.presetRaw = p.rawValue } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(p.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                                    if p == .defaultPreset { Text("Default").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.sageText) }
                                }
                                Text(p.pitch)
                                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                            }
                            Spacer()
                            if app.preset == p { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.sageText) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(app.preset == p ? Ink.sageTint : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if p != .accurate { Divider().overlay(Ink.hairline) }
                }
            }
            .background(Ink.reader, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.hairline))
            .padding(.top, 16)
            Label(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off, so everything stays on this Mac",
                  systemImage: Cloud.enabled ? "icloud" : "icloud.slash")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 12)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step == 0 {
                Button("Skip the tour") { done() }.buttonStyle(.plain).foregroundStyle(Ink.dim)
            } else {
                Button("Back") { step -= 1 }.buttonStyle(.plain).foregroundStyle(Ink.dim)
                if step == 1 && !(trusted && micStatus == .authorized) {
                    Button("Do this later") { step += 1 }.buttonStyle(.plain).foregroundStyle(Ink.mute).padding(.leading, 14)
                }
                if step == 2 && practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Skip this step") { step += 1 }.buttonStyle(.plain).foregroundStyle(Ink.mute).padding(.leading, 14)
                }
            }
            Spacer()
            Button(primaryTitle) { if step == total - 1 { done() } else { step += 1 } }
                .buttonStyle(.brandPrimaryLarge)
                .disabled(step == 1 && !(trusted && micStatus == .authorized))
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13.5, weight: .medium))
    }

    private var primaryTitle: String {
        switch step {
        case 0: return "Get started"
        case 2: return practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Continue" : "Nice, continue"
        case total - 1: return "Start using Verbatim"
        default: return "Continue"
        }
    }

    private func done() {
        Onboarding.finish()
        app.showOnboarding = false
    }

    // MARK: Pieces

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
        .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(symbol: String, tint: Color, name: String, why: String, ok: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Ink.ink)
                .frame(width: 36, height: 36).background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                Button(action, action: perform).buttonStyle(.brandSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .animation(Motion.settle, value: ok)
    }

    private func edgeChoice(_ e: BarEdge, _ name: String) -> some View {
        Button { edge = e; app.dictation.bar?.moveTo(edge: e) } label: {
            VStack(spacing: 8) {
                ZStack(alignment: e == .bottom ? .bottom : (e == .left ? .leading : .trailing)) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.reader)
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(edge == e ? Ink.ink : Ink.hairline, lineWidth: edge == e ? 2 : 1)
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
