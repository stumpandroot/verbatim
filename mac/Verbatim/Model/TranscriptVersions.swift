import Foundation

/// Transcribe again with Whisper Turbo keeps the words it replaces (`previousVersion`), so you can switch back, and
/// carries what you added over to the new words: speaker names by time, and notes and moments by their time. Shared
/// by the Mac and the iPhone; the Linux tests (mac/tools/test-unclear.sh) run it.
extension Transcript {
    /// Whisper Large v3 Turbo, the engine and model Transcribe again with Whisper Turbo runs.
    static let turboEngine = "whisper"
    static let turboModel = "large-v3_turbo"
    /// Its name as the transcript records it (`Engines.displayName`; the self-tests check the two agree).
    static let turboName = "Whisper Large v3 Turbo"
    /// Its download, for the offer on a Mac that doesn't have it yet.
    static let turboSize = "1.6 GB"

    /// Edits of yours that new words would replace: your own fixes (not the Dictionary's) and lines you changed.
    /// They stay in the previous version, which you can switch back to.
    var hasHandEdits: Bool {
        if corrections.contains(where: { !$0.byDictionary }) { return true }
        let fixed = Set(corrections.map(\.segmentId))
        var heard: [UUID: String] = [:]
        for s in original where heard[s.id] == nil { heard[s.id] = s.text }
        for s in segments where !fixed.contains(s.id) {
            if let o = heard[s.id], o != s.text { return true }
        }
        return false
    }

    /// The words as they are now, as a version to keep.
    var currentVersion: TranscriptVersion {
        TranscriptVersion(original: original, segments: segments, speakers: speakers, corrections: corrections,
                          engine: engine, model: model, language: language, unclear: unclear, savedAt: Date())
    }

    /// Ran on Whisper Turbo (now, or in the version kept).
    var isTurbo: Bool { engine == Self.turboEngine && model == Self.turboName }

    /// New words are in, replacing `old`: speakers carry over by time when the new words have none, and notes and
    /// moments move to the new line at their time. Call after the new words are set.
    mutating func carryOver(from old: TranscriptVersion) {
        if speakers.isEmpty, !old.speakers.isEmpty, old.segments.contains(where: { $0.speaker != nil }) {
            for i in segments.indices { segments[i].speaker = Self.speaker(for: segments[i], in: old.segments) }
            for i in original.indices { original[i].speaker = Self.speaker(for: original[i], in: old.segments) }
            let used = Set(segments.compactMap(\.speaker))
            speakers = old.speakers.filter { used.contains($0.id) || !$0.isPlaceholder }
        }
        notes = Self.remap(notes, from: old.segments, to: segments)
    }

    /// Swaps the words with the kept version: Switch back, and Switch to Whisper Turbo after that. False when there's
    /// no version kept.
    @discardableResult
    mutating func switchVersion() -> Bool {
        guard let other = previousVersion else { return false }
        let now = currentVersion
        original = other.original; segments = other.segments; speakers = other.speakers; corrections = other.corrections
        engine = other.engine; model = other.model; language = other.language; unclear = other.unclear
        previousVersion = now
        notes = Self.remap(notes, from: now.segments, to: segments)
        return true
    }

    /// The speaker who talks most over a line's time in `lines`; nil when nobody does.
    static func speaker(for s: Segment, in lines: [Segment]) -> String? {
        var time: [String: Double] = [:]
        for o in lines {
            guard let sp = o.speaker else { continue }
            let overlap = min(s.end, o.end) - max(s.start, o.start)
            if overlap > 0 { time[sp, default: 0] += overlap }
        }
        if let best = time.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { return best.key }
        // No overlap (a line in a gap): the nearest line's speaker.
        let mid = (s.start + s.end) / 2
        return lines.filter { $0.speaker != nil }.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.speaker
    }

    /// Notes pinned to a line move to the new line at the same time: their own time when they have one, else the
    /// middle of the old line. A note whose line can't be found keeps its time and loses only the line.
    static func remap(_ notes: [Note], from old: [Segment], to new: [Segment]) -> [Note] {
        guard !new.isEmpty else { return notes.map { var n = $0; n.segmentId = nil; return n } }
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return notes.map { n in
            guard let sid = n.segmentId else { return n }
            if new.contains(where: { $0.id == sid }) { return n }
            var m = n
            let at = n.at ?? oldByID[sid].map { ($0.start + $0.end) / 2 }
            guard let t = at else { m.segmentId = nil; return m }
            let line = new.first { t >= $0.start && t < $0.end } ?? new.last { $0.start <= t } ?? new.first
            m.segmentId = line?.id
            return m
        }
    }
}
