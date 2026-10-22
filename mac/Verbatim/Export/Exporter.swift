import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// Turns a Transcript into exports. The options, timecodes, text layout, and subtitle segmentation live in
// ExportCore.swift (Foundation only, tested by mac/tools/test-export.sh); this file maps transcripts onto them.

extension Transcript {
    /// Lines the reading view hides: filler-only lines (Settings › Hide filler lines) and background voices
    /// (Settings › Main speaker only). Exports leave them out unless "Include hidden lines" is on.
    var hiddenSegmentIDs: Set<UUID> {
        let shown = Set(displaySegments(hideFiller: Transcript.hideFiller, mainOnly: Transcript.mainSpeakerOnly).map(\.id))
        return Set(segments.map(\.id)).subtracting(shown)
    }
}

enum Exporter {
    // MARK: Building the document

    /// The transcript's summary, when it has one (see `ExportSummary.reflect`).
    static func summary(_ t: Transcript) -> ExportSummary? { ExportSummary.reflect(t) }

    /// The segments an export covers: all of them, or without the hidden ones.
    static func segments(_ t: Transcript, _ o: ExportOptions) -> [Segment] {
        guard !o.includeHidden else { return t.segments }
        let hidden = t.hiddenSegmentIDs
        return hidden.isEmpty ? t.segments : t.segments.filter { !hidden.contains($0.id) }
    }

    /// Kind, date, duration, speakers: "Meeting · Oct 20, 2026 · 42 min · Ana, Tim".
    static func details(_ t: Transcript) -> [String] {
        var out: [String] = []
        if let k = t.kind { out.append(k.label) } else if !t.sourceLabel.isEmpty { out.append(t.sourceLabel) }
        out.append(Formats.style(date: .medium, time: .none).string(from: t.createdAt))
        if t.duration > 0 { out.append(Timecode.spoken(t.duration)) }
        if t.speakers.count >= 2 { out.append(t.speakers.map(\.label).joined(separator: ", ")) }
        return out
    }

    /// Notes pinned to a time, oldest moment first. A bookmark with no text reads as its line.
    static func moments(_ t: Transcript) -> [ExportMoment] {
        t.notes.compactMap { n -> ExportMoment? in
            guard let at = n.at else { return nil }
            var text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, let sid = n.segmentId, let s = t.segments.first(where: { $0.id == sid }) {
                text = s.text.count > 80 ? String(s.text.prefix(79)) + "…" : s.text
            }
            return ExportMoment(at: at, text: text, bookmark: n.isBookmark)
        }
        .sorted { $0.at < $1.at }
    }

    static func provenance(_ t: Transcript) -> String {
        let f = Formats.style(date: .medium, time: .short)
        return "Transcribed with Verbatim (\(t.model.isEmpty ? "on-device" : t.model)) on \(f.string(from: t.createdAt))"
    }

    /// The note on Cleaned text Apple Intelligence touched.
    static let aiNoteText = "Cleaned by Apple Intelligence from the original transcript."

    static func document(_ t: Transcript, _ o: ExportOptions, markdown: Bool = false) -> ExportDocument {
        let multi = t.speakers.count >= 2
        func name(_ s: Segment) -> String? { multi ? t.speakerName(s.speaker) : nil }
        var paragraphs: [ExportParagraph] = []
        var segs = segments(t, o)
        // Original (engine words): the engine's own lines for the same passages, before any correction.
        if o.source == .engine { segs = t.engineLines(for: segs) }
        segs = segs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let lineByLine = o.source != .document && !o.groupLines
        if lineByLine {
            paragraphs = segs.map { ExportParagraph(speaker: name($0), pieces: [ExportPiece(start: $0.start, text: $0.text.trimmingCharacters(in: .whitespaces))]) }
        } else if o.source == .document, let edited = t.document {
            paragraphs = editedParagraphs(t, edited)
        } else {
            // The same paragraphs DocumentText.build makes, keeping each line's time.
            var cur: ExportParagraph? = nil
            var lastEnd = 0.0
            for s in segs {
                let piece = ExportPiece(start: s.start, text: s.text.trimmingCharacters(in: .whitespaces))
                if var c = cur {
                    let speakerChanged = multi && name(s) != c.speaker
                    let longPause = s.start - lastEnd > 2.0
                    if speakerChanged || (!multi && (longPause || c.pieces.count >= 5)) {
                        paragraphs.append(c); cur = ExportParagraph(speaker: name(s), pieces: [piece])
                    } else {
                        c.pieces.append(piece); cur = c
                    }
                } else {
                    cur = ExportParagraph(speaker: name(s), pieces: [piece])
                }
                lastEnd = s.end
            }
            if let c = cur { paragraphs.append(c) }
        }
        var doc = ExportDocument(title: t.title, details: details(t), summary: summary(t), paragraphs: paragraphs,
                                 moments: moments(t), footer: provenance(t), lineByLine: lineByLine)
        if o.source == .document, t.cleanedByModel { doc.aiNote = aiNoteText }
        if let info = t.linkInfo {
            let label = [info.channel, info.site].compactMap { $0 }.joined(separator: " · ").ifEmpty(info.url)
            doc.sourceLine = (markdown ? "Source: [\(label)](\(info.url))" : "Source: \(info.url)") + (info.uploadDisplay.map { " · \($0)" } ?? "")
            if markdown, info.supportsTimestamps { doc.link = { info.url(at: $0)?.absoluteString } }
        }
        return doc
    }

