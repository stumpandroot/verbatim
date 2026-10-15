import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt = "Plain text", md = "Markdown", docx = "Word", srt = "SRT", vtt = "VTT", json = "JSON"
    var id: String { rawValue }
    var ext: String { switch self { case .txt: return "txt"; case .md: return "md"; case .docx: return "docx"; case .srt: return "srt"; case .vtt: return "vtt"; case .json: return "json" } }
    var note: String {
        switch self {
        case .txt: return "Anywhere"; case .md: return "Notes, Obsidian, Notion"; case .docx: return "Word, Pages, Google Docs"
        case .srt: return "Subtitles"; case .vtt: return "Web subtitles"; case .json: return "Everything, for tools"
        }
    }
    var timed: Bool { self == .srt || self == .vtt }
}

/// What goes into a text export or the clipboard. Mirrors what people expect from Otter and Wispr: pick the
/// text (document or transcript), whether speaker names and timecodes come along, and whether it's one paragraph.
struct ExportOptions: Equatable {
    enum Source: String, CaseIterable, Identifiable { case document = "Document", transcript = "Transcript"; var id: String { rawValue } }
    var source: Source = .document
    var speakers = true
    var timecodes = false
    var singleParagraph = false
    var provenance = false

    static var saved: ExportOptions {
        let d = UserDefaults.standard
        var o = ExportOptions()
        if let s = d.string(forKey: "export.source"), let v = Source(rawValue: s) { o.source = v }
        if d.object(forKey: "export.speakers") != nil { o.speakers = d.bool(forKey: "export.speakers") }
        o.timecodes = d.bool(forKey: "export.timecodes"); o.singleParagraph = d.bool(forKey: "export.single"); o.provenance = d.bool(forKey: "export.prov")
        return o
    }
    func save() {
        let d = UserDefaults.standard
        d.set(source.rawValue, forKey: "export.source"); d.set(speakers, forKey: "export.speakers"); d.set(timecodes, forKey: "export.timecodes")
        d.set(singleParagraph, forKey: "export.single"); d.set(provenance, forKey: "export.prov")
    }
}

enum Exporter {
    /// The text people copy or export, shaped by the options.
    static func text(_ t: Transcript, _ o: ExportOptions, markdownLinks: Bool = false) -> String {
        var body: String
        if o.source == .document && !o.timecodes {
            body = t.documentText
            if !o.speakers {
                let names = t.speakers.map(\.label)
                body = DocumentText.paragraphs(body).map { DocumentText.split($0, speakers: names).text }.joined(separator: "\n\n")
            }
        } else {
            var lines: [String] = []
            var lastSpeaker: String? = "\u{0}"
            for s in t.segments {
                var line = ""
                if o.timecodes {
                    if markdownLinks, let info = t.linkInfo, info.supportsTimestamps, let u = info.url(at: s.start) { line += "[\(s.start.timecode)](\(u.absoluteString)) " }
                    else { line += "[\(s.start.timecode)] " }
                }
                if o.speakers, s.speaker != lastSpeaker, let n = t.speakerName(s.speaker) { line += "\(n): " }
                lastSpeaker = s.speaker
                lines.append(line + s.text)
            }
            body = lines.joined(separator: o.timecodes ? "\n" : "\n\n")
        }
        if o.singleParagraph { body = body.replacingOccurrences(of: "\n+", with: " ", options: .regularExpression) }
        return body + (o.provenance ? provenance(t) : "")
    }

    static func render(_ t: Transcript, as f: ExportFormat, options o: ExportOptions) -> String {
        switch f {
        case .txt: return text(t, o)
        case .md:
            var out = "# \(t.title)\n\n_\(t.sourceLabel) · \(t.duration.timecode)_\n\n"
            if let info = t.linkInfo {
                out += "Source: [\([info.channel, info.site].compactMap { $0 }.joined(separator: " · ").ifEmpty(info.url))](\(info.url))"
                if let d = info.uploadDisplay { out += " · \(d)" }
                out += "\n\n"
            }
            out += text(t, o, markdownLinks: true).replacingOccurrences(of: "(?m)^([^:\\[\\n][^:\\n]{0,27}): ", with: "**$1:** ", options: .regularExpression)
            return out
        default: return render(t, as: f)
        }
    }

