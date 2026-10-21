import SwiftUI
import AppKit

/// Copy and Export. Copy uses the saved export options; Export opens the export sheet (ExportSheet), which edits them.
struct ExportMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            Button { ExportMenu.copy(transcript, app: app) } label: { ToolLabel(title: "Copy", symbol: "doc.on.doc", compact: compact) }
                .buttonStyle(.plain).help("Copy the text to the clipboard (⌘⇧C)")
            Button { app.exportRequest = ExportRequest(ids: [transcript.id]) } label: { ToolLabel(title: "Export", symbol: "square.and.arrow.up", compact: compact) }
                .buttonStyle(.plain).help("Export as text, Markdown, Word, subtitles, or JSON")
        }
        .disabled(transcript.status != .ready)
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
