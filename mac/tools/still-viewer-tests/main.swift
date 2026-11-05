import Foundation

// The stills viewer (Model/StillViewerRules.swift): the order it steps through, where ← and → land, the caption and
// VoiceOver label, and how far a still zooms. Not part of any app target; run mac/tools/test-still-viewer.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

// Order: by time, ties in their stored order (an imported video's stills and a call's both store times).
struct Still { var at: Double; var file: String }
let stored = [Still(at: 724, file: "c"), Still(at: 12, file: "a"), Still(at: 300, file: "b1"), Still(at: 300, file: "b2")]
let order = StillViewerRules.ordered(stored, at: \.at).map(\.file)
check("stills step in time order, ties as stored", order == ["a", "b1", "b2", "c"], "\(order)")
check("no stills, no order", StillViewerRules.ordered([Still](), at: \.at).isEmpty)

// Opening on the clicked still.
check("opens on the clicked still", StillViewerRules.startIndex(file: "b2", in: order) == 2)
check("a still that's gone opens the first", StillViewerRules.startIndex(file: "zz", in: order) == 0)

// Stepping: held at both ends, no wrap-around.
check("→ moves one on", StillViewerRules.step(0, by: 1, count: 9) == 1)
check("← moves one back", StillViewerRules.step(4, by: -1, count: 9) == 3)
check("→ on the last stays on the last", StillViewerRules.step(8, by: 1, count: 9) == 8)
check("← on the first stays on the first", StillViewerRules.step(0, by: -1, count: 9) == 0)
check("a big step stops at the end", StillViewerRules.step(2, by: 50, count: 9) == 8 && StillViewerRules.step(2, by: -50, count: 9) == 0)
check("one still never moves", StillViewerRules.step(0, by: 1, count: 1) == 0 && StillViewerRules.step(0, by: -1, count: 1) == 0)
check("no stills lands on 0", StillViewerRules.step(3, by: 1, count: 0) == 0)
check("an index past the end after a still goes is held to the last", StillViewerRules.clamp(9, count: 7) == 6 && StillViewerRules.clamp(-2, count: 7) == 0)
check("previous and next exist only between the ends",
      !StillViewerRules.hasPrevious(0, count: 9) && StillViewerRules.hasNext(0, count: 9)
      && StillViewerRules.hasPrevious(8, count: 9) && !StillViewerRules.hasNext(8, count: 9)
      && !StillViewerRules.hasPrevious(0, count: 1) && !StillViewerRules.hasNext(0, count: 1)
      && !StillViewerRules.hasNext(0, count: 0))

// Caption and VoiceOver.
check("caption is the transcript's time", StillViewerRules.caption(724) == "12:04" && StillViewerRules.caption(5.9) == "0:05")
check("caption past an hour", StillViewerRules.caption(3734) == "1:02:14")
check("position reads 3 of 9", StillViewerRules.position(2, count: 9) == "3 of 9")
check("position holds a stale index", StillViewerRules.position(12, count: 9) == "9 of 9")
check("VoiceOver label: Still at 12:04, 3 of 9", StillViewerRules.spokenLabel(at: 724, index: 2, count: 9) == "Still at 12:04, 3 of 9",
      StillViewerRules.spokenLabel(at: 724, index: 2, count: 9))
let copy = [StillViewerRules.spokenLabel(at: 724, index: 2, count: 9), StillViewerRules.position(0, count: 1)]
check("copy has no em dashes or exclamation points", copy.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") })

// Zoom: fitting.
let wide = StillZoom.fit(imageWidth: 1280, imageHeight: 720, viewportWidth: 640, viewportHeight: 640)
check("a wide still fits by its width", near(wide, 0.5), "\(wide)")
let tall = StillZoom.fit(imageWidth: 360, imageHeight: 640, viewportWidth: 900, viewportHeight: 640)
check("a tall still fits by its height", near(tall, 1), "\(tall)")
let small = StillZoom.fit(imageWidth: 360, imageHeight: 203, viewportWidth: 1080, viewportHeight: 700)
check("a small video still grows to fit the window", near(small, 3), "\(small)")
check("no size yet fits at 1", StillZoom.fit(imageWidth: 0, imageHeight: 720, viewportWidth: 640, viewportHeight: 640) == 1
      && StillZoom.fit(imageWidth: 1280, imageHeight: 720, viewportWidth: 0, viewportHeight: 0) == 1)

// Zoom: limits.
check("zooms in to 4 times the fitted size", near(StillZoom.maxScale(fit: 3), 12))
check("or twice the still's own size, whichever is more", near(StillZoom.maxScale(fit: 0.25), 2))
check("never smaller than fitting", near(StillZoom.clamp(0.1, fit: 0.5), 0.5))
check("never past the most", near(StillZoom.clamp(40, fit: 0.5), 2))
check("a bad scale fits", near(StillZoom.clamp(.nan, fit: 0.5), 0.5) && near(StillZoom.clamp(.infinity, fit: 0.5), 0.5))

// Zoom: ⌘+ and ⌘−.
check("⌘+ steps in by half again", near(StillZoom.zoomIn(0.5, fit: 0.5), 0.75))
check("⌘+ stops at the most", near(StillZoom.zoomIn(1.9, fit: 0.5), 2))
check("⌘− steps out", near(StillZoom.zoomOut(1.5, fit: 0.5), 1))
check("⌘− near fitting comes back to fitting", near(StillZoom.zoomOut(0.78, fit: 0.5), 0.5))
check("⌘− at fitting stays", near(StillZoom.zoomOut(0.5, fit: 0.5), 0.5))
var s = 0.5
for _ in 0..<20 { s = StillZoom.zoomIn(s, fit: 0.5) }
check("⌘+ held stops at the most", near(s, 2))
for _ in 0..<20 { s = StillZoom.zoomOut(s, fit: 0.5) }
check("⌘− held comes all the way back", near(s, 0.5))

// Zoom: zoomed and double-tap.
check("fitting isn't zoomed", !StillZoom.isZoomed(0.5, fit: 0.5) && !StillZoom.isZoomed(0.504, fit: 0.5))
check("past fitting is zoomed", StillZoom.isZoomed(0.6, fit: 0.5))
check("double-tap zooms in", near(StillZoom.doubleTap(0.5, fit: 0.5), 1.25))
check("double-tap again fits", near(StillZoom.doubleTap(1.25, fit: 0.5), 0.5))
check("double-tap zoom stays inside the most", near(StillZoom.doubleTap(3, fit: 3), 7.5) && StillZoom.doubleTap(3, fit: 3) <= StillZoom.maxScale(fit: 3))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
