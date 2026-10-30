import SwiftUI
import AppKit

/// The export sheet (approved mockup, October 2026), on the refined kit (DESIGN.md §13): options on the left with the
/// format at the top, a live preview of the actual output on the right, then Cancel, Copy, and Export…. SRT and VTT
/// swap the options for subtitle settings. Every change is saved, so Copy elsewhere (⌘⇧C, the Copy button) uses the
/// same options.
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
            Rectangle().fill(Refined.separator).frame(width: 1)
            previewPane(ts)
        }
        // Never taller than the window it hangs from, less 80 pt, so Cancel and Export stay on screen; the options
        // scroll instead (review M-28).
        .frame(width: 980, height: ExportSheet.height(window: app.mainWindow?.contentLayoutRect.height))
        .background(Refined.paper)
        .tint(Refined.accentText)
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
                Text("Export").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Text(tag(ts)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
            }
            FormatControl(selection: $format)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The card at its own height when it fits; scrolling when it doesn't.
            ViewThatFits(in: .vertical) {
                optionsCard(ts)
                ScrollView { optionsCard(ts) }
            }
            if let note = footnote {
                Text(note).refinedFont(.meta).foregroundStyle(Refined.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy") { copy(ts) }.disabled(ts.isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(ExportSheet.exportTitle(count: ts.count, batch: batch)) { export(ts) }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(ts.isEmpty || offsetInvalid)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
    }

    /// The sheet's height: 660 pt, or the window's content height less 80 when that's less (never under 420).
    static func height(window: CGFloat?) -> CGFloat {
        guard let window, window > 0 else { return 660 }
        return max(420, min(660, window - 80))
    }

    /// "Export…", or "Export 3 files…" for a batch: the whole label always fits its button.
    static func exportTitle(count: Int, batch: Bool) -> String {
        batch ? "Export \(count) \(count == 1 ? "file" : "files")…" : "Export…"
    }

    /// "Studio walkthrough · 42 min", or "3 transcripts · 2 h 10 min".
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
                    .refinedFont(.body).foregroundStyle(Refined.dim).lineSpacing(2)
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
        .refinedFont(.rowTitle)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    // MARK: Rows and controls

    private func row<C: View>(_ label: String, badge: String? = nil, detail: String? = nil, divider: Bool, @ViewBuilder control: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(Refined.ink).lineLimit(1)
                if let badge { Text(badge).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Refined.mute) }
                if let detail { Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(Refined.mute) }
                Spacer(minLength: 10)
                control()
            }
            .padding(.horizontal, 14).frame(minHeight: 42)
            if divider { PaperDivider(leading: 14, trailing: 14) }
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View {
        Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().controlSize(.small).refinedSwitchTint()
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
        .foregroundStyle(Refined.dim)
    }

    private func stepper<V: Strideable & Comparable>(_ b: Binding<V>, _ range: ClosedRange<V>, _ step: V.Stride, _ text: @escaping (V) -> String) -> some View {
        HStack(spacing: 8) {
            Text(text(b.wrappedValue)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Refined.dim).frame(minWidth: 44, alignment: .trailing)
            Stepper("", value: b, in: range, step: step).labelsHidden().controlSize(.small)
        }
    }

    private var offsetField: some View {
        TextField("00:00:00", text: $offsetText)
            .textFieldStyle(.plain).font(.system(size: 12.5)).monospacedDigit().multilineTextAlignment(.trailing)
            .foregroundStyle(offsetInvalid ? Refined.accentText : Refined.ink)
            .padding(.horizontal, 8).frame(width: 104, height: 24)
            .refinedFieldBox()
            .overlay { if offsetInvalid { RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous).strokeBorder(Refined.accentText) } }
            .help("Added to every time: hours, minutes, and seconds, such as 01:00:00")
            .onChange(of: offsetText) { _, v in
                if let s = Timecode.parseOffset(v) { offsetInvalid = false; options.timecodeOffset = s } else { offsetInvalid = true }
            }
    }

    // MARK: Preview

    private func previewPane(_ ts: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The file's name as it will be saved, never uppercased (names are case-sensitive).
            Text(previewTitle(ts)).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1).truncationMode(.middle)
            if ts.isEmpty {
                Text("Nothing to export yet. Transcripts still in progress are left out.").refinedFont(.body).foregroundStyle(Refined.mute)
                Spacer()
            } else {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 13)).lineSpacing(6).foregroundStyle(Refined.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Refined.card)
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

/// The six formats in the kit's segmented control, sized to their titles. Each format's note is its tooltip.
struct FormatControl: View {
    @Binding var selection: ExportFormat
    var body: some View {
        RefinedSegmented(label: "Format", options: ExportFormat.allCases.map { ($0, $0.short) }, selection: $selection)
            .fixedSize()
            .help(selection.note)
    }
}
