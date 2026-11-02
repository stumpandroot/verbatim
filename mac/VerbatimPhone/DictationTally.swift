import Foundation
import Combine

/// Every dictation this iPhone has counted for time saved, kept after you delete the dictation, so You's all-time time
/// saved and the keyboard's "since you started" don't drop (the Mac keeps the same in its Activity log). One record per
/// dictation: when, its words, and how long you talked. Stored on this iPhone only, never synced. PhoneState feeds it
/// the library from its stats queue; You and Home read `allTime`.
final class DictationTally: ObservableObject, @unchecked Sendable {
    struct Record: Codable, Equatable {
        var date: Date
        var words: Int
        var seconds: Double
    }

    /// The screenshot tour counts its made-up dictations in its own file, never in your real tally.
    static let shared = DictationTally(file: Paths.local.appendingPathComponent(
        ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" ? "dictation-tally-uitest.json" : "dictation-tally.json"))

    /// All time's words and talking time, and the first dictation's date, on the main thread.
    @Published private(set) var allTime = TimeSaved.Span()
    @Published private(set) var since: Date?

    private let file: URL
    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([UUID: Record].self, from: data) { records = r }
        let t = Self.totals(records)
        allTime = t.0
        since = t.1
    }

    /// Adds the live dictations and updates the numbers of ones already counted (an edit changes the words); a deleted
    /// dictation keeps its record. Returns all time. Safe on any queue; saves only when something changed.
    @discardableResult
    func merge(_ dictations: [Transcript]) -> (span: TimeSaved.Span, since: Date?) {
        // Off the main thread: the stats queue (PhoneState) and the self-test call it.
        lock.lock()
        var changed = false
        for t in dictations where t.isDictation && t.status == .ready {
            let r = Record(date: t.createdAt, words: HomeCounts.words(t), seconds: t.duration)
            if records[t.id] != r { records[t.id] = r; changed = true }
        }
        let totals = Self.totals(records)
        let data = changed ? try? JSONEncoder().encode(records) : nil
        lock.unlock()
        if let data {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        DispatchQueue.main.async { [self] in
            if allTime != totals.0 { allTime = totals.0 }
            if since != totals.1 { since = totals.1 }
        }
        return (totals.0, totals.1)
    }

    /// How many dictations are counted (the self-test).
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    static func totals(_ records: [UUID: Record]) -> (TimeSaved.Span, Date?) {
        var span = TimeSaved.Span()
        var first: Date?
        for r in records.values {
            span.words += r.words; span.seconds += r.seconds
            first = min(first ?? r.date, r.date)
        }
        return (span, first)
    }
}
