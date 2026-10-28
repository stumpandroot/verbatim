import SwiftUI
import AppKit

// brand: native file
//
// What's left of Native's recording rows once the Library and Home moved to the refined look: the preview of what
// was said, which Home's Journal and By day still show.

/// The first lines of what was said, filler left out, remembered per transcript until its words change (lists ask on
/// every render).
@MainActor
enum PremiumPreview {
    private struct Key: Hashable { var id: UUID; var segments: Int; var chars: Int; var cleaned: Bool }
    private static var cache: [Key: String] = [:]

    static func text(_ t: Transcript) -> String {
        guard t.status == .ready else { return "" }
        let key = Key(id: t.id, segments: t.segments.count, chars: t.segments.reduce(0) { $0 + $1.text.utf8.count }, cleaned: t.document != nil)
        if let hit = cache[key] { return hit }
        let text = JournalDays.preview(t)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = text
        return text
    }
}
