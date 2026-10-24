import Foundation

// Sponsor reads on a transcript: which lines they cover, the folded rows, skipping them in playback, leaving them
// out of summaries, labels, copy, and export, and the corrections people make ("Not a sponsor", "Mark as sponsor").
// Pure Foundation (no SwiftUI), so mac/tools/test-sponsors.sh checks it on Linux. Detection itself is
// Transcription/SponsorDetect.swift.

extension Transcript {
    /// Settings › Skip sponsor reads (Mac and iPhone): playback jumps past them. On by default.
    static let skipSponsorsKey = "playback.skipSponsors"
    static var skipSponsors: Bool { UserDefaults.standard.object(forKey: skipSponsorsKey) as? Bool ?? true }

    /// Whether a line's menu offers "Mark as sponsor": transcripts already checked, links, and imported files.
    var offersSponsorMarking: Bool { sponsors != nil || source == .link || source == .file || link != nil }

    /// The kinds sponsor detection runs for.
    static let sponsorKinds: Set<RecordingKind> = [.podcast, .video, .talk, .interview]

    /// Whether to look for sponsor reads: a link or an imported file whose kind is a podcast, video, talk, or
    /// interview (`kind` is the transcript's, or the rule's while it has none yet).
    static func detectsSponsors(isMedia: Bool, kind: RecordingKind?) -> Bool {
        guard isMedia, let kind else { return false }
        return sponsorKinds.contains(kind)
    }

