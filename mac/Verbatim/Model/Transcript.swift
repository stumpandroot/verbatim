import Foundation

/// One recognized word with its time span. Only present when the engine supplies word timings;
/// never fabricated from segment times.
struct WordSpan: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
    /// How sure the engine was of this word (0…1), from engines that say: Whisper's word probability, Parakeet's
    /// average token confidence. nil for Apple's engine and for words from builds before this was kept. Stored as
    /// "p" with two decimals; the reading view marks words under `UnclearRules.lowConfidence`.
    var confidence: Double? = nil

    enum CodingKeys: String, CodingKey { case text, start, end, confidence = "p" }

    init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end
        self.confidence = confidence.map { ($0 * 100).rounded() / 100 }
    }
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
///
/// Brain dump and Audio only (approved mockup "Verbose Brain Dump", October 27, 2026) are kinds you pick, never
/// suggested. Builds before them read their raw values ("brainDump", "audio") as unlabeled and write them back
/// unchanged while the kind stays as read (`Transcript.init(from:)`, `UnknownFields`).
enum RecordingKind: String, Codable, CaseIterable, Identifiable, TolerantEnum {
    case journal, idea, meeting, note, dictation, podcast, video, talk, interview, brainDump, audio
    static var fallback: RecordingKind { .note }
    init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .journal: return "Journal"
        case .idea: return "Thoughts"
        case .meeting: return "Meeting"
        case .note: return "Note"
        case .dictation: return "Dictation"
        case .podcast: return "Podcast"
        case .video: return "Video"
        case .talk: return "Talk"
        case .interview: return "Interview"
        case .brainDump: return "Brain dump"
        case .audio: return "Audio only"
        }
    }
    /// The kind as a filter or a list names it: "Meetings", "Thoughts", "Audio".
    var plural: String {
        switch self {
        case .journal: return "Journal"
        case .idea: return "Thoughts"
        case .meeting: return "Meetings"
        case .note: return "Notes"
        case .dictation: return "Dictations"
        case .podcast: return "Podcasts"
        case .video: return "Videos"
        case .talk: return "Talks"
        case .interview: return "Interviews"
        case .brainDump: return "Brain dumps"
        case .audio: return "Audio"
        }
    }
    /// The kinds a person can pick; dictation is set automatically for dictations. Brain dump and Audio only come last,
    /// as they do in Record as.
    static let pickable: [RecordingKind] = [.journal, .idea, .meeting, .note, .podcast, .video, .talk, .interview, .brainDump, .audio]
    /// The kinds Apple Intelligence may suggest for a recording (AutoLabel). Links and imported media get theirs from
    /// `AutoLabel.mediaKind`; interview is only ever picked.
    static let modelKinds: [RecordingKind] = [.journal, .idea, .meeting, .note]
}

/// A voice found by diarization. `label` is the engine's anonymous ID; `name` is what the person typed.
struct Speaker: Codable, Identifiable, Equatable {
    var id: String          // "S1"
    var name: String        // "Speaker 1" until renamed
    var label: String { name.isEmpty ? id : name }
    /// Still Verbatim's own name ("Speaker 2", or none): nobody has named this speaker yet.
    var isPlaceholder: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return true }
        guard n.hasPrefix("Speaker ") else { return false }
        let rest = n.dropFirst("Speaker ".count)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// Named for the app that carried the other side of a call ("Chrome", "Zoom") or "Others" for all system audio
    /// (MeetingSession): a label, not a person. The real call that showed it named the other person "Chrome" for good,
    /// since suggestions only ran on placeholders.
    var isAppLabel: Bool { Self.appLabels.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) }

    /// Nobody has put a person's name on this speaker: a placeholder or a call app's label. Name suggestions run on
    /// these and may replace them; a past name never comes from them.
    var isUnnamed: Bool { isPlaceholder || isAppLabel }

    /// The names a meeting capture gives the call's track (`MeetingApps.known`, "Others"), plus the services' own
    /// names, lowercased.
    static let appLabels: Set<String> = [
        "others", "them", "system audio", "app audio", "chrome", "google chrome", "safari", "arc", "edge", "microsoft edge",
        "brave", "firefox", "zoom", "zoom.us", "teams", "microsoft teams", "facetime", "webex", "slack", "discord", "meet",
        "google meet",
    ]
}

/// A call recorded for a calendar event (Mac, App/MeetingSession.swift): the event's title, the other people invited
/// (you left out), and the label the capture gave the call's track. Kept with the recording so the transcript can
/// suggest who the other side is, give the engine the meeting's own words, and fix misheard names after the call
/// (MeetingNames.swift). Every field decodes with a default, so one a newer build wrote still reads.
struct MeetingContext: Codable, Equatable {
    var title: String = ""
    var attendees: [String] = []
    /// "Chrome", "Zoom": the call's track before anyone names it.
    var app: String? = nil
    /// The other person's name as the call app's window showed it while recording (CallWindowNames, read through
    /// Accessibility; a contact's name when one matched), most seen first. Suggested like the one other invitee.
    var windowNames: [String] = []
    /// A meeting's own name from the call window's title ("Meet - Weekly design sync" gives "Weekly design sync"),
    /// for a call with no calendar title. The recording takes it as its title.
    var windowTitle: String? = nil

    init(title: String = "", attendees: [String] = [], app: String? = nil, windowNames: [String] = [], windowTitle: String? = nil) {
        self.title = title; self.attendees = attendees; self.app = app; self.windowNames = windowNames; self.windowTitle = windowTitle
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case title, attendees, app, windowNames, windowTitle }
        let c = try d.container(keyedBy: K.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        attendees = (try? c.decodeIfPresent([String].self, forKey: .attendees)) ?? []
        app = (try? c.decodeIfPresent(String.self, forKey: .app)) ?? nil
        windowNames = (try? c.decodeIfPresent([String].self, forKey: .windowNames)) ?? []
        windowTitle = (try? c.decodeIfPresent(String.self, forKey: .windowTitle)) ?? nil
    }

    func encode(to e: Encoder) throws {
        enum K: String, CodingKey { case title, attendees, app, windowNames, windowTitle }
        var c = e.container(keyedBy: K.self)
        try c.encode(title, forKey: .title)
        try c.encode(attendees, forKey: .attendees)
        try c.encodeIfPresent(app, forKey: .app)
        if !windowNames.isEmpty { try c.encode(windowNames, forKey: .windowNames) }
        try c.encodeIfPresent(windowTitle, forKey: .windowTitle)
    }

