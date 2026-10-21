import SwiftUI

// Export options as standard Form rows, shared by the iPhone export sheet and Settings (Mac and iPhone).
// The Mac export sheet draws the same options in its own card (ExportSheet.swift).

/// The rows for one format's options. `format` nil shows every option (Settings: text and subtitles).
struct ExportOptionRows: View {
    @Binding var options: ExportOptions
    var format: ExportFormat?
    var speakersAvailable = true
    var summaryAvailable = true
    @State private var offsetText = ""
    @State private var offsetInvalid = false

    private var showsText: Bool { format.map { !$0.timed && $0 != .json } ?? true }
    private var showsSubtitles: Bool { format?.timed ?? true }

    var body: some View {
        if format == .json {
            Text("JSON includes everything: segments with word timings, speakers, moments, the summary, and details. These options don't change it.")
                .font(.footnote).foregroundStyle(Ink.mute)
        } else {
            if showsText {
                Picker("Text", selection: $options.source) { ForEach(ExportOptions.Source.allCases) { Text($0.label).tag($0) } }
                Toggle("Title and details header", isOn: $options.header)
                Toggle(isOn: $options.summary) {
                    HStack(spacing: 6) { Text("Summary"); Text("AI").font(Ink.mono(10, weight: .medium)).tracking(1).foregroundStyle(Ink.mute) }
                }
                .disabled(!summaryAvailable)
            }
            Picker("Speaker names", selection: $options.speakerMode) {
                ForEach(ExportOptions.SpeakerMode.allCases) { Text(showsText ? $0.label : $0.captionLabel).tag($0) }
            }
            .disabled(!speakersAvailable)
            if showsText {
                Picker("Timecodes", selection: $options.timecodeMode) { ForEach(ExportOptions.TimecodeMode.allCases) { Text($0.label).tag($0) } }
                if options.timecodeMode != .off || options.moments != .off {
                    Picker("Timecode style", selection: $options.timecodeStyle) { ForEach(ExportOptions.TimecodeStyle.allCases) { Text($0.label).tag($0) } }
                }
                Picker("Moments", selection: $options.moments) { ForEach(ExportOptions.MomentsMode.allCases) { Text($0.label).tag($0) } }
            }
            if showsSubtitles || options.timecodeMode != .off || options.moments != .off {
                offsetRow
            }
            Toggle("Include hidden lines", isOn: $options.includeHidden)
            if showsText {
                Toggle("One paragraph", isOn: $options.singleParagraph)
                Toggle("“Transcribed with Verbatim” footer", isOn: $options.provenance)
            }
            if showsSubtitles {
                Stepper(value: $options.subtitles.charsPerLine, in: 16...80) {
                    LabeledContent("Characters per line") { Text("\(options.subtitles.charsPerLine)").font(Ink.mono(13)) }
                }
                Stepper(value: $options.subtitles.linesPerCaption, in: 1...3) {
                    LabeledContent("Lines per caption") { Text("\(options.subtitles.linesPerCaption)").font(Ink.mono(13)) }
                }
                Stepper(value: $options.subtitles.minDuration, in: 0.3...5, step: 0.1) {
                    LabeledContent("Shortest caption") { Text(String(format: "%.1f s", options.subtitles.minDuration)).font(Ink.mono(13)) }
                }
                Stepper(value: $options.subtitles.maxDuration, in: 2...20, step: 0.5) {
                    LabeledContent("Longest caption") { Text(ExportOptionRows.seconds(options.subtitles.maxDuration)).font(Ink.mono(13)) }
                }
            }
        }
    }

    private var offsetRow: some View {
        LabeledContent("Start at") {
            TextField("00:00:00", text: $offsetText)
                .font(Ink.mono(13)).multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .foregroundStyle(offsetInvalid ? Ink.accentText : Ink.ink)
                .frame(maxWidth: 110)
                .onAppear { offsetText = Timecode.offsetText(options.timecodeOffset) }
                .onChange(of: offsetText) { _, v in
                    if let s = Timecode.parseOffset(v) { offsetInvalid = false; options.timecodeOffset = s } else { offsetInvalid = true }
                }
                .accessibilityHint("Hours, minutes, and seconds added to every time, such as 01:00:00")
        }
    }

    /// "7 s", "7.5 s".
    static func seconds(_ v: Double) -> String { v == v.rounded() ? "\(Int(v)) s" : String(format: "%.1f s", v) }
}

/// Settings › Export: the defaults every copy and export starts from. The rebuilt Settings embeds this; it edits the
/// same saved options as the export sheet.
struct ExportDefaultsSection: View {
    @State private var options = ExportOptions.saved
    var body: some View {
        Section {
            ExportOptionRows(options: $options, format: nil)
        } header: {
            Text("Export")
        } footer: {
            Text("Copy and every export start from these. The export sheet changes them too.")
        }
        .onChange(of: options) { _, o in o.save() }
    }
}
