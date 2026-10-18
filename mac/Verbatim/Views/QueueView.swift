import SwiftUI

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Queue").font(Ink.serif(30, weight: .regular)).foregroundStyle(Ink.ink)
                    Spacer()
                    if running != nil || !waiting.isEmpty {
                        Button("Cancel all") { app.cancelAll() }.buttonStyle(.bordered)
                    }
                    Button { app.chooseFiles() } label: { Label("Add files", systemImage: "plus") }
                        .buttonStyle(.brandPrimary).keyboardShortcut("o", modifiers: .command)
                }
                .padding(.bottom, 6)
                Text("Files are transcribed one at a time, in order, on this Mac. Drop files or folders anywhere on this page.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.mute).padding(.bottom, 18)

                if running == nil && waiting.isEmpty && importing.isEmpty {
                    empty
                } else {
                    section("Up next")
                    VStack(spacing: 0) {
                        if let r = running { QueueRow(transcript: r, state: .running) ; Divider().opacity(0.5) }
                        ForEach(importing) { t in QueueRow(transcript: t, state: .importing); Divider().opacity(0.5) }
                        ForEach(Array(waiting.enumerated()), id: \.element.id) { i, t in
                            QueueRow(transcript: t, state: .waiting(i + 1))
                            if i < waiting.count - 1 { Divider().opacity(0.5) }
                        }
                    }
                    .background(NoteCardBackground(hover: false))
                }

                if !recent.isEmpty {
                    section("Recently finished").padding(.top, 26)
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { i, t in
                            QueueRow(transcript: t, state: t.status == .failed ? .failed : .done)
                            if i < recent.count - 1 { Divider().opacity(0.5) }
                        }
                    }
                    .background(NoteCardBackground(hover: false))
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.iris, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Ink.irisTint.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(Text("Drop to add to the queue").font(Ink.serif(22, weight: .regular)).foregroundStyle(Ink.irisDeep))
                    .padding(20).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { app.handleDrop($0) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.mute).padding(.bottom, 8)
    }

    private var empty: some View {
        HStack(spacing: 16) {
            IconPlate(art: .iconQueue, size: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing waiting").font(Ink.serif(20, weight: .regular))
                Text("Add a batch of recordings, interviews, or videos. Verbatim works through them while you do something else.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
            }
            Spacer()
        }
        .padding(20).background(NoteCardBackground(hover: false))
    }
}

struct QueueRow: View {
    enum State: Equatable { case running, importing, waiting(Int), done, failed }
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var state: State
    @SwiftUI.State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transcript.source.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.iris)
                .frame(width: 34, height: 34).background(Ink.irisTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(transcript.title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(status).foregroundStyle(state == .failed ? Ink.coral : Ink.mute)
                    if transcript.duration > 0 { Text("·").foregroundStyle(Ink.mute); Text(transcript.duration.timecode).foregroundStyle(Ink.mute) }
                }
                .font(.system(size: 12.5)).lineLimit(1)
                if state == .running, let f = fraction {
                    ProgressView(value: f).progressViewStyle(.linear).tint(Ink.iris).frame(maxWidth: 320).padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            switch state {
            case .running, .importing:
                ProgressView().controlSize(.small)
                cancelButton
            case .waiting:
                cancelButton
            case .done:
                Button("Open") { app.go(.transcript(transcript.id)) }.buttonStyle(.bordered).controlSize(.small)
            case .failed:
                Button("Retry") { app.retry(transcript) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hover ? Ink.iris.opacity(0.035) : .clear)
        .onHover { hover = $0 }
        .contextMenu { RowMenu(transcript: transcript) }
    }

    private var cancelButton: some View {
        Button { app.cancel(transcript.id) } label: { Label("Cancel", systemImage: "xmark") }
            .buttonStyle(.bordered).controlSize(.small).tint(Ink.coral)
    }

    private var status: String {
        switch state {
        case .running: return transcript.stage ?? "Transcribing"
        case .importing: return "Importing…"
        case .waiting(let n): return n == 1 ? "Next" : "Queued · #\(n)"
        case .done: return "Done"
        case .failed: return transcript.error ?? "Failed"
        }
    }

    /// Reads the percentage out of the engine's stage label ("Transcribing 42%").
    private var fraction: Double? {
        guard let s = transcript.stage, let r = s.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        return Double(s[r].dropLast()).map { $0 / 100 }
    }
}
