import Foundation

// The export options and the format-independent parts of exporting: timecodes, the paragraph model that text,
// Markdown, and Word share, and subtitle segmentation. Foundation only (no app types), so mac/tools/test-export.sh
// compiles this file on its own and tests it. Exporter.swift turns a Transcript into these shapes.

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt = "Plain text", md = "Markdown", docx = "Word", srt = "SRT", vtt = "VTT", json = "JSON"
    var id: String { rawValue }
    var ext: String { switch self { case .txt: return "txt"; case .md: return "md"; case .docx: return "docx"; case .srt: return "srt"; case .vtt: return "vtt"; case .json: return "json" } }
    /// The segmented control's label.
    var short: String { self == .txt ? "Text" : rawValue }
    var note: String {
        switch self {
        case .txt: return "Anywhere"; case .md: return "Notes, Obsidian, Notion"; case .docx: return "Word, Pages, Google Docs"
        case .srt: return "Subtitles"; case .vtt: return "Web subtitles"; case .json: return "Everything, for tools"
        }
    }
    var timed: Bool { self == .srt || self == .vtt }
}

/// What goes into an export. The export sheet and Settings › Export edit the saved copy; exports and watched folders
/// read it. Copy doesn't: it follows the tab you're on (Exporter.copyOptions).
/// Keys from earlier builds (`export.speakers`, `export.timecodes`) still read, and are still written for them.
struct ExportOptions: Equatable {
    /// Which version of the words. Raw values stay as earlier builds saved them.
    enum Source: String, CaseIterable, Identifiable {
        case document = "Document", transcript = "Transcript", engine = "Engine"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .document: return "Cleaned"
            case .transcript: return "Original with corrections"
            case .engine: return "Original (engine words)"
            }
        }
        /// One line for the export sheet: what this version is.
        var hint: String {
            switch self {
            case .document: return "Paragraphs from the Cleaned tab, with your edits and any cleanup."
            case .transcript: return "One line per passage, with your corrections and Dictionary fixes."
            case .engine: return "One line per passage, exactly as the engine heard it, before any corrections."
            }
        }
    }
    enum SpeakerMode: String, CaseIterable, Identifiable {
        case off, onChange, everyParagraph
        var id: String { rawValue }
        var label: String { switch self { case .off: return "Off"; case .onChange: return "When the speaker changes"; case .everyParagraph: return "Every paragraph" } }
        var captionLabel: String { switch self { case .off: return "Off"; case .onChange: return "When the speaker changes"; case .everyParagraph: return "Every caption" } }
    }
    enum TimecodeMode: String, CaseIterable, Identifiable {
        case off, everyParagraph, onSpeakerChange, every30s
        var id: String { rawValue }
        var label: String {
            switch self { case .off: return "Off"; case .everyParagraph: return "Every paragraph"; case .onSpeakerChange: return "Every speaker change"; case .every30s: return "Every 30 seconds" }
        }
    }
    enum TimecodeStyle: String, CaseIterable, Identifiable {
        case bracketed, plain
        var id: String { rawValue }
        var label: String { self == .bracketed ? "[00:12:04]" : "12:04" }
    }
    enum MomentsMode: String, CaseIterable, Identifiable {
        case off, inline, end
        var id: String { rawValue }
        var label: String { switch self { case .off: return "Off"; case .inline: return "Inline markers"; case .end: return "Listed at the end" } }
    }

    var source: Source = .document
    /// Title, then kind · date · duration · speakers.
    var header = true
    /// The transcript's summary (when it has one) before the text. Same name and key as the summaries change.
    var summary = false
    var speakerMode: SpeakerMode = .onChange
    var timecodeMode: TimecodeMode = .off
    var timecodeStyle: TimecodeStyle = .bracketed
    /// Added to every time shown (timecodes, moments, subtitle cues), for media that starts at 01:00:00.
    var timecodeOffset: Double = 0
    var moments: MomentsMode = .off
    /// Filler-only lines and background voices the app hides (Settings › Hide filler lines, Main speaker only).
    var includeHidden = false
    var singleParagraph = false
    /// The "Transcribed with Verbatim" footer.
    var provenance = false
    /// "Cleaned by Apple Intelligence from the original transcript." at the top of Cleaned text the model touched.
    var aiNote = true
    var subtitles = SubtitleSettings()
    /// Copy only, never saved: the Original's lines joined into paragraphs (as the Cleaned tab builds them) instead of
    /// one line per passage.
    var groupLines = false

    /// Earlier builds' switches, kept for callers that think in on and off.
    var speakers: Bool {
        get { speakerMode != .off }
        set { speakerMode = newValue ? (speakerMode == .off ? .onChange : speakerMode) : .off }
    }
    var timecodes: Bool {
        get { timecodeMode != .off }
        set { timecodeMode = newValue ? (timecodeMode == .off ? .everyParagraph : timecodeMode) : .off }
    }

    static var saved: ExportOptions { load(UserDefaults.standard) }

    static func load(_ d: UserDefaults) -> ExportOptions {
        var o = ExportOptions()
        if let s = d.string(forKey: "export.source"), let v = Source(rawValue: s) { o.source = v }
        if d.object(forKey: "export.header") != nil { o.header = d.bool(forKey: "export.header") }
        o.summary = d.bool(forKey: "export.summary")
        if let s = d.string(forKey: "export.speakerMode"), let v = SpeakerMode(rawValue: s) { o.speakerMode = v }
        else if d.object(forKey: "export.speakers") != nil { o.speakerMode = d.bool(forKey: "export.speakers") ? .onChange : .off }
        if let s = d.string(forKey: "export.timecodeMode"), let v = TimecodeMode(rawValue: s) { o.timecodeMode = v }
        else { o.timecodeMode = d.bool(forKey: "export.timecodes") ? .everyParagraph : .off }
        if let s = d.string(forKey: "export.timecodeStyle"), let v = TimecodeStyle(rawValue: s) { o.timecodeStyle = v }
        o.timecodeOffset = max(0, d.double(forKey: "export.timecodeOffset"))
        if let s = d.string(forKey: "export.moments"), let v = MomentsMode(rawValue: s) { o.moments = v }
        o.includeHidden = d.bool(forKey: "export.hidden")
        o.singleParagraph = d.bool(forKey: "export.single")
        o.provenance = d.bool(forKey: "export.prov")
        if d.object(forKey: "export.aiNote") != nil { o.aiNote = d.bool(forKey: "export.aiNote") }
        if d.object(forKey: "export.sub.chars") != nil { o.subtitles.charsPerLine = SubtitleSettings.clampChars(d.integer(forKey: "export.sub.chars")) }
        if d.object(forKey: "export.sub.lines") != nil { o.subtitles.linesPerCaption = SubtitleSettings.clampLines(d.integer(forKey: "export.sub.lines")) }
        if d.object(forKey: "export.sub.min") != nil { o.subtitles.minDuration = d.double(forKey: "export.sub.min") }
        if d.object(forKey: "export.sub.max") != nil { o.subtitles.maxDuration = d.double(forKey: "export.sub.max") }
        o.subtitles.normalize()
        return o
    }

    func save() { save(to: UserDefaults.standard) }

    func save(to d: UserDefaults) {
        d.set(source.rawValue, forKey: "export.source")
        d.set(header, forKey: "export.header")
        d.set(summary, forKey: "export.summary")
        d.set(speakerMode.rawValue, forKey: "export.speakerMode"); d.set(speakers, forKey: "export.speakers")
        d.set(timecodeMode.rawValue, forKey: "export.timecodeMode"); d.set(timecodes, forKey: "export.timecodes")
        d.set(timecodeStyle.rawValue, forKey: "export.timecodeStyle")
        d.set(timecodeOffset, forKey: "export.timecodeOffset")
        d.set(moments.rawValue, forKey: "export.moments")
        d.set(includeHidden, forKey: "export.hidden")
        d.set(singleParagraph, forKey: "export.single")
        d.set(provenance, forKey: "export.prov")
        d.set(aiNote, forKey: "export.aiNote")
        d.set(subtitles.charsPerLine, forKey: "export.sub.chars")
        d.set(subtitles.linesPerCaption, forKey: "export.sub.lines")
        d.set(subtitles.minDuration, forKey: "export.sub.min")
        d.set(subtitles.maxDuration, forKey: "export.sub.max")
    }

    /// The last format picked in the export sheet.
    static var savedFormat: ExportFormat {
        get { UserDefaults.standard.string(forKey: "export.format").flatMap(ExportFormat.init(rawValue:)) ?? .txt }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "export.format") }
    }
}

