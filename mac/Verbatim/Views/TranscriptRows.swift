import SwiftUI
import AppKit

/// Static waveform thumbnail from the stored envelope. A Shape, so it costs nothing after layout.
struct WaveformThumb: Shape {
    var values: [Float]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard !values.isEmpty else { return p }
        let n = values.count
        let step = r.width / CGFloat(n)
        let bw = max(1.5, step * 0.55)
        for (i, v) in values.enumerated() {
            let h = max(2, CGFloat(v) * r.height)
            let x = r.minX + CGFloat(i) * step + (step - bw) / 2
            p.addRoundedRect(in: CGRect(x: x, y: r.midY - h / 2, width: bw, height: h), cornerSize: CGSize(width: bw / 2, height: bw / 2))
        }
        return p
    }
}

/// Keep video (links) and Keep audio, or Show in Finder once kept.
struct KeepMenuItems: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var kept = KeptMedia.shared
    var transcript: Transcript
    var body: some View {
        if let busy = app.keeping[transcript.id] {
            Button(busy) {}.disabled(true)
        } else if let v = transcript.keptVideo, kept.exists(v) {
            Button("Show video in Finder") { app.showKept(v) }
        } else if transcript.linkInfo != nil {
            Button("Keep video (MP4)") { app.keepVideo(transcript.id) }
        }
        if let a = transcript.keptAudio, kept.exists(a) {
            Button("Show audio in Finder") { app.showKept(a) }
        } else if transcript.audioFileName != nil {
            Button("Keep audio (\((transcript.audioFileName.map { URL(fileURLWithPath: $0).pathExtension.uppercased() }) ?? "M4A"))") { app.keepAudio(transcript.id) }
        }
    }
}

struct RowMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        Button("Open") { app.go(.transcript(transcript.id)) }
        Button("Rename…") { RenameCenter.shared.begin(transcript) }
        Button(transcript.pinned ? "Unpin" : "Pin") { app.store.update(transcript.id) { $0.pinned.toggle() } }
        Menu("Add to project") {
            // One project at a time: choosing another moves it there (the current one has a checkmark).
            ForEach(app.store.projects) { p in
                if transcript.projectId == p.id {
                    Button { } label: { Label(p.name, systemImage: "checkmark") }.disabled(true)
                } else {
                    Button(p.name) { app.addToProject([transcript.id], p.id) }
                }
            }
            if let current = transcript.projectId, let name = app.store.projectsByID[current]?.name {
                Divider()
                Button("Remove from \(name)") { app.move([transcript.id], to: nil) }
            }
            if !app.store.projects.isEmpty { Divider() }
            Button("New project…") { app.newProjectFor = [transcript.id] }
        }
        if AudioOnlyRules.canTranscribe(transcript) {
            // Audio only: Transcribe, or Transcribe As each kind, like Record As (AudioOnly.swift).
            Button("Transcribe") { app.transcribeLater(transcript.id) }
            Menu("Transcribe As") {
                ForEach(AudioOnlyRules.transcribeChoices, id: \.self) { k in
                    Button(AudioOnlyRules.choiceName(k).capitalized) { app.transcribeLater(transcript.id, as: k) }
                }
            }
        }
        if transcript.status == .ready, !transcript.showsAudioDetail { Button("Export…") { app.exportRequest = ExportRequest(ids: [transcript.id]) } }
        if transcript.status == .failed { Button("Retry transcription") { app.retry(transcript) } }
        if transcript.status == .processing { Button("Cancel transcription") { app.cancel(transcript.id) } }
        Divider()
        KeepMenuItems(transcript: transcript)
        Divider()
        Button("Delete", role: .destructive) { app.delete([transcript.id]) }
    }
}
