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

    /// Words that carry nothing on their own ("Um.", "uh, hmm"). Lowercased, punctuation stripped. Not here:
    /// "uh-huh", "mm-hmm", and "mhm" (they mean yes) and "er" (a word in other languages).
    static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "ah", "ahh", "hmm", "hm", "mm", "mmm"]
    private static let edgePunctuation = CharacterSet.punctuationCharacters.union(.symbols)

    /// True when the line is only fillers and punctuation, like a standalone "Um." Empty lines aren't filler.
    var isFillerOnly: Bool {
        // "Hmm?" is a question, not filler.
        if text.contains("?") { return false }
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: Self.edgePunctuation) }
            .filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy { Self.fillerWords.contains($0) }
    }
}

/// What a recording is, for filtering the library. Suggested automatically (`Transcript.kindIsAuto`), changeable later.
enum RecordingKind: String, Codable, CaseIterable, Identifiable {
    case journal, idea, meeting, note, dictation
    var id: String { rawValue }
    var label: String {
        switch self {
        case .journal: return "Journal"
        case .idea: return "Idea"
        case .meeting: return "Meeting"
        case .note: return "Note"
        case .dictation: return "Dictation"
        }
    }
    /// The kinds a person can pick; dictation is set automatically for dictations.
    static let pickable: [RecordingKind] = [.journal, .idea, .meeting, .note]
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
    /// Where each replacement went (CorrectionEdits). nil for corrections from builds before this was kept.
    var spans: [CorrectionSpan]? = nil
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

/// A short summary of a transcript: a 2–4 sentence overview and up to 5 key points.
struct TranscriptSummary: Codable, Equatable {
    var overview: String
    var keyPoints: [String] = []
    var createdAt = Date()

    static let maxKeyPoints = 5

    init(overview: String, keyPoints: [String] = [], createdAt: Date = Date()) {
        self.overview = overview; self.keyPoints = Array(keyPoints.prefix(Self.maxKeyPoints)); self.createdAt = createdAt
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case overview, keyPoints, createdAt }
        let c = try d.container(keyedBy: K.self)
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var isEmpty: Bool { overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyPoints.isEmpty }

    /// The overview, a blank line, then one "- " line per key point. Also the editable form (`parse` reads it back).
    var plainText: String {
        var out = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyPoints.isEmpty { out += (out.isEmpty ? "" : "\n\n") + keyPoints.map { "- " + $0 }.joined(separator: "\n") }
        return out
    }

    /// Reads text edited in the `plainText` shape: lines that start with "- ", "• ", or "* " are key points (no limit on
    /// what the person keeps), everything else is the overview.
    static func parse(_ text: String) -> TranscriptSummary {
        var overview: [String] = [], points: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let p = ["- ", "• ", "* ", "– "].first(where: { line.hasPrefix($0) }) {
                let point = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                if !point.isEmpty { points.append(point) }
            } else if !line.isEmpty {
                overview.append(line)
            }
        }
        var s = TranscriptSummary(overview: overview.joined(separator: " "))
        s.keyPoints = points
        return s
    }
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
    /// The action that wrote this note with Apple Intelligence ("Make a plan"), so the transcript view and exports
    /// keep it marked as the model's. nil for notes the person wrote. Older files decode without it.
    var aiAction: String? = nil

    var byModel: Bool { aiAction != nil }
}

