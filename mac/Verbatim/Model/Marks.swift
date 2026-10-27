import Foundation

// Mark a moment while recording, from anywhere (mockup "Library features", section 3, October 26, 2026): the
// Dynamic Island and the Lock Screen, the Action button, the in-app recorder, the Mac's recording bubble and record
// panel, and ⌃⌥B on the Mac. A mark is the time into the recording and where it came from. Marks are written beside
// the recording as they're made (".<stem>.marks"), so launch recovery keeps them; on Stop they become bookmarks
// (`Note`, `isBookmark`, with `markSource`) that sync with the transcript like every other moment. Once the words are
// in, each mark snaps to the line that was being said: the line's time, and its first sentence as the quote, unless
// you named the moment. Pure rules, no UI, so the Linux tests (`mac/tools/test-marks.sh`) cover them.

/// Where a mark came from. Stored by raw value; a value this build doesn't know reads as "marked while recording".
enum MarkSource: String, CaseIterable {
    case island, lockScreen, actionButton, phoneApp, macApp, macBubble, macHotkey
    /// The Apple Watch app, when it comes (mockup section 4). Named now so a mark from it reads everywhere.
    case watch

    /// After "Moment 4:12 · " on the transcript's line: "from the Lock Screen".
    func chip(keys: String? = nil) -> String {
        switch self {
        case .island: return "from the Dynamic Island"
        case .lockScreen: return "from the Lock Screen"
        case .actionButton: return "from the Action button"
        case .phoneApp: return "from the iPhone app"
        case .macApp: return "from the Mac app"
        case .macBubble: return "from the bubble on the Mac"
        case .macHotkey: return "from \(keys ?? Marks.defaultHotkey) on the Mac"
        case .watch: return "from the Apple Watch"
        }
    }

    /// In the Moments column and on the Moments screen: "Lock Screen", "Mac, ⌃⌥B".
    func short(keys: String? = nil) -> String {
        switch self {
        case .island: return "Dynamic Island"
        case .lockScreen: return "Lock Screen"
        case .actionButton: return "Action button"
        case .phoneApp: return "iPhone"
        case .macApp: return "Mac"
        case .macBubble: return "Mac, bubble"
        case .macHotkey: return "Mac, \(keys ?? Marks.defaultHotkey)"
        case .watch: return "Apple Watch"
        }
    }
}

/// One mark, while the recording runs and in its ".marks" file beside it.
struct RecordingMark: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Seconds into the recording.
    var at: Double
    /// The name you gave it on the iPhone's recorder; empty until you name it (the line it marks is its quote).
    var name = ""
    /// `MarkSource`'s raw value.
    var source: String
    /// The Mac's hotkey as pressed ("⌃⌥B"), for a mark from it.
    var keys: String? = nil
    var createdAt = Date()

    /// Bookmarks for the saved recording, `offset` seconds in when it's added to another; marks within
    /// `Marks.dedupeWindow` of each other count once.
    static func notes(_ marks: [RecordingMark], offset: Double = 0) -> [Note] {
        Marks.deduped(marks).map { m in
            var n = Note(text: m.name.trimmingCharacters(in: .whitespacesAndNewlines), at: offset + m.at, isBookmark: true)
            n.createdAt = m.createdAt
            n.markSource = m.source
            n.markKeys = m.keys
            return n
        }
    }
}

/// "Marked 4:12" and the count, for the two seconds after a mark (the Island, the Lock Screen, the bubble, the record panel).
struct MarkConfirmation: Equatable {
    var id = UUID()
    /// Seconds into the recording.
    var at: Double
    /// Moments marked in this recording so far.
    var count: Int
}

enum Marks {
    /// The Mac's hotkey unless you change it (Settings › Dictation › Other shortcuts).
    static let defaultHotkey = "⌃⌥B"
    /// Two marks closer than this are one moment: a double press, or the Island and the Action button together.
    static let dedupeWindow: Double = 3
    /// How long "Marked 4:12" shows.
    static let confirmSeconds: Double = 2
    /// The longest quote a mark takes from its line.
    static let quoteLimit = 120

    // MARK: Making marks

    /// The marks to keep: in time order, each at least `dedupeWindow` after the one kept before it. A name on a mark
    /// that's dropped moves to the one kept, if that one has none.
    static func deduped(_ marks: [RecordingMark]) -> [RecordingMark] {
        var out: [RecordingMark] = []
        for m in marks.sorted(by: { $0.at < $1.at }) {
            if let last = out.last, m.at - last.at < dedupeWindow {
                if out[out.count - 1].name.trimmingCharacters(in: .whitespaces).isEmpty { out[out.count - 1].name = m.name }
                continue
            }
            out.append(m)
        }
        return out
    }

    /// Adds a mark at `at` unless the last one is within `dedupeWindow` (then that one stands). Returns the marks and
    /// the one to confirm.
    static func adding(_ mark: RecordingMark, to marks: [RecordingMark]) -> (marks: [RecordingMark], confirmed: RecordingMark) {
        if let near = marks.last(where: { abs($0.at - mark.at) < dedupeWindow }) { return (marks, near) }
        return (marks + [mark], mark)
    }

