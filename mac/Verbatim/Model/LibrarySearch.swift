import Foundation
import Combine

/// What Library search reads, shared by the Mac and the iPhone: the words (with corrections), the Cleaned text, the
/// summary, notes, and tags. `Store.searchText` builds it once per transcript and caches it until the transcript
/// changes, so typing in the search field never rebuilds it.
enum LibrarySearch {
    /// Lowercased text to search. The title is matched on its own by the callers.
    static func index(_ t: Transcript) -> String {
        var parts: [String] = [t.text]
        if let d = t.document, !d.isEmpty { parts.append(d) }
        if let s = t.summary, !s.isEmpty { parts.append(s.plainText) }
        for n in t.notes where !n.text.isEmpty { parts.append(n.text) }
        if !t.tags.isEmpty { parts.append(t.tags.joined(separator: " ")) }
        return parts.joined(separator: "\n").lowercased()
    }

    /// The same test the Library uses: the title, or anything in `index`. `q` is lowercased and trimmed.
    static func matches(_ t: Transcript, _ q: String, index: String) -> Bool {
        q.isEmpty || t.title.lowercased().contains(q) || index.contains(q)
    }

    /// Search that finds the moment: per transcript, up to `perTranscript` matching lines and how many lines match
    /// in all. Stops after about `cap` lines, so a common word stays fast.
    struct PassageHit: Identifiable {
        let transcript: Transcript
        let lines: [Segment]
        /// Every matching line in the transcript, not only those in `lines`.
        let count: Int
        var id: UUID { transcript.id }
    }

    static func passages(_ list: [Transcript], query: String, perTranscript: Int = 6, cap: Int = 300) -> [PassageHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var out: [PassageHit] = []
        var total = 0
        for t in list where t.status == .ready {
            let segs = t.segments.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            guard !segs.isEmpty else { continue }
            out.append(PassageHit(transcript: t, lines: Array(segs.prefix(perTranscript)), count: segs.count))
            total += segs.count
            if total > cap { break }
        }
        return out
    }
}

/// How the Library is ordered, remembered per device (`key` in UserDefaults; never synced).
enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, longest, title
    static let key = "library.sort"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .longest: return "Longest"
        case .title: return "Title A–Z"
        }
    }
    var symbol: String {
        switch self {
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        case .longest: return "clock"
        case .title: return "textformat"
        }
    }
    /// Date orders keep the Mac's day headings; the others list everything under one heading.
    var groupsByDay: Bool { self == .newest || self == .oldest }

    static var saved: LibrarySort { LibrarySort(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .newest }

    /// Sorted, with ties broken newest first so the order never jumps.
    func sorted(_ list: [Transcript]) -> [Transcript] {
        switch self {
        case .newest: return list.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return list.sorted { $0.createdAt < $1.createdAt }
        case .longest: return list.sorted { $0.duration != $1.duration ? $0.duration > $1.duration : $0.createdAt > $1.createdAt }
        case .title:
            return list.sorted {
                let c = $0.title.localizedStandardCompare($1.title)
                return c != .orderedSame ? c == .orderedAscending : $0.createdAt > $1.createdAt
            }
        }
    }
}

extension Store {
    /// The Library's groups in a sort order: Pinned first, then day headings for Newest and Oldest, or one
    /// heading for Longest and Title A–Z.
    static func group(_ list: [Transcript], sort: LibrarySort) -> [(label: String, items: [Transcript])] {
        let sorted = sort.sorted(list)
        if sort.groupsByDay { return group(sorted) }
        let live = sorted.filter { $0.deletedAt == nil }
        var out: [(label: String, items: [Transcript])] = []
        let pinned = live.filter(\.pinned)
        if !pinned.isEmpty { out.append((label: "Pinned", items: pinned)) }
        let rest = live.filter { !$0.pinned }
        if !rest.isEmpty { out.append((label: sort == .longest ? "Longest first" : "A to Z", items: rest)) }
        return out
    }
}

/// A transcript to rename from a row's menu (Mac and iPhone). The app's root view shows one rename prompt for it.
@MainActor
final class RenameCenter: ObservableObject {
    static let shared = RenameCenter()
    @Published var target: UUID? = nil
    @Published var draft = ""

    func begin(_ t: Transcript) { draft = t.title; target = t.id }

    /// Saves a non-empty, changed title as the person's own (automatic titles never replace it).
    func commit(_ store: Store) {
        defer { target = nil; draft = "" }
        guard let id = target, let t = store.transcript(id) else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != t.title else { return }
        store.update(id) { $0.title = name; $0.titleIsAuto = false; $0.titleByModel = false }
    }
}

/// Synced playback: which time a line plays from, which line and word are under the playhead, and the speeds.
enum PlaybackSync {
    static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// "0.75×", "1×", "1.5×".
    static func speedLabel(_ r: Float) -> String {
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "×"
    }

    /// Where a tap on a line plays from: its start, kept inside the recording.
    static func seekTime(_ s: Segment, duration: Double) -> Double {
        let start = s.start.isFinite ? max(0, s.start) : 0
        return duration > 0 ? min(start, max(0, duration - 0.05)) : start
    }

    /// The line under the playhead.
    static func line(at time: Double, in segments: [Segment]) -> Segment? {
        segments.first { time >= $0.start && time < $0.end }
    }

    private static func letters(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// True when the line's word timings still describe its text: it hasn't been corrected or edited since it was
    /// transcribed. After a correction the timings are stale, and the line highlights as a whole.
    static func timingsFresh(_ s: Segment) -> Bool {
        guard let w = s.words, !w.isEmpty else { return false }
        return letters(w.map(\.text).joined()) == letters(s.text)
    }

    /// The word under the playhead, by its index in `words`; nil when timings are stale or between words.
    static func wordIndex(at time: Double, in s: Segment) -> Int? {
        guard timingsFresh(s), let w = s.words else { return nil }
        if let i = w.lastIndex(where: { time >= $0.start }), time < max(w[i].end, w[i].start + 0.05) || (i + 1 < w.count && time < w[i + 1].start) {
            return i
        }
        return nil
    }

    /// The line's text split into words, each with its timing index, so a view can tint the playing one. The
    /// words come from the line's text (spacing and punctuation as shown), matched in order to the timed words.
    static func displayWords(_ s: Segment) -> [String] {
        wordRanges(s.text).map { String(s.text[$0]) }
    }

    /// Where each whitespace-separated word sits in `text`.
    static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index? = nil
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                if let s = start { out.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i = text.index(after: i)
        }
        if let s = start { out.append(s..<text.endIndex) }
        return out
    }

    /// Maps each displayed word to a timed word by letter position (the letters match when timings are fresh).
    /// nil entries are words with no timing, which the highlight skips.
    static func timingIndex(_ s: Segment) -> [Int?] {
        let shown = displayWords(s)
        guard let w = s.words, timingsFresh(s) else { return shown.map { _ in nil } }
        var starts: [Int] = []
        var acc = 0
        for x in w { starts.append(acc); acc += letters(x.text).count }
        var out: [Int?] = []
        var off = 0
        for word in shown {
            let n = letters(word).count
            guard n > 0 else { out.append(nil); continue }
            out.append(starts.lastIndex { $0 <= off })
            off += n
        }
        return out
    }
}
