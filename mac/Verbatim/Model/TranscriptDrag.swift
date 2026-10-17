import Foundation

/// What a dragged transcript (or a selection of them) carries: a prefixed list of IDs.
enum TranscriptDrag {
    static let prefix = "verbatim-transcripts:"
    static func payload(_ ids: [UUID]) -> String { prefix + ids.map(\.uuidString).joined(separator: ",") }
    static func ids(from s: String) -> [UUID] {
        guard s.hasPrefix(prefix) else { return [] }
        return s.dropFirst(prefix.count).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }
}
