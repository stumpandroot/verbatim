import SwiftUI
import UIKit

/// The iPhone export sheet: the Mac sheet's options as a list (format first; SRT and VTT show subtitle settings), a
/// preview of the actual output, then Copy and Share. Changes are saved for the next export; Copy text on the
/// transcript keeps its own defaults (the tab you're on). On the refined kit (DESIGN.md §13).
struct PhoneExportSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    var ids: [UUID]
    @State private var format = ExportOptions.savedFormat
    @State private var options = ExportOptions.saved
    @State private var preview = ""
    @State private var shareItems: [Any]? = nil

    private var transcripts: [Transcript] { ids.compactMap { app.store.transcript($0) }.filter { $0.status == .ready } }

    var body: some View {
        let ts = transcripts
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.short).tag($0) }
                    }
                } footer: {
                    Text(format.note).foregroundStyle(Refined.mute)
                }
                .listRowBackground(Refined.card)
                Section("Options") {
                    ExportOptionRows(options: $options, format: format,
                                     speakersAvailable: ts.contains { $0.speakers.count >= 2 },
                                     summaryAvailable: ts.contains { Exporter.summary($0) != nil })
                }
                .listRowBackground(Refined.card)
                .refinedSwitchTint()
                Section {
                    Text(preview.isEmpty ? "Nothing to export yet." : preview)
                        .font(.system(size: 12)).foregroundStyle(Refined.ink).lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Preview")
                } header: {
                    Text(previewTitle(ts))
                }
                .listRowBackground(Refined.field)
            }
            .scrollContentBackground(.hidden)
            .background(Refined.paper.ignoresSafeArea())
            .navigationTitle(ts.count > 1 ? "Export \(ts.count) transcripts" : "Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button { copy(ts) } label: { Text("Copy").frame(maxWidth: .infinity) }
                        .buttonStyle(RefinedActionStyle(kind: .quiet))
                    Button { share(ts) } label: { Text("Share").frame(maxWidth: .infinity) }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                }
                .disabled(ts.isEmpty)
                .padding(.horizontal, 20).padding(.vertical, 10)
                // Opaque paper with a separator on top: the Copy and Share labels never sit on a blur (DESIGN.md §13).
                .background(Refined.paper)
                .overlay(alignment: .top) { Rectangle().fill(Refined.separator).frame(height: 1) }
            }
        }
        // Values and Cancel in the accent; the Options switches take the kit's switch tint (above).
        .tint(Refined.accentText)
        .onAppear(perform: refresh)
        .onChange(of: options) { _, o in o.save(); refresh() }
        .onChange(of: format) { _, f in ExportOptions.savedFormat = f; refresh() }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ShareSheet(items: shareItems ?? []) }
    }

    private func refresh() {
        guard let t = transcripts.first else { preview = ""; return }
        preview = Exporter.preview(t, as: format, options: options, lines: 40)
    }

    private func previewTitle(_ ts: [Transcript]) -> String {
        guard let t = ts.first else { return "Preview" }
        var used = Set<String>()
        let name = ExportNames.unique(t.title, ext: format.ext, used: &used)
        return ts.count > 1 ? "Preview · first of \(ts.count) · \(name)" : "Preview · \(name)"
    }

    private func copy(_ ts: [Transcript]) {
        guard !ts.isEmpty else { return }
        UIPasteboard.general.string = Exporter.clipboard(ts, as: format, options: options)
        app.say(ts.count == 1 ? "Copied" : "Copied \(ts.count) transcripts")
        Haptics.play(.copied)
        dismiss()
    }

    /// One file per transcript, handed to the share sheet (Save to Files, Mail, AirDrop…).
    private func share(_ ts: [Transcript]) {
        let urls = ts.compactMap { app.exportFile($0, as: format, options: options) }
        if !urls.isEmpty { shareItems = urls }
    }
}