    /// An edited document's paragraphs. Edits don't keep times, so each paragraph takes the time of the line at the
    /// same point in the words (its share of the document's words, mapped onto the transcript's).
    static func editedParagraphs(_ t: Transcript, _ text: String) -> [ExportParagraph] {
        let names = t.speakers.count >= 2 ? t.speakers.map(\.label) : []
        let paras = DocumentText.paragraphs(text).map { DocumentText.split($0, speakers: names) }
        func count(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
        let docWords = max(1, paras.map { count($0.text) }.reduce(0, +))
        var cumulative: [(start: Double, upTo: Int)] = []
        var total = 0
        for s in t.segments { total += count(s.text); cumulative.append((s.start, total)) }
        var seen = 0
        return paras.map { p in
            let target = total == 0 ? 0 : Int(Double(seen) / Double(docWords) * Double(total))
            let start = cumulative.first { $0.upTo > target }?.start ?? cumulative.last?.start ?? 0
            seen += count(p.text)
            return ExportParagraph(speaker: p.speaker, pieces: [ExportPiece(start: start, text: p.text)])
        }
    }

    static func captions(_ t: Transcript, _ o: ExportOptions) -> [Caption] {
        let multi = t.speakers.count >= 2
        var words: [TimedWord] = []
        for s in segments(t, o) {
            words += Subtitles.words(text: s.text, start: s.start, end: s.end, timings: s.words?.map { ($0.start, $0.end) },
                                     speaker: multi ? t.speakerName(s.speaker) : nil)
        }
        return Subtitles.captions(words, o.subtitles, speakerMode: o.speakerMode)
    }

    // MARK: Output

    /// The text people copy, shaped by the options.
    static func text(_ t: Transcript, _ o: ExportOptions) -> String {
        ExportLayout.text(document(t, o), o)
    }

    static func render(_ t: Transcript, as f: ExportFormat, options o: ExportOptions) -> String {
        switch f {
        case .txt, .docx: return text(t, o)
        case .md: return ExportLayout.markdown(document(t, o, markdown: true), o)
        case .srt: return Subtitles.srt(captions(t, o), offset: o.timecodeOffset)
        case .vtt: return Subtitles.vtt(captions(t, o), offset: o.timecodeOffset)
        case .json: return json(t, o)
        }
    }

    /// The live preview: the start of the actual output (Word shows its text, headings included).
    static func preview(_ t: Transcript, as f: ExportFormat, options o: ExportOptions, lines: Int = 60) -> String {
        var t = t
        // JSON writes every word; a short transcript is enough to show its shape.
        if f == .json, t.segments.count > 12 { t.segments = Array(t.segments.prefix(12)); t.original = []; t.documentHistory = [] }
        let full = render(t, as: f, options: o)
        var out: [Substring] = []
        for line in full.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(line)
            if out.count >= lines { out.append("…"); break }
        }
        return out.joined(separator: "\n")
    }

