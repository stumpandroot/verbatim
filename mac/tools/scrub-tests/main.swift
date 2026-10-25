import Foundation

// The transcript scrubber (ScrubMath): when it shows, where a drag lands, the haptic ticks, and VoiceOver's
// one-minute steps. Not part of any app target; run mac/tools/test-scrub.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// A 40-minute talk, a line every 10 seconds.
let starts = stride(from: 0.0, to: 2400, by: 10).map { $0 }
let end = 2400.0

check("shows past three screens", ScrubMath.shows(contentHeight: 2500, viewport: 800))
check("hidden at three screens or fewer", !ScrubMath.shows(contentHeight: 2400, viewport: 800) && !ScrubMath.shows(contentHeight: 900, viewport: 0))

check("paced by time with real timings", ScrubMath.pacedByTime(starts: starts, end: end))
check("paced by line without timings", !ScrubMath.pacedByTime(starts: Array(repeating: 0, count: 50), end: 0)
      && !ScrubMath.pacedByTime(starts: Array(repeating: 0, count: 50), end: 30))

check("top lands on the first line", ScrubMath.index(at: 0, starts: starts, end: end) == 0)
check("bottom lands on the last line", ScrubMath.index(at: 1, starts: starts, end: end) == starts.count - 1)
check("past the ends clamps", ScrubMath.index(at: -0.3, starts: starts, end: end) == 0 && ScrubMath.index(at: 1.4, starts: starts, end: end) == starts.count - 1)
let half = ScrubMath.index(at: 0.5, starts: starts, end: end)
check("halfway lands at 20:00", starts[half] == 1200, "\(starts[half])")
check("fraction and index agree", ScrubMath.fraction(of: half, starts: starts, end: end) == 0.5)

// Uneven lines: one long monologue in the middle. Paced by time, a drag moves evenly through the recording.
let uneven = [0.0, 5, 10, 15, 600, 605, 610]
check("paced by time skips evenly over a long line", ScrubMath.index(at: 0.5, starts: uneven, end: 620) == 3)
check("a time before any start is the first line", ScrubMath.line(at: -5, starts: uneven) == 0)
check("a time after every start is the last line", ScrubMath.line(at: 9_999, starts: uneven) == uneven.count - 1)

// Paced by line.
let flat = Array(repeating: 0.0, count: 101)
check("paced by line, halfway is the middle line", ScrubMath.index(at: 0.5, starts: flat, end: 0) == 50)
check("paced by line, fraction of the last line is 1", ScrubMath.fraction(of: 100, starts: flat, end: 0) == 1)

// Ticks.
check("a minute per tick on a 40-minute talk with a tall track", ScrubMath.step(duration: 2400, trackHeight: 720) == 60)
check("longer steps on a 3-hour recording", ScrubMath.step(duration: 10_800, trackHeight: 600) == 600, "\(ScrubMath.step(duration: 10_800, trackHeight: 600))")
check("never more than one tick per 18 points", [600.0, 2400, 7200, 36_000].allSatisfy { d in
    let s = ScrubMath.step(duration: d, trackHeight: 500); return d / s <= 500 / 18 || s == 3600 })
check("ticks change at each minute, not each line",
      ScrubMath.tick(index: 0, starts: starts, end: end, trackHeight: 720) == ScrubMath.tick(index: 5, starts: starts, end: end, trackHeight: 720)
      && ScrubMath.tick(index: 6, starts: starts, end: end, trackHeight: 720) == 1)
check("line ticks space out on many lines", ScrubMath.lineStep(count: 1000, trackHeight: 540) == 34)

// VoiceOver.
check("swipe up moves a minute later", starts[ScrubMath.stepped(from: 12, direction: 1, starts: starts, end: end, trackHeight: 720)] == 180)
check("swipe down moves a minute earlier", starts[ScrubMath.stepped(from: 12, direction: -1, starts: starts, end: end, trackHeight: 720)] == 60)
check("stops at the ends", ScrubMath.stepped(from: 0, direction: -1, starts: starts, end: end, trackHeight: 720) == 0
      && ScrubMath.stepped(from: starts.count - 1, direction: 1, starts: starts, end: end, trackHeight: 720) == starts.count - 1)
check("a line longer than a minute still moves one line", ScrubMath.stepped(from: 3, direction: 1, starts: [0, 100, 200, 300, 400], end: 500, trackHeight: 720) == 4)
check("paced by line, a step is a run of lines", ScrubMath.stepped(from: 10, direction: 1, starts: Array(repeating: 0, count: 1000), end: 0, trackHeight: 540) == 44)
check("empty transcripts don't crash", ScrubMath.index(at: 0.5, starts: [], end: 0) == 0 && ScrubMath.stepped(from: 0, direction: 1, starts: [], end: 0, trackHeight: 100) == 0)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
