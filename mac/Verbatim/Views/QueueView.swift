import SwiftUI

// The queue on the refined kit (DESIGN.md §13) in both look settings: the large serif title with the count, Cancel all
// and Add files, serif section titles over cards of rows (the kind's dot, the title, the status, and a thin persimmon
// bar for the running file), and the kit's empty state.

/// Everything waiting to be transcribed, one at a time: what's running, what's next, and a way to stop either.
struct QueueView: View {
    @EnvironmentObject var app: AppState
    @State private var dropping = false

    private var running: Transcript? { app.runningID.flatMap { app.store.transcript($0) } }
    private var waiting: [Transcript] { app.queue.compactMap { app.store.transcript($0) } }
    private var importing: [Transcript] {
        app.store.memo("queue-importing") { app.store.live.filter { $0.status == .processing && $0.audioFileName == nil }.sorted { $0.createdAt < $1.createdAt } }
    }
    private var recent: [Transcript] {
        app.store.memo("queue-recent") { app.store.live.filter { ($0.status == .ready || $0.status == .failed) && $0.source == .file }.prefix(8).map { $0 } }
    }

    var body: some View {
        let running = self.running, waiting = self.waiting, importing = self.importing, recent = self.recent
        let count = (running == nil ? 0 : 1) + importing.count + waiting.count
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RefinedPageHeader(title: "Queue", count: "\(count.formatted()) waiting",
                                  lede: "Files are transcribed in order, on this Mac. Drop files or folders anywhere on this page.") {
                    if running != nil || !waiting.isEmpty {
                        Button("Cancel all") { app.cancelAll() }
                            .buttonStyle(RefinedActionStyle())
                            .help("Stops the running file and clears the queue.")
                    }
                    Button { app.chooseFiles() } label: {
                        HStack(spacing: 8) {
                            Text("Add files")
                            Text("⌘O").refinedFont(.caption).opacity(0.8).accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Add audio or video files to the queue (⌘O)")
                    .accessibilityLabel("Add files")
                }

                if count == 0 {
                    RefinedEmptyState(art: .iconQueue, title: "Nothing waiting",
                                      message: "Add a batch of recordings, interviews, or videos. Verbose works through them while you do something else.",
                                      action: "Add files") { app.chooseFiles() }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SerifSectionTitle("Up next")
                        // Lazy: a batch import can queue hundreds.
                        LazyVStack(spacing: 0) {
                            if let r = running { QueueRow(transcript: r, state: .running) }
                            ForEach(Array(importing.enumerated()), id: \.element.id) { i, t in
                                if i > 0 || running != nil { PaperDivider(leading: 16, trailing: 16) }
                                QueueRow(transcript: t, state: .importing)
                            }
                            ForEach(Array(waiting.enumerated()), id: \.element.id) { i, t in
                                if i > 0 || running != nil || !importing.isEmpty { PaperDivider(leading: 16, trailing: 16) }
                                QueueRow(transcript: t, state: .waiting(i + 1))
                            }
                        }
                        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                    }
                }

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SerifSectionTitle("Recently finished")
                        PaperList(recent, id: \.id, inset: 16, trailingInset: 16) { t in
                            QueueRow(transcript: t, state: t.status == .failed ? .failed : .done)
                        }
                    }
                }

                if count > 0 || !recent.isEmpty {
                    QueueDropArea()
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 18).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges(.top)
        .background(Refined.paper)
        .overlay {
            if dropping {
                let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.record), style: .continuous)
                shape.fill(Refined.card)
                    .overlay(shape.strokeBorder(Refined.accentText, style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))
                    .overlay(Text("Drop to add to the queue").refinedFont(.sectionTitle).foregroundStyle(Refined.ink))
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
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous)
        Text("Drop files or folders anywhere to add them to the queue")
            .refinedFont(.body).foregroundStyle(Refined.mute)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 70)
            .overlay(shape.strokeBorder(Refined.separator, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
    }
}

/// A queue row in a card: the kind's dot, the title, and the status line (with a thin bar for the running file), then
/// a spinner and Cancel, or Open or Retry. Clicking the row opens the transcript.
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
        HStack(spacing: 12) {
            PaperRowButton(action: { app.go(.transcript(transcript.id)) }) {
                HStack(spacing: 12) {
                    KindBadge(kind: transcript.kind, size: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transcript.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                        statusLine
                        if state == .running, let f = StageFraction.fraction(stage) {
                            StageProgressBar(value: f).frame(width: 260).padding(.top, 5)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(minHeight: 56)
            }
            controls.padding(.trailing, 16)
        }
        .contextMenu { RowMenu(transcript: transcript) }
    }

    /// "Transcribing 47% · 48:10", "Next · 3:12", "Queued · #3 · 1:02:44", "Done · 12:04", or the error.
    private var statusLine: some View {
        let failed = state == .failed
        var parts = [status]
        if !failed, transcript.duration > 0 { parts.append(HomeRecentStyle.length(transcript.duration)) }
        return Text(parts.joined(separator: " · "))
            .refinedFont(.meta, weight: failed ? .semibold : .regular)
            .foregroundStyle(failed ? Refined.ink : Refined.mute)
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
            Button("Open") { app.go(.transcript(transcript.id)) }.buttonStyle(RefinedActionStyle())
        case .failed:
            Button("Retry") { app.retry(transcript) }.buttonStyle(RefinedActionStyle()).help("Transcribes the file again.")
        }
    }

    private var cancelButton: some View {
        Button { app.cancel(transcript.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                Text("Cancel")
            }
        }
        .buttonStyle(RefinedActionStyle())
        .help("Cancel \(transcript.title)")
        .accessibilityLabel("Cancel \(transcript.title)")
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
