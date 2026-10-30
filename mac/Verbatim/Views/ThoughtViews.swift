import SwiftUI

// brand: web style
//
// Thoughts' drawings (mockup "Thoughts", section 09): the Thoughts icon with a wave that follows the mic while a thought
// records, the empty-day illustration that plays once, and Ways in, the top of the iPhone's Settings › Thoughts.
// Shared by the Mac and the iPhone (SwiftUI only).

/// The Thoughts icon (`BrandArt.iconThought`) with its wave drawn on its own, so the wave can follow your voice.
/// `level` is the mic level (0…1) while a thought records, nil at rest. It never moves on its own; with Limit
/// animation or Reduce Motion it holds one shape while recording.
struct ThoughtGlyph: View {
    var level: Double? = nil
    var color: Color = Refined.ink
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
                ArtPath(d: Self.corner, t: t).fill(Refined.butter)
                ArtPath(d: Self.page, t: t).stroke(Refined.ink, style: stroke)
                ArtPath(d: Self.fold, t: t).stroke(Refined.ink, style: stroke)
                ForEach(Self.rules.indices, id: \.self) { i in
                    ArtPath(d: Self.rules[i], t: t).stroke(Refined.ink.opacity(0.45), lineWidth: max(0.8, s))
                }
                ForEach(0..<3, id: \.self) { i in
                    let r = Self.ringSpecs[i]
                    Circle().stroke(Refined.ink, lineWidth: w)
                        .frame(width: 2 * r.2 * s, height: 2 * r.2 * s)
                        .position(x: ox + r.0 * s, y: oy + r.1 * s)
                        .scaleEffect(rings[i] ? 1 : 0.4, anchor: UnitPoint(x: (ox + r.0 * s) / max(1, g.size.width), y: (oy + r.1 * s) / max(1, g.size.height)))
                        .opacity(rings[i] ? 1 : 0)
                }
                ArtPath(d: Self.wire, t: t).trim(from: 1 - line, to: 1).stroke(Refined.ink, style: stroke)
                Circle().fill(Refined.persimmon)
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

// MARK: - Ways in

/// "Ways in" (section 09): the Mac with the floating bubble, the iPhone with the Dynamic Island, a widget, the Action
/// button, and Back Tap (two tap rings), each joined by a dashed line to one persimmon dot, one thought. Butter marks
/// dictation (§1). Plays once each time the page it's on opens: each dashed line runs toward the dot in turn, then
/// the dot appears. Still under Limit animation and Reduce Motion.
struct WaysInArt: View {
    /// Plays the drawing in; false shows it finished.
    var play: Bool
    @Environment(\.limitMotion) private var limitMotion
    @State private var lines: [Bool] = Array(repeating: true, count: 5)
    @State private var dot: CGFloat = 1

