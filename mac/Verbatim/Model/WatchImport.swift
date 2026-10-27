import Foundation

// The iPhone's side of Apple Watch capture (DESIGN.md §20): what a recording from the watch becomes in the Library.
// A thought is a Thoughts recording (`idea`, chosen by you, so AutoLabel never replaces it) on the page of the day it
// started, with "Apple Watch" as where it came from; a voice note is a voice memo whose kind AutoLabel picks, like one
// recorded on the iPhone. Marks become bookmarks from the Apple Watch (`MarkSource.watch`, Marks.swift), deduped and
// snapped to their lines like every other mark. Pure rules, so the Linux tests (`mac/tools/test-watch.sh`) cover them;
// PhoneWatch.swift does the receiving and the import.

enum WatchImport {
    /// The source labels. `ThoughtText.origin` reads "Apple Watch" from them for a thought's meta line.
    static let thoughtLabel = "Thought · Apple Watch"
    static let voiceLabel = "Voice memo · Apple Watch"
    /// What the meta line under a thought says.
    static let origin = "Apple Watch"

    /// What one transfer becomes.
    struct Plan: Equatable {
        var title: String
        var label: String
        /// Nil for a voice note: AutoLabel picks its kind after the words are in.
        var kind: RecordingKind?
        var createdAt: Date
        var marks: [RecordingMark]
        /// The bookmarks the transcript starts with.
        var notes: [Note] { RecordingMark.notes(marks) }
    }

    static func plan(_ t: WatchTransfer) -> Plan {
        let thought = t.kind == .thought
        let marks = t.marks.map { RecordingMark(at: $0.at, source: WatchTransfer.markSource, createdAt: $0.createdAt) }
        return Plan(title: thought ? "Thought" : "Voice memo", label: thought ? thoughtLabel : voiceLabel,
                    kind: thought ? .idea : nil, createdAt: t.startedAt, marks: marks)
    }

    /// True for a transcript that came from the watch.
    static func isFromWatch(_ t: Transcript) -> Bool { t.sourceLabel == thoughtLabel || t.sourceLabel == voiceLabel }

    /// What the iPhone tells the watch: today's thoughts and when their page ends, and the newest recording that isn't
    /// a dictation (for the Smart Stack).
    static func context(today: [Transcript], pageEnds: Date, live: [Transcript], now: Date = Date()) -> WatchContext {
        let last = live.filter { !$0.isDictation && $0.deletedAt == nil }.max { $0.createdAt < $1.createdAt }
        let kind: String? = last.map { t in
            if t.kind == .idea { return "Thought" }
            return t.kind?.label ?? "Voice memo"
        }
        return WatchContext(thoughtsToday: today.count, pageEnds: pageEnds, lastTitle: last?.title, lastKind: kind,
                            lastDuration: last?.duration, lastAt: last?.createdAt, sentAt: now)
    }

    // MARK: Imported once

    /// The transfers already imported, newest last, so a file the watch sends again is never a second recording.
    static let importedKey = "watch.importedTransfers"
    static let importedLimit = 200

    static func remembering(_ id: UUID, in list: [String]) -> [String] {
        var l = list.filter { $0 != id.uuidString }
        l.append(id.uuidString)
        return Array(l.suffix(importedLimit))
    }
}