    /// The calendar event's title, or without one the call window's (`windowTitle`).
    var meetingTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty && attendees.isEmpty && windowNames.isEmpty
            && (windowTitle ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A name Verbose suggests for a diarized speaker (SpeakerNames.swift), shown with Use and Dismiss and never applied
/// on its own. Kept after Use (with its reasons) and after Dismiss, so a dismissed name never comes back. Every field
/// decodes with a default, so a suggestion a newer build wrote still reads.
struct SpeakerSuggestion: Codable, Equatable, Identifiable {
    enum State: String, Codable, TolerantEnum {
        case pending, accepted, dismissed
        /// A state a newer build added reads as dismissed: never shown, never suggested again.
        static var fallback: State { .dismissed }
        init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    }
    /// The speaker it's for ("S1").
    var speakerId: String
    var name: String
    /// Short reasons, most telling first ("called “Jenna” at 1:05", "named in the title").
    var reasons: [String] = []
    /// Where the evidence came from: "speech", "link", "model", "past", "voice".
    var sources: [String] = []
    var state: State = .pending

    var id: String { speakerId + "|" + name.lowercased() }
    /// `sources` for a name from a calendar event's attendees (a call set up from Home's Next call card, Mac).
    static let calendarSource = "calendar"
    var fromCalendar: Bool { sources.contains(Self.calendarSource) }
    /// `sources` for a name the call app's window showed while recording (MeetingContext.windowNames, Mac).
    static let windowSource = "window"
    var fromCallWindow: Bool { sources.contains(Self.windowSource) }
    /// Made from the call itself (the invite or the call window), not by a suggestion run: a later run keeps it.
    var fromCall: Bool { fromCalendar || fromCallWindow }
    /// The reasons on one line, first letter capitalized.
    var reasonText: String {
        let t = reasons.joined(separator: " · ")
        guard let f = t.first else { return t }
        return f.uppercased() + t.dropFirst()
    }

    init(speakerId: String, name: String, reasons: [String] = [], sources: [String] = [], state: State = .pending) {
        self.speakerId = speakerId; self.name = name; self.reasons = reasons; self.sources = sources; self.state = state
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case speakerId, name, reasons, sources, state }
        let c = try d.container(keyedBy: K.self)
        speakerId = try c.decodeIfPresent(String.self, forKey: .speakerId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
        sources = (try? c.decodeIfPresent([String].self, forKey: .sources)) ?? []
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .pending
    }
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
    /// True for a name the meeting pass put in after the call (MeetingNames.correctNames): a word heard where someone
    /// was addressed, replaced with an invitee's name or yours. nil for every other fix; an older build reads it as
    /// your fix.
    var byName: Bool? = nil

    var isNameFix: Bool { byName == true }
    /// Who made the fix, as Review says it.
    var madeBy: String { isNameFix ? "Name from the meeting" : byDictionary ? "Dictionary" : "Your fix" }
}

enum SourceKind: String, Codable, TolerantEnum {
    case voiceMemo, file, link, app, dictation
    /// A source a newer build added reads as a file.
    static var fallback: SourceKind { .file }
    init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }

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

    /// The page, only as an http or https address with a host. A synced record can hold any text, and opening a
    /// file: address or another app's scheme from a button would run or launch it (security review MC-04 and IPH-17,
    /// October 31, 2026). Open and fetch links through this, never `URL(string: url)`.
    var webURL: URL? { Self.web(url) }

    /// `s` as an http or https address with a host, or nil.
    static func web(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }

    /// The page at a given second, where the site supports it. Nil unless the page is an http or https address.
    func url(at seconds: Double) -> URL? {
        guard let page = webURL else { return nil }
        guard var c = URLComponents(string: url) else { return page }
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
            return page   // no known way to deep-link; open the page
        }
        return c.url.flatMap { Self.web($0.absoluteString) } ?? page
    }
    var supportsTimestamps: Bool { let u = url.lowercased(); return u.contains("youtube.com") || u.contains("youtu.be") || u.contains("vimeo.com") || u.contains("twitch.tv") }

    var uploadDisplay: String? {
        guard let d = uploadDate, d.count == 8 else { return nil }
        guard let date = Formats.pattern("yyyyMMdd").date(from: d) else { return nil }
        return Formats.style(date: .medium, time: .none).string(from: date)
    }
}

struct Project: Codable, Identifiable, Equatable, Hashable, SyncEntry {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var colorIndex: Int = 0     // coral, lime, iris, …
    /// When this project last changed on any device (SyncMerge). Nil in files from older builds.
    var updatedAt: Date? = nil
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
    /// Marked while recording (Marks.swift): where the mark came from (`MarkSource`'s raw value, "lockScreen"), kept as
    /// text so a source a newer build adds (the Apple Watch) still reads. nil for moments made any other way. Older
    /// files decode without it.
    var markSource: String? = nil
    /// The Mac's mark hotkey as it was when you pressed it ("⌃⌥B"), for "Mac · ⌃⌥B". nil for every other source.
    var markKeys: String? = nil

    var byModel: Bool { aiAction != nil }
    /// A moment marked while recording, from the Dynamic Island, the Lock Screen, the Action button, the Mac, or the app.
    var isMark: Bool { markSource != nil }
}

/// A template's result in a transcript (Templates.swift): what Apple Intelligence wrote, which template wrote it, and
/// why. Kept in the transcript file, so it syncs with the library. Every field decodes with a default, so a result a
/// newer build wrote still reads; older builds keep the `templateResults` key as they found it and write it back.
struct TemplateResult: Codable, Equatable, Identifiable {
    var id = UUID()
    var templateId: UUID
    /// The template's name when it ran ("Meeting notes").
    var name: String
    /// The result: section headings as "## Name" lines, then paragraphs, "- " bullets, and "- [ ] " checklist lines.
    var text: String
    /// True when it ran on its own after the recording finished (Run automatically).
    var auto = false
    /// The kind it ran for, when it ran automatically ("Ran automatically because this is a Meeting").
    var kind: RecordingKind? = nil
    /// "Mac" or "iPhone": where Apple Intelligence wrote it, for the footer.
    var madeOn: String = ""
    var createdAt = Date()
    /// True once the person edits it; Run again asks before replacing it then.
    var edited = false
    /// Parts Apple Intelligence declined; their words aren't in `text`.
    var skippedParts = 0
    var totalParts = 1
    /// The kind whose "Now a Meeting. Run Meeting notes?" offer was dismissed with Not now (its raw value).
    var offerDismissed: String? = nil
    /// Send to Reminders (Plan my day, DayPlan.swift): each sent task's key (`DayPlan.Item.key`) and the reminder's
    /// identifier, so a second send adds only what's new. nil until something is sent. Builds before this drop the key
    /// when they save the transcript (their results write only the fields they know).
    var sent: [String: String]? = nil