    /// A minimal .docx: one paragraph per blank-line-separated block, speaker labels bold. Zipped with /usr/bin/zip.
    static func writeDocx(_ t: Transcript, options o: ExportOptions, to url: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-docx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("word"), withIntermediateDirectories: true)
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var paras = "<w:p><w:pPr><w:pStyle w:val=\"Title\"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val=\"40\"/></w:rPr><w:t xml:space=\"preserve\">\(esc(t.title))</w:t></w:r></w:p>"
        if let info = t.linkInfo {
            paras += "<w:p><w:r><w:rPr><w:color w:val=\"857D70\"/></w:rPr><w:t xml:space=\"preserve\">Source: \(esc(info.url))</w:t></w:r></w:p>"
        }
        let names = t.speakers.map(\.label)
        for p in DocumentText.paragraphs(text(t, o)) {
            let (sp, body) = DocumentText.split(p, speakers: names)
            paras += "<w:p><w:pPr><w:spacing w:after=\"200\"/></w:pPr>"
            if let sp { paras += "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(esc(sp)): </w:t></w:r>" }
            paras += "<w:r><w:t xml:space=\"preserve\">\(esc(body))</w:t></w:r></w:p>"
        }
        let doc = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paras)<w:sectPr/></w:body></w:document>"
        let types = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        try types.write(to: tmp.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rels.write(to: tmp.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try doc.write(to: tmp.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: url)
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tmp
        zip.arguments = ["-q", "-r", "-X", url.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run(); zip.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
    }

    static func render(_ t: Transcript, as f: ExportFormat) -> String {
        switch f {
        case .docx:
            return text(t, ExportOptions())
        case .txt:
            return t.segments.map { "[\($0.start.timecode)] " + speakerPrefix(t, $0) + $0.text }.joined(separator: "\n") + provenance(t)
        case .srt:
            return t.segments.enumerated().map { i, s in
                "\(i + 1)\n\(stamp(s.start, sep: ",")) --> \(stamp(s.end, sep: ","))\n\(speakerPrefix(t, s))\(s.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + t.segments.map { s in
                "\(stamp(s.start, sep: ".")) --> \(stamp(s.end, sep: "."))\n\(speakerPrefix(t, s))\(s.text)\n"
            }.joined(separator: "\n")
        case .md:
            var out = "# \(t.title)\n\n"
            out += "_\(t.sourceLabel) · \(t.duration.timecode) · \(t.model)_\n\n"
            var lastSpeaker: String? = "\u{0}"
            for s in t.segments {
                if s.speaker != lastSpeaker {
                    if let name = t.speakerName(s.speaker) { out += "\n**\(name)**\n\n" }
                    lastSpeaker = s.speaker
                }
                out += "`\(s.start.timecode)` \(s.text)\n\n"
            }
            return out
        case .json:
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? String(data: enc.encode(t), encoding: .utf8)) ?? "{}"
        }
    }

    private static func speakerPrefix(_ t: Transcript, _ s: Segment) -> String {
        t.speakerName(s.speaker).map { "\($0): " } ?? ""
    }

    private static func provenance(_ t: Transcript) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return "\n\n—\n\(t.title) · \(t.sourceLabel) · \(t.duration.timecode) · transcribed with \(t.model) on \(f.string(from: t.createdAt)) · Verbatim"
    }

    private static func stamp(_ t: Double, sep: String) -> String {
        let ms = Int((t - floor(t)) * 1000)
        let s = Int(t)
        return String(format: "%02d:%02d:%02d%@%03d", s / 3600, (s % 3600) / 60, s % 60, sep, ms)
    }

    @MainActor
    static func save(_ t: Transcript, as f: ExportFormat, options o: ExportOptions = .saved) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = t.title + "." + f.ext
        panel.allowedContentTypes = [UTType(filenameExtension: f.ext) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if f == .docx { try? writeDocx(t, options: o, to: url) }
        else { try? render(t, as: f, options: o).write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Exports many transcripts at once into a folder the person picks: one file each, named by title.
    /// Returns how many were written.
    @MainActor @discardableResult
    static func saveMany(_ ts: [Transcript], as f: ExportFormat, options o: ExportOptions = .saved) -> Int {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Export \(ts.count) transcript\(ts.count == 1 ? "" : "s") as \(f.rawValue)."
        guard panel.runModal() == .OK, let dir = panel.url else { return 0 }
        var used = Set<String>()
        var written = 0
        for t in ts where t.status == .ready {
            var base = t.title.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "Transcript" }
            var name = base, n = 2
            while used.contains(name.lowercased()) || FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + "." + f.ext).path) { name = "\(base) \(n)"; n += 1 }
            used.insert(name.lowercased())
            let url = dir.appendingPathComponent(name + "." + f.ext)
            do {
                if f == .docx { try writeDocx(t, options: o, to: url) }
                else { try render(t, as: f, options: o).write(to: url, atomically: true, encoding: .utf8) }
                written += 1
            } catch { Log.note("bulk export failed for \(t.title): \(error)") }
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        return written
    }

    @MainActor
    static func copy(_ t: Transcript, options o: ExportOptions = .saved) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(t, o), forType: .string)
    }
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
