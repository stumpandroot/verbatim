import SwiftUI

// The Mac's small recording surfaces on the refined kit (DESIGN.md §6.10; mockup "Verbose Refined Look", MacRecorder,
// October 28, 2026): the toolbar's live timer capsule while you record or capture an
// app's audio, and the menu bar panel's recording card. Home's recording card is `HomeRecordingCard` (HomeView.swift);
// the meeting panel, the Thought bubble, Live captions, and the meeting banner draw the kit in their own files.

/// The toolbar while you record or capture an app's audio (mockup MacRecorder): `RecordingTimerCapsule` with the red
/// dot, the time, and Stop (⌥⇧.; Cancel while the microphone starts), in Record's place in the toolbar (MacChrome.swift),
/// in the system's glass group.
struct ToolbarRecordingStatus: View {
    @EnvironmentObject var app: AppState
    var onCard: Bool

    var body: some View {
        let recording = app.recorder.isRecording
        let starting = recording && app.recorder.isStarting
        RecordingTimerCapsule(live: recording ? app.recorder.live : app.capture.live,
                              paused: recording && app.recorder.isPaused,
                              onCard: onCard,
                              stopLabel: starting ? "Cancel" : "Stop",
                              stopHint: recording ? "Stops the recording and transcribes it." : "Stops capturing \(app.capture.appName) and transcribes it.") {
            if app.recorder.isRecording { app.stopRecording() } else { app.stopCapture() }
        }
        .uiTarget("toolbar-recording")
    }
}

/// The menu bar panel while you record or capture (Verbose's menu bar item): the compact recording card, persimmon
/// with what's recording, the microphone, the clock, the live waveform, Pause or Resume, and Stop. The panel's own
/// rows (New thought, the last transcript, Open Verbose) stay under it.
struct MenuBarRecordingRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var mics = HomeMic.shared
    @CurrentPalette private var palette: AppPalette

    var body: some View {
        let capturing = app.capture.isCapturing && !app.recorder.isRecording
        let paused = app.recorder.isPaused && !capturing
        let ink = Refined.onFill(.persimmon, palette)
        RecordingCard(title: capturing ? "Capturing \(app.capture.appName)" : paused ? "Paused" : "Recording " + HomeRecordingCard.noun(app.recordKind),
                      detail: capturing ? "Saved as you go" : mics.device?.name ?? "Microphone",
                      live: capturing ? app.capture.live : app.recorder.live, paused: paused, compact: true) {
            EmptyView()
        } controls: {
            if !capturing {
                Button { app.togglePause() } label: {
                    HStack(spacing: 6) {
                        IconGlyph(art: paused ? .iconPlay : .iconPause, size: 12, color: ink)
                        Text(paused ? "Resume" : "Pause")
                    }
                }
                .buttonStyle(RefinedActionStyle(ink: ink, wash: Refined.readyChip(palette)))
                .disabled(app.recorder.isStarting)
            }
            Spacer(minLength: 8)
            Button {
                if capturing { app.stopCapture() } else { app.stopRecording() }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Refined.recordRed).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text("Stop")
                }
            }
            .buttonStyle(RefinedActionStyle(kind: .strong, ink: ink, light: palette == .full ? Refined.lift : Refined.paper))
            .accessibilityHint(capturing ? "Stops capturing and transcribes it." : "Stops the recording and transcribes it.")
        }
        .accessibilityLabel(paused ? "Recording paused" : capturing ? "Capturing \(app.capture.appName)" : "Recording")
    }
}
