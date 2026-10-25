import SwiftUI
import UIKit
import ReplayKit

/// Transcribe what's playing: starts the VerbatimBroadcast extension, which records only the sound other apps play
/// (TikTok, Instagram, a browser) and never the microphone or the screen. When you stop, the app transcribes it
/// (PhoneInbox.swift). Nothing is downloaded from those apps.
///
/// iOS starts a broadcast only from its own picker. The system picker sits behind the Start button, and Start
/// forwards the tap to the picker's button.
struct WhatsPlayingSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State private var picker = BroadcastPickerHandle()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                        Overline(text: "App audio", color: Ink.dim)
                        DottedRule().frame(height: 1)
                    }
                    .accessibilityHidden(true)

                    Text("Transcribe what's playing")
                        .lookSerif(30).foregroundStyle(.lookInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                        .accessibilityAddTraits(.isHeader)

                    Text("Start, then open TikTok or any app and play videos. Verbose records the sound they play — not your microphone or screen — and transcribes it when you stop.")
                        .font(.system(size: 16)).foregroundStyle(.lookDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    steps.padding(.top, 20)

                    Button { picker.start() } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Ink.persimmon).frame(width: 12, height: 12)
                            Text("Start").font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlayingStartStyle())
                    .background(
                        // The system picker, behind the button. It does the starting; the button forwards to it.
                        BroadcastPicker(handle: picker)
                            .frame(width: 54, height: 54)
                            .opacity(0.02)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    )
                    .padding(.top, 22)
                    .accessibilityHint("Opens the screen broadcast picker with Verbose chosen. Only app sound is kept.")

                    Text("You can also start it from Control Center: press and hold Screen Recording, then choose Verbose.")
                        .font(.system(size: 13.5)).foregroundStyle(.lookMute)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
                .padding(20)
            }
            .phonePage()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task {
            // From the Action button (What's playing): the system's broadcast sheet comes up by itself, once the
            // picker behind Start is on screen. iOS still asks you to tap Start Broadcast.
            guard app.playingSheetStartsPicker else { return }
            app.playingSheetStartsPicker = false
            try? await Task.sleep(nanoseconds: 600_000_000)
            picker.start()
        }
    }

    /// Three short steps on a reader-white card.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step("1", "Tap Start, then Start Broadcast.")
            step("2", "Play videos in TikTok or any other app.")
            step("3", "Stop from the red status bar or Control Center. The transcript appears in Library.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.tile)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).lookMono(12, weight: .medium).foregroundStyle(.lookMute).frame(width: 14, alignment: .leading)
            Text(text).font(.system(size: 15)).foregroundStyle(.lookInk).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Start button: ink fill with a reader-white label (cream with an ink label in dark), on an opaque surface.
private struct PlayingStartStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Ink.onInteractive)
            .background(Ink.interactive.opacity(configuration.isPressed ? 0.86 : 1), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Holds the system picker so the Start button can forward its tap.
final class BroadcastPickerHandle {
    weak var view: RPSystemBroadcastPickerView?

    /// Sends the picker's own button a tap, which opens the system broadcast sheet with Verbatim chosen.
    func start() {
        guard let view, let button = Self.firstButton(in: view) else { return }
        button.sendActions(for: .touchUpInside)
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        if let b = view as? UIButton { return b }
        for v in view.subviews { if let b = firstButton(in: v) { return b } }
        return nil
    }
}

/// RPSystemBroadcastPickerView for SwiftUI, set to the Verbatim broadcast extension, with no microphone button.
struct BroadcastPicker: UIViewRepresentable {
    let handle: BroadcastPickerHandle

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 54, height: 54))
        v.preferredExtension = VerbatimInbox.broadcastExtensionID
        v.showsMicrophoneButton = false
        handle.view = v
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = VerbatimInbox.broadcastExtensionID
        uiView.showsMicrophoneButton = false
        handle.view = uiView
    }
}
