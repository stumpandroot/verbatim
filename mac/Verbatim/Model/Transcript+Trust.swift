import Foundation
import Combine

// The trust features' Transcript side, shared by the Mac and the iPhone: where a transcript came from and where its
// data went (the provenance line and data path badge), Copy for AI, Fix all, and the Dictionary's CSV and Markdown
// notes. The pure rules live in NetworkActivity.swift, CorrectEverywhere.swift, DictionaryCSV.swift, and ExportCore.

// MARK: - Provenance

extension Transcript {
    /// The link's host for link transcripts ("youtube.com"), else nil.
    var linkHost: String? {
        guard source == .link else { return nil }
        let h = NetworkHost.of(linkInfo?.url ?? sourceURL ?? "")
        return h.isEmpty ? nil : h
    }

    /// Where the audio came from: the file's name, the link's host, the app a dictation went to.
    var provenanceSource: String {
        switch source {
        case .link: return linkHost ?? sourceLabel
        case .file:
            if let p = originalMedia { return URL(fileURLWithPath: p).lastPathComponent }
            return sourceLabel.isEmpty ? "File" : sourceLabel
        case .dictation: return flow.map { "Dictation into \($0.app)" } ?? "Dictation"
        case .voiceMemo: return "Voice note"
        case .app: return sourceLabel.isEmpty ? "App audio" : sourceLabel
        }
    }

    /// "Local audio · local text", "Audio from youtube.com · local text", "Local audio · cloud cleanup (Anthropic)".
    var dataPathBadge: String { DataPath.badge(linkHost: linkHost, cloudCleanup: flow?.cloudCleanup) }

    /// True when a link download or cloud cleanup took part.
    var dataLeftDevice: Bool { DataPath.leftDevice(linkHost: linkHost, cloudCleanup: flow?.cloudCleanup) }

    /// "English", or nil when unknown.
    var languageName: String? { language.map(LanguageDetection.name) }

