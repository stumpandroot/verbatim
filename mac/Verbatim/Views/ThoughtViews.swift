import SwiftUI
import AppKit

// brand: web style
//
// Thoughts' drawings (mockup "Thoughts", section 09): the Thoughts icon with a wave that follows the mic while a thought
// records, and the empty-day illustration that plays once.

/// The Thoughts icon (`BrandArt.iconThought`) with its wave drawn on its own, so the wave can follow your voice.
/// `level` is the mic level (0…1) while a thought records, nil at rest. It never moves on its own; with Limit
/// animation or Reduce Motion it holds one shape while recording.
struct ThoughtGlyph: View {
    var level: Double? = nil
    var color: Color = Ink.ink
    var lineWidth: CGFloat = 1.3
    @Environment(\.limitMotion) private var limitMotion

    /// The wave's height above and below its line, in the icon's 24-unit grid.
    static let rest: CGFloat = 1.7
    static func amplitude(level: Double?, still: Bool) -> CGFloat {
        guard let level else { return rest }
        return still ? 1.2 : 0.35 + CGFloat(min(max(level, 0), 1)) * 1.95
    }

    var body: some View {
        let amp = Self.amplitude(level: level, still: limitMotion)
        ZStack {
            ThoughtBulbShape().stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            ThoughtWaveShape(amplitude: amp).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .animation(limitMotion || level == nil ? .easeOut(duration: 0.18) : .easeOut(duration: 0.09), value: amp)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The icon without its wave: the bulb and the base.
struct ThoughtBulbShape: Shape {
    func path(in r: CGRect) -> Path {
        let art = BrandArt.iconThought
        let s = min(r.width, r.height) / art.box.width
        let t = CGAffineTransform(translationX: r.midX - art.box.midX * s, y: r.midY - art.box.midY * s).scaledBy(x: s, y: s)
        return Path(BrandArt.cgPath(Array(art.strokes.dropLast()))).applying(t)
    }
}

/// The filament: a short sound wave whose height can change smoothly.
struct ThoughtWaveShape: Shape {
    var amplitude: CGFloat
    var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 24
        let ox = r.midX - 12 * s, oy = r.midY - 12 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let a = amplitude
        var path = Path()
        path.move(to: p(8.4, 9.5))
        path.addCurve(to: p(10.4, 9.5 - a), control1: p(9.3, 9.5), control2: p(9.5, 9.5 - a))
        path.addCurve(to: p(13.6, 9.5 + a), control1: p(11.3, 9.5 - a), control2: p(12.6, 9.5 + a))
        path.addCurve(to: p(15.6, 9.5), control1: p(14.6, 9.5 + a), control2: p(14.7, 9.5))
        return path
    }
}

// MARK: - Empty day

/// "Empty day" (section 09): a blank page; three tangent rings come off its edge; one line runs back to where the voice
/// started (the persimmon dot). The first time a day's page is empty it plays once: the dot appears, the line draws
/// from it into the rings, and the rings land on the page, in about a second. After that it shows the finished
/// drawing. Still under Limit animation and Reduce Motion.
struct EmptyDayArt: View {
    /// Plays the drawing in (once); false shows it finished.
    var play: Bool
    @Environment(\.limitMotion) private var limitMotion
    @State private var dot: CGFloat = 1
    @State private var line: CGFloat = 1
    @State private var rings: [Bool] = [true, true, true]

    private static let box = CGSize(width: 600, height: 400)
    private static let page = "M62 48H272L292 68V352H62Z"
    private static let fold = "M272 48V68H292"
    private static let corner = "M272 48V68H292Z"
    private static let rules = (0..<9).map { "M88 \(96 + $0 * 26)H266" }
    private static let ringSpecs: [(CGFloat, CGFloat, CGFloat)] = [(305, 150, 13), (340, 146, 22), (392, 134, 31)]
    private static let wire = "M392 165C436 170 452 210 462 248C472 286 486 306 512 300C532 295 532 270 514 268C494 266 500 300 524 316C540 326 556 330 572 331"

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / Self.box.width, g.size.height / Self.box.height)
            let ox = (g.size.width - Self.box.width * s) / 2, oy = (g.size.height - Self.box.height * s) / 2
            let t = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
            let w = max(1.2, 2 * s)
            let stroke = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
            ZStack {
                ArtPath(d: Self.corner, t: t).fill(Ink.butter)
                ArtPath(d: Self.page, t: t).stroke(Ink.ink, style: stroke)
                ArtPath(d: Self.fold, t: t).stroke(Ink.ink, style: stroke)
                ForEach(Self.rules.indices, id: \.self) { i in
                    ArtPath(d: Self.rules[i], t: t).stroke(Ink.ink.opacity(0.45), lineWidth: max(0.8, s))
                }
                ForEach(0..<3, id: \.self) { i in
                    let r = Self.ringSpecs[i]
                    Circle().stroke(Ink.ink, lineWidth: w)
                        .frame(width: 2 * r.2 * s, height: 2 * r.2 * s)
                        .position(x: ox + r.0 * s, y: oy + r.1 * s)
                        .scaleEffect(rings[i] ? 1 : 0.4, anchor: UnitPoint(x: (ox + r.0 * s) / max(1, g.size.width), y: (oy + r.1 * s) / max(1, g.size.height)))
                        .opacity(rings[i] ? 1 : 0)
                }
                ArtPath(d: Self.wire, t: t).trim(from: 1 - line, to: 1).stroke(Ink.ink, style: stroke)
                Circle().fill(Ink.persimmon)
                    .frame(width: 12 * s, height: 12 * s)
                    .scaleEffect(dot)
                    .position(x: ox + 574 * s, y: oy + 331 * s)
            }
        }
        .aspectRatio(Self.box.width / Self.box.height, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear { if play && !limitMotion { run() } }
    }

    private func run() {
        dot = 0; line = 0; rings = [false, false, false]
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)) { dot = 1.25 }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.08).delay(0.18)) { dot = 1 }
        withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: 0.76).delay(0.16)) { line = 1 }
        // The biggest ring lands first, where the line arrives.
        for (n, i) in [2, 1, 0].enumerated() {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3).delay(0.82 + Double(n) * 0.11)) { rings[i] = true }
        }
    }

    /// Whether today's empty page plays the drawing: once per day, the first time it's empty.
    @MainActor static func shouldPlay(day: Date) -> Bool {
        let key = "thoughts.emptyPlayedDay"
        let stamp = Formats.pattern("yyyy-MM-dd").string(from: day)
        guard UserDefaults.standard.string(forKey: key) != stamp else { return false }
        UserDefaults.standard.set(stamp, forKey: key)
        return true
    }
}

/// One path of the 600 × 400 drawing, placed in the view.
private struct ArtPath: Shape {
    var d: String
    var t: CGAffineTransform
    func path(in r: CGRect) -> Path { Path(SVGPathData.cached(d)).applying(t) }
}
