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

/// A transcribed link's page details, kept so the original is one click away, at any moment.
struct LinkInfo: Codable, Equatable, Hashable {
    var url: String
    var site: String? = nil          // "YouTube", "Vimeo", …
    var channel: String? = nil
    var uploadDate: String? = nil    // yyyyMMdd from yt-dlp
    var thumbnailFile: String? = nil // in Paths.thumbs

    /// The page at a given second, where the site supports it.
    func url(at seconds: Double) -> URL? {
        guard var c = URLComponents(string: url) else { return URL(string: url) }
        let s = max(0, Int(seconds))
        let host = (c.host ?? "").lowercased()
        if host.contains("youtube.com") || host.contains("youtu.be") {
            var q = (c.queryItems ?? []).filter { $0.name != "t" }
            q.append(URLQueryItem(name: "t", value: "\(s)s"))
            c.queryItems = q
        } else if host.contains("vimeo.com") {
            c.fragment = "t=\(s)s"
        } else if host.contains("twitch.tv") {
            var q = (c.queryItems ?? []).filter { $0.name != "t" }
            q.append(URLQueryItem(name: "t", value: "\(s / 3600)h\((s % 3600) / 60)m\(s % 60)s"))
            c.queryItems = q
        } else {
            return URL(string: url)   // no known way to deep-link; open the page
        }
        return c.url
    }
    var supportsTimestamps: Bool { let u = url.lowercased(); return u.contains("youtube.com") || u.contains("youtu.be") || u.contains("vimeo.com") || u.contains("twitch.tv") }

    var uploadDisplay: String? {
        guard let d = uploadDate, d.count == 8 else { return nil }
        guard let date = Formats.pattern("yyyyMMdd").date(from: d) else { return nil }
        return Formats.style(date: .medium, time: .none).string(from: date)
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
    /// A still from the video at `at` (Paths.thumbs), when a video file is available.
    var frameFile: String? = nil
}

struct Transcript: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case processing, ready, failed }
    /// Every stored field except the local-only paths, so those never reach the synced file.
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, source, sourceLabel, sourceURL, duration, audioFileName, original, segments, speakers,
             corrections, projectId, tags, pinned, notes, waveform, model, engine, language, status, stage, error,
             document, documentHistory, documentLevel, documentTone, deletedAt, link, processingDevice,
             processingDeviceName, pendingLink, flow, pendingAppend
    }
    /// Keys older builds wrote; read once to move the paths into `LocalMedia`.
    enum LegacyKeys: String, CodingKey { case keptVideo, keptAudio, originalMedia }

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
    /// Set when moved to Recently Deleted; purged 30 days later.
    var deletedAt: Date? = nil
    /// What the source page said about itself (link imports only).
    var link: LinkInfo? = nil
    /// Keep: media saved to your Keep folder (absolute paths), and an imported video's original location,
    /// used for frame grabs.
    /// These hold absolute paths (which contain the macOS user name), so they're never written to the synced
    /// transcript file: `LocalMedia` keeps them in a file on this device only.
    var keptVideo: String? = nil { didSet { LocalMedia.set(id, .video, keptVideo) } }
    var keptAudio: String? = nil { didSet { LocalMedia.set(id, .audio, keptAudio) } }
    var originalMedia: String? = nil { didSet { LocalMedia.set(id, .original, originalMedia) } }
    /// Sync: the device running this transcript's job (only that device resumes it), and its name for display.
    var processingDevice: String? = nil
    var processingDeviceName: String? = nil
    /// A link added on iPhone, waiting for a Mac to fetch its audio (iPhone can't run the link helper).
    var pendingLink = false
    /// Dictations: which app it went to, the words before cleanup, and what was pasted.
    var flow: FlowInfo? = nil
    /// Continue recording: an audio file (in Paths.audio) recorded after this one, waiting to be transcribed and joined on.
    var pendingAppend: String? = nil

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
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        link = try c.decodeIfPresent(LinkInfo.self, forKey: .link)
        // Paths: this device's local record first; older builds wrote them into the file itself, so those move
        // to the local record (when they point at a file on this device) and drop out of the file on its next save.
        let legacy = try d.container(keyedBy: LegacyKeys.self)
        let id = self.id
        let local = LocalMedia.paths(id)
        #if os(macOS)
        // Only Macs write these paths, so only a Mac rewrites the file (an iPhone would drop a Mac's paths).
        if legacy.contains(.keptVideo) || legacy.contains(.keptAudio) || legacy.contains(.originalMedia) { LocalMedia.noteLegacy(id) }
        #endif
        func path(_ k: LegacyKeys, _ kind: LocalMedia.Kind) -> String? {
            if let p = local[kind] { return p }
            guard let p = try? legacy.decodeIfPresent(String.self, forKey: k), FileManager.default.fileExists(atPath: p) else { return nil }
            LocalMedia.set(id, kind, p)
            return p
        }
        keptVideo = path(.keptVideo, .video)
        keptAudio = path(.keptAudio, .audio)
        originalMedia = path(.originalMedia, .original)
        processingDevice = try c.decodeIfPresent(String.self, forKey: .processingDevice)
        processingDeviceName = try c.decodeIfPresent(String.self, forKey: .processingDeviceName)
        pendingLink = try c.decodeIfPresent(Bool.self, forKey: .pendingLink) ?? false
        flow = try c.decodeIfPresent(FlowInfo.self, forKey: .flow)
        pendingAppend = try c.decodeIfPresent(String.self, forKey: .pendingAppend)
    }

    /// Status text that knows about the other device: "Transcribing on Tim's Mac", "Waiting for your Mac".
    var stageText: String {
        if pendingLink { return "Waiting for your Mac to fetch the audio" }
        if pendingAppend != nil, status == .ready {
            if let d = processingDevice, d != Device.id { return "Adding the new recording on \(processingDeviceName ?? "your other device")" }
            return stage ?? "Adding the new recording"
        }
        if status == .processing, let d = processingDevice, d != Device.id { return "Transcribing on \(processingDeviceName ?? "your other device")" }
        return stage ?? (status == .processing ? "Queued" : "")
    }

    /// A video file on this Mac for this transcript (kept from a link, or the original import), if it still exists.
    var videoFile: URL? {
        for p in [keptVideo, originalMedia].compactMap({ $0 }) where FileManager.default.fileExists(atPath: p) {
            let u = URL(fileURLWithPath: p)
            if MediaImport.videoExts.contains(u.pathExtension.lowercased()) { return u }
        }
        return nil
    }

    /// Link details, including for link imports made before Verbatim kept them.
    var linkInfo: LinkInfo? {
        if let link { return link }
        guard let s = sourceURL, let h = URL(string: s)?.host else { return nil }
        let host = h.replacingOccurrences(of: "www.", with: "")
        return LinkInfo(url: s, site: host.contains("youtu") ? "YouTube" : host.contains("vimeo") ? "Vimeo" : host)
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