// MARK: - Timecodes

enum Timecode {
    /// "[00:12:04]" (always hours) or "12:04" ("1:02:14" past an hour). Whole seconds, rounded down, so a stamp is
    /// never ahead of the words it marks.
    static func format(_ seconds: Double, style: ExportOptions.TimecodeStyle, offset: Double = 0) -> String {
        let s = max(0, Int((seconds + offset + 0.0005).rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        switch style {
        case .bracketed: return String(format: "[%02d:%02d:%02d]", h, m, sec)
        case .plain: return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
        }
    }

    /// The digits alone, for Markdown links: "00:12:04" or "12:04".
    static func digits(_ seconds: Double, style: ExportOptions.TimecodeStyle, offset: Double = 0) -> String {
        format(seconds, style: style, offset: offset).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// Reads a start offset typed as HH:MM:SS, MM:SS, or seconds (fractions allowed). nil when it isn't one;
    /// an empty field is zero.
    static func parseOffset(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard !p.isEmpty, let v = Double(p), v >= 0, v.isFinite else { return nil }
            // Minutes and seconds after the first field stay under 60.
            if i > 0 && v >= 60 { return nil }
            // Only the last field may have a fraction.
            if i < parts.count - 1 && v != v.rounded() { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// The offset as the field shows it: "01:00:00", or "" for none.
    static func offsetText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let s = Int(seconds.rounded(.down))
        let frac = seconds - Double(s)
        let base = String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        return frac > 0.0005 ? base + String(format: ".%03d", Int((frac * 1000).rounded())).replacingOccurrences(of: "0+$", with: "", options: .regularExpression) : base
    }

    /// Subtitle cue time: 00:01:02,345 (SRT) or 00:01:02.345 (VTT).
    static func cue(_ seconds: Double, sep: String) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, sep, ms % 1000)
    }

    /// "42 min", "1 h 12 min", "38 s".
    static func spoken(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = (s + 30) / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

// MARK: - The document model shared by text, Markdown, and Word

/// A summary as exports show it.
struct ExportSummary: Equatable {
    var overview: String
    var keyPoints: [String]
    /// Written by Apple Intelligence and not edited since.
    var byModel: Bool
    var isEmpty: Bool { overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyPoints.isEmpty }

    /// Reads a `summary` property (overview, keyPoints) and `summaryByModel` off any value by name. The summaries
    /// change adds those to Transcript; reading them by reflection compiles with or without it.
    static func reflect(_ value: Any) -> ExportSummary? {
        let m = Mirror(reflecting: value)
        guard let raw = m.children.first(where: { $0.label == "summary" })?.value else { return nil }
        var inner: Any = raw
        let rm = Mirror(reflecting: raw)
        if rm.displayStyle == .optional {
            guard let some = rm.children.first?.value else { return nil }
            inner = some
        }
        let sm = Mirror(reflecting: inner)
        let overview = sm.children.first { $0.label == "overview" }?.value as? String ?? ""
        let points = sm.children.first { $0.label == "keyPoints" }?.value as? [String] ?? []
        let byModel = m.children.first { $0.label == "summaryByModel" }?.value as? Bool ?? false
        let s = ExportSummary(overview: overview, keyPoints: points, byModel: byModel)
        return s.isEmpty ? nil : s
    }
}

/// One stretch of a paragraph with the time it starts, so timecodes and moments can go between stretches.
struct ExportPiece: Equatable {
    var start: Double
    var text: String
}

struct ExportParagraph: Equatable {
    var speaker: String?
    var pieces: [ExportPiece]
    var start: Double { pieces.first?.start ?? 0 }
}

struct ExportMoment: Equatable {
    var at: Double
    var text: String
    var bookmark: Bool
    var label: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (bookmark ? "Bookmark" : "Note") : t
    }
}

/// Everything a text-like export shows, before the options shape it.
struct ExportDocument {
    var title: String
    /// Kind, date, duration, speakers.
    var details: [String]
    /// A "Source: …" line for link transcripts (Markdown and Word).
    var sourceLine: String? = nil
    var summary: ExportSummary?
    var paragraphs: [ExportParagraph]
    var moments: [ExportMoment]
    var footer: String
    /// "Cleaned by Apple Intelligence from the original transcript." when the model touched the text (shown when
    /// `ExportOptions.aiNote` is on).
    var aiNote: String? = nil
    /// True for the raw transcript: one short line each, so stamped lines sit one per line.
    var lineByLine = false
    /// A page at a given second, for Markdown timecode links.
    var link: ((Double) -> String?)? = nil
    /// Notes saved from an action (Make a plan, Key points): the action's name and the text, shown after the body
    /// under a heading that says Apple Intelligence made them. Included with the summary option.
    var aiResults: [(action: String, text: String)] = []
}

/// A rendered piece of an export, in reading order. Text, Markdown, and Word each write these their own way.
enum ExportBlock: Equatable {
    case title(String)
    case details(String)
    case source(String)
    /// A one-line note about the text, such as who cleaned it.
    case note(String)
    case heading(String)
    /// `lead` is the timecode before the speaker; `markdownLead` is the same as a link, when there is one.
    case paragraph(lead: String, markdownLead: String, speaker: String?, text: String)
    /// A plain paragraph outside the body (the summary's overview).
    case text(String)
    case bullet(String)
    /// "[00:00:31] Bring the second key in": a list item in Markdown and Word, a plain line in text.
    case moment(String)
    /// "Transcript", between a summary and the body: Markdown and Word only.
    case bodyHeading(String)
    case footer(String)
}

enum ExportLayout {
    static func blocks(_ doc: ExportDocument, _ o: ExportOptions) -> [ExportBlock] {
        var out: [ExportBlock] = []
        if o.header {
            out.append(.title(doc.title))
            if !doc.details.isEmpty { out.append(.details(doc.details.joined(separator: " · "))) }
            if let s = doc.sourceLine { out.append(.source(s)) }
        }
        if o.aiNote, let n = doc.aiNote { out.append(.note(n)) }
        let summary = o.summary ? doc.summary : nil
        if let s = summary {
            out.append(.heading(s.byModel ? "Summary (AI-generated)" : "Summary"))
            let ov = s.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ov.isEmpty { out.append(.text(ov)) }
            for p in s.keyPoints { out.append(.bullet(p)) }
            out.append(.bodyHeading("Transcript"))
        }
        let body = paragraphs(doc, o)
        if o.singleParagraph, !body.isEmpty {
            let text = body.map { b -> String in
                guard case let .paragraph(lead, _, speaker, text) = b else { return "" }
                return [lead, speaker.map { "\($0):" } ?? "", text].filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: " ")
            out.append(.paragraph(lead: "", markdownLead: "", speaker: nil, text: text))
        } else {
            out += body
        }
        if o.moments == .end, !doc.moments.isEmpty {
            out.append(.heading("Moments"))
            for m in doc.moments.sorted(by: { $0.at < $1.at }) {
                out.append(.moment(Timecode.format(m.at, style: o.timecodeStyle, offset: o.timecodeOffset) + " " + m.label))
            }
        }
        if o.summary {
            for r in doc.aiResults {
                out.append(.heading("\(r.action) (made by Apple Intelligence from this transcript)"))
                for para in r.text.components(separatedBy: "\n\n") {
                    let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !p.isEmpty { out.append(.text(p)) }
                }
            }
        }
        if o.provenance { out.append(.footer(doc.footer)) }
        return out
    }

    /// The body, with speaker names, timecodes, and inline moments placed by the options.
    static func paragraphs(_ doc: ExportDocument, _ o: ExportOptions) -> [ExportBlock] {
        var out: [ExportBlock] = []
        var previous: String?? = .none
        var nextStamp = 0.0
        var moments = o.moments == .inline ? doc.moments.sorted { $0.at < $1.at } : []
        func stamp(_ t: Double) -> (String, String) {
            let plain = Timecode.format(t, style: o.timecodeStyle, offset: o.timecodeOffset)
            if let u = doc.link?(t) { return (plain, "[\(Timecode.digits(t, style: o.timecodeStyle, offset: o.timecodeOffset))](\(u))") }
            return (plain, plain)
        }
        for (pi, p) in doc.paragraphs.enumerated() {
            let changed: Bool = { if case .some(let s) = previous { return s != p.speaker } else { return true } }()
            previous = .some(p.speaker)
            var lead = "", mdLead = ""
            switch o.timecodeMode {
            case .everyParagraph: (lead, mdLead) = stamp(p.start)
            case .onSpeakerChange: if changed { (lead, mdLead) = stamp(p.start) }
            case .every30s, .off: break
            }
            var parts: [String] = []
            for (i, piece) in p.pieces.enumerated() {
                // Moments up to this stretch's start go just ahead of it (a bookmark sits on its line's start).
                while let m = moments.first, m.at <= piece.start + 0.001 {
                    parts.append("[★ \(m.label)]"); moments.removeFirst()
                }
                if o.timecodeMode == .every30s, piece.start + 0.0005 >= nextStamp {
                    let s = stamp(piece.start)
                    if i == 0 { lead = s.0; mdLead = s.1 } else { parts.append(s.0) }
                    nextStamp = ((piece.start / 30).rounded(.down) + 1) * 30
                }
                parts.append(piece.text)
            }
            if pi == doc.paragraphs.count - 1 { while let m = moments.first { parts.append("[★ \(m.label)]"); moments.removeFirst() } }
            let speaker = p.speaker != nil && (o.speakerMode == .everyParagraph || (o.speakerMode == .onChange && changed)) ? p.speaker : nil
            out.append(.paragraph(lead: lead, markdownLead: mdLead, speaker: speaker, text: parts.joined(separator: " ")))
        }
        return out
    }

    // MARK: Writers

    static func text(_ doc: ExportDocument, _ o: ExportOptions) -> String {
        render(blocks(doc, o), markdown: false, tight: doc.lineByLine && o.timecodeMode == .everyParagraph)
    }

    static func markdown(_ doc: ExportDocument, _ o: ExportOptions) -> String {
        render(blocks(doc, o), markdown: true, tight: doc.lineByLine && o.timecodeMode == .everyParagraph)
    }

    /// `tight` keeps consecutive body lines on single newlines (the raw transcript with a stamp on every line).
    static func render(_ blocks: [ExportBlock], markdown md: Bool, tight: Bool) -> String {
        var out = ""
        var last: ExportBlock? = nil
        for b in blocks {
            if case .bodyHeading = b, !md { continue }
            let sep: String
            switch (last, b) {
            case (nil, _): sep = ""
            case (.title, .details), (.details, .source), (.title, .source): sep = md ? "\n\n" : "\n"
            case (.heading, _) where !md: sep = "\n"
            case (.bullet, .bullet), (.moment, .moment): sep = "\n"
            case (.text, .bullet) where !md: sep = "\n"
            case (.paragraph, .paragraph) where tight: sep = "\n"
            default: sep = "\n\n"
            }
            out += sep
            switch b {
            case .title(let s): out += md ? "# \(s)" : s
            case .details(let s): out += md ? "_\(s)_" : s
            case .source(let s): out += s
            case .note(let s): out += md ? "_\(s)_" : s
            case .heading(let s): out += md ? "## \(s)" : s
            case let .paragraph(lead, mdLead, speaker, text):
                var line = md ? mdLead : lead
                if let sp = speaker { line += (line.isEmpty ? "" : " ") + (md ? "**\(sp):**" : "\(sp):") }
                if !text.isEmpty { line += (line.isEmpty ? "" : " ") + text }
                out += line
            case .text(let s): out += s
            case .bullet(let s): out += "- " + s
            case .moment(let s): out += md ? "- " + s : s
            case .bodyHeading(let s): out += "## " + s
            case .footer(let s): out += "—\n" + s
            }
            last = b
        }
        return out
    }
}

// MARK: - Subtitles

struct SubtitleSettings: Equatable {
    var charsPerLine = 42
    var linesPerCaption = 2
    /// Shortest a caption stays on screen, in seconds.
    var minDuration = 1.0
    /// Longest a caption stays on screen, in seconds.
    var maxDuration = 7.0

    static func clampChars(_ v: Int) -> Int { min(80, max(16, v)) }
    static func clampLines(_ v: Int) -> Int { min(3, max(1, v)) }
    mutating func normalize() {
        charsPerLine = Self.clampChars(charsPerLine)
        linesPerCaption = Self.clampLines(linesPerCaption)
        minDuration = min(5, max(0.3, minDuration))
        maxDuration = min(20, max(minDuration + 0.5, maxDuration))
    }
}

/// A word with its time span and speaker name, the input to caption segmentation.
struct TimedWord: Equatable {
    var text: String
    var start: Double
    var end: Double
    var speaker: String? = nil
}

struct Caption: Equatable {
    var start: Double
    var end: Double
    var lines: [String]
    /// The speaker name to show on this caption, per the speaker mode.
    var label: String? = nil
    var speaker: String? = nil
    var words: [String] = []
}

enum Subtitles {
    /// A pause this long between words always starts a new caption.
    static let pauseBreak = 1.2

    /// Words for a line of text spoken over `start…end`. Uses the engine's word timings when they still match the
    /// (possibly edited) text word for word; otherwise spreads the text over the line by length.
    static func words(text: String, start: Double, end: Double, timings: [(start: Double, end: Double)]?, speaker: String?) -> [TimedWord] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        if let timings, timings.count == tokens.count {
            return zip(tokens, timings).map { TimedWord(text: $0, start: $1.start, end: max($1.start, $1.end), speaker: speaker) }
        }
        let span = max(0, end - start)
        let weights = tokens.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        var t = start
        return zip(tokens, weights).map { tok, w in
            let d = span * w / total
            defer { t += d }
            return TimedWord(text: tok, start: t, end: t + d, speaker: speaker)
        }
    }

    /// Lines for a caption's words: the fewest lines that fit, balanced; nil when they don't fit in `maxLines`.
    /// `reserve` is room taken on the first line (a "Name: " label). A single word longer than a line is allowed
    /// on a line of its own.
    static func layout(_ words: [String], charsPerLine cpl: Int, maxLines: Int, reserve: Int = 0) -> [String]? {
        guard !words.isEmpty else { return [] }
        let n = words.count
        let lens = words.map(\.count)
        func len(_ a: Int, _ b: Int) -> Int { lens[a..<b].reduce(0, +) + (b - a - 1) }   // words a..<b with spaces
        func ok(_ a: Int, _ b: Int, first: Bool) -> Bool { b - a == 1 || len(a, b) + (first ? reserve : 0) <= cpl }
        for lines in 1...max(1, maxLines) where lines <= n {
            // best[k][i]: the smallest possible longest line splitting words 0..<i into k lines; prev for the split.
            let inf = Int.max
            var best = Array(repeating: Array(repeating: inf, count: n + 1), count: lines + 1)
            var prev = Array(repeating: Array(repeating: -1, count: n + 1), count: lines + 1)
            best[0][0] = 0
            for k in 1...lines {
                for i in k...n {
                    for j in (k - 1)..<i where best[k - 1][j] != inf && ok(j, i, first: k == 1) {
                        let cost = max(best[k - 1][j], len(j, i) + (k == 1 ? reserve : 0))
                        if cost < best[k][i] { best[k][i] = cost; prev[k][i] = j }
                    }
                }
            }
            guard best[lines][n] != inf else { continue }
            var cuts: [Int] = []
            var i = n
            for k in stride(from: lines, to: 0, by: -1) { cuts.append(i); i = prev[k][i] }
            var out: [String] = []
            var a = 0
            for b in cuts.reversed() { out.append(words[a..<b].joined(separator: " ")); a = b }
            return out
        }
        return nil
    }

    /// Splits timed words into captions that honor the settings: characters per line, lines per caption, shortest
    /// and longest time on screen. Captions break at speaker changes and pauses, prefer sentence and clause ends,
    /// never overlap, and stay at least `minDuration` long where the next caption leaves room.
    static func captions(_ words: [TimedWord], _ s: SubtitleSettings, speakerMode: ExportOptions.SpeakerMode = .off) -> [Caption] {
        var s = s; s.normalize()
        var groups: [[TimedWord]] = []
        var cur: [TimedWord] = []
        func chars(_ ws: [TimedWord]) -> Int { ws.map(\.text.count).reduce(0, +) + max(0, ws.count - 1) }
        func fits(_ ws: [TimedWord]) -> Bool {
            layout(ws.map(\.text), charsPerLine: s.charsPerLine, maxLines: s.linesPerCaption, reserve: reserveFor(ws, groups)) != nil
        }
        // Room for a "Name: " label on captions that will carry one.
        func reserveFor(_ ws: [TimedWord], _ done: [[TimedWord]]) -> Int {
            guard let sp = ws.first?.speaker, speakerMode != .off else { return 0 }
            if speakerMode == .onChange, done.last?.first?.speaker == sp { return 0 }
            return sp.count + 2
        }
        func endsSentence(_ w: String) -> Bool { w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!") || w.hasSuffix("…") }
        func endsClause(_ w: String) -> Bool { endsSentence(w) || w.hasSuffix(",") || w.hasSuffix(";") || w.hasSuffix(":") || w.hasSuffix("—") }
        let capacity = s.charsPerLine * s.linesPerCaption

        for w in words where !w.text.isEmpty {
            if let last = cur.last {
                if w.speaker != last.speaker || w.start - last.end >= pauseBreak {
                    groups.append(cur); cur = []
                } else if !fits(cur + [w]) || w.end - cur[0].start > s.maxDuration {
                    // Full: break at the last clause end in the back half if there is one, else here.
                    if let j = cur.indices.last(where: { $0 >= cur.count / 2 && $0 < cur.count - 1 && endsClause(cur[$0].text) }) {
                        groups.append(Array(cur[...j])); cur = Array(cur[(j + 1)...])
                        if !fits(cur + [w]) || w.end - cur[0].start > s.maxDuration { groups.append(cur); cur = [] }
                    } else {
                        groups.append(cur); cur = []
                    }
                } else if endsSentence(last.text) && chars(cur) * 2 >= capacity {
                    groups.append(cur); cur = []
                }
            }
            cur.append(w)
        }
        if !cur.isEmpty { groups.append(cur) }

        // An orphan (a word or two cut off the end of a full caption) takes words from the caption before it, at
        // the most even split that still fits, preferring a clause end.
        if groups.count > 1 {
            for i in 1..<groups.count {
                let a = groups[i - 1], b = groups[i]
                guard a.count > 1, let al = a.last, let bf = b.first, al.speaker == bf.speaker, bf.start - al.end < pauseBreak,
                      b.count <= 2 || chars(b) * 3 < s.charsPerLine else { continue }
                let reserveA = reserveFor(a, Array(groups[..<(i - 1)]))
                let reserveB = speakerMode == .everyParagraph ? (bf.speaker.map { $0.count + 2 } ?? 0) : 0
                func fitsR(_ ws: [TimedWord], _ r: Int) -> Bool {
                    layout(ws.map(\.text), charsPerLine: s.charsPerLine, maxLines: s.linesPerCaption, reserve: r) != nil
                }
                var best: (k: Int, score: Int)? = nil
                for k in 1..<a.count {
                    let na = Array(a.dropLast(k)), nb = Array(a.suffix(k)) + b
                    guard fitsR(na, reserveA), fitsR(nb, reserveB), nb.last!.end - nb[0].start <= s.maxDuration else { continue }
                    let score = abs(chars(na) - chars(nb)) - (endsClause(na.last!.text) ? s.charsPerLine / 2 : 0)
                    if best == nil || score < best!.score { best = (k, score) }
                }
                if let k = best?.k {
                    groups[i - 1] = Array(a.dropLast(k)); groups[i] = Array(a.suffix(k)) + b
                }
            }
        }

        var caps: [Caption] = []
        var done: [[TimedWord]] = []
        for g in groups {
            let reserve = reserveFor(g, done)
            let texts = g.map(\.text)
            let lines = layout(texts, charsPerLine: s.charsPerLine, maxLines: s.linesPerCaption, reserve: reserve) ?? [texts.joined(separator: " ")]
            let start = g[0].start
            let end = min(max(g.last!.end, start), start + s.maxDuration)
            caps.append(Caption(start: start, end: end, lines: lines, label: reserve > 0 ? g[0].speaker : nil, speaker: g[0].speaker, words: texts))
            done.append(g)
        }

        // Too short: join the next caption when the pair still fits and stays under the longest; else stretch.
        var i = 0
        while i < caps.count {
            if caps[i].end - caps[i].start < s.minDuration, i + 1 < caps.count {
                let a = caps[i], b = caps[i + 1]
                let merged = a.words + b.words
                if a.speaker == b.speaker, b.start - a.end < pauseBreak, b.end - a.start <= s.maxDuration,
                   let lines = layout(merged, charsPerLine: s.charsPerLine, maxLines: s.linesPerCaption, reserve: a.label.map { $0.count + 2 } ?? 0) {
                    caps[i] = Caption(start: a.start, end: b.end, lines: lines, label: a.label, speaker: a.speaker, words: merged)
                    caps.remove(at: i + 1)
                    continue
                }
            }
            i += 1
        }
        for i in caps.indices {
            let next = i + 1 < caps.count ? caps[i + 1].start : Double.infinity
            if caps[i].end - caps[i].start < s.minDuration { caps[i].end = caps[i].start + s.minDuration }
            if caps[i].end > next { caps[i].end = max(caps[i].start + 0.001, next) }
        }
        return caps
    }

    static func srt(_ caps: [Caption], offset: Double = 0) -> String {
        caps.enumerated().map { i, c in
            var lines = c.lines
            if let l = c.label, !lines.isEmpty { lines[0] = "\(l): " + lines[0] }
            return "\(i + 1)\n\(Timecode.cue(c.start + offset, sep: ",")) --> \(Timecode.cue(c.end + offset, sep: ","))\n\(lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ caps: [Caption], offset: Double = 0) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        return "WEBVTT\n\n" + caps.map { c in
            var lines = c.lines.map(esc)
            if let l = c.label, !lines.isEmpty { lines[0] = "<v \(esc(l))>" + lines[0] }
            return "\(Timecode.cue(c.start + offset, sep: ".")) --> \(Timecode.cue(c.end + offset, sep: "."))\n\(lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }
}

// MARK: - File names

enum ExportNames {
    /// "{title}.{ext}", with characters file systems refuse replaced, and " 2", " 3"… when a name is taken
    /// (case-insensitively) in `used` or by `exists`.
    static func unique(_ title: String, ext: String, used: inout Set<String>, exists: (String) -> Bool = { _ in false }) -> String {
        var base = title.replacingOccurrences(of: "[/:\\\\?%*|\"<>\\x00-\\x1F]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.count > 120 { base = String(base.prefix(120)).trimmingCharacters(in: .whitespaces) }
        if base.isEmpty { base = "Transcript" }
        var name = base, n = 2
        while used.contains((name + "." + ext).lowercased()) || exists(name + "." + ext) { name = "\(base) \(n)"; n += 1 }
        used.insert((name + "." + ext).lowercased())
        return name + "." + ext
    }
}
