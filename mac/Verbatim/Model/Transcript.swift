import Foundation

/// One recognized word with its time span. Only present when the engine supplies word timings;
/// never fabricated from segment times.
struct WordSpan: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var words: [WordSpan]? = nil
    /// Diarization label such as "S1". Resolved to a name through `Transcript.speakers`.
    var speaker: String? = nil
}

/// A voice found by diarization. `label` is the engine's anonymous ID; `name` is what the person typed.
struct Speaker: Codable, Identifiable, Equatable {
    var id: String          // "S1"
    var name: String        // "Speaker 1" until renamed
    var label: String { name.isEmpty ? id : name }
}

/// A dictionary fix applied after recognition, kept so it can be reviewed or undone.
struct Correction: Codable, Identifiable, Equatable {
    var id = UUID()
    var segmentId: UUID
    var from: String
    var to: String
    var byDictionary: Bool
}

enum SourceKind: String, Codable {
    case voiceMemo, file, link, app, dictation

    var symbol: String {
        switch self {
        case .voiceMemo: return "mic.fill"
        case .dictation: return "keyboard"
        case .file: return "doc.fill"
        case .link: return "link"
        case .app: return "rectangle.on.rectangle"
        }
    }
}

struct Project: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var colorIndex: Int = 0     // coral, lime, iris, …
}

/// A note attached to a transcript, optionally pinned to a moment (passage-linked) or marked as a bookmark.
struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var at: Double? = nil            // seconds into the recording
    var segmentId: UUID? = nil       // the passage it was written against
    var isBookmark = false
    var createdAt = Date()
}

struct Transcript: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case processing, ready, failed }

    var id = UUID()
    var title: String
    var createdAt = Date()
    var source: SourceKind
    var sourceLabel: String
    var sourceURL: String? = nil
    var duration: Double
    var audioFileName: String?
    /// The engine's output, never edited. Corrections and edits go to `segments`.
    var original: [Segment] = []
    var segments: [Segment] = []
    var speakers: [Speaker] = []
    var corrections: [Correction] = []
    var projectId: UUID? = nil
    var tags: [String] = []
    var pinned = false
    var notes: [Note] = []
    var waveform: [Float] = []       // 120 RMS buckets in 0…1
    var model: String
    var engine: String = ""
    var language: String? = nil
    var status: Status = .ready
    var stage: String? = nil      // "Downloading model 42%", "Transcribing", "Finding speakers"
    var error: String?
    /// The Document view's text once someone has edited or polished it; nil means "build it from segments".
    var document: String? = nil
    /// Previous document versions, newest last, for Undo (capped at 30).
    var documentHistory: [String] = []
    var documentLevel: String = "None"
    var documentTone: String = "As spoken"

    init(title: String, source: SourceKind, sourceLabel: String, duration: Double, audioFileName: String?, model: String) {
        self.title = title; self.source = source; self.sourceLabel = sourceLabel; self.duration = duration; self.audioFileName = audioFileName; self.model = model
    }

    /// Tolerant of files written by earlier builds: every field added later decodes with its default.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        source = try c.decodeIfPresent(SourceKind.self, forKey: .source) ?? .voiceMemo
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        original = try c.decodeIfPresent([Segment].self, forKey: .original) ?? []
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        corrections = try c.decodeIfPresent([Correction].self, forKey: .corrections) ?? []
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        waveform = try c.decodeIfPresent([Float].self, forKey: .waveform) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .ready
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        document = try c.decodeIfPresent(String.self, forKey: .document)
        documentHistory = try c.decodeIfPresent([String].self, forKey: .documentHistory) ?? []
        documentLevel = try c.decodeIfPresent(String.self, forKey: .documentLevel) ?? "None"
        documentTone = try c.decodeIfPresent(String.self, forKey: .documentTone) ?? "As spoken"
    }

    /// The document text: edited version if there is one, else built from the segments.
    var documentText: String { document ?? DocumentText.build(from: self) }

    var text: String { segments.map(\.text).joined(separator: " ") }

    var preview: String {
        if status == .processing { return stage ?? "Transcribing…" }
        if status == .failed { return error ?? "Transcription failed." }
        return text
    }

    func speakerName(_ id: String?) -> String? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }?.label ?? id
    }

    /// First few words of the first segment, for an untitled recording.
    static func titleFrom(_ segments: [Segment]) -> String? {
        guard let first = segments.first(where: { !$0.text.isEmpty }) else { return nil }
        let words = first.text.split(separator: " ").prefix(8).joined(separator: " ")
        let t = words.trimmingCharacters(in: .punctuationCharacters)
        return t.isEmpty ? nil : t
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
