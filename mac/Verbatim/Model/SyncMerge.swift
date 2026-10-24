import Foundation

/// An entry of a list synced through iCloud as one JSON file (projects, the Dictionary, snippets). Each entry
/// carries when it last changed, so two devices' copies merge entry by entry instead of one file replacing the
/// other.
protocol SyncEntry: Codable, Equatable, Identifiable where ID == UUID {
    /// When this entry last changed on any device. Nil in files written before merging existed.
    var updatedAt: Date? { get set }
}

/// A deleted entry, remembered so a merge with a copy that still has it doesn't bring it back.
struct Tombstone: Codable, Equatable {
    var id: UUID
    var deletedAt: Date
}

/// How a synced list's file read went.
enum ListRead<T> {
    /// No file (and no iCloud placeholder): a list that was never written. Safe to write.
    case missing
    /// The file is there but its bytes aren't on this device yet, or it couldn't be read or decoded. Never
    /// written over until it reads cleanly.
    case unavailable(String)
    case ok(T)
}

/// The merge rules, pure so mac/tools/test-sync.sh checks them on Linux.
enum SyncMerge {
    /// Tombstones older than this are dropped: by then every device has seen the delete.
    static let tombstoneDays: Double = 90

    /// Merges two copies of a list. For an entry in both, the one changed last wins (ties go to the larger
    /// encoding, so both devices pick the same one). An entry deleted (a tombstone) at or after its last change is
    /// dropped; one changed after its delete comes back. Order: `local`'s, then entries only `remote` has, in its
    /// order. A change dated after `now` counts as made now (`clamped`), so an entry dated in the future (a wrong
    /// clock, or a file someone edited) can't outlast every later edit and delete.
    static func merge<T: SyncEntry>(local: [T], remote: [T], localTombstones: [Tombstone], remoteTombstones: [Tombstone],
                                    now: Date = Date()) -> (items: [T], tombstones: [Tombstone]) {
        let local = clamped(local, now: now), remote = clamped(remote, now: now)
        let tombstones = mergeTombstones(localTombstones, remoteTombstones, now: now)
        let deleted = Dictionary(tombstones.map { ($0.id, $0.deletedAt) }, uniquingKeysWith: max)
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [T] = []
        var seen = Set<UUID>()
        for l in local where !seen.contains(l.id) {
            seen.insert(l.id)
            out.append(remoteByID[l.id].map { pick(l, $0) } ?? l)
        }
        for r in remote where !seen.contains(r.id) {
            seen.insert(r.id)
            out.append(r)
        }
        out.removeAll { e in
            guard let d = deleted[e.id] else { return false }
            return (e.updatedAt ?? .distantPast) <= d
        }
        return (out, tombstones)
    }

    /// Entries with `updatedAt` no later than `now`.
    static func clamped<T: SyncEntry>(_ items: [T], now: Date) -> [T] {
        items.map { e in
            guard let d = e.updatedAt, d > now else { return e }
            var e = e; e.updatedAt = now; return e
        }
    }

    /// Of two versions of one entry, the one changed last; a tie goes to the larger encoding (deterministic).
    static func pick<T: SyncEntry>(_ a: T, _ b: T) -> T {
        if a == b { return a }
        let ta = a.updatedAt ?? .distantPast, tb = b.updatedAt ?? .distantPast
        if ta != tb { return ta > tb ? a : b }
        return encoded(a) >= encoded(b) ? a : b
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()

    private static func encoded<T: Encodable>(_ x: T) -> String {
        (try? encoder.encode(x)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Union by ID, keeping the latest delete; ones older than `tombstoneDays` are dropped. Sorted by ID, so both
    /// devices write the same file.
    static func mergeTombstones(_ a: [Tombstone], _ b: [Tombstone], now: Date = Date()) -> [Tombstone] {
        let cutoff = now.addingTimeInterval(-tombstoneDays * 86_400)
        var byID: [UUID: Date] = [:]
        for t in a + b where t.deletedAt >= cutoff { byID[t.id] = max(byID[t.id] ?? .distantPast, t.deletedAt) }
        return byID.map { Tombstone(id: $0.key, deletedAt: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// A local edit: entries that are new or changed since `old` get `updatedAt = now` (unless the edit set it
    /// already), and entries that are gone get a tombstone.
    static func stamp<T: SyncEntry>(old: [T], new: [T], now: Date = Date()) -> (items: [T], deleted: [Tombstone]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items = new
        for i in items.indices {
            if let o = before[items[i].id] {
                guard o != items[i], o.updatedAt == items[i].updatedAt else { continue }
                items[i].updatedAt = now
            } else if items[i].updatedAt == nil {
                items[i].updatedAt = now
            }
        }
        let kept = Set(new.map(\.id))
        let deleted = old.filter { !kept.contains($0.id) }.map { Tombstone(id: $0.id, deletedAt: now) }
        return (items, deleted)
    }

    /// Of a transcript file's iCloud conflict versions (both devices wrote it at once), the one to put in place of
    /// the current file: the most recently modified, when it's newer than the current one; nil keeps the current
    /// file. Every device picks the same version, so their copies agree again; keeping each device's own current
    /// file left two devices showing different words for one transcript.
    static func conflictWinner(current: Date?, others: [Date?]) -> Int? {
        var best: (i: Int, date: Date)? = nil
        for (i, d) in others.enumerated() {
            guard let d else { continue }
            if best == nil || d > best!.date { best = (i, d) }
        }
        guard let best, best.date > (current ?? .distantPast) else { return nil }
        return best.i
    }

    /// Whether this device may write the list after reading its file: never while the file is there but not
    /// downloaded or not decodable, so a device that hasn't seen the list can't replace it with an empty one.
    static func mayWrite<T>(after read: ListRead<T>) -> Bool {
        if case .unavailable = read { return false }
        return true
    }

    /// Decodes a list file. Nil when the data isn't a list of `T` (the caller then never writes over the file).
    /// Dates after `now` read as `now` (`clamped`), fixed at the first read, so a delete made after it wins.
    static func decode<T: SyncEntry>(_ type: T.Type, from data: Data, decoder: JSONDecoder, now: Date = Date()) -> [T]? {
        (try? decoder.decode([T].self, from: data)).map { clamped($0, now: now) }
    }
}
