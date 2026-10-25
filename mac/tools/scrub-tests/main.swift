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

// One scale, both ways: a drag to a fraction lands on a line, and that line maps back to within one line of it.
func roundTrips(_ st: [Double], _ e: Double) -> Bool {
    for k in 0...400 {
        let f = Double(k) / 400
        let i = ScrubMath.index(at: f, starts: st, end: e)
        let back = ScrubMath.fraction(of: i, starts: st, end: e)
        let span: Double
        if ScrubMath.pacedByTime(starts: st, end: e) {
            let next = i + 1 < st.count ? st[i + 1] : e
            span = (next - st[i]) / e
        } else {
            span = 1 / Double(st.count - 1)
        }
        if abs(back - f) > span + 1e-9 { print("    f \(f) -> line \(i) -> \(back)"); return false }
    }
    return st.indices.allSatisfy { ScrubMath.index(at: ScrubMath.fraction(of: $0, starts: st, end: e), starts: st, end: e) == $0 }
}
check("fraction to line to fraction round-trips within one line (even lines)", roundTrips(starts, end))
check("fraction to line to fraction round-trips within one line (uneven lines)", roundTrips(uneven, 620))
check("fraction to line to fraction round-trips within one line (no timings)", roundTrips(flat, 0))
var jittered: [Double] = []; var tj = 0.0
for k in 0..<370 { jittered.append(tj); tj += Double(3 + (k * 7919) % 17) }
check("fraction to line to fraction round-trips within one line (podcast pacing)", roundTrips(jittered, tj))

// The scale's end is when the last line ends, never a stored duration. A YouTube import stored 2:03:58 for a
// recording whose last line ends near 1:02; a drag to 40% of the track must land near 25 minutes, not 50.
let podStarts = stride(from: 0.0, to: 3720, by: 12).map { $0 }
let podEnds = podStarts.map { $0 + 11 }
let podEnd = ScrubMath.scaleEnd(starts: podStarts, ends: podEnds)
check("the scale ends with the last line, not the doubled duration", podEnd == podEnds.last! && podEnd < 7438 / 1.9, "\(podEnd)")
let at40 = podStarts[ScrubMath.index(at: 0.4, starts: podStarts, end: podEnd)]
check("a drag to 40% lands at 40% of the lines' time", abs(at40 - 0.4 * podEnd) <= 12, "\(at40)")
check("a drag to the bottom lands on the last line", ScrubMath.index(at: 1, starts: podStarts, end: podEnd) == podStarts.count - 1)
check("fractions 0.25, 0.5, 0.75 land within 1% of the time", [0.25, 0.5, 0.75].allSatisfy { f in
    abs(podStarts[ScrubMath.index(at: f, starts: podStarts, end: podEnd)] / podEnd - f) <= 0.01 })
check("no timings, no scale", ScrubMath.scaleEnd(starts: [0, 0, 0], ends: [0, 0, 0]) == 0 && ScrubMath.scaleEnd(starts: [], ends: []) == 0)

// Where the handle sits while scrolling: the top line's place, and 1 at the bottom of the scroll.
check("the bottom of the scroll is 1.0", ScrubMath.progress(top: 0.93, remaining: 0, visible: 640) == 1)
check("past the bottom (a bounce) is still 1.0", ScrubMath.progress(top: 0.93, remaining: -30, visible: 640) == 1)
check("above the last screenful, the top line's place", ScrubMath.progress(top: 0.5, remaining: 5000, visible: 640) == 0.5
      && ScrubMath.progress(top: 0.6, remaining: 640, visible: 640) == 0.6)
check("the last screenful eases toward 1", ScrubMath.progress(top: 0.9, remaining: 320, visible: 640) == 0.95)
check("the middle line at the top sits at 0.5", abs(ScrubMath.progress(top: ScrubMath.fraction(of: ScrubMath.index(at: 0.5, starts: podStarts, end: podEnd), starts: podStarts, end: podEnd), remaining: 20_000, visible: 640) - 0.5) < 0.005)

// The track: the handle's center reaches both ends, and the finger's height maps back to the same fraction.
check("handle center at the ends of its travel", ScrubMath.handleCenter(0, track: 600, handle: 44) == 22 && ScrubMath.handleCenter(1, track: 600, handle: 44) == 578)
check("finger height and handle center agree", [0.0, 0.1, 0.37, 0.5, 0.9, 1].allSatisfy { f in
    abs(ScrubMath.fraction(atY: ScrubMath.handleCenter(f, track: 600, handle: 44), track: 600, handle: 44) - f) < 1e-9 })
check("a finger past the ends clamps", ScrubMath.fraction(atY: -10, track: 600, handle: 44) == 0 && ScrubMath.fraction(atY: 700, track: 600, handle: 44) == 1
      && ScrubMath.fraction(atY: 10, track: 30, handle: 44) == 0)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
