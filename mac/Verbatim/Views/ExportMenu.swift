import SwiftUI
import AppKit

/// Copy and Export with the options people expect: which text, speaker names, timecodes, one paragraph.
struct ExportMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var open = false
    @State private var options = ExportOptions.saved
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            Button { ExportMenu.copy(transcript, app: app) } label: { ToolLabel(title: "Copy", symbol: "doc.on.doc", compact: compact) }
                .buttonStyle(.plain).help("Copy the text to the clipboard (⌘⇧C)")
            Button { open.toggle() } label: { ToolLabel(title: "Export", symbol: "square.and.arrow.up", compact: compact) }
                .buttonStyle(.plain).help("Export as text, Markdown, Word, subtitles, or JSON")
                .popover(isPresented: $open, arrowEdge: .bottom) { ExportPanel(transcript: transcript, options: $options, done: { open = false }) }
        }
        .disabled(transcript.status != .ready)
        .onChange(of: options) { _, o in o.save() }
    }

    /// Copy with the saved export options. Also bound to ⌘⇧C once per transcript screen.
    static func copy(_ t: Transcript, app: AppState) {
        guard t.status == .ready else { return }
        let options = ExportOptions.saved
        Exporter.copy(t, options: options)
        app.toast = Toast("Copied " + (options.source == .document ? "document" : "transcript"))
        Sounds.done()
    }
}

/// A quiet text-and-icon tool button for the transcript's mode bar.
struct ToolLabel: View {
    var title: String
    var symbol: String
    var compact = false
    var on = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
            if !compact { Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(on ? Ink.iris : Ink.dim)
        .padding(.horizontal, compact ? 7 : 9).frame(height: 28)
        .background(on ? Ink.iris.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .hoverChip()
    }
}

struct ExportPanel: View {
    var transcript: Transcript
    @Binding var options: ExportOptions
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.system(size: 14, weight: .bold))
            Picker("Text", selection: $options.source) { ForEach(ExportOptions.Source.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Text(options.source == .document ? "Paragraphs with your edits and polish." : "Line by line, as transcribed.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Speaker names", isOn: $options.speakers).disabled(transcript.speakers.count < 2)
                Toggle("Timecodes", isOn: $options.timecodes)
                Toggle("One paragraph", isOn: $options.singleParagraph)
                Toggle("Add a “transcribed with” footer", isOn: $options.provenance)
            }
            .toggleStyle(.checkbox).font(.system(size: 12.5))
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ExportFormat.allCases) { f in
                    Button { done(); Exporter.save(transcript, as: f, options: options) } label: {
                        HStack { Text(f.rawValue).fontWeight(.medium); Spacer(); Text(f.timed ? "with timecodes" : f.note).foregroundStyle(.secondary) }
                            .font(.system(size: 12.5)).padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { done(); Exporter.copy(transcript, options: options) } label: { Label("Copy to clipboard", systemImage: "doc.on.doc") }
                .buttonStyle(.brandPrimary).frame(maxWidth: .infinity)
        }
        .padding(16).frame(width: 300)
    }
}
