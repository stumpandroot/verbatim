import SwiftUI
import UIKit
import ReplayKit

/// Transcribe what's playing: starts the VerbatimBroadcast extension, which records only the sound other apps play
/// (TikTok, Instagram, a browser) and never the microphone or the screen. When you stop, the app transcribes it
/// (PhoneInbox.swift). Nothing is downloaded from those apps.
///
/// iOS starts a broadcast only from its own picker. The system picker sits behind the Start button, and Start
/// forwards the tap to the picker's button. On the refined kit (DESIGN.md §13).
struct WhatsPlayingSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State private var picker = BroadcastPickerHandle()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LargeSerifTitle(title: "Transcribe what's playing", eyebrow: "App audio")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)

                    Text("Start, then open the app that's playing. Verbose records the sound it plays, not your microphone or screen, and transcribes it when you stop. Record only what you have the right to.")
                        .refinedFont(.body).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    steps.padding(.top, 20)

                    Button { picker.start() } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Refined.recordRed).frame(width: 12, height: 12)
                            Text("Start")
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RefinedActionStyle(kind: .strong))
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
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
                .padding(20)
            }
            .background(Refined.paper.ignoresSafeArea())
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

    /// Three short steps on a card.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step("1", "Tap Start, then Start Broadcast.")
            step("2", "Play the audio in any app.")
            step("3", "Stop from the red status bar or Control Center. The transcript appears in Library.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).refinedFont(.meta, weight: .semibold).monospacedDigit().foregroundStyle(Refined.accentText).frame(width: 14, alignment: .leading)
            Text(text).refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