    init(templateId: UUID, name: String, text: String, auto: Bool = false, kind: RecordingKind? = nil, madeOn: String = "",
         createdAt: Date = Date(), skippedParts: Int = 0, totalParts: Int = 1) {
        self.templateId = templateId; self.name = name; self.text = text; self.auto = auto; self.kind = kind; self.madeOn = madeOn
        self.createdAt = createdAt; self.skippedParts = skippedParts; self.totalParts = totalParts
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case id, templateId, name, text, auto, kind, madeOn, createdAt, edited, skippedParts, totalParts, offerDismissed, sent }
        let c = try d.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        templateId = (try? c.decodeIfPresent(UUID.self, forKey: .templateId)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Template"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        auto = (try? c.decodeIfPresent(Bool.self, forKey: .auto)) ?? false
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { RecordingKind(rawValue: $0) }
        madeOn = (try? c.decodeIfPresent(String.self, forKey: .madeOn)) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        edited = (try? c.decodeIfPresent(Bool.self, forKey: .edited)) ?? false
        skippedParts = (try? c.decodeIfPresent(Int.self, forKey: .skippedParts)) ?? 0
        totalParts = (try? c.decodeIfPresent(Int.self, forKey: .totalParts)) ?? 1
        offerDismissed = (try? c.decodeIfPresent(String.self, forKey: .offerDismissed)) ?? nil
        sent = (try? c.decodeIfPresent([String: String].self, forKey: .sent)) ?? nil
    }
}

/// Run automatically's mark on a recording (Templates.swift, AutoRunRules): set when the recording finishes and its
/// kind has a template, so the template runs once per recording and never again on a relaunch, a sync, or Transcribe
/// again. Synced in the transcript file, so the other device never runs it too.
struct AutoRunMark: Codable, Equatable {
    enum State: String, Codable, TolerantEnum {
        /// Waiting in the queue, or running ("Waiting to run Meeting notes").
        case waiting
        /// The result is in the transcript.
        case done
        /// It ran and failed (Apple Intelligence declined, or was off); Run again is in the result block.
        case failed
        /// It never ran: the recording was under two minutes with Skip short recordings on.
        case skipped
        /// A state a newer build added reads as done: never run again.
        static var fallback: State { .done }
        init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    }
    var templateId: UUID
    var name: String
    var kind: RecordingKind? = nil
    var state: State = .waiting
    /// The device that runs it (Device.id): only that device picks a waiting run back up.
    var device: String = ""
    var at = Date()
    /// Why it failed, for the result block.
    var note: String? = nil

    init(templateId: UUID, name: String, kind: RecordingKind?, state: State = .waiting, device: String = "", at: Date = Date(), note: String? = nil) {
        self.templateId = templateId; self.name = name; self.kind = kind; self.state = state; self.device = device; self.at = at; self.note = note
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case templateId, name, kind, state, device, at, note }
        let c = try d.container(keyedBy: K.self)
        templateId = (try? c.decodeIfPresent(UUID.self, forKey: .templateId)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Template"
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { RecordingKind(rawValue: $0) }
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .done
        device = (try? c.decodeIfPresent(String.self, forKey: .device)) ?? ""
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? Date()
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }
}

/// A sponsor read in a podcast or video (SponsorDetect), by time, so it survives edits to the lines. The transcript
/// folds it into one row, playback can skip it, and summaries, labels, copy, and export leave it out.
struct SponsorSpan: Codable, Identifiable, Equatable {
    /// Who found it. A source a newer build added reads as the rules'.
    enum Source: String, Codable, TolerantEnum {
        case rules, model, person
        static var fallback: Source { .rules }
        init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    }
    var id = UUID()
    var start: Double
    var end: Double
    /// "Good Ranchers"; nil when nothing named it.
    var name: String? = nil
    var source: Source = .rules
    /// Marked "Not a sponsor": kept only so detecting again (after Transcribe again) leaves that stretch alone.
    var dismissed = false

    init(start: Double, end: Double, name: String? = nil, source: Source = .rules) {
        self.start = start; self.end = end; self.name = name; self.source = source
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case id, start, end, name, source, dismissed }
        let c = try d.container(keyedBy: K.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        name = try c.decodeIfPresent(String.self, forKey: .name)
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .rules
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
    }

    func encode(to e: Encoder) throws {
        enum K: String, CodingKey { case id, start, end, name, source, dismissed }
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(source, forKey: .source)
        if dismissed { try c.encode(true, forKey: .dismissed) }
    }
}

/// A stretch where speech was heard but the words are missing or unsure (UnclearRules, the noise report's rules):
/// the reading view shows a quiet "unclear 2:10" chip that plays it, and exports can list it. Every field decodes
/// with a default, so a span a newer build wrote still reads.
struct UnclearSpan: Codable, Equatable {
    enum Reason: String, Codable {
        /// Speech detection heard someone for 2 s or more, and the engine wrote nothing it was sure of.
        case noWords
        /// Three or more words in a row under the low-confidence line: shown as a best guess.
        case lowConfidence
    }
    var start: Double
    var end: Double
    var reason: Reason = .noWords

    init(start: Double, end: Double, reason: Reason = .noWords) { self.start = start; self.end = end; self.reason = reason }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case start, end, reason }
        let c = try d.container(keyedBy: K.self)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        // A reason a newer build added reads as missing words (the chip shows either way).
        let raw: String? = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        reason = raw.flatMap(Reason.init(rawValue:)) ?? .noWords
    }
}

/// The words a transcript had before Transcribe again with Whisper Turbo replaced them, so you can switch back
/// (TranscriptVersions.swift). Switching swaps this with the current words; notes, moments, title, and tags stay.
struct TranscriptVersion: Codable, Equatable {
    var original: [Segment] = []
    var segments: [Segment] = []
    var speakers: [Speaker] = []
    var corrections: [Correction] = []
    var engine: String = ""
    var model: String = ""
    var language: String? = nil
    var unclear: [UnclearSpan]? = nil
    var savedAt = Date()
}

/// Transcribe again with another engine, asked for on a device that can't run it (the iPhone asks; a Mac runs
/// Whisper Turbo). Synced with the transcript: the Mac that picks it up takes the job (`processingDevice`), and the
/// request goes once the new words are in or the job stops.
struct RerunRequest: Codable, Equatable {
    var engine: String
    var model: String
    var requestedAt = Date()
    /// The device that asked, and its name.
    var device: String = ""
    var deviceName: String = ""
}

