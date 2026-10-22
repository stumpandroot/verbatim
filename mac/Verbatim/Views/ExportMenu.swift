import SwiftUI
import AppKit

/// Copy and Export. Copy takes the tab you're on (Original or Cleaned) with its own defaults, never the export
/// sheet's options; the menu beside it copies with timestamps, the other version, or the engine's words. Export
/// opens the export sheet (ExportSheet), which keeps its own saved options.
struct ExportMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var compact = false
    /// The version the current tab shows.
    var version: Exporter.CopyVersion = .original
    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                Button { ExportMenu.copy(transcript, version, app: app) } label: { ToolLabel(title: "Copy", symbol: "doc.on.doc", compact: compact) }
                    .buttonStyle(.plain).help("Copy the \(version.name) (⌘⇧C)")
                    .accessibilityIdentifier("copy-tab")
                Menu {
                    Button("Copy with timestamps") { ExportMenu.copy(transcript, version, timestamps: true, app: app) }
                    Button(version == .cleaned ? "Copy the original" : "Copy the cleaned text") { ExportMenu.copy(transcript, version.other, app: app) }
                    Button("Copy engine words") { ExportMenu.copy(transcript, .engine, app: app) }
                        .disabled(!transcript.hasEngineWords)
                    Divider()
                    // The text with a header (title, date, duration, speakers, source, language) for an AI assistant.
                    // ⌥⇧⌘C on the transcript screen (TranscriptView); ⌥⌘C is Live captions.
                    Button("Copy for AI (⌥⇧⌘C)") { CopyForAI.copy(transcript, app: app) }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.dim)
                        .frame(width: 16, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More ways to copy")
                .accessibilityLabel("More ways to copy")
            }
            Button { app.exportRequest = ExportRequest(ids: [transcript.id]) } label: { ToolLabel(title: "Export", symbol: "square.and.arrow.up", compact: compact) }
                .buttonStyle(.plain).help("Export as text, Markdown, Word, subtitles, or JSON")
        }
        .disabled(transcript.status != .ready)
    }

    /// Copies one version with Copy's own defaults. Also bound to ⌘⇧C once per transcript screen.
    static func copy(_ t: Transcript, _ v: Exporter.CopyVersion, timestamps: Bool = false, app: AppState) {
        guard t.status == .ready else { return }
        Exporter.copy(t, v, timestamps: timestamps)
        app.toast = Toast("Copied the \(v.name)" + (timestamps ? " with timestamps" : ""))
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
