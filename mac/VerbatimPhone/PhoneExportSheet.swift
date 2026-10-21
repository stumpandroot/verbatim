import SwiftUI
import UIKit

/// Which transcripts the export sheet covers.
struct PhoneExportRequest: Identifiable {
    let id = UUID()
    var ids: [UUID]
}

/// The iPhone export sheet: the Mac sheet's options as a list (format first; SRT and VTT show subtitle settings), a
/// preview of the actual output, then Copy and Share. Changes are saved, so Copy text elsewhere uses them too.
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
                    Text(format.note)
                }
                Section("Options") {
                    ExportOptionRows(options: $options, format: format,
                                     speakersAvailable: ts.contains { $0.speakers.count >= 2 },
                                     summaryAvailable: ts.contains { Exporter.summary($0) != nil })
                }
                .listRowBackground(Ink.card)
                Section {
                    Text(preview.isEmpty ? "Nothing to export yet." : preview)
                        .font(Ink.mono(11.5)).foregroundStyle(Ink.ink).lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Preview")
                } header: {
                    Text(previewTitle(ts))
                }
                .listRowBackground(Ink.reader)
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(ts.count > 1 ? "Export \(ts.count) transcripts" : "Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button { copy(ts) } label: { Text("Copy").frame(maxWidth: .infinity).frame(height: 46) }
                        .buttonStyle(.bordered).tint(Ink.ink)
                    Button { share(ts) } label: { Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).frame(height: 46) }
                        .buttonStyle(.borderedProminent).tint(Ink.interactive).foregroundStyle(Ink.onInteractive)
                }
                .font(.system(size: 16, weight: .semibold))
                .disabled(ts.isEmpty)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.bar)
            }
        }
        .tint(Ink.switchOn)
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
        dismiss()
    }

    /// One file per transcript, handed to the share sheet (Save to Files, Mail, AirDrop…).
    private func share(_ ts: [Transcript]) {
        let urls = ts.compactMap { app.exportFile($0, as: format, options: options) }
        if !urls.isEmpty { shareItems = urls }
    }
}