    private static let box = CGSize(width: 640, height: 360)
    /// Ink strokes: the Mac, the phone's Dynamic Island, the widget's line, and the Action button's edge.
    private static let strokes: [(String, CGFloat)] = [
        ("M118 52H236C239.3 52 242 54.7 242 58V128H112V58C112 54.7 114.7 52 118 52Z", 2),
        ("M120 60H234V120H120Z", 1.6), ("M96 128H258L266 138H88Z", 2), ("M156 133H198", 1.6),
        ("M474 48H492", 2), ("M112 272H146", 1.6),
        ("M322 254V330", 2), ("M330 254V330", 2),
        ("M330 276H334C335.1 276 336 276.9 336 278V296C336 297.1 335.1 298 334 298H330", 2),
    ]
    private static let butterFills = ["M330 276H334C335.1 276 336 276.9 336 278V296C336 297.1 335.1 298 334 298H330Z"]
    /// The phone's front, the widget tile, and the phone's back: x, y, width, height, corner radius.
    private static let tiles: [CGRect] = [CGRect(x: 452, y: 38, width: 62, height: 118), CGRect(x: 98, y: 226, width: 62, height: 62),
                                          CGRect(x: 500, y: 208, width: 62, height: 118)]
    private static let butterDots: [(CGFloat, CGFloat, CGFloat)] = [(226, 34, 7), (117, 245, 8), (538, 272, 4)]
    /// Ink rings: the bubble, the camera lenses, and Back Tap's two rings (the outer one dashed).
    private static let rings: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [(226, 34, 7, 2, false), (514, 222, 5, 1.6, false),
                                                                             (514, 236, 5, 1.6, false), (538, 272, 9, 1.6, false),
                                                                             (538, 272, 15, 1.6, true)]
    private static let dashes = ["M246 104C290 116 296 168 312 184", "M446 112C410 136 362 166 336 184",
                                 "M166 252C214 240 270 214 312 196", "M326 246C318 232 320 214 322 202",
                                 "M494 252C450 232 380 210 340 196"]

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / Self.box.width, g.size.height / Self.box.height)
            let ox = (g.size.width - Self.box.width * s) / 2, oy = (g.size.height - Self.box.height * s) / 2
            let t = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
            let round = { (w: CGFloat) in Self.line(w, scale: s) }
            ZStack {
                ForEach(Self.butterFills.indices, id: \.self) { i in ArtPath(d: Self.butterFills[i], t: t).fill(Refined.butter) }
                ForEach(Self.butterDots.indices, id: \.self) { i in
                    let c = Self.butterDots[i]
                    ArtShape(path: Path(ellipseIn: CGRect(x: c.0 - c.2, y: c.1 - c.2, width: 2 * c.2, height: 2 * c.2)), t: t).fill(Refined.butter)
                }
                ForEach(Self.strokes.indices, id: \.self) { i in
                    ArtPath(d: Self.strokes[i].0, t: t).stroke(Refined.ink, style: round(Self.strokes[i].1))
                }
                ForEach(Self.tiles.indices, id: \.self) { i in
                    ArtShape(path: Path(roundedRect: Self.tiles[i], cornerRadius: 12), t: t).stroke(Refined.ink, style: round(2))
                }
                ForEach(Self.rings.indices, id: \.self) { i in
                    let c = Self.rings[i]
                    ArtShape(path: Path(ellipseIn: CGRect(x: c.0 - c.2, y: c.1 - c.2, width: 2 * c.2, height: 2 * c.2)), t: t)
                        .stroke(Refined.ink, style: Self.line(c.3, scale: s, dash: c.4 ? [3, 4] : []))
                }
                ForEach(Self.dashes.indices, id: \.self) { i in
                    ArtPath(d: Self.dashes[i], t: t).trim(from: 0, to: lines[i] ? 1 : 0).stroke(Refined.ink, style: Self.line(1.6, scale: s, dash: [5, 6]))
                        .opacity(lines[i] ? 1 : 0)
                }
                Circle().fill(Refined.persimmon)
                    .frame(width: 20 * s, height: 20 * s)
                    .scaleEffect(dot)
                    .position(x: ox + 324 * s, y: oy + 191 * s)
            }
        }
        .aspectRatio(Self.box.width / Self.box.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A Mac, an iPhone, a widget, the Action button, and the back of an iPhone, each joined to one thought")
        .onAppear { if play && !limitMotion { run() } }
    }

    /// A round-ended line `w` units wide in the drawing, dashed in drawing units.
    private static func line(_ w: CGFloat, scale s: CGFloat, dash: [CGFloat] = []) -> StrokeStyle {
        StrokeStyle(lineWidth: max(0.8, w * s), lineCap: .round, lineJoin: .round, dash: dash.map { $0 * s })
    }

    private func run() {
        lines = Array(repeating: false, count: 5); dot = 0
        for i in 0..<5 {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.52).delay(Double(i) * 0.11)) { lines[i] = true }
        }
        let d = 5 * 0.11 + 0.26
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.21).delay(d)) { dot = 1.2 }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.09).delay(d + 0.21)) { dot = 1 }
    }
}

/// A ready-made path in the drawing's coordinates, placed in the view.
private struct ArtShape: Shape {
    var path: Path
    var t: CGAffineTransform
    func path(in r: CGRect) -> Path { path.applying(t) }
}

/// One path of the 600 × 400 drawing, placed in the view.
private struct ArtPath: Shape {
    var d: String
    var t: CGAffineTransform
    func path(in r: CGRect) -> Path { Path(SVGPathData.cached(d)).applying(t) }
}
