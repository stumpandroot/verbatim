import Foundation

// The Search or ask panel's Search results on the Mac (MAC-35; DESIGN.md §19): recordings whose title matches, then the
// lines that match, in one list the arrow keys walk. The toolbar's search field and ⌘K open the same panel, so the
// Library never filters under you while you type. Foundation only, so mac/tools/test-library.sh runs it on Linux.

/// One result: a recording, or one line (a passage) in a recording.
enum SearchPanelItem: Hashable {
    case recording(UUID)
    case passage(transcript: UUID, segment: UUID)

    /// The recording it opens.
    var transcript: UUID {
        switch self {
        case .recording(let id): return id
        case .passage(let id, _): return id
        }
    }

    /// The line it opens at, for a passage.
    var segment: UUID? {
        if case .passage(_, let s) = self { return s }
        return nil
    }
}

/// What Search lists for a query, worked out once per render of the panel.
struct SearchPanelResults {
    /// A recording's matching lines (up to `perRecording`) and how many of its lines match in all.
    struct Passage {
        let transcript: Transcript
        let lines: [Segment]
        let count: Int
    }

    /// Search starts at two letters, as Library search always has.
    static let minLength = 2
    static let maxRecordings = 5
    static let perRecording = 3
    static let maxLines = 8

    var recordings: [Transcript] = []
    var passages: [Passage] = []

    /// Every result in the order shown and walked: the recordings, then each recording's lines.
    var items: [SearchPanelItem] {
        recordings.map { .recording($0.id) } + passages.flatMap { p in p.lines.map { .passage(transcript: p.transcript.id, segment: $0.id) } }
    }

    var isEmpty: Bool { recordings.isEmpty && passages.isEmpty }

    /// True when `query` is long enough to search.
    static func searches(_ query: String) -> Bool { query.trimmingCharacters(in: .whitespaces).count >= minLength }

    /// Recordings whose title holds the query (ignoring case and accents), up to `maxRecordings`, then matching lines
    /// in ready recordings, up to `perRecording` from one and `maxLines` in all. `list` is in the order to show
    /// (newest first, from the caller).
    static func find(_ query: String, in list: [Transcript]) -> SearchPanelResults {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= minLength else { return SearchPanelResults() }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var out = SearchPanelResults()
        out.recordings = Array(list.lazy.filter { $0.title.range(of: q, options: options) != nil }.prefix(maxRecordings))
        var lines = 0
        for t in list where t.status == .ready {
            guard lines < maxLines else { break }
            let matching = t.segments.filter { $0.text.range(of: q, options: options) != nil }
            guard !matching.isEmpty else { continue }
            let shown = Array(matching.prefix(min(perRecording, maxLines - lines)))
            out.passages.append(Passage(transcript: t, lines: shown, count: matching.count))
            lines += shown.count
        }
        return out
    }
}
