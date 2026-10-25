import SwiftUI
import AppKit

// brand: native file
//
// The transcript's toolbar and player in the Native look (mockup section 03, "Mac Transcript"): Original, Cleaned, and
// Review as a segmented control in the toolbar, then Continue Recording, Actions, Share (copy and export), Text Size,
// and the inspector's button; and a standard player bar at the foot, with a persimmon play button and slider, the
// time in monospaced digits, the speed, and Bookmark. Line selection, bookmarks, and the playing tint stay custom.

struct NativeTranscriptToolbar: ToolbarContent {
    var app: AppState
    var transcript: Transcript
    @Binding var mode: TranscriptView.Mode
    @Binding var inspector: Bool
    @Binding var textSize: CGFloat
    var copyVersion: Exporter.CopyVersion
    var onAction: (FlowAction) -> Void
    var onSummarize: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { app.go(.library) } label: { Label("Library", systemImage: "chevron.left") }
                .help("Back to the Library")
        }
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $mode) {
                ForEach(TranscriptView.visibleModes, id: \.self) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Original keeps every word as said; Cleaned is the tidied text; Review shows each fix")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.continueRecording(transcript.id) } label: { Label("Continue Recording", systemImage: "mic.badge.plus") }
                .disabled(transcript.status != .ready || transcript.audioFileName == nil || transcript.pendingAppend != nil || app.recorder.isRecording)
                .help("Record more and add it to the end of this transcript")
            Menu {
                ActionsMenuItems { onAction($0) }
                Divider()
                Button(SummaryAction.title(transcript)) { onSummarize() }
                    .disabled(transcript.summaryIsEdited || SummaryCenter.shared.isRunning(transcript.id))
            } label: { Label("Actions", systemImage: "sparkles") }
                .disabled(transcript.status != .ready)
                .help("Run a saved action on this transcript: decisions and next steps, a brief, an email")
            Menu {
                Button("Copy (⇧⌘C)") { ExportMenu.copy(transcript, copyVersion, app: app) }
                Button("Copy with Timestamps") { ExportMenu.copy(transcript, copyVersion, timestamps: true, app: app) }
                Button(copyVersion == .cleaned ? "Copy the Original" : "Copy the Cleaned Text") { ExportMenu.copy(transcript, copyVersion.other, app: app) }
                Button("Copy Engine Words") { ExportMenu.copy(transcript, .engine, app: app) }
                    .disabled(!transcript.hasEngineWords)
                Button("Copy for AI") { CopyForAI.copy(transcript, app: app) }
                Divider()
                Button("Export…") { app.exportRequest = ExportRequest(ids: [transcript.id]) }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(transcript.status != .ready)
                .help("Copy, or export as text, Markdown, Word, subtitles, or JSON")
            Menu {
                Button("Larger Text") { textSize = min(22, textSize + 1) }
                Button("Smaller Text") { textSize = max(13, textSize - 1) }
                Button("Default Size") { textSize = 16 }
            } label: { Label("Text Size", systemImage: "textformat.size") }
                .help("Text size (⌘+ and ⌘−)")
            Button { inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help(inspector ? "Hide the summary, moments, and details" : "Show the summary, moments, and details")
        }
    }
}

/// The player at the foot of the transcript: play, back and forward 5 s, the time, a slider to seek, the speed, and
/// Bookmark. Opaque, so its text never sits on a blur (DESIGN.md §5.1).
struct NativePlayerBar: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock

    var body: some View {
        let total = max(app.player.duration, transcript.duration, 1)
        HStack(spacing: 10) {
            Button { app.player.toggle() } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .offset(x: app.player.isPlaying ? 0 : 1)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Ink.nativeAccent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).help("Play or pause (Space)")
            .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
            Button { app.player.seek(to: app.player.time - 5) } label: { Image(systemName: "gobackward.5") }
                .buttonStyle(.borderless).help("Back 5 seconds (←)").accessibilityLabel("Back 5 seconds")
            if let note = clock.note {
                Text(note).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .onAppear { AccessibilityNotification.Announcement(note).post() }
            } else {
                (Text(app.player.time.timecode).fontWeight(.semibold) + Text(" / \(total.timecode)").foregroundColor(.secondary))
                    .font(.system(size: 12).monospacedDigit()).lineLimit(1).fixedSize()
            }
            Slider(value: Binding(get: { min(app.player.time, total) }, set: { app.player.seek(to: $0) }), in: 0...total)
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            Button { app.player.seek(to: app.player.time + 5) } label: { Image(systemName: "goforward.5") }
                .buttonStyle(.borderless).help("Forward 5 seconds (→)").accessibilityLabel("Forward 5 seconds")
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(String(format: "%g", r))×") { app.player.setRate(Float(r)) } }
            } label: {
                Text("\(String(format: "%g", app.player.rate))×").monospacedDigit()
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Playback speed").accessibilityLabel("Playback speed")
            Button("Bookmark") {
                let at = app.player.time
                let seg = transcript.segments.first(where: { at >= $0.start && at < $0.end })
                app.addNote(transcript: transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Bookmark this moment (B)")
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .frame(height: 46)
        .background(NativeInk.content, in: Capsule())
        .overlay(Capsule().strokeBorder(NativeInk.boxEdge, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 760)
    }
}
