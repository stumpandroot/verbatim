import SwiftUI

/// The playing line's text with the word under the playhead tinted, from the line's stored word timings
/// (`PlaybackSync`). Used only for the line that's playing, and only while its timings are fresh (the line wasn't
/// corrected since it was transcribed); otherwise the line highlights as a whole.
///
/// It reads the clock without observing it: the text re-renders only when the playing word changes, and at most
/// 15 times a second, so the rest of the screen stays still.
struct PlayingWordText: View {
    var segment: Segment
    /// The line's text, already styled (search matches). Built from `segment.text`, so its indices line up.
    var base: AttributedString
    var clock: PlayerClock
    var tint: Color
    @State private var word: Int? = nil
    @State private var lastUpdate = Date.distantPast

    /// The fastest the highlight moves.
    static let maxUpdatesPerSecond = 15.0

    var body: some View {
        Text(attributed)
            .onReceive(clock.$time) { now in
                let w = PlaybackSync.wordIndex(at: now, in: segment)
                guard w != word else { return }
                let t = Date()
                guard t.timeIntervalSince(lastUpdate) >= 1 / Self.maxUpdatesPerSecond else { return }
                lastUpdate = t
                word = w
            }
    }

    private var attributed: AttributedString {
        guard let word else { return base }
        var a = base
        let ranges = PlaybackSync.wordRanges(segment.text)
        let map = PlaybackSync.timingIndex(segment)
        for (i, r) in ranges.enumerated() where i < map.count && map[i] == word {
            if let ar = Range<AttributedString.Index>(r, in: a) { a[ar].backgroundColor = tint }
        }
        return a
    }
}