    // MARK: After transcription

    /// Snaps each mark that isn't on a line yet to the line being said at its time (the line under it, else the last
    /// one that started before it, else the first): it takes the line's time, and the line's first sentence as its
    /// words unless you named it. Two marks on one line are one moment (the first, with a name if either had one).
    /// Notes that aren't marks, and marks already on a line, are left as they are.
    static func snap(_ notes: [Note], to segments: [Segment]) -> [Note] {
        guard !segments.isEmpty, notes.contains(where: { $0.isMark && $0.segmentId == nil && $0.at != nil }) else { return notes }
        // The line each mark stands on: its place in `out`, or -1 for a mark that was already on a line.
        var held: [UUID: Int] = [:]
        // The places in `out` of marks snapped here that carry a name you gave them.
        var named = Set<Int>()
        var out: [Note] = []
        for n in notes where n.isMark { if let s = n.segmentId, held[s] == nil { held[s] = -1 } }
        for n in notes {
            guard n.isMark, n.segmentId == nil, let at = n.at else { out.append(n); continue }
            guard let line = segments.first(where: { at >= $0.start && at < $0.end }) ?? segments.last(where: { $0.start <= at }) ?? segments.first else {
                out.append(n); continue
            }
            let hasName = !n.text.trimmingCharacters(in: .whitespaces).isEmpty
            if let i = held[line.id] {
                // Already marked: a name you gave this one replaces the quote on the one that stands.
                if hasName, i >= 0, !named.contains(i) { out[i].text = n.text; named.insert(i) }
                continue
            }
            var m = n
            m.segmentId = line.id
            m.at = line.start
            if hasName { named.insert(out.count) } else { m.text = quote(line.text) }
            held[line.id] = out.count
            out.append(m)
        }
        return out
    }

    /// A line's first sentence (at least a few words), cut at a word to `limit` characters with an ellipsis.
    static func quote(_ line: String, limit: Int = quoteLimit) -> String {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var end: String.Index? = nil
        var i = t.startIndex
        while i < t.endIndex {
            let next = t.index(after: i)
            if ".?!".contains(t[i]), next == t.endIndex || t[next] == " ", t.distance(from: t.startIndex, to: next) >= 12 {
                end = next
                break
            }
            i = next
        }
        var s = end.map { String(t[..<$0]) } ?? t
        if s.count > limit {
            let cut = s.prefix(limit)
            let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            s = word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
        }
        return s
    }

    // MARK: Words

    /// "4:12" or "1:02:14": a mark's time in the confirmation and the chip.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "1 moment", "3 moments".
    static func count(_ n: Int) -> String { n == 1 ? "1 moment" : "\(n) moments" }

    /// "Marked 4:12 · 3 moments".
    static func confirmation(_ c: MarkConfirmation) -> String { "Marked \(clock(c.at)) · \(count(c.count))" }

    /// The source a note was marked from; nil for other notes, and for a source this build doesn't know.
    static func source(_ n: Note) -> MarkSource? { n.markSource.flatMap(MarkSource.init(rawValue:)) }

    /// "from the Lock Screen" for a mark; nil for other notes.
    static func chipSource(_ n: Note) -> String? {
        guard n.isMark else { return nil }
        return source(n)?.chip(keys: n.markKeys) ?? "marked while recording"
    }

    /// "Lock Screen" for a mark; nil for other notes.
    static func shortSource(_ n: Note) -> String? {
        guard n.isMark else { return nil }
        return source(n)?.short(keys: n.markKeys) ?? "Marked"
    }

    /// "Moment 4:12 · from the Lock Screen", for VoiceOver and the chip's words.
    static func chip(_ n: Note) -> String? {
        guard let from = chipSource(n) else { return nil }
        return "Moment \(clock(n.at ?? 0)) · \(from)"
    }

    /// A moment's words: what it says, or for a bookmark with none, the line it's on (or "Moment" before the words are in).
    static func words(_ n: Note, in segments: [Segment]) -> String {
        let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty || !n.isBookmark { return t }
        let at = n.at ?? 0
        if let line = segments.first(where: { $0.id == n.segmentId }) ?? segments.last(where: { $0.start <= at }) { return quote(line.text) }
        return "Moment"
    }

    // MARK: Beside the recording

    /// ".<stem>.marks" beside a recording, holding its marks as JSON, rewritten on each mark.
    static func marker(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(".\(recording.deletingPathExtension().lastPathComponent).marks")
    }

    static func save(_ marks: [RecordingMark], for recording: URL) {
        guard !marks.isEmpty else { clear(recording); return }
        guard let data = try? JSONEncoder().encode(marks) else { return }
        try? data.write(to: marker(for: recording), options: .atomic)
    }

    /// The marks written beside a recording; empty when there are none or the file can't be read.
    static func load(for recording: URL) -> [RecordingMark] {
        guard let data = try? Data(contentsOf: marker(for: recording)) else { return [] }
        return (try? JSONDecoder().decode([RecordingMark].self, from: data)) ?? []
    }

    static func clear(_ recording: URL) {
        try? FileManager.default.removeItem(at: marker(for: recording))
    }
}
