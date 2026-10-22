import Foundation

/// Edits the Mac and iPhone screens both make, kept here so each makes them the same way.
extension Store {
    /// Days Recently Deleted keeps a transcript before it's removed for good.
    static let trashDays = 30

    /// Whole days left before a deleted transcript is removed for good (the full span if it isn't deleted).
    func trashDaysLeft(_ t: Transcript) -> Int {
        guard let d = t.deletedAt else { return Self.trashDays }
        return max(0, Self.trashDays - (Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0))
    }

    /// Undoes one correction: puts what was heard back exactly where the fix went (Transcript.undo) and drops it
    /// from the list. Words that were in the passage before stay as they are.
    func undoCorrection(_ c: Correction, in id: UUID) {
        update(id) { $0.undo(c) }
    }

    /// The passage playing at `time` (start inclusive, end exclusive), the one Bookmark attaches to.
    func segment(at time: Double, in id: UUID) -> Segment? {
        transcript(id)?.segments.first { time >= $0.start && time < $0.end }
    }
}
