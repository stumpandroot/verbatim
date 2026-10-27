import SwiftUI
import AppKit

/// Which transcripts the export sheet covers: one from its transcript screen, or a Library selection.
struct ExportRequest: Identifiable, Equatable {
    let id = UUID()
    var ids: [UUID]
}

/// The export sheet (approved mockup, October 2026): options on the left with the format at the top, a live preview
/// of the actual output on the right, then Cancel, Copy, and Export…. SRT and VTT swap the options for subtitle
/// settings. Every change is saved, so Copy elsewhere (⌘⇧C, the Copy button) uses the same options.
struct ExportSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var ids: [UUID]
    @State private var format = ExportOptions.savedFormat
    @State private var options = ExportOptions.saved
    @State private var offsetText = ""
    @State private var offsetInvalid = false
    @State private var preview = ""

    private var transcripts: [Transcript] { ids.compactMap { app.store.transcript($0) }.filter { $0.status == .ready } }
    private var batch: Bool { ids.count > 1 }

    var body: some View {
        let ts = transcripts
        HStack(spacing: 0) {
            controls(ts).frame(width: 430)
            Rectangle().fill(Ink.ink.opacity(0.10)).frame(width: 1)
            previewPane(ts)
        }
        .frame(width: 980, height: 660)
        .background(Ink.paper)
        .tint(Ink.switchOn)
        .onAppear { offsetText = Timecode.offsetText(options.timecodeOffset); refresh() }
        .onChange(of: options) { _, o in o.save(); refresh() }
        .onChange(of: format) { _, f in ExportOptions.savedFormat = f; refresh() }
    }

    private func refresh() {
        guard let t = transcripts.first else { preview = ""; return }
        preview = Exporter.preview(t, as: format, options: options)
    }

    // MARK: Left column

    private func controls(_ ts: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Export").font(Ink.serif(30)).foregroundStyle(Ink.ink)
                Spacer(minLength: 12)
                Text(tag(ts)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.mute)
            }
            FormatControl(selection: $format)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The card at its own height when it fits; scrolling when it doesn't.
            ViewThatFits(in: .vertical) {
                optionsCard(ts)
                ScrollView { optionsCard(ts) }
            }
            if let note = footnote {
                Text(note).font(.system(size: 12)).foregroundStyle(Ink.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }.buttonStyle(SheetButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Copy") { copy(ts) }.buttonStyle(SheetButtonStyle()).disabled(ts.isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(batch ? "Export \(ts.count)…" : "Export…") { export(ts) }.buttonStyle(SheetButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction).disabled(ts.isEmpty || offsetInvalid)
            }
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
    }

    /// "STUDIO WALKTHROUGH · 42 MIN", or "3 TRANSCRIPTS · 2 H 10 MIN".
    private func tag(_ ts: [Transcript]) -> String {
        if batch {
            let total = ts.map(\.duration).reduce(0, +)
            return "\(ts.count) transcript\(ts.count == 1 ? "" : "s")" + (total > 0 ? " · " + Timecode.spoken(total) : "")
        }
        guard let t = ts.first else { return "" }
        let title = t.title.count > 28 ? String(t.title.prefix(27)) + "…" : t.title
        return t.duration > 0 ? "\(title) · \(Timecode.spoken(t.duration))" : title
    }

    private var footnote: String? {
        switch format {
        case .txt: return options.source.hint
        case .md: return "Title as a heading, speaker names in bold. Opens in Notes, Obsidian, and Notion."
        case .docx: return "Title as a heading, speaker names in bold. Opens in Word, Pages, and Google Docs."
        case .srt, .vtt: return "Captions follow the word timings, break at speaker changes and pauses, and prefer sentence ends."
        case .json: return nil
        }
    }

    @ViewBuilder private func optionsCard(_ ts: [Transcript]) -> some View {
        let multi = ts.contains { $0.speakers.count >= 2 }
        let hasSummary = ts.contains { Exporter.summary($0) != nil }
        let hidden = ts.first.map { $0.hiddenSegmentIDs.count } ?? 0
        let sponsors = ts.reduce(0) { $0 + $1.sponsorSpans.count }
        let unclear = ts.reduce(0) { $0 + ($1.unclear?.count ?? 0) }
        VStack(spacing: 0) {
            switch format {
            case .json:
                Text("JSON includes everything: segments with word timings, speakers, moments, the summary, and details. The options don't change it.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            case .srt, .vtt:
                row("Speaker names", divider: true) { menu(ExportOptions.SpeakerMode.allCases, $options.speakerMode, \.captionLabel) }.disabled(!multi)
                row("Include hidden lines", detail: hidden > 0 ? "\(hidden)" : nil, divider: true) { toggle($options.includeHidden) }
                row("Include sponsor reads", detail: sponsors > 0 ? "\(sponsors)" : nil, divider: true) { toggle($options.includeSponsors) }
                    .help("Sponsor reads found in podcasts and videos")
                row("Characters per line", divider: true) { stepper($options.subtitles.charsPerLine, 16...80, 1) { "\($0)" } }
                row("Lines per caption", divider: true) { stepper($options.subtitles.linesPerCaption, 1...3, 1) { "\($0)" } }
                row("Shortest caption", divider: true) { stepper($options.subtitles.minDuration, 0.3...5, 0.1) { String(format: "%.1f s", $0) } }
                row("Longest caption", divider: true) { stepper($options.subtitles.maxDuration, 2...20, 0.5) { ExportOptionRows.seconds($0) } }
                row("Start at", divider: false) { offsetField }
            case .txt, .md, .docx:
                row("Text", divider: true) { menu(ExportOptions.Source.allCases, $options.source, \.label) }
                row("Title and details header", divider: true) { toggle($options.header) }
                if options.source == .document {
                    row("Note when Apple Intelligence cleaned it", divider: true) { toggle($options.aiNote) }
                        .help("Adds “\(Exporter.aiNoteText)” to Cleaned text Apple Intelligence touched")
                }
                row("Summary", badge: "AI", detail: hasSummary ? nil : "None yet", divider: true) { toggle($options.summary) }
                    .disabled(!hasSummary)
                    .help(hasSummary ? "Put the summary before the text" : "Summarize from the Actions menu first")
                row("Speaker names", divider: true) { menu(ExportOptions.SpeakerMode.allCases, $options.speakerMode, \.label) }
                    .disabled(!multi).help(multi ? "" : "One speaker")
                row("Timecodes", divider: true) { timecodeMenu }
                if options.timecodeMode != .off || options.moments != .off {
                    row("Start at", divider: true) { offsetField }
                }
                row("Moments", divider: true) { menu(ExportOptions.MomentsMode.allCases, $options.moments, \.label) }
                row("Include hidden lines", detail: hidden > 0 ? "\(hidden)" : nil, divider: true) { toggle($options.includeHidden) }
                    .disabled(options.source == .document && ts.first?.document != nil)
                    .help(options.source == .document && ts.first?.document != nil ? "The edited document has no hidden lines" : "Filler-only lines and background voices the transcript hides")
                row("Include sponsor reads", detail: sponsors > 0 ? "\(sponsors)" : nil, divider: true) { toggle($options.includeSponsors) }
                    .disabled(options.source == .document && ts.first?.document != nil)
                    .help(options.source == .document && ts.first?.document != nil ? "The edited document keeps its own text" : "Sponsor reads found in podcasts and videos")
                row("Unclear markers", detail: unclear > 0 ? "\(unclear)" : nil, divider: true) { toggle($options.includeUnclear) }
                    .help("Adds “[unclear 2:10]” where speech was heard but the words didn't come through")
                row("One paragraph", divider: true) { toggle($options.singleParagraph) }
                row("“Transcribed with Verbose” footer", divider: false) { toggle($options.provenance) }
            }
        }
        .font(.system(size: 13.5))
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
    }

    // MARK: Rows and controls

    private func row<C: View>(_ label: String, badge: String? = nil, detail: String? = nil, divider: Bool, @ViewBuilder control: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(Ink.ink).lineLimit(1)
                if let badge { Text(badge).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Ink.mute) }
                if let detail { Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.mute) }
                Spacer(minLength: 10)
                control()
            }
            .padding(.horizontal, 14).frame(minHeight: 42)
            if divider { Rectangle().fill(Ink.ink.opacity(0.07)).frame(height: 1) }
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View {
        Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().controlSize(.small)
    }

    private func menu<T: Hashable & Identifiable>(_ all: [T], _ b: Binding<T>, _ label: KeyPath<T, String>) -> some View {
        Menu {
            Picker("", selection: b) { ForEach(all) { Text($0[keyPath: label]).tag($0) } }.pickerStyle(.inline).labelsHidden()
        } label: {
            menuLabel(b.wrappedValue[keyPath: label])
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var timecodeMenu: some View {
        Menu {
            Picker("", selection: $options.timecodeMode) { ForEach(ExportOptions.TimecodeMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline).labelsHidden()
            Divider()
            Picker("Style", selection: $options.timecodeStyle) { ForEach(ExportOptions.TimecodeStyle.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline)
        } label: {
            menuLabel(options.timecodeMode == .off ? "Off" : "\(options.timecodeMode.label) · \(options.timecodeStyle.label)")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func menuLabel(_ s: String) -> some View {
        HStack(spacing: 4) {
            Text(s)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Ink.dim)
    }

    private func stepper<V: Strideable & Comparable>(_ b: Binding<V>, _ range: ClosedRange<V>, _ step: V.Stride, _ text: @escaping (V) -> String) -> some View {
        HStack(spacing: 8) {
            Text(text(b.wrappedValue)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.dim).frame(minWidth: 44, alignment: .trailing)
            Stepper("", value: b, in: range, step: step).labelsHidden().controlSize(.small)
        }
    }

    private var offsetField: some View {
        TextField("00:00:00", text: $offsetText)
            .textFieldStyle(.plain).font(Ink.mono(12.5)).multilineTextAlignment(.trailing)
            .foregroundStyle(offsetInvalid ? Ink.accentText : Ink.ink)
            .padding(.horizontal, 8).frame(width: 104, height: 24)
            .background(Ink.paper, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(offsetInvalid ? Ink.accentText : Ink.hairline))
            .help("Added to every time: hours, minutes, and seconds, such as 01:00:00")
            .onChange(of: offsetText) { _, v in
                if let s = Timecode.parseOffset(v) { offsetInvalid = false; options.timecodeOffset = s } else { offsetInvalid = true }
            }
    }

    // MARK: Preview

    private func previewPane(_ ts: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: previewTitle(ts), color: Ink.mute)
            if ts.isEmpty {
                Text("Nothing to export yet. Transcripts still in progress are left out.").font(.system(size: 13)).foregroundStyle(Ink.mute)
                Spacer()
            } else {
                ScrollView {
                    Text(preview)
                        .font(Ink.mono(12.5)).lineSpacing(7).foregroundStyle(Ink.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.reader)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
    }

    private func previewTitle(_ ts: [Transcript]) -> String {
        guard let t = ts.first else { return "Preview" }
        var used = Set<String>()
        let name = ExportNames.unique(t.title, ext: format.ext, used: &used)
        return batch ? "Preview · first of \(ts.count) · \(name)" : "Preview · \(name)"
    }

    // MARK: Actions

    private func copy(_ ts: [Transcript]) {
        guard !ts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporter.clipboard(ts, as: format, options: options), forType: .string)
        app.toast = Toast(ts.count == 1 ? "Copied" : "Copied \(ts.count) transcripts")
        Sounds.done()
        dismiss()
    }

    private func export(_ ts: [Transcript]) {
        guard !ts.isEmpty else { return }
        if ts.count == 1 && !batch {
            if Exporter.save(ts[0], as: format, options: options) {
                app.toast = Toast("Exported \(format.rawValue)")
                dismiss()
            }
        } else {
            let n = Exporter.saveMany(ts, as: format, options: options)
            if n > 0 {
                app.toast = Toast("Exported \(n) transcript\(n == 1 ? "" : "s")")
                dismiss()
            }
        }
    }
}

/// The six formats in the shared view switch (DESIGN.md §11.15), as the transcript's modes and You's Week | Month;
/// Native draws the system segmented control. Each format's note is its tooltip.
struct FormatControl: View {
    @Binding var selection: ExportFormat
    var body: some View {
        SegmentedCapsule(label: "Format", options: ExportFormat.allCases, selection: $selection, title: { $0.short },
                         small: true, help: { $0.note }, target: { "export-format-\($0.rawValue)" })
    }
}

/// The sheet's bottom buttons, equal widths: regular pills (DESIGN.md §11.5), dark for the main one and line for the
/// rest; Native draws its own faces.
struct SheetButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        PillButtonStyle(kind: primary ? .dark : .line, size: .regular, fullWidth: true).makeBody(configuration: configuration)
    }
}
