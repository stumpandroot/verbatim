import Foundation

/// Whole-library work, kept until the library changes (Store's `transcriptsGeneration`), so screens stop redoing it in
/// `body` on every render: the live list, Recently Deleted, search and filter results, the Library's day groups, the
/// sidebars' counts, and the week's numbers. A value is worked out on its first use after a change and then shared by
/// every view that asks for it with the same key.
@MainActor
final class LibraryMemo {
    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }
    private var generation = -1
    private var values: [String: AnyObject] = [:]

    func value<T>(_ key: String, generation g: Int, _ make: () -> T) -> T {
        if g != generation { values.removeAll(keepingCapacity: true); generation = g }
        if let hit = values[key] as? Box<T> { return hit.value }
        let v = make()
        // Each search keystroke is a key of its own: a long search between library changes doesn't pile them up.
        if values.count >= 64 { values.removeAll(keepingCapacity: true) }
        values[key] = Box(v)
        return v
    }
}

/// Values worked out once per transcript and kept until that transcript changes (`Store.revision`): the filler count,
/// the lines a transcript shows, and where its sponsor reads fold.
@MainActor
final class TranscriptMemo {
    private final class Entry {
        let revision: Int
        let value: Any
        init(_ revision: Int, _ value: Any) { self.revision = revision; self.value = value }
    }
    private var entries: [String: Entry] = [:]

    func value<T>(_ key: String, revision: Int, _ make: () -> T) -> T {
        if let e = entries[key], e.revision == revision, let v = e.value as? T { return v }
        let v = make()
        // A few open transcripts' worth; a long session doesn't keep every transcript it ever showed.
        if entries.count > 256 { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(revision, v)
        return v
    }
}

/// What the sidebars count, in one pass over the library.
struct LibraryCounts: Equatable {
    /// Live recordings that aren't dictations (the Library's own count).
    var library = 0
    var trash = 0
    /// Live recordings that aren't dictations, by project.
    var perProject: [UUID: Int] = [:]
}

extension Store {
    /// `make()`, kept until the library changes. A view that reads it re-renders when the library changes, as it would
    /// reading `transcripts` itself. `key` must name everything besides the library that the value depends on.
    func memo<T>(_ key: String, _ make: () -> T) -> T {
        memoTable.value(key, generation: observedGeneration, make)
    }

    /// The sidebars' counts.
    var counts: LibraryCounts {
        memo("counts") {
            var c = LibraryCounts()
            for t in transcripts {
                if t.deletedAt != nil { c.trash += 1; continue }
                if t.isDictation { continue }
                c.library += 1
                if let p = t.projectId { c.perProject[p, default: 0] += 1 }
            }
            return c
        }
    }

    /// `Store.group(list, sort:)` (LibrarySearch.swift), kept for this exact list until the library changes or the day
    /// turns ("Today" and "Yesterday" move with the clock).
    func grouped(_ list: [Transcript], sort: LibrarySort) -> [(label: String, items: [Transcript])] {
        var h = Hasher()
        h.combine(list.count)
        for t in list { h.combine(t.id) }
        return memo("groups|\(sort.rawValue)|\(Self.dayKey())|\(h.finalize())") { Store.group(list, sort: sort) }
    }

    /// This week's numbers from your dictations (the iPhone's Home, You, and keyboard count these; the Mac counts its
    /// Activity log, `ActivityLog.week`).
    func dictationWeek(now: Date) -> HomeWeek {
        let entries = memo("dictation-entries") { HomeCounts.entries(fromDictations: live) }
        return memo("dictation-week|\(Self.dayKey(now))") { HomeWeek(entries, now: now) }
    }

    /// The newest live transcript (the menu bar panel's last recording).
    var newestLive: Transcript? { memo("newest-live") { live.first } }

    /// Whether the library has a journal entry (a live recording of the Journal kind): By day's Journal shows then, or
    /// when Record as shows Journal entry (`RecordAsRows.showsJournal`).
    var hasJournalEntries: Bool { memo("has-journal") { transcripts.contains { $0.deletedAt == nil && $0.kind == .journal && !$0.isDictation } } }

    /// Whether anything live is transcribing or importing.
    var isWorking: Bool { memo("working") { transcripts.contains { $0.deletedAt == nil && $0.status == .processing } } }

    /// `make()` for one transcript, kept until that transcript changes. `make` must work from the Store's own copy
    /// (`transcript(id)`), never a copy a view kept, so whichever view asks first, the value is the current one.
    func perTranscript<T>(_ id: UUID, _ key: String, _ make: () -> T) -> T {
        _ = observedGeneration   // a view that uses it re-renders when the library changes, as reading the transcript would
        return transcriptMemo.value("\(id.uuidString)|\(key)", revision: revision(id), make)
    }

    /// Lines the filler rule hides (`Transcript.fillerCount`).
    func fillerCount(_ id: UUID) -> Int { perTranscript(id, "fillers") { transcript(id)?.fillerCount ?? 0 } }

    /// The lines the transcript shows (`Transcript.displaySegments`).
    func displaySegments(_ id: UUID, hideFiller: Bool, mainOnly: Bool) -> [Segment] {
        perTranscript(id, "lines|\(hideFiller)|\(mainOnly)") { transcript(id)?.displaySegments(hideFiller: hideFiller, mainOnly: mainOnly) ?? [] }
    }

    /// Where sponsor reads fold among the lines shown (`SponsorFold.places`), for the same lines `displaySegments`
    /// gives (`engine`: the engine's words for those lines, which fold the same way).
    func sponsorFolds(_ id: UUID, hideFiller: Bool, mainOnly: Bool, engine: Bool) -> [SponsorFold.Place?] {
        perTranscript(id, "folds|\(hideFiller)|\(mainOnly)|\(engine)") {
            guard let t = transcript(id) else { return [] }
            let shown = displaySegments(id, hideFiller: hideFiller, mainOnly: mainOnly)
            return SponsorFold.places(engine ? t.engineLines(for: shown) : shown, in: t)
        }
    }

    /// Today, as a number that changes when the day does: the part of a memo key for values that say "Today".
    static func dayKey(_ now: Date = Date()) -> Int {
        Int(Calendar.current.startOfDay(for: now).timeIntervalSinceReferenceDate)
    }
}

extension Array where Element == Segment {
    /// A hash of each line's id, start, and end: it changes whenever what's under the playhead could, and costs far
    /// less to compare on every render than the lines themselves (their words included).
    var timingKey: Int {
        var h = Hasher()
        h.combine(count)
        for s in self { h.combine(s.id); h.combine(s.start); h.combine(s.end) }
        return h.finalize()
    }
}
