import SwiftUI

/// "unclear 2:10" in the reading view: where speech was heard but the engine wrote nothing it was sure of
/// (UnclearRules). A quiet chip on the refined look's neutral wash (dim text, the time in tabular digits; no hue,
/// DESIGN.md §13) that plays that spot. Shared by the Mac and the iPhone.
struct UnclearChip: View {
    var span: UnclearSpan
    /// Plays from the span's start; nil when the audio isn't open.
    var onPlay: (() -> Void)?

    private var time: String { UnclearRules.clock(span.start) }

    private var label: some View {
        HStack(spacing: 6) {
            Text("unclear").refinedFont(.chip, weight: .medium)
            Text(time).refinedFont(.chip).monospacedDigit()
        }
        .foregroundStyle(Refined.dim)
        .padding(.horizontal, 10).frame(minHeight: 24)
        .background(Refined.neutral, in: Capsule())
        .contentShape(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unclear audio at \(time)")
    }

    var body: some View {
        if let onPlay {
            #if os(macOS)
            label.tapArea(onPlay)
                .help("Speech the engine couldn't make out. Click to play it.")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Plays this spot")
                .accessibilityAction { onPlay() }
            #else
            Button(action: onPlay) { label }
                .buttonStyle(.plain)
                .accessibilityHint("Plays this spot")
            #endif
        } else {
            label
        }
    }
}

/// Low-confidence words (UnclearRules.lowWords) underlined with a quiet dotted line in the reading view, as a best
/// guess. Only while the line's word timings still describe its text (no correction since); exports never mark them.
enum UnclearStyle {
    /// `base` is built from `s.text` (search matches may already be styled), so its indices line up.
    static func marked(_ base: AttributedString, _ s: Segment) -> AttributedString {
        let low = UnclearRules.lowWords(s)
        guard !low.isEmpty, PlaybackSync.timingsFresh(s) else { return base }
        var a = base
        let ranges = PlaybackSync.wordRanges(s.text)
        let map = PlaybackSync.timingIndex(s)
        for (i, r) in ranges.enumerated() where i < map.count {
            guard let w = map[i], low.contains(w), let ar = Range<AttributedString.Index>(r, in: a) else { continue }
            a[ar].underlineStyle = Text.LineStyle(pattern: .dot, color: Ink.mute)
        }
        return a
    }

    /// The chips to show before line `i` of `lines` (and, for `i == lines.count`, after the last line).
    static func chips(_ t: Transcript, lines: [Segment]) -> [Int: [UnclearSpan]] {
        guard let spans = t.unclear, !spans.isEmpty, !lines.isEmpty else { return [:] }
        var out: [Int: [UnclearSpan]] = [:]
        for p in UnclearRules.placements(spans, lineStarts: lines.map(\.start)) {
            out[min(p.before, lines.count), default: []].append(p.span)
        }
        return out
    }
}

/// Reduce background noise, as a checkmark item in a player's menu (both apps, both looks). Listening only: the
/// transcript and the saved file never change.
struct ReduceNoiseToggle: View {
    @ObservedObject var player: Player
    var body: some View {
        Toggle(ListeningCleanup.title, isOn: Binding(get: { player.reduceNoise }, set: { player.setReduceNoise($0) }))
            .help("Turns down steady noise like wind or a mower while you listen. The transcript and the recording don't change.")
            .accessibilityIdentifier("reduce-noise")
    }
}
