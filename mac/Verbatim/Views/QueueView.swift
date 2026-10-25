import SwiftUI

// brand: web style
//
// The queue in the website style (mac/DESIGN.md §11): a compact title with a mono count, pill actions, serif section
// titles, flat rows with the source dot, plain status text, and a thin Record-colored bar for the running item.

/// Everything waiting to be transcribed, one at a time: what's running, what's next, and a way to stop either.
struct QueueView: View {
    @EnvironmentObject var app: AppState
    @State private var dropping = false

    private var running: Transcript? { app.runningID.flatMap { app.store.transcript($0) } }
    private var waiting: [Transcript] { app.queue.compactMap { app.store.transcript($0) } }
    private var importing: [Transcript] {
        app.store.live.filter { $0.status == .processing && $0.audioFileName == nil }.sorted { $0.createdAt < $1.createdAt }
    }
    private var recent: [Transcript] {
        app.store.live.filter { ($0.status == .ready || $0.status == .failed) && $0.source == .file }.prefix(8).map { $0 }
    }

    var body: some View {
        let running = self.running, waiting = self.waiting, importing = self.importing, recent = self.recent
        let count = (running == nil ? 0 : 1) + importing.count + waiting.count
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Queue", count: "\(count.formatted()) waiting",
                          lede: "Files are transcribed in order, on this Mac. Drop files or folders anywhere on this page.") {
                    HStack(spacing: 8) {
                        if running != nil || !waiting.isEmpty {
                            PillButton(title: "Cancel all", kind: .line, hint: "Stops the running file and clears the queue.") { app.cancelAll() }
                        }
                        Button { app.chooseFiles() } label: {
                            HStack(spacing: 8) {
                                Text("Add files")
                                Keycap(keys: "⌘O", size: 12).opacity(0.7)
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .dark, size: .regular))
                        .keyboardShortcut("o", modifiers: .command)
                        .help("Add audio or video files to the queue (⌘O)")
                        .accessibilityLabel("Add files")
                    }
                }
                .staggerIn(0)

                if count == 0 {
                    EmptyStateCard(art: .iconQueue, title: "Nothing waiting",
                                   message: "Add a batch of recordings, interviews, or videos. Verbose works through them while you do something else.",
                                   button: "Add files", action: { app.chooseFiles() })
                        .padding(.top, 22).staggerIn(1)
                } else {
                    SectionTitle(title: "Up", italic: "next").padding(.top, 22).padding(.bottom, 10).staggerIn(1)
                    // Lazy: a batch import can queue hundreds.
                    LazyVStack(spacing: 2) {
                        if let r = running { QueueRow(transcript: r, state: .running) }
                        ForEach(importing) { t in QueueRow(transcript: t, state: .importing) }
                        ForEach(Array(waiting.enumerated()), id: \.element.id) { i, t in
                            QueueRow(transcript: t, state: .waiting(i + 1))
                        }
                    }
                    .staggerIn(2)
                }

                if !recent.isEmpty {
                    SectionTitle(title: "Recently", italic: "finished").padding(.top, 26).padding(.bottom, 10).staggerIn(3)
                    VStack(spacing: 2) {
                        ForEach(recent) { t in QueueRow(transcript: t, state: t.status == .failed ? .failed : .done) }
                    }
                    .staggerIn(4)
                }

                if count > 0 || !recent.isEmpty {
                    QueueDropArea().padding(.top, 18).staggerIn(5)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if dropping {
                let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
                shape.fill(Ink.card)
                    .overlay(shape.strokeBorder(Ink.ink, style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))
                    .overlay(Text("Drop to add to the queue").font(Ink.serif(26)).foregroundStyle(Ink.ink))
                    .padding(20).allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Motion.touch, value: dropping)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { app.handleDrop($0) }
    }
}

/// The dashed area at the foot of the queue. Drops land anywhere on the page; this only says so.
private struct QueueDropArea: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        Text("Drop files or folders anywhere to add them to the queue")
            .font(.system(size: 13)).foregroundStyle(Ink.mute)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 70)
            .overlay(shape.strokeBorder(Ink.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
    }
}

/// A flat queue row: the source dot, the title, and the status line (with a thin bar for the running file), then a
/// spinner and Cancel, or Open or Retry. Clicking the row opens the transcript.
struct QueueRow: View {
    enum State: Equatable { case running, importing, waiting(Int), done, failed }
    @EnvironmentObject var app: AppState
    /// The running file's live progress (StageClock): a tick re-renders the queue's rows, not the window.
    @ObservedObject private var stages = StageClock.shared
    var transcript: Transcript
    var state: State
    /// The stage as it shows: the live label while a job ticks, else the transcript's own.
    private var stage: String? { stages.stage(transcript.id) ?? transcript.stage }

    var body: some View {
        FlatRowButton(action: { app.go(.transcript(transcript.id)) }) { _ in
            HStack(spacing: 14) {
                KindDot(transcript: transcript, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transcript.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    statusLine
                    if state == .running, let f = StageFraction.fraction(stage) {
                        StageProgressBar(value: f).frame(width: 260).padding(.top, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the controls above the click layer.
                Color.clear.frame(width: controlsWidth, height: 28)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(minHeight: 64)
        } accessory: { _ in
            controls.padding(.trailing, 16)
        }
        .contextMenu { RowMenu(transcript: transcript) }
    }

    /// The controls' width for this state: the spinner and Cancel, Cancel, or a mini pill.
    private var controlsWidth: CGFloat {
        switch state {
        case .running, .importing: return 110
        case .waiting: return 76
        case .done, .failed: return 72
        }
    }

    /// "Transcribing 47% · 48:10", "Next · 03:12", "Queued · #3 · 1:02:44", "Done · 12:04", or the error in danger.
    private var statusLine: some View {
        let failed = state == .failed
        var parts = [status]
        if !failed, transcript.duration > 0 { parts.append(WebFormat.clock(transcript.duration)) }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 12.5, weight: failed ? .semibold : .regular))
            .foregroundStyle(failed ? Ink.danger : Ink.mute)
            .monospacedDigit().lineLimit(1)
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .running, .importing:
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                cancelButton
            }
        case .waiting:
            cancelButton
        case .done:
            PillButton(title: "Open", kind: .line, size: .mini) { app.go(.transcript(transcript.id)) }
        case .failed:
            PillButton(title: "Retry", kind: .line, size: .mini, hint: "Transcribes the file again.") { app.retry(transcript) }
        }
    }

    /// "✕ Cancel" as plain accent text.
    private var cancelButton: some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            Text("Cancel")
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Ink.accentText)
        .padding(.horizontal, 6).frame(height: 28)
        .tapArea { app.cancel(transcript.id) }
        .help("Cancel \(transcript.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cancel \(transcript.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.cancel(transcript.id) }
    }

    private var status: String {
        switch state {
        case .running: return stage ?? "Transcribing"
        case .importing: return transcript.multitrack != nil ? (stage ?? "Preparing tracks") : "Importing…"
        case .waiting(let n): return n == 1 ? "Next" : "Queued · #\(n)"
        case .done: return "Done"
        case .failed: return transcript.error ?? "Failed"
        }
    }
}