struct Transcript: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case processing, ready, failed }
    /// Every stored field except the local-only paths, so those never reach the synced file.
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, source, sourceLabel, sourceURL, duration, audioFileName, original, segments, speakers,
             corrections, projectId, tags, pinned, notes, waveform, model, engine, language, status, stage, error,
             document, documentHistory, documentLevel, documentTone, deletedAt, link, processingDevice,
             processingDeviceName, pendingLink, flow, pendingAppend, kind, kindIsAuto, titleIsAuto, titleByModel,
             summary, summaryByModel, multitrack, documentCleanedBy, documentMarkHistory, documentEdited
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
    /// Journal, idea, meeting, note (or dictation). nil until labeled; `kindIsAuto` false once the person picks one.
    var kind: RecordingKind? = nil
    var kindIsAuto = true
    /// False once the person renames the transcript, so automatic titles never overwrite theirs.
    var titleIsAuto = true
    /// The title came from Apple Intelligence (AutoLabel), not the first words: re-transcribing keeps it, and the
    /// transcript says where it came from. Only meaningful while `titleIsAuto`.
    var titleByModel = false
    /// A short overview and key points (Summarizer). nil until written. `summaryByModel` is true while the text is
    /// Apple Intelligence's; it turns false once the person edits it, and automatic summaries never replace it then.
    var summary: TranscriptSummary? = nil
    var summaryByModel = false
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
    /// What last cleaned the Cleaned text: Apple Intelligence or rules (Harper's fixes). nil when nothing has.
    var documentCleanedBy: CleanupSource? = nil
    /// `documentCleanedBy` for each entry in `documentHistory` ("" for none), so Undo restores the label too.
    var documentMarkHistory: [String] = []
    /// True once the person types in the Cleaned text after the last Clean up; Clean up warns before replacing it.
    var documentEdited = false
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
    /// Multi-track recordings: one file per mic, each transcribed on its own and woven together by time.
    var multitrack: MultitrackInfo? = nil

    init(title: String, source: SourceKind, sourceLabel: String, duration: Double, audioFileName: String?, model: String) {
        self.title = title; self.source = source; self.sourceLabel = sourceLabel; self.duration = duration; self.audioFileName = audioFileName; self.model = model
        if source == .dictation { kind = .dictation }
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
        // Files from before these fields: a cleaned document with a level or tone was Apple Intelligence's.
        if c.contains(.documentCleanedBy) {
            documentCleanedBy = try? c.decodeIfPresent(CleanupSource.self, forKey: .documentCleanedBy)
        } else if document != nil, documentLevel != "None" || documentTone != "As spoken" {
            documentCleanedBy = .model
        }
        documentMarkHistory = try c.decodeIfPresent([String].self, forKey: .documentMarkHistory) ?? []
        documentEdited = try c.decodeIfPresent(Bool.self, forKey: .documentEdited) ?? false
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
        multitrack = try? c.decodeIfPresent(MultitrackInfo.self, forKey: .multitrack)
        // An unknown kind (from a newer build) reads as unlabeled rather than failing the whole file.
        kind = (try? c.decodeIfPresent(RecordingKind.self, forKey: .kind)) ?? (source == .dictation ? .dictation : nil)
        kindIsAuto = try c.decodeIfPresent(Bool.self, forKey: .kindIsAuto) ?? true
        // Files from before this field: automatic only if the title is still one Verbatim made (the first words or a
        // placeholder). Anything else was named by the person, so automatic titles leave it alone.
        if let auto = try c.decodeIfPresent(Bool.self, forKey: .titleIsAuto) {
            titleIsAuto = auto
        } else {
            titleIsAuto = Self.defaultTitles.contains(title) || title == Self.titleFrom(segments)
        }
        titleByModel = try c.decodeIfPresent(Bool.self, forKey: .titleByModel) ?? false
        // A summary a newer build wrote in a shape this one can't read is dropped, never the whole file.
        summary = (try? c.decodeIfPresent(TranscriptSummary.self, forKey: .summary)) ?? nil
        summaryByModel = try c.decodeIfPresent(Bool.self, forKey: .summaryByModel) ?? false
    }

    /// A summary the person wrote or edited: automatic summaries leave it alone.
    var summaryIsEdited: Bool { summary != nil && !summaryByModel }

    /// Placeholder titles Verbatim gives a transcript before it has words.
    static let defaultTitles: Set<String> = ["Voice memo", "Recovered recording", "Dictation", "App audio", "Untitled"]

    /// A press-and-hold (or hands-free) dictation. These live only in Dictations: the Library and Home's Recent
    /// leave them out unless you're searching (Tim, October 18, 2026).
    var isDictation: Bool { flow != nil || source == .dictation || kind == .dictation }

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
    /// Segments to show: all of them, or without filler-only lines ("Um.") when `hideFiller`. Nothing is deleted;
    /// ids are unchanged, so edits and exports still map to the right segment.
    func visibleSegments(hideFiller: Bool) -> [Segment] {
        guard hideFiller else { return segments }
        return segments.indices.filter { !hidesAsFiller($0) }.map { segments[$0] }
    }

    /// A filler-only line is hidden unless it's someone else's turn on both sides of it: a lone "Um." from the
    /// other person is a reply (a pause, a hesitation), not noise inside one speaker's paragraph.
    func hidesAsFiller(_ i: Int) -> Bool {
        let s = segments[i]
        guard s.isFillerOnly else { return false }
        guard let me = s.speaker else { return true }
        let before = i > 0 ? segments[i - 1].speaker : nil
        let after = i + 1 < segments.count ? segments[i + 1].speaker : nil
        let others = [before, after].compactMap { $0 }
        return !(others.count == 2 && others.allSatisfy { $0 != me })
    }

    /// Settings key for hiding filler-only lines (default on).
    static let hideFillerKey = "transcript.hideFiller"
    static var hideFiller: Bool { UserDefaults.standard.object(forKey: hideFillerKey) as? Bool ?? true }

    /// The speaker with the most talk time, when there are at least two.
    var mainSpeaker: String? {
        guard speakers.count >= 2 else { return nil }
        var time: [String: Double] = [:]
        for s in segments { if let sp = s.speaker { time[sp, default: 0] += max(0, s.end - s.start) } }
        guard time.count >= 2 else { return nil }
        return time.max { $0.value < $1.value }?.key
    }

    /// Lines spoken by anyone other than the main speaker (background voices). Empty without a main speaker.
    var backgroundSegments: [Segment] {
        guard let main = mainSpeaker else { return [] }
        return segments.filter { $0.speaker != nil && $0.speaker != main }
    }

    static func titleFrom(_ segments: [Segment]) -> String? {
        guard let first = segments.first(where: { !$0.text.isEmpty && !$0.isFillerOnly }) else { return nil }
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
