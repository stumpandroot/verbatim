import Foundation

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

enum SourceKind: String, Codable {
    case voiceMemo, file, link, app

    var symbol: String {
        switch self {
        case .voiceMemo: return "mic.fill"
        case .file: return "doc.fill"
        case .link: return "link"
        case .app: return "rectangle.on.rectangle"
        }
    }
}

struct Transcript: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case processing, ready, failed }

    var id = UUID()
    var title: String
    var createdAt = Date()
    var source: SourceKind
    var sourceLabel: String
    var duration: Double
    var audioFileName: String?
    var segments: [Segment] = []
    var model: String
    var status: Status = .ready
    var error: String?

    var text: String { segments.map(\.text).joined(separator: " ") }

    var preview: String {
        if status == .processing { return "Transcribing… the first sentence appears here as soon as it is ready." }
        if status == .failed { return error ?? "Transcription failed." }
        return text
    }

    /// First few words of the first segment, for an untitled voice memo.
    static func titleFrom(_ segments: [Segment]) -> String? {
        guard let first = segments.first(where: { !$0.text.isEmpty }) else { return nil }
        let words = first.text.split(separator: " ").prefix(7).joined(separator: " ")
        return words.isEmpty ? nil : words.trimmingCharacters(in: .punctuationCharacters)
    }
}

extension Double {
    /// 00:00 or 1:02:14
    var timecode: String {
        let s = Int(self.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