struct Transcript: Codable, Identifiable, Equatable {
    enum Status: String, Codable, TolerantEnum {
        case processing, ready, failed
        /// A status a newer build added reads as ready (its text and audio are shown as they are).
        static var fallback: Status { .ready }
        init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    }
    /// Every stored field except the local-only paths, so those never reach the synced file.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sponsors
        case id, title, createdAt, source, sourceLabel, sourceURL, duration, audioFileName, original, segments, speakers,
             corrections, projectId, tags, pinned, notes, waveform, model, engine, language, languageChoice, status, stage, error,
             document, documentHistory, documentLevel, documentTone, deletedAt, link, processingDevice,
             processingDeviceName, pendingLink, flow, pendingAppend, kind, kindIsAuto, titleIsAuto, titleByModel,
             summary, summaryByModel, multitrack, documentCleanedBy, documentMarkHistory, documentEdited, schemaVersion,
             speakerSuggestions, unclear, previousVersion, rerunRequest, templateResults, autoRun, remindersSent, stills,
             freeTranscriptLimit, meeting, askWhoDismissed
    }
    /// Every key this build reads or writes, including the legacy path keys: anything else is a newer build's.
    static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue) + LegacyKeys.allCases.map(\.stringValue))

    /// The file format this build writes. A file from a newer build keeps its higher number when saved here.
    /// 1: files before this field. 2: unknown keys and enum values are kept and written back.
    static let currentSchema = 2
    /// Keys older builds wrote; read once to move the paths into `LocalMedia`.
    enum LegacyKeys: String, CodingKey, CaseIterable { case keptVideo, keptAudio, originalMedia }

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
    /// Names suggested for `speakers` (SpeakerNames), with what you did about each. nil until suggestions run; older
    /// builds keep the field as an unknown key and write it back.
    var speakerSuggestions: [SpeakerSuggestion]? = nil
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
    /// The language the engine transcribed (ISO 639-1, such as "es"); nil when unknown.
    var language: String? = nil
    /// The language you picked with Transcribe again in…; nil means Verbatim checks the language itself.
    var languageChoice: String? = nil
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

    /// Whether `device` may carry on with this transcript's job and write its result: no other device has taken the
    /// job over since (a Retry, Transcribe again, or a claimed link there). Without this check two devices could
    /// each transcribe one record, and each kept its own words.
    func jobIsMine(_ device: String = Device.id) -> Bool { processingDevice == nil || processingDevice == device }
    /// A link added on iPhone, waiting for a Mac to fetch its audio (iPhone can't run the link helper).
    var pendingLink = false
    /// Dictations: which app it went to, the words before cleanup, and what was pasted.
    var flow: FlowInfo? = nil
    /// Continue recording: an audio file (in Paths.audio) recorded after this one, waiting to be transcribed and joined on.
    var pendingAppend: String? = nil
    /// A free recording longer than the free transcription (Verbose Unlock, `FreeTranscription`): the seconds of each
    /// recording that are transcribed while the iPhone is free. The audio is saved in full; a run with the trial,
    /// Verbose Unlock, or on a Mac transcribes all of it and clears this.
    var freeTranscriptLimit: Double? = nil
    /// Multi-track recordings: one file per mic, each transcribed on its own and woven together by time.
    var multitrack: MultitrackInfo? = nil
    /// A call recorded for a calendar event: its title and the other people invited (MeetingContext). nil for
    /// everything else; older builds keep the key and write it back.
    var meeting: MeetingContext? = nil
    /// Dismiss on the Mac's "Who was this with?" (`callPartnerToAsk`): it doesn't ask about this transcript again.
    /// Written only when true; older builds keep the key and write it back.
    var askWhoDismissed = false
    /// An imported video's stills, one where the picture changes (VideoStill.pick), shown in the transcript's margin.
    /// nil for audio and for videos imported before stills.
    var stills: [VideoStill]? = nil
    /// Sponsor reads (SponsorDetect, Sponsors.swift): nil until a podcast or video is checked, [] when it has none.
    /// Older builds keep the key as they found it and write it back.
    var sponsors: [SponsorSpan]? = nil
    /// Stretches where speech was heard but the words are missing or unsure (UnclearRules). nil for transcripts made
    /// before this was checked; [] when it was checked and found none. Older builds keep the key and write it back.
    var unclear: [UnclearSpan]? = nil
    /// The words before Transcribe again with Whisper Turbo, to switch back to (TranscriptVersions.swift).
    var previousVersion: TranscriptVersion? = nil
    /// Transcribe again asked for on the iPhone, waiting for a Mac (or running there).
    var rerunRequest: RerunRequest? = nil
    /// Templates' results (Templates.swift), newest first: one per template. nil until a template runs; older builds
    /// keep the key and write it back.
    var templateResults: [TemplateResult]? = nil
    /// Run automatically's mark: the template ran (or is waiting to run) once for this recording, never again.
    var autoRun: AutoRunMark? = nil
    /// Plan my day's sent reminders (`TemplateResult.sent`), kept beside the results too: builds before Brain dump
    /// write a result back without its `sent`, but keep a transcript key they don't know, so a plan sent from this
    /// build is never sent twice after an older build saves the file (`recordSentReminders`).
    var remindersSent: [String: String]? = nil
    /// The file format of the file this was read from (`currentSchema` for new transcripts).
    var schemaVersion = Transcript.currentSchema
    /// What a newer build wrote that this one doesn't understand, written back unchanged on save.
    var unknown = UnknownFields()

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
        var unknown = UnknownFields()
        source = SourceKind.decodeTolerantly(c, forKey: .source, field: "source", unknown: &unknown) ?? .voiceMemo
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        // File names join library folders: anything but a bare file name is dropped (LibraryFile).
        audioFileName = try LibraryFile.checked(c.decodeIfPresent(String.self, forKey: .audioFileName), field: "audio")
        original = try c.decodeIfPresent([Segment].self, forKey: .original) ?? []
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        // Suggestions a newer build wrote in a shape this one can't read are dropped, never the whole file.
        speakerSuggestions = (try? c.decodeIfPresent([SpeakerSuggestion].self, forKey: .speakerSuggestions)) ?? nil
        corrections = try c.decodeIfPresent([Correction].self, forKey: .corrections) ?? []
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        for i in notes.indices { if let f = notes[i].frameFile { notes[i].frameFile = LibraryFile.checked(f, field: "note still") } }
        waveform = try c.decodeIfPresent([Float].self, forKey: .waveform) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language)
        languageChoice = try c.decodeIfPresent(String.self, forKey: .languageChoice)
        status = Status.decodeTolerantly(c, forKey: .status, field: "status", unknown: &unknown) ?? .ready
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        document = try c.decodeIfPresent(String.self, forKey: .document)
        documentHistory = try c.decodeIfPresent([String].self, forKey: .documentHistory) ?? []
        documentLevel = try c.decodeIfPresent(String.self, forKey: .documentLevel) ?? "None"
        documentTone = try c.decodeIfPresent(String.self, forKey: .documentTone) ?? "As spoken"
        // Files from before these fields: a cleaned document with a level or tone was Apple Intelligence's.
        if c.contains(.documentCleanedBy) {
            documentCleanedBy = CleanupSource.decodeTolerantly(c, forKey: .documentCleanedBy, field: "documentCleanedBy", unknown: &unknown)
        } else if document != nil, documentLevel != "None" || documentTone != "As spoken" {
            documentCleanedBy = .model
        }
        documentMarkHistory = try c.decodeIfPresent([String].self, forKey: .documentMarkHistory) ?? []
        documentEdited = try c.decodeIfPresent(Bool.self, forKey: .documentEdited) ?? false
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        link = try c.decodeIfPresent(LinkInfo.self, forKey: .link)
        if let thumb = link?.thumbnailFile { link?.thumbnailFile = LibraryFile.checked(thumb, field: "thumbnail") }
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
        freeTranscriptLimit = try? c.decodeIfPresent(Double.self, forKey: .freeTranscriptLimit)
        pendingLink = try c.decodeIfPresent(Bool.self, forKey: .pendingLink) ?? false
        flow = try c.decodeIfPresent(FlowInfo.self, forKey: .flow)
        pendingAppend = try LibraryFile.checked(c.decodeIfPresent(String.self, forKey: .pendingAppend), field: "continued recording")
        multitrack = try? c.decodeIfPresent(MultitrackInfo.self, forKey: .multitrack)
        meeting = (try? c.decodeIfPresent(MeetingContext.self, forKey: .meeting)) ?? nil
        askWhoDismissed = (try? c.decodeIfPresent(Bool.self, forKey: .askWhoDismissed)) ?? false
        stills = (try? c.decodeIfPresent([VideoStill].self, forKey: .stills)) ?? nil
        // Spans a newer build wrote in a shape this one can't read are dropped, never the whole file.
        sponsors = (try? c.decodeIfPresent([SponsorSpan].self, forKey: .sponsors)) ?? nil
        // An unknown kind (from a newer build) reads as unlabeled rather than failing the whole file.
        let rawKind = try? c.decodeIfPresent(String.self, forKey: .kind)
        if let rawKind, let k = RecordingKind(rawValue: rawKind) {
            kind = k
        } else {
            kind = source == .dictation ? .dictation : nil
            // Kept to write back while the kind stays as read ("" stands for unlabeled).
            if let rawKind { unknown.rawEnums["kind"] = .init(raw: rawKind, readAs: kind?.rawValue ?? "") }
        }
        kindIsAuto = try c.decodeIfPresent(Bool.self, forKey: .kindIsAuto) ?? true
        // Files from before this field: automatic only if the title is still one Verbatim made (the first words or a
        // placeholder). Anything else was named by the person, so automatic titles leave it alone.
        if let auto = try c.decodeIfPresent(Bool.self, forKey: .titleIsAuto) {
            titleIsAuto = auto
        } else {
            titleIsAuto = Self.defaultTitles.contains(title) || title == Self.titleFrom(segments)
        }
        // Calls recorded before November 6, 2026 saved their generated title ("Meeting · FaceTime · Nov 6, 2026 at 8:33 PM")
        // as one you named. Nobody types that, so it's automatic again and may be replaced (`isMeetingPlaceholder`).
        if !titleIsAuto, kind == .meeting, Self.isMeetingPlaceholder(title) { titleIsAuto = true }
        titleByModel = try c.decodeIfPresent(Bool.self, forKey: .titleByModel) ?? false
        // A summary a newer build wrote in a shape this one can't read is dropped, never the whole file.
        summary = (try? c.decodeIfPresent(TranscriptSummary.self, forKey: .summary)) ?? nil
        summaryByModel = try c.decodeIfPresent(Bool.self, forKey: .summaryByModel) ?? false
        // Read in shapes a newer build might change: what can't be read is dropped, never the whole file.
        unclear = (try? c.decodeIfPresent([UnclearSpan].self, forKey: .unclear)) ?? nil
        previousVersion = (try? c.decodeIfPresent(TranscriptVersion.self, forKey: .previousVersion)) ?? nil
        rerunRequest = (try? c.decodeIfPresent(RerunRequest.self, forKey: .rerunRequest)) ?? nil
        templateResults = (try? c.decodeIfPresent([TemplateResult].self, forKey: .templateResults)) ?? nil
        autoRun = (try? c.decodeIfPresent(AutoRunMark.self, forKey: .autoRun)) ?? nil
        remindersSent = (try? c.decodeIfPresent([String: String].self, forKey: .remindersSent)) ?? nil
        // An older build saved the file and dropped the result's own copy: it comes back from the kept one.
        if let kept = remindersSent, !kept.isEmpty, let i = templateResults?.firstIndex(where: { $0.templateId == Self.planMyDayID }) {
            let mine = templateResults?[i].sent ?? [:]
            templateResults?[i].sent = mine.merging(kept) { a, _ in a }
        }
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        unknown.keys = UnknownFields.collect(from: d, known: Self.knownKeys)
        self.unknown = unknown
    }

    /// Every field in `CodingKeys` (optional ones only when set), then what a newer build wrote that this one keeps.
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(unknown.raw(for: "source", current: source.rawValue), forKey: .source)
        try c.encode(sourceLabel, forKey: .sourceLabel)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try c.encode(original, forKey: .original)
        try c.encode(segments, forKey: .segments)
        try c.encode(speakers, forKey: .speakers)
        try c.encodeIfPresent(speakerSuggestions, forKey: .speakerSuggestions)
        try c.encode(corrections, forKey: .corrections)
        try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encode(tags, forKey: .tags)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(notes, forKey: .notes)
        try c.encode(waveform, forKey: .waveform)
        try c.encode(model, forKey: .model)
        try c.encode(engine, forKey: .engine)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(languageChoice, forKey: .languageChoice)
        try c.encode(unknown.raw(for: "status", current: status.rawValue), forKey: .status)
        try c.encodeIfPresent(stage, forKey: .stage)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(document, forKey: .document)
        try c.encode(documentHistory, forKey: .documentHistory)
        try c.encode(documentLevel, forKey: .documentLevel)
        try c.encode(documentTone, forKey: .documentTone)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(processingDevice, forKey: .processingDevice)
        try c.encodeIfPresent(processingDeviceName, forKey: .processingDeviceName)
        try c.encodeIfPresent(freeTranscriptLimit, forKey: .freeTranscriptLimit)
        try c.encode(pendingLink, forKey: .pendingLink)
        try c.encodeIfPresent(flow, forKey: .flow)
        try c.encodeIfPresent(pendingAppend, forKey: .pendingAppend)
        let kindRaw = unknown.raw(for: "kind", current: kind?.rawValue ?? "")
        if !kindRaw.isEmpty { try c.encode(kindRaw, forKey: .kind) }
        try c.encode(kindIsAuto, forKey: .kindIsAuto)
        try c.encode(titleIsAuto, forKey: .titleIsAuto)
        try c.encode(titleByModel, forKey: .titleByModel)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(summaryByModel, forKey: .summaryByModel)
        try c.encodeIfPresent(multitrack, forKey: .multitrack)
        try c.encodeIfPresent(meeting, forKey: .meeting)
        if askWhoDismissed { try c.encode(true, forKey: .askWhoDismissed) }
        try c.encodeIfPresent(stills, forKey: .stills)
        try c.encodeIfPresent(sponsors, forKey: .sponsors)
        if let cleaned = documentCleanedBy { try c.encode(unknown.raw(for: "documentCleanedBy", current: cleaned.rawValue), forKey: .documentCleanedBy) }
        try c.encode(documentMarkHistory, forKey: .documentMarkHistory)
        try c.encode(documentEdited, forKey: .documentEdited)
        try c.encodeIfPresent(unclear, forKey: .unclear)
        try c.encodeIfPresent(previousVersion, forKey: .previousVersion)
        try c.encodeIfPresent(rerunRequest, forKey: .rerunRequest)
        try c.encodeIfPresent(templateResults, forKey: .templateResults)
        try c.encodeIfPresent(autoRun, forKey: .autoRun)
        try c.encodeIfPresent(remindersSent, forKey: .remindersSent)
        try c.encode(max(schemaVersion, Self.currentSchema), forKey: .schemaVersion)
        try unknown.encodeKeys(to: e, known: Self.knownKeys)
    }

    /// Nobody has named this speaker yet: a placeholder, a call app's label, or the label this call's capture used
    /// (`meeting.app`).
    func isUnnamed(_ s: Speaker) -> Bool {
        if s.isUnnamed { return true }
        guard let app = meeting?.app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else { return false }
        return s.name.trimmingCharacters(in: .whitespaces).lowercased() == app.lowercased()
    }

    /// Suggestions to show: still pending, for a speaker who exists and hasn't been named, with a name no other
    /// speaker has. A calendar call's attendee shows for the call's track only when they're the one other person
    /// invited, or when what people said backs them (`SpeakerNames.merge` adds that evidence to the invitee's
    /// suggestion); otherwise the names are in the speaker's menu (`calendarNames`).
    var visibleSpeakerSuggestions: [SpeakerSuggestion] {
        guard let list = speakerSuggestions else { return [] }
        let taken = Set(speakers.filter { !isUnnamed($0) }.map { $0.name.lowercased() })
        var seen = Set<String>()
        // Backed by more than the invite first, so the corroborated invitee wins over the menu's others.
        let ordered = list.filter { $0.fromCalendar && $0.sources.count > 1 } + list.filter { !($0.fromCalendar && $0.sources.count > 1) }
        return ordered.filter { s in
            guard s.state == .pending, !s.name.isEmpty, !taken.contains(s.name.lowercased()), !seen.contains(s.speakerId) else { return false }
            if s.fromCalendar {
                let mine = list.filter { $0.fromCalendar && $0.speakerId == s.speakerId && $0.state == .pending }
                guard mine.count == 1 || s.sources.count > 1, speakers.contains(where: { $0.id == s.speakerId && isUnnamed($0) }) else { return false }
            } else {
                guard speakers.contains(where: { $0.id == s.speakerId && isUnnamed($0) }) else { return false }
            }
            seen.insert(s.speakerId)
            return true
        }
    }

    /// A calendar call's attendee names for a speaker (the call's track), to pick from in the speaker's menu; [] for
    /// other speakers and recordings.
    func calendarNames(for speakerId: String) -> [String] {
        (speakerSuggestions ?? []).filter { $0.fromCalendar && $0.speakerId == speakerId }.map(\.name)
    }

    /// Marks a suggestion used or dismissed. Using one doesn't rename the speaker; the caller renames it the way a
    /// typed name does.
    mutating func markSpeakerSuggestion(_ id: String, _ state: SpeakerSuggestion.State) {
        guard let i = speakerSuggestions?.firstIndex(where: { $0.id == id }) else { return }
        speakerSuggestions?[i].state = state
    }

    /// A summary the person wrote or edited: automatic summaries leave it alone.
    var summaryIsEdited: Bool { summary != nil && !summaryByModel }

    /// Plan my day's template ID (`TemplateLibrary.planMyDayID`, the ninth Scenario), here so this file reads on its own.
    static let planMyDayID = UUID(uuidString: "5E7B0A02-F1A0-4C00-9000-000000000009")!

    /// Placeholder titles Verbatim gives a transcript before it has words.
    static let defaultTitles: Set<String> = ["Voice memo", "Voice note", "Recovered recording", "Dictation", "App audio", "Untitled", "Audio only", "Brain dump"]

    /// Whether an automatic title (Apple Intelligence's, or the first words) may replace this one: never after you
    /// rename it; for the sources the app names itself (`sources`, the coordinator's `autoTitleSources`); and for an
    /// imported file whose name a phone, camera, or site made up, such as a TikTok download
    /// ("v12044gd0000db8m6m7og65g3h4k8r50"), "IMG_4821", or "Screen Recording 2026-11-02 at 6.05 PM". A file you named
    /// yourself ("Client interview, March") keeps its name.
    func mayAutoTitle(_ sources: Set<SourceKind>) -> Bool {
        guard titleIsAuto else { return false }
        if sources.contains(source) { return true }
        // A file keeps qualifying once the app has replaced its made-up name, with the first words or a model's
        // title, so Apple Intelligence can still improve on the first words.
        return source == .file && (Self.isMadeUpFileName(title) || titleByModel || title == Self.titleFrom(segments))
    }

    /// Names devices, apps, and download sites give files: a camera or app prefix with a number or date, a generic
    /// word ("video", "audio", "download"), a UUID or long ID, or a name that's mostly digits.
    static func isMadeUpFileName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || defaultTitles.contains(n) { return true }
        let lower = n.lowercased()
        // Generic words alone or with a number, date, or copy marker after them.
        let generic = ["video", "audio", "movie", "recording", "new recording", "voice memo", "screen recording", "screenshot",
                       "download", "untitled", "file", "clip", "trim", "export", "output", "final", "rpreplay_final", "rpreplay"]
        let tail = CharacterSet(charactersIn: "0123456789 _-.()[]:,").union(.whitespaces)
        for g in generic where lower.hasPrefix(g) {
            let rest = lower.dropFirst(g.count)
            if rest.unicodeScalars.allSatisfy({ tail.contains($0) }) { return true }
            // "Screen Recording 2026-11-02 at 6.05.12 PM"
            if g.contains(" ") || g == "recording", rest.range(of: #"^[\s_-]*\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return true }
        }
        // Camera, phone, and app prefixes followed by digits: IMG_4821, VID_20261102_180512, PXL_…, DJI_0042, GX010123,
        // DSC01234, MVI_1234, WhatsApp Video 2026-11-02 at …, snaptik_…, ssstik.io_….
        if lower.range(of: #"^(img|vid|mov|pxl|dji|gopr|gx|gh|dsc|dscf|mvi|mah|trim|signal|telegram|whatsapp( video| audio)?|snaptik|ssstik(\.io)?|tiktok|musicaldown|savefrom|y2mate|yt1s|snapinsta)[\s_.-]*\d"#,
                         options: .regularExpression) != nil { return true }
        // A UUID.
        if UUID(uuidString: n) != nil { return true }
        let alnum = n.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let digits = alnum.filter { CharacterSet.decimalDigits.contains($0) }.count
        // One long token mixing letters and digits, with no spaces: an ID from a site or app.
        if !n.contains(" "), alnum.count >= 16, digits >= 4, digits < alnum.count { return true }
        // Mostly digits: a timestamp or a number.
        return digits >= 5 && Double(digits) >= Double(alnum.count) * 0.5
    }

    /// Audio only (AudioOnly.swift): kept as sound. The transcription queue, AutoLabel, Ask's index, and Run
    /// automatically leave it alone until you transcribe it, which files it as a voice note.
    var isAudioOnly: Bool { kind == .audio }

    /// An Audio only recording with no words yet: it opens on its own screen (the player, title, moments, notes, and
    /// Transcribe) instead of the transcript. A transcribed recording you later file as Audio only keeps its words
    /// and opens as a transcript.
    var showsAudioDetail: Bool { kind == .audio && segments.isEmpty }

    /// A press-and-hold (or hands-free) dictation. These live only in Dictations: the Library and Home's Recent
    /// leave them out unless you're searching (Tim, October 18, 2026).
    var isDictation: Bool { flow != nil || source == .dictation || kind == .dictation }

    /// Status text that knows about the other device: "Transcribing on Tim's Mac", "Waiting for your Mac".
    var stageText: String {
        if pendingLink { return "Waiting for your Mac to fetch the audio" }
        if rerunRequest != nil, status == .ready, processingDevice == nil { return "Waiting for your Mac" }
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
    var documentText: String { document.map { DocumentText.shown($0, in: self) } ?? DocumentText.build(from: self) }

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

    /// Lines spoken by anyone other than the main speaker (background voices). Empty without a main speaker, and
    /// wherever the other voices are part of the recording (`hasBackgroundVoices`).
    var backgroundSegments: [Segment] {
        guard hasBackgroundVoices, let main = mainSpeaker else { return [] }
        return segments.filter { $0.speaker != nil && $0.speaker != main }
    }

    /// Main speaker only folds other voices away only in a recording made by one person with people nearby: a voice
    /// memo where the others talk for under a third of the time. Never in a link, an imported file, app audio, a
    /// multi-track recording, or a meeting, podcast, interview, talk, or video, where every voice is a participant
    /// (a podcast's host is not a background voice).
    var hasBackgroundVoices: Bool {
        guard source == .voiceMemo, link == nil, sourceURL == nil, multitrack == nil else { return false }
        if let kind, [.meeting, .podcast, .interview, .talk, .video].contains(kind) { return false }
        guard let main = mainSpeaker else { return false }
        var mine = 0.0, others = 0.0
        for s in segments {
            guard let sp = s.speaker else { continue }
            if sp == main { mine += max(0, s.end - s.start) } else { others += max(0, s.end - s.start) }
        }
        return others < (mine + others) / 3
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

/// A still from an imported video (Paths.thumbs), at the moment the picture changed. Shown beside the line playing
/// then, in the transcript's margin; a tap plays from `at` (November 2, 2026, mockup "Verbose Video Stills", option B).
struct VideoStill: Codable, Equatable, Hashable, Sendable {
    /// Seconds into the recording.
    var at: Double
    /// The JPEG's name in Paths.thumbs.
    var file: String
    /// Width over height as the video plays (a phone video is about 0.56, a widescreen one 1.78).
    var aspect: Double

    /// The longest a video gets one still for, and the fewest seconds between two.
    static let limit = 30
    static let minGap: Double = 10
    /// How different two 16 by 16 gray frames must be (mean difference, 0 to 1) to count as a new picture.
    static let threshold = 0.12
    /// Samples taken across a video: one a second, fewer for videos over 10 minutes.
    static let maxSamples = 600

    /// A small gray frame taken while picking: its time and 16 by 16 brightness values.
    struct Sample: Sendable {
        var at: Double
        var gray: [UInt8]
    }

    /// The times to keep: the first frame, then each frame that differs enough from the last one kept, at least
    /// `minGap` seconds later, up to `limit`. A fast-cut video gets one still per `minGap` at most; one steady camera
    /// gets one.
    static func pick(_ samples: [Sample], limit: Int = limit, minGap: Double = minGap, threshold: Double = threshold) -> [Double] {
        var kept: [Double] = []
        var last: Sample?
        for s in samples.sorted(by: { $0.at < $1.at }) {
            guard kept.count < limit else { break }
            if let l = last {
                guard s.at - l.at >= minGap, difference(s.gray, l.gray) >= threshold else { continue }
            }
            kept.append(s.at)
            last = s
        }
        return kept
    }

    /// Mean absolute difference of two gray frames, 0 (same) to 1 (black against white).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 1 }
        var sum = 0
        for i in 0..<n { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(n) / 255
    }

    /// The times to sample a video `duration` seconds long: every second, or evenly spaced when that's over
    /// `maxSamples`.
    static func sampleTimes(duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        let step = max(1, duration / Double(maxSamples))
        return Array(stride(from: 0, to: duration, by: step))
    }

    /// Each still's line: the last line that starts at or before it (the first line for a still before any words).
    /// A line gets at most one still, the earliest.
    static func byLine(_ stills: [VideoStill], lines: [Segment]) -> [UUID: VideoStill] {
        let sorted = lines.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [:] }
        var out: [UUID: VideoStill] = [:]
        for still in stills.sorted(by: { $0.at < $1.at }) {
            let line = sorted.last { $0.start <= still.at + 0.25 } ?? first
            if out[line.id] == nil { out[line.id] = still }
        }
        return out
    }

    /// The still's size in the margin: `width` points across for a tall video, wider for a wide one, and as tall as
    /// its shape (never over 1.8 times its width).
    static func size(aspect: Double, tallWidth: Double) -> (width: Double, height: Double) {
        let a = aspect > 0 ? aspect : 9.0 / 16
        let w = a >= 1 ? tallWidth * 1.5 : tallWidth
        return (w, min(w / a, w * 1.8))
    }
}

// MARK: - Calls: the generated title, naming the other side

extension Transcript {
    /// A call's title before it has a better one (App/MeetingSession.swift): "Meeting · FaceTime · Nov 6, 2026 at
    /// 8:33 PM", or "Recovered meeting · Zoom · …" after a crash. `app` is the call track's label, `stamp` the date
    /// as `Store.stamp` writes it.
    static func meetingPlaceholder(app: String, stamp: String, recovered: Bool = false) -> String {
        "\(recovered ? "Recovered meeting" : "Meeting") · \(app) · \(stamp)"
    }

    /// The title is one `meetingPlaceholder` wrote (or that with the other person's name, "Meeting with Dana · …"),
    /// not a calendar event's title or one you typed: Apple Intelligence may replace it, and the first words never do.
    static func isMeetingPlaceholder(_ title: String) -> Bool {
        let parts = title.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " · ")
        guard parts.count == 3 else { return false }
        let lead = parts[0]
        let named = ["Meeting with ", "Recovered meeting with "].contains { lead.hasPrefix($0) && lead.count > $0.count }
        guard lead == "Meeting" || lead == "Recovered meeting" || named else { return false }
        let app = parts[1].trimmingCharacters(in: .whitespaces), stamp = parts[2].trimmingCharacters(in: .whitespaces)
        // The date in any locale's style ("Nov 6, 2026 at 8:33 PM", "2026/11/06 20:33"): some digits.
        return !app.isEmpty && app.count <= 40 && stamp.count <= 48 && stamp.contains(where: \.isNumber)
    }

    /// A placeholder still waiting for a model's title: the first words never replace it (they'd be a call's "Hi,
    /// can you hear me?").
    var waitsForModelTitle: Bool { Self.isMeetingPlaceholder(title) }

    /// `title` with the one other person on a call added, or nil when it wouldn't read naturally. A placeholder takes
    /// the name after "Meeting" ("Meeting with Dana · FaceTime · …"). A written title ("Film schedule and sound mix")
    /// takes " with Dana" at its end only when it's 2 to 8 words and 60 characters with the name, ends in a letter or
    /// a digit, has no " · ", no "with", and no name yet: no possessive, none of the name's words, and no capital
    /// after the first word (titles are sentence case, so a capital there is a name; "I" and short acronyms aside).
    static func titleAddingName(_ title: String, name: String) -> String? {
        let n = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard (2...40).contains(n.count), n.contains(where: \.isLetter), !n.contains("@"), !n.contains(where: \.isNumber),
              n.lowercased() != "you" else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMeetingPlaceholder(t) {
            var parts = t.components(separatedBy: " · ")
            guard parts[0] == "Meeting" || parts[0] == "Recovered meeting" else { return nil }
            parts[0] += " with " + n
            return parts.joined(separator: " · ")
        }
        let words = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (2...8).contains(words.count), t.count + n.count + 6 <= 60, !t.contains(" · "),
              let last = t.last, last.isLetter || last.isNumber else { return nil }
        let nameWords = Set(n.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) })
        for (i, w) in words.enumerated() {
            let clean = w.trimmingCharacters(in: .punctuationCharacters)
            let lower = clean.lowercased()
            if lower == "with" || nameWords.contains(lower) { return nil }
            if lower.hasSuffix("'s") || lower.hasSuffix("’s") { return nil }
            guard i > 0, let f = clean.first, f.isUppercase else { continue }
            let acronym = clean.count <= 5 && clean.allSatisfy { $0.isUppercase || $0.isNumber }
            if clean != "I", !acronym { return nil }
        }
        // A title ending in a word that wants what follows ("Notes for", "Plans to") would read badly with "with".
        if let l = words.last?.lowercased(), ["a", "an", "the", "for", "to", "of", "on", "about", "and", "or", "in", "at", "from"].contains(l) { return nil }
        return t + " with " + n
    }

    private static func isYou(_ s: Speaker) -> Bool { s.name.trimmingCharacters(in: .whitespaces).lowercased() == "you" }

    /// A two-speaker call (You and one other) whose other speaker has a person's name: that name, else nil.
    var namedCallPartner: String? {
        guard kind == .meeting, speakers.count == 2, speakers.contains(where: Self.isYou),
              let other = speakers.first(where: { !Self.isYou($0) }), !isUnnamed(other) else { return nil }
        let n = other.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    /// After the other side of a call is named (Use on a suggestion, "Who was this with?", a rename) or an automatic
    /// title is written: the name joins an automatic title when it reads naturally (`titleAddingName`). A title you
    /// typed, or a calendar event's, never changes.
    mutating func addCallNameToTitle() {
        guard titleIsAuto, let n = namedCallPartner, let t = Self.titleAddingName(title, name: n), t != title else { return }
        title = t
    }

    /// The other side of a finished two-track call (You and one other speaker) that nobody has named and nothing
    /// suggests a name for: the speaker "Who was this with?" asks about on the Mac. Nil once suggestions have had
    /// their run with one to show, once the speaker has a name, and after Dismiss (`askWhoDismissed`).
    var callPartnerToAsk: Speaker? {
        guard kind == .meeting, status == .ready, stage == nil, !askWhoDismissed, speakerSuggestions != nil,
              speakers.count == 2, speakers.contains(where: Self.isYou),
              let other = speakers.first(where: { !Self.isYou($0) }), isUnnamed(other),
              !visibleSpeakerSuggestions.contains(where: { $0.speakerId == other.id }) else { return nil }
        return other
    }
}