    /// Everything: the stored transcript (segments with words, speakers, notes, corrections, document) plus an
    /// `export` section with resolved details, moments, the summary, and which lines the app hides.
    static func json(_ t: Transcript, _ o: ExportOptions) -> String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(t) else { return "{}" }
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return String(data: data, encoding: .utf8) ?? "{}" }
        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = [
            "title": t.title, "createdAt": iso.string(from: t.createdAt), "duration": t.duration, "durationText": Timecode.spoken(t.duration),
            "source": t.source.rawValue, "sourceLabel": t.sourceLabel, "model": t.model, "engine": t.engine,
            "details": details(t).joined(separator: " · "),
        ]
        meta["kind"] = t.kind?.rawValue ?? NSNull()
        meta["language"] = t.language ?? NSNull()
        meta["url"] = t.linkInfo?.url ?? NSNull()
        var export: [String: Any] = [
            "format": "verbatim-export", "version": 2, "metadata": meta,
            "speakers": t.speakers.map { ["id": $0.id, "name": $0.label] },
            "moments": moments(t).map { ["at": $0.at, "timecode": Timecode.digits($0.at, style: .bracketed), "text": $0.text, "bookmark": $0.bookmark] },
            "hiddenSegmentIds": t.hiddenSegmentIDs.map(\.uuidString).sorted(),
            "documentText": t.documentText,
            "engineText": (t.hasEngineWords ? t.original : t.segments).map(\.text).joined(separator: " "),
            "cleanedBy": t.cleanedBy?.rawValue ?? "none",
        ]
        if let s = summary(t) { export["summary"] = ["overview": s.overview, "keyPoints": s.keyPoints, "byModel": s.byModel] }
        else { export["summary"] = NSNull() }
        obj["export"] = export
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return String(data: out, encoding: .utf8) ?? "{}"
    }

    /// A minimal .docx from the same blocks as text and Markdown: title, details, headings, paragraphs with bold
    /// speaker names, and list items.
    static func docxData(_ t: Transcript, options o: ExportOptions) -> Data {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        func run(_ s: String, bold: Bool = false, size: Int? = nil, color: String? = nil) -> String {
            var pr = ""
            if bold { pr += "<w:b/>" }
            if let c = color { pr += "<w:color w:val=\"\(c)\"/>" }
            if let sz = size { pr += "<w:sz w:val=\"\(sz)\"/>" }
            return "<w:r>\(pr.isEmpty ? "" : "<w:rPr>\(pr)</w:rPr>")<w:t xml:space=\"preserve\">\(esc(s))</w:t></w:r>"
        }
        func para(_ runs: String, after: Int = 200, before: Int = 0) -> String {
            "<w:p><w:pPr><w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/></w:pPr>\(runs)</w:p>"
        }
        var paras = ""
        for b in ExportLayout.blocks(document(t, o), o) {
            switch b {
            case .title(let s): paras += para(run(s, bold: true, size: 40), after: 120)
            case .details(let s), .source(let s): paras += para(run(s, color: "857D70"), after: 120)
            case .note(let s): paras += para(run(s, color: "857D70"), after: 200)
            case .heading(let s), .bodyHeading(let s): paras += para(run(s, bold: true, size: 28), after: 120, before: 240)
            case .text(let s): paras += para(run(s))
            case let .paragraph(lead, _, speaker, text):
                var runs = ""
                if !lead.isEmpty { runs += run(lead + " ", color: "857D70") }
                if let sp = speaker { runs += run(sp + ": ", bold: true) }
                runs += run(text)
                paras += para(runs)
            case .bullet(let s), .moment(let s): paras += para(run("•\u{00A0}\u{00A0}" + s), after: 80)
            case .footer(let s): paras += para(run("—", color: "857D70"), after: 0, before: 240) + para(run(s, color: "857D70"))
            }
        }
        let doc = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paras)<w:sectPr/></w:body></w:document>"
        let types = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(types.utf8))
        zip.add("_rels/.rels", Data(rels.utf8))
        zip.add("word/document.xml", Data(doc.utf8))
        return zip.finish()
    }

    static func writeDocx(_ t: Transcript, options o: ExportOptions, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try docxData(t, options: o).write(to: url, options: .atomic)
    }

    /// Writes one export file.
    static func write(_ t: Transcript, as f: ExportFormat, options o: ExportOptions, to url: URL) throws {
        if f == .docx { try writeDocx(t, options: o, to: url) }
        else { try render(t, as: f, options: o).write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: Copy

    /// The versions Copy can take: the Original with corrections, the Cleaned text, or the engine's own words.
    enum CopyVersion {
        case original, cleaned, engine
        var name: String {
            switch self { case .original: return "original"; case .cleaned: return "cleaned text"; case .engine: return "engine words" }
        }
        /// The other tab's version, for "Copy the other version".
        var other: CopyVersion { self == .cleaned ? .original : .cleaned }
    }

    /// Copy's own options, never the export sheet's: no header, summary, or footer; speaker names when they change;
    /// lines joined into paragraphs, or with timestamps one line per passage.
    static func copyOptions(_ v: CopyVersion, timestamps: Bool = false) -> ExportOptions {
        var o = ExportOptions()
        o.source = v == .cleaned ? .document : v == .engine ? .engine : .transcript
        o.header = false; o.summary = false; o.provenance = false; o.aiNote = false
        o.speakerMode = .onChange; o.moments = .off; o.includeHidden = false; o.singleParagraph = false
        o.timecodeMode = timestamps ? .everyParagraph : .off
        o.timecodeStyle = .bracketed
        o.groupLines = !timestamps
        return o
    }

    /// The text Copy puts on the clipboard for one version.
    static func copyText(_ t: Transcript, _ v: CopyVersion, timestamps: Bool = false) -> String {
        text(t, copyOptions(v, timestamps: timestamps))
    }

    /// What Copy puts on the clipboard for a format: the text for text and Word, the file's contents otherwise.
    static func clipboard(_ ts: [Transcript], as f: ExportFormat, options o: ExportOptions) -> String {
        let fmt: ExportFormat = f == .docx ? .txt : f
        if ts.count == 1 { return render(ts[0], as: fmt, options: o) }
        return ts.map { t in
            // Without a header, keep each transcript's title so the pieces stay apart.
            (o.header || fmt.timed || fmt == .json ? "" : t.title + "\n\n") + render(t, as: fmt, options: o)
        }.joined(separator: "\n\n———\n\n")
    }

#if os(macOS)
    /// Exports one transcript to a file the person picks. Returns whether it was written.
    @MainActor @discardableResult
    static func save(_ t: Transcript, as f: ExportFormat, options o: ExportOptions = .saved) -> Bool {
        let panel = NSSavePanel()
        var used = Set<String>()
        panel.nameFieldStringValue = ExportNames.unique(t.title, ext: f.ext, used: &used)
        panel.allowedContentTypes = [UTType(filenameExtension: f.ext) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try write(t, as: f, options: o, to: url); return true }
        catch { Log.note("export failed for \(t.title): \(error)"); return false }
    }

    /// Exports many transcripts at once into a folder the person picks: one file each, "{title}.{ext}", with
    /// unsafe characters replaced and " 2", " 3"… for repeats. Returns how many were written.
    @MainActor @discardableResult
    static func saveMany(_ ts: [Transcript], as f: ExportFormat, options o: ExportOptions = .saved) -> Int {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Export \(ts.count) transcript\(ts.count == 1 ? "" : "s") as \(f.rawValue)."
        guard panel.runModal() == .OK, let dir = panel.url else { return 0 }
        return writeMany(ts, as: f, options: o, into: dir)
    }

    @MainActor @discardableResult
    static func writeMany(_ ts: [Transcript], as f: ExportFormat, options o: ExportOptions, into dir: URL, reveal: Bool = true) -> Int {
        var used = Set<String>()
        var written = 0
        for t in ts where t.status == .ready {
            let name = ExportNames.unique(t.title, ext: f.ext, used: &used) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            do { try write(t, as: f, options: o, to: dir.appendingPathComponent(name)); written += 1 }
            catch { Log.note("bulk export failed for \(t.title): \(error)") }
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        return written
    }

    @MainActor
    static func copy(_ t: Transcript, options o: ExportOptions = .saved) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(t, o), forType: .string)
    }

    @MainActor
    static func copy(_ t: Transcript, _ v: CopyVersion, timestamps: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText(t, v, timestamps: timestamps), forType: .string)
    }
#endif
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
