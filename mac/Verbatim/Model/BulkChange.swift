import Foundation

// Changes to many transcripts at once: Recently Deleted's Empty and Restore all, deleting a selection, the 30-day purge,
// and dictation retention. The Store makes each as one change to its list (`moveToTrash(_ ids:)`, `restore(_ ids:)`,
// `delete(_ list:)`), so the library publishes and re-renders once, not once per transcript, and the screens that follow
// it (Kept media, the widgets, Ask) look at the library once. Foundation only, so mac/tools/test-library.sh runs it on
// Linux.
enum BulkChange {
    /// The ids in the order given, each once.
    static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// The transcripts in the order given, one per id (the first).
    static func unique(_ list: [Transcript]) -> [Transcript] {
        var seen = Set<UUID>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// What's been in Recently Deleted longer than `days`: deleted for good.
    static func expired(_ list: [Transcript], days: Int, now: Date = Date()) -> [Transcript] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return list.filter { ($0.deletedAt ?? .distantFuture) < cutoff }
    }

    /// Dictations older than Keep dictations (`keepDays`; 0 keeps them all), pinned ones aside, among `live`: they move
    /// to Recently Deleted.
    static func oldDictations(_ live: [Transcript], keepDays: Int, now: Date = Date()) -> [UUID] {
        guard keepDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return live.filter { $0.source == .dictation && $0.createdAt < cutoff && !$0.pinned }.map(\.id)
    }
}
