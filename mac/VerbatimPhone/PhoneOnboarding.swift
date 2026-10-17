import SwiftUI
import AVFoundation

/// The welcome tour on iPhone: what Verbatim does, the microphone, and transcription quality with iCloud status.
struct PhoneOnboarding: View {
    @EnvironmentObject var app: PhoneState
    @State private var step: Int
    @State private var micAllowed = AVAudioApplication.shared.recordPermission == .granted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let total = 3

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                Overline(text: ["Verbatim", "Microphone", "Last step"][step], color: Ink.dim)
                DottedRule().frame(height: 1)
                Overline(text: String(format: "%02d / %02d", step + 1, total), color: Ink.mute)
            }
            .padding(.top, 16)
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
                ForEach(0..<total, id: \.self) { i in Capsule().fill(i <= step ? Ink.ink : Ink.track).frame(width: 22, height: 4) }
            }
            .frame(maxWidth: .infinity).padding(.bottom, 18)
            .accessibilityHidden(true)
            primary
            secondary.frame(maxWidth: .infinity).padding(.top, 14).padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .background(Ink.paper.ignoresSafeArea())
        .animation(Motion.settle, value: step)
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Words worth keeping.")
            para("Record a thought, an interview, or a call. Verbatim writes it down on this iPhone and keeps it in sync with your Mac.")
            BrandGlyph(art: .diagramCapture, color: Ink.ink, minLineWidth: 1.2)
                .frame(width: 170, height: 220).frame(maxWidth: .infinity).padding(.top, 50)
                .accessibilityHidden(true)
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Let Verbatim hear you.")
            para("Only while you record. Audio is transcribed on this iPhone and isn't uploaded anywhere but your own iCloud.")
            HStack(spacing: 14) {
                Image(systemName: "mic").font(.system(size: 19)).foregroundStyle(Ink.ink)
                    .frame(width: 44, height: 44).background(Ink.persimmonTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text("Keeps recording with the screen locked").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                Spacer()
                if micAllowed { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Ink.sageText) }
            }
            .padding(16)
            .background(Ink.reader, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.hairline))
            .padding(.top, 28)
        }
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Ready when you are.")
            para("Pick how careful transcription should be. The model downloads once.")
            VStack(spacing: 0) {
                ForEach([QualityPreset.fast, .balanced, .accurate], id: \.self) { p in
                    Button { app.presetRaw = p.rawValue } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                                Text(p == .balanced ? "Recommended · " + p.pitch : p.pitch)
                                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
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
            .background(Ink.reader, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.hairline))
            .padding(.top, 22)
            Label(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off, so everything stays on this iPhone",
                  systemImage: Cloud.enabled ? "icloud" : "icloud.slash")
                .font(.system(size: 14)).foregroundStyle(Ink.dim).padding(.top, 16)
        }
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case 0: bigButton("Get started", fill: Ink.interactive, text: Ink.onInteractive) { step = 1 }
        case 1:
            if micAllowed { bigButton("Continue", fill: Ink.interactive, text: Ink.onInteractive) { step = 2 } }
            else {
                bigButton("Allow Microphone", fill: Ink.persimmon, text: Ink.inkFixed) {
                    AVAudioApplication.requestRecordPermission { ok in
                        DispatchQueue.main.async { micAllowed = ok; step = 2 }
                    }
                }
            }
        default: bigButton("Start using Verbatim", fill: Ink.interactive, text: Ink.onInteractive) { done() }
        }
    }

    @ViewBuilder private var secondary: some View {
        switch step {
        case 0: Button("Skip the tour") { done() }.font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.dim)
        case 1: Button(micAllowed ? "Back" : "Not now") { if micAllowed { step = 0 } else { step = 2 } }.font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.dim)
        default: Button("Back") { step = 1 }.font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.dim)
        }
    }

    private func bigButton(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(text)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScale())
    }

    private func title(_ s: String) -> some View {
        Text(s).font(Ink.serif(36)).foregroundStyle(Ink.ink).padding(.top, 18).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
    }
    private func para(_ s: String) -> some View {
        Text(s).font(.system(size: 16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
    }

    private func done() {
        Onboarding.finish()
        app.showOnboarding = false
    }
}
