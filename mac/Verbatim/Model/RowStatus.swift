import Foundation

/// What a recording's row says about it: the filler words its Original still has (Home's Recent offers Clean up), and
/// whether it's words with no audio.
enum RowStatus {
    static func fillerCount(_ text: String) -> Int {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "…" })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { Segment.fillerWords.contains($0) }.count
    }

    /// Filler words a recording's Original still has, when it hasn't been cleaned yet (Home offers Clean up).
    static func fillers(_ t: Transcript) -> Int {
        guard t.status == .ready, !t.isDictation, t.document == nil else { return 0 }
        return t.segments.reduce(0) { $0 + fillerCount($1.text) }
    }

    /// `fillers`, remembered per transcript until its words, cleanup, or status change: counting splits every segment,
    /// and Home's Recent rows asked on every render.
    static func cachedFillers(_ t: Transcript) -> Int {
        let key = FillerKey(id: t.id, segments: t.segments.count, chars: t.segments.reduce(0) { $0 + $1.text.utf8.count },
                            cleaned: t.document != nil, ready: t.status == .ready, dictation: t.isDictation)
        if let hit = fillerCache[key] { return hit }
        let n = fillers(t)
        if fillerCache.count > 256 { fillerCache.removeAll(keepingCapacity: true) }
        fillerCache[key] = n
        return n
    }
    private struct FillerKey: Hashable { var id: UUID; var segments: Int; var chars: Int; var cleaned: Bool; var ready: Bool; var dictation: Bool }
    private static var fillerCache: [FillerKey: Int] = [:]

    /// A transcript with words and no audio (a Thought pad piece that became a text-only thought): its status reads
    /// "Text" and it shows no length or play control (review M-13).
    static func isTextOnly(_ t: Transcript) -> Bool {
        t.status == .ready && t.audioFileName == nil && t.duration < 0.5 && !t.isDictation && !LibrarySource.isLink(t)
    }
}