    /// The sponsor reads in effect, in time order ("Not a sponsor" ones left out).
    var sponsorSpans: [SponsorSpan] {
        (sponsors ?? []).filter { !$0.dismissed && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// The read a line belongs to: the one its middle falls in.
    func sponsorSpan(for s: Segment, in spans: [SponsorSpan]? = nil) -> SponsorSpan? {
        let mid = (s.start + s.end) / 2
        return (spans ?? sponsorSpans).first { mid >= $0.start && mid < $0.end }
    }

    /// Lines inside a sponsor read.
    var sponsorSegmentIDs: Set<UUID> {
        let spans = sponsorSpans
        guard !spans.isEmpty else { return [] }
        return Set(segments.filter { sponsorSpan(for: $0, in: spans) != nil }.map(\.id))
    }

    /// The lines without sponsor reads: what summaries, titles, kinds, and tags are written from.
    var segmentsWithoutSponsors: [Segment] { withoutSponsors(segments) }

    /// `segs` without the lines inside sponsor reads (Exporter: copy and export leave them out by default).
    func withoutSponsors(_ segs: [Segment]) -> [Segment] {
        let spans = sponsorSpans
        guard !spans.isEmpty else { return segs }
        return segs.filter { sponsorSpan(for: $0, in: spans) == nil }
    }

    /// The detector's view of the lines.
    var sponsorLines: [SponsorDetect.Line] {
        segments.map { SponsorDetect.Line(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) }
    }

    /// Replaces what detection found before with `found`: spans someone marked stay, and so do the ones marked
    /// "Not a sponsor", which also keep a new span from coming back over the same stretch.
    mutating func applySponsors(_ found: [SponsorDetect.Found]) {
        let kept = (sponsors ?? []).filter { $0.source == .person || $0.dismissed }
        let fresh = found.map { SponsorSpan(start: $0.start, end: $0.end, name: $0.name) }.filter { f in
            !kept.contains { b in Self.overlap(f, b) > 0.5 * min(f.end - f.start, b.end - b.start) }
        }
        sponsors = (kept + fresh).sorted { $0.start < $1.start }
    }

    static func overlap(_ a: SponsorSpan, _ b: SponsorSpan) -> Double { max(0, min(a.end, b.end) - max(a.start, b.start)) }

    /// "Not a sponsor": the span stops folding, skipping, and leaving its lines out. A span someone marked goes
    /// away; a detected one stays as dismissed so detecting again doesn't bring it back.
    mutating func dismissSponsor(_ id: UUID) {
        guard var list = sponsors, let i = list.firstIndex(where: { $0.id == id }) else { return }
        if list[i].source == .person { list.remove(at: i) } else { list[i].dismissed = true }
        sponsors = list
    }

    /// "Mark as sponsor" on a line: joins the read right before or after it (so marking line by line grows one
    /// read), or starts a new one. A line in a dismissed stretch brings that span back.
    mutating func markSponsor(segment id: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = segments[i]
        var list = sponsors ?? []
        let mid = (seg.start + seg.end) / 2
        if let d = list.firstIndex(where: { $0.dismissed && mid >= $0.start && mid < $0.end }) {
            list[d].dismissed = false; list[d].source = .person
            sponsors = list.sorted { $0.start < $1.start }
            return
        }
        let active = list.indices.filter { !list[$0].dismissed }
        func spanIndex(of j: Int) -> Int? {
            guard segments.indices.contains(j) else { return nil }
            let m = (segments[j].start + segments[j].end) / 2
            return active.first { m >= list[$0].start && m < list[$0].end }
        }
        let before = spanIndex(of: i - 1), after = spanIndex(of: i + 1)
        switch (before, after) {
        case let (b?, a?) where b != a:
            list[b].end = max(list[a].end, seg.end); list[b].source = .person
            list.remove(at: a)
        case let (b?, _):
            list[b].end = max(list[b].end, seg.end); list[b].source = .person
        case let (nil, a?):
            list[a].start = min(list[a].start, seg.start); list[a].source = .person
        default:
            list.append(SponsorSpan(start: seg.start, end: seg.end, source: .person))
        }
        sponsors = list.sorted { $0.start < $1.start }
    }
}

/// How a list of shown lines folds: each line's read, if any, and whether it's the read's first shown line.
enum SponsorFold {
    struct Place: Equatable {
        var span: SponsorSpan
        var first: Bool
    }

    /// One entry per line in `segments` (nil outside a read). `segments` is what the transcript shows, so lines it
    /// hides (filler) don't start a second fold.
    static func places(_ segments: [Segment], in t: Transcript) -> [Place?] {
        let spans = t.sponsorSpans
        guard !spans.isEmpty else { return Array(repeating: nil, count: segments.count) }
        var out: [Place?] = []
        out.reserveCapacity(segments.count)
        var last: UUID? = nil
        for s in segments {
            if let sp = t.sponsorSpan(for: s, in: spans) {
                out.append(Place(span: sp, first: sp.id != last))
                last = sp.id
            } else {
                out.append(nil); last = nil
            }
        }
        return out
    }

    /// "Sponsor: Good Ranchers · 1:12", or "Sponsor · 1:12" without a name.
    static func title(_ span: SponsorSpan) -> String {
        let length = length(span.end - span.start)
        if let n = span.name, !n.isEmpty { return "Sponsor: \(n) · \(length)" }
        return "Sponsor · \(length)"
    }

    /// "1:12", "12:04", "1:02:14".
    static func length(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Skipping sponsor reads in playback. Only crossing into a read skips it: tapping a line inside one, or dragging
/// the playhead into it, plays it, so people can still listen when they choose to.
enum SponsorSkip {
    /// Where to jump when playback moved from `previous` to `now`: the end of a read whose start it just crossed.
    /// nil when it didn't cross one, or when the read is nearly over anyway.
    static func target(from previous: Double, to now: Double, spans: [(start: Double, end: Double)]) -> Double? {
        // A jump bigger than a few ticks is a seek, not playback.
        guard now >= previous, now - previous < 2 else { return nil }
        guard var to = spans.first(where: { previous < $0.start && now >= $0.start && now < $0.end - 1 })?.end else { return nil }
        // Back-to-back reads go in one jump.
        while let next = spans.first(where: { $0.start <= to + 0.5 && $0.end > to + 0.5 }) { to = next.end }
        return to
    }
}
