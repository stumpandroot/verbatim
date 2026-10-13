import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt = "TXT", srt = "SRT", vtt = "VTT"
    var id: String { rawValue }
    var ext: String { rawValue.lowercased() }
}

enum Exporter {
    static func render(_ t: Transcript, as f: ExportFormat) -> String {
        switch f {
        case .txt:
            return t.segments.map { "[\($0.start.timecode)] \($0.text)" }.joined(separator: "\n") + provenance(t)
        case .srt:
            return t.segments.enumerated().map { i, s in
                "\(i + 1)\n\(stamp(s.start, sep: ",")) --> \(stamp(s.end, sep: ","))\n\(s.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + t.segments.map { s in
                "\(stamp(s.start, sep: ".")) --> \(stamp(s.end, sep: "."))\n\(s.text)\n"
            }.joined(separator: "\n")
        }
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
    static func save(_ t: Transcript, as f: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = t.title + "." + f.ext
        panel.allowedContentTypes = [UTType(filenameExtension: f.ext) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? render(t, as: f).write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    static func copy(_ t: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.text, forType: .string)
    }
}
