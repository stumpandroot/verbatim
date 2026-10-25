import Foundation

/// The transcript scrubber's arithmetic (TranscriptScrubber.swift), with no UI so it runs in the Linux tests
/// (`mac/tools/test-scrub.sh`). A line is known by its start time; `end` is when the last line ends (`scaleEnd`), never
/// the stored duration, which can be wrong (an early import stored twice the real length).
///
/// One scale, both ways: the handle sits at the fraction of the line at the top of the screen (`fraction(of:)`), and a
/// drag to a fraction lands on the line `index(at:)` names, which `fraction(of:)` maps back to within one line.
///
/// - Paced by time when the lines have real times, so an even drag moves evenly through the recording. Otherwise
///   (a transcript with no timings) paced by line.
/// - Ticks: one minute, or a longer step on long recordings, so the haptic never fires more often than about once
///   every 18 points of track. Paced by line, a tick is a run of lines with the same spacing.
enum ScrubMath {
    /// The scrubber shows only on transcripts taller than about three screens.
    static func shows(contentHeight: Double, viewport: Double, screens: Double = 3) -> Bool {
        viewport > 0 && contentHeight > viewport * screens
    }

    /// The end of the scale: when the last line ends (or starts, if its end is missing). Zero without timings.
    static func scaleEnd(starts: [Double], ends: [Double]) -> Double {
        max(0, max(starts.max() ?? 0, ends.max() ?? 0))
    }

    /// Where the handle sits while you scroll: at the line at the top of the screen (`top`, its `fraction(of:)`), and
    /// over the last screenful, which can't scroll its top line any higher, eased to 1 as the remaining distance to
    /// the bottom (`remaining`, in points) falls from one screen (`visible`) to zero.
    static func progress(top: Double, remaining: Double, visible: Double) -> Double {
        let p = min(1, max(0, top))
        guard visible > 0, remaining < visible else { return p }
        let near = 1 - max(0, remaining) / visible
        return min(1, p + (1 - p) * near)
    }

    /// The handle's center on a track `track` points tall: the top of its travel at 0, the bottom at 1, so the
    /// handle stays whole at both ends.
    static func handleCenter(_ fraction: Double, track: Double, handle: Double) -> Double {
        handle / 2 + min(1, max(0, fraction)) * max(0, track - handle)
    }

    /// The fraction a point on the track names (the inverse of `handleCenter`, clamped to 0...1). `y` is measured
    /// from the top of the track.
    static func fraction(atY y: Double, track: Double, handle: Double) -> Double {
        let travel = track - handle
        guard travel > 0 else { return 0 }
        return min(1, max(0, (y - handle / 2) / travel))
    }

    /// True when most lines have distinct, usable start times.
    static func pacedByTime(starts: [Double], end: Double) -> Bool {
        guard starts.count > 1, end > 0 else { return false }
        return Set(starts).count * 2 >= starts.count
    }

    /// The line a fraction of the track (0 at the top, 1 at the bottom) lands on.
    static func index(at fraction: Double, starts: [Double], end: Double) -> Int {
        guard !starts.isEmpty else { return 0 }
        let f = min(1, max(0, fraction))
        guard pacedByTime(starts: starts, end: end) else {
            return min(starts.count - 1, Int((f * Double(starts.count - 1)).rounded()))
        }
        // A microsecond of slack, so a line's own fraction (start / end) lands back on it despite rounding.
        return line(at: f * end + 1e-6, starts: starts)
    }

    /// The last line that starts at or before `time` (the first line before any start).
    static func line(at time: Double, starts: [Double]) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    /// Where a line sits on the track, 0...1.
    static func fraction(of index: Int, starts: [Double], end: Double) -> Double {
        guard starts.count > 1, starts.indices.contains(index) else { return 0 }
        if pacedByTime(starts: starts, end: end) { return min(1, max(0, starts[index] / end)) }
        return Double(index) / Double(starts.count - 1)
    }

    /// The haptic step in seconds: a minute, or the shortest of 2, 5, 10, 15, 30, or 60 minutes that leaves at
    /// least `minSpacing` points of track between ticks.
    static func step(duration: Double, trackHeight: Double, minSpacing: Double = 18) -> Double {
        let steps: [Double] = [60, 120, 300, 600, 900, 1800, 3600]
        guard duration > 0, trackHeight > 0 else { return 60 }
        let most = max(1, trackHeight / minSpacing)
        return steps.first { duration / $0 <= most } ?? steps[steps.count - 1]
    }

    /// Lines per tick when paced by line: enough that ticks are at least `minSpacing` points apart.
    static func lineStep(count: Int, trackHeight: Double, minSpacing: Double = 18) -> Int {
        guard count > 0, trackHeight > 0 else { return 1 }
        let most = max(1, trackHeight / minSpacing)
        return max(1, Int((Double(count) / most).rounded(.up)))
    }

    /// Where the ticks the haptic marks sit on the track, 0...1 on the drag's scale, ends left out: each step of
    /// time when paced by time, each `lineStep` lines otherwise. `trackHeight` is the handle's travel.
    static func tickFractions(starts: [Double], end: Double, trackHeight: Double, minSpacing: Double = 18) -> [Double] {
        guard starts.count > 1 else { return [] }
        if pacedByTime(starts: starts, end: end) {
            let s = step(duration: end, trackHeight: trackHeight, minSpacing: minSpacing)
            return stride(from: s, to: end, by: s).map { $0 / end }
        }
        let n = lineStep(count: starts.count, trackHeight: trackHeight, minSpacing: minSpacing)
        return stride(from: n, to: starts.count - 1, by: n).map { Double($0) / Double(starts.count - 1) }
    }

    /// The tick a line falls in; the haptic fires when it changes.
    static func tick(index: Int, starts: [Double], end: Double, trackHeight: Double) -> Int {
        guard starts.indices.contains(index) else { return 0 }
        if pacedByTime(starts: starts, end: end) {
            return Int(starts[index] / step(duration: end, trackHeight: trackHeight))
        }
        return index / lineStep(count: starts.count, trackHeight: trackHeight)
    }

    /// VoiceOver's swipe up or down: the line one minute later (`direction` 1) or earlier (-1). Paced by line, a
    /// step of `lineStep` lines. Always moves at least one line when there's one to move to.
    static func stepped(from index: Int, direction: Int, starts: [Double], end: Double, trackHeight: Double, seconds: Double = 60) -> Int {
        guard !starts.isEmpty else { return 0 }
        let i = min(starts.count - 1, max(0, index))
        let next: Int
        if pacedByTime(starts: starts, end: end) {
            let target = starts[i] + Double(direction) * seconds
            next = line(at: target, starts: starts)
        } else {
            next = i + direction * lineStep(count: starts.count, trackHeight: trackHeight)
        }
        let clamped = min(starts.count - 1, max(0, next))
        if clamped == i, direction != 0 { return min(starts.count - 1, max(0, i + direction)) }
        return clamped
    }
}
