import Foundation

// The stills viewer's pure rules (DESIGN.md §6.9, Stills viewer), shared by the Mac viewer (Views/StillViewer.swift)
// and the iPhone's (VerbatimPhone/StillViewerScreen.swift): the order it steps through a transcript's stills, where a
// step lands, how far a still zooms, and what its caption and VoiceOver label say. Foundation only, so
// mac/tools/test-still-viewer.sh compiles it on Linux with RefinedRules (for the time).

/// Stepping through a transcript's stills and naming the one on screen.
enum StillViewerRules {
    /// The order the viewer steps through stills: by time, ties kept in their stored order.
    static func ordered<T>(_ items: [T], at time: (T) -> Double) -> [T] {
        items.enumerated()
            .sorted { a, b in
                let ta = time(a.element), tb = time(b.element)
                return ta != tb ? ta < tb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The still a step lands on: `delta` places from `index`, held at the first and the last. No wrap-around, so
    /// holding → stops on the last still instead of jumping back to the first.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, index + delta))
    }

    /// `index` held inside the stills there are (a still can go while the viewer is open, when its transcript syncs).
    static func clamp(_ index: Int, count: Int) -> Int { step(index, by: 0, count: count) }

    /// Whether there's a still before or after `index`.
    static func hasPrevious(_ index: Int, count: Int) -> Bool { count > 0 && clamp(index, count: count) > 0 }
    static func hasNext(_ index: Int, count: Int) -> Bool { count > 0 && clamp(index, count: count) < count - 1 }

    /// Where the viewer opens: the clicked still's place among the stills in viewing order, or the first.
    static func startIndex(file: String, in files: [String]) -> Int { files.firstIndex(of: file) ?? 0 }

    /// The caption: the still's time as the transcript writes it ("12:04", "1:02:14").
    static func caption(_ seconds: Double) -> String { RefinedRules.time(seconds) }

    /// "3 of 9".
    static func position(_ index: Int, count: Int) -> String {
        "\(clamp(index, count: count) + 1) of \(max(count, 1))"
    }

    /// VoiceOver's label for a still, in the margin and in the viewer: "Still at 12:04, 3 of 9".
    static func spokenLabel(at seconds: Double, index: Int, count: Int) -> String {
        "Still at \(caption(seconds)), \(position(index, count: count))"
    }
}

/// How far a still zooms. Scales are points per image pixel: 1 draws the still at its own size, and `fit` is the
/// scale that shows all of it in the space there is (above 1 for a small still in a big window).
enum StillZoom {
    /// ⌘+ and ⌘− (and the iPhone's zoom buttons) multiply or divide the scale by this.
    static let step = 1.5
    /// Double-tap on iPhone zooms to this many times the fitted size.
    static let doubleTapFactor = 2.5

    /// The scale that fits the whole still in `viewportWidth` by `viewportHeight`. 1 when either has no size yet.
    static func fit(imageWidth: Double, imageHeight: Double, viewportWidth: Double, viewportHeight: Double) -> Double {
        guard imageWidth > 0, imageHeight > 0, viewportWidth > 0, viewportHeight > 0 else { return 1 }
        return min(viewportWidth / imageWidth, viewportHeight / imageHeight)
    }

    /// The most it zooms in: four times the fitted size, or twice the still's own size, whichever is more.
    static func maxScale(fit: Double) -> Double { max(fit * 4, 2) }

    /// `scale` held between fitting the still and `maxScale`.
    static func clamp(_ scale: Double, fit: Double) -> Double {
        guard scale.isFinite else { return fit }
        return min(maxScale(fit: fit), max(fit, scale))
    }

    /// One step in.
    static func zoomIn(_ scale: Double, fit: Double) -> Double { clamp(scale * step, fit: fit) }

    /// One step out; within 5% of fitting, it fits, so ⌘− always comes back to the whole still.
    static func zoomOut(_ scale: Double, fit: Double) -> Double {
        let out = scale / step
        return out < fit * 1.05 ? fit : clamp(out, fit: fit)
    }

    /// Zoomed in past fitting (by more than 1%): the iPhone's pages stop swiping, and a resize keeps the scale.
    static func isZoomed(_ scale: Double, fit: Double) -> Bool { scale > fit * 1.01 }

    /// A double-tap: back to fitting when zoomed in, else `doubleTapFactor` times the fitted size.
    static func doubleTap(_ scale: Double, fit: Double) -> Double {
        isZoomed(scale, fit: fit) ? fit : clamp(fit * doubleTapFactor, fit: fit)
    }
}