    /// One line: source · engine and model · language · date.
    var provenanceLine: String {
        var parts = [provenanceSource]
        if !model.isEmpty { parts.append(model) }
        if let l = languageName { parts.append(l) }
        parts.append(Formats.style(date: .medium, time: .short).string(from: createdAt))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Copy for AI

extension Transcript {
    /// True when the Cleaned tab has its own text (edited or cleaned), so Copy for AI takes it.
    var hasCleanedText: Bool { document != nil }

    /// The transcript under a header an assistant can read: title, date, duration, speakers, source, and language.
    /// Takes the Cleaned tab's text, or the Original (with corrections) when nothing has been cleaned.
    var copyForAI: String {
        let cleaned = hasCleanedText
        let body = Exporter.copyText(self, cleaned ? .cleaned : .original)
        let speakerNames = speakers.count >= 2 ? speakers.map(\.label) : []
        let h = AICopy.Header(title: title, date: Formats.style(date: .long, time: .short).string(from: createdAt),
                              duration: Timecode.spoken(duration), speakers: speakerNames, source: provenanceSource,
                              language: languageName, version: cleaned ? "Cleaned transcript" : "Original transcript")
        return AICopy.text(h, body: body)
    }
}

// MARK: - Markdown notes

extension Transcript {
    /// One Markdown note with properties, for Export as Markdown files. The body follows Settings › Export, without
    /// its own header (the properties carry the title and details).
    func markdownNote(projectName: String?, options: ExportOptions = .saved) -> String {
        var o = options
        o.header = false
        let body = Exporter.render(self, as: .md, options: o)
        let p = MarkdownNotes.Properties(title: title, date: createdAt, duration: duration,
                                         speakers: speakers.count >= 2 ? speakers.map(\.label) : [],
                                         tags: tags + (kind.map { [$0.label.lowercased()] } ?? []), project: projectName,
                                         source: provenanceSource, language: languageName, id: id.uuidString)
        return MarkdownNotes.note(p, body: body)
    }
}

// MARK: - Fix all

extension Transcript {
    /// How many more places "Fix all" would change, across every line.
    func fixAllCount(heard: String, fix: String) -> Int {
        CorrectEverywhere.count(heard: heard, fix: fix, in: segments.map(\.text))
    }

    /// Replaces every whole-word `heard` (any case) with `fix` in the case of the word it replaces, through the
    /// corrections layer: each replacement is recorded, so Review lists it and Undo restores exactly it, and the
    /// engine's words (`original`) never change. Returns how many places changed.
    @discardableResult
    mutating func fixEverywhere(heard: String, fix: String) -> Int {
        guard !heard.trimmingCharacters(in: .whitespaces).isEmpty, heard != fix else { return 0 }
        var total = 0
        for i in segments.indices {
            let changes = CorrectEverywhere.changes(heard: heard, fix: fix, in: segments[i].text)
            guard !changes.isEmpty else { continue }
            // One correction per spelling of the fix ("the", "The"), each with every place it went.
            var groups: [String: [CorrectEverywhere.Change]] = [:]
            var order: [String] = []
            for c in changes {
                if groups[c.with] == nil { order.append(c.with) }
                groups[c.with, default: []].append(c)
            }
            for with in order {
                let list = groups[with] ?? []
                // Ranges were found in the text before this pass; re-find them after earlier groups changed it.
                let current = CorrectEverywhere.changes(heard: heard, fix: fix, in: segments[i].text).filter { $0.with == with }
                let ranges = current.map(\.range)
                if CorrectionEdits.apply(ranges, in: &segments, at: i, to: with, label: list.first?.found ?? heard,
                                         byDictionary: false, corrections: &corrections) != nil {
                    total += ranges.count
                }
            }
        }
        return total
    }
}

/// The "Fix all" banner's state: shown on the transcript after a correction when the same word appears elsewhere.
@MainActor
final class FixAllOffer: ObservableObject {
    static let shared = FixAllOffer()

    struct Offer: Equatable {
        var transcript: UUID
        var heard: String
        var fix: String
        var count: Int
        /// False when the correction already went to the Dictionary (Remember was on).
        var offerDictionary: Bool
    }
    @Published var offer: Offer?

    /// After a correction: offers Fix all when the word appears elsewhere in the transcript.
    func consider(_ t: Transcript, heard: String, fix: String, remembered: Bool) {
        let n = t.fixAllCount(heard: heard, fix: fix)
        offer = n > 0 ? Offer(transcript: t.id, heard: heard, fix: fix, count: n, offerDictionary: !remembered) : nil
    }

    func dismiss() { offer = nil }
}

extension Store {
    /// Fix all, as one saved change. Returns how many places changed.
    @discardableResult
    func fixEverywhere(_ id: UUID, heard: String, fix: String) -> Int {
        var n = 0
        update(id) { n = $0.fixEverywhere(heard: heard, fix: fix) }
        return n
    }
}

// MARK: - Dictionary CSV

extension Store {
    /// The Dictionary as CSV rows (projects by name).
    func dictionaryCSV() -> String {
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let rows = dictionary.map { e in
            DictionaryCSV.Row(heard: e.heardAs, replacement: e.preferred, enabled: e.enabled,
                              project: e.projectId.flatMap { names[$0] }, learnedFrom: e.learnedFrom, created: e.createdAt)
        }
        return DictionaryCSV.export(rows)
    }

    /// Merges a CSV into the Dictionary: new words are added, new heard forms join their word, and rows already there
    /// are skipped. A project named in the file that doesn't exist yet is created.
    func importDictionaryCSV(_ text: String) -> DictionaryCSV.Report {
        let parsed = DictionaryCSV.parse(text)
        var names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let existing = dictionary.map { e in
            DictionaryCSV.Row(heard: e.heardAs, replacement: e.preferred, enabled: e.enabled, project: e.projectId.flatMap { names[$0] })
        }
        var (steps, report) = DictionaryCSV.plan(existing: existing, incoming: parsed.rows)
        report.invalid = parsed.invalid
        var list = dictionary
        for step in steps {
            switch step {
            case .skip: continue
            case .addHeard(let i, let extra):
                if list.indices.contains(i) { list[i].heardAs += extra }
            case .add(let r):
                var projectId: UUID? = nil
                if let name = r.project {
                    if let found = names.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame })?.key { projectId = found }
                    else { let p = addProject(name); names[p.id] = p.name; projectId = p.id }
                }
                var e = DictionaryEntry(preferred: r.replacement, heardAs: r.heard, enabled: r.enabled,
                                        learnedFrom: r.learnedFrom ?? "Imported", projectId: projectId)
                if let c = r.created { e.createdAt = c }
                list.append(e)
            }
        }
        if list != dictionary { dictionary = list }
        return report
    }
}
