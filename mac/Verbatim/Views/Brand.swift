import SwiftUI

// MARK: - Brand artwork (from Verbatim_Brand_Starter_Kit SVGs)
//
// The kit's SVGs are simple geometry, so they're drawn natively from their own path data (copied verbatim)
// rather than shipped as images: they stay sharp at every size and recolor for dark mode and selection.

/// Parses SVG path data (M L H V C S Q Z, absolute and relative) into a CGPath.
enum SVGPathData {
    static func parse(_ d: String) -> CGMutablePath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        var prev: Character = " "
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" { flush(); tokens.append(String(ch)) }
            else if ch == "," || ch == " " || ch == "\n" || ch == "\t" { flush() }
            else if ch == "-" && !(prev == "e" || prev == "E") { flush(); num.append(ch) }
            else if ch == "." && num.contains(".") { flush(); num.append(ch) }
            else { num.append(ch) }
            prev = ch
        }
        flush()

        var i = 0, cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
        func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        func hasNum() -> Bool { i < tokens.count && Double(tokens[i]) != nil }
        while i < tokens.count {
            if let c = tokens[i].first, tokens[i].count == 1, c.isLetter { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch cmd {
            case "M", "m":
                guard hasNum() else { i += 1; continue }
                cur = pt(n(), n()); start = cur; path.move(to: cur); lastCtrl = nil
                cmd = rel ? "l" : "L"   // subsequent pairs are line-tos
            case "L", "l":
                guard hasNum() else { i += 1; continue }
                cur = pt(n(), n()); path.addLine(to: cur); lastCtrl = nil
            case "H", "h":
                guard hasNum() else { i += 1; continue }
                let x = n(); cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCtrl = nil
            case "V", "v":
                guard hasNum() else { i += 1; continue }
                let y = n(); cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCtrl = nil
            case "C", "c":
                guard hasNum() else { i += 1; continue }
                let c1 = pt(n(), n()), c2 = pt(n(), n()), e = pt(n(), n())
                path.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2
            case "S", "s":
                guard hasNum() else { i += 1; continue }
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(n(), n()), e = pt(n(), n())
                path.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2
            case "Q", "q":
                guard hasNum() else { i += 1; continue }
                let c = pt(n(), n()), e = pt(n(), n())
                path.addQuadCurve(to: e, control: c); cur = e; lastCtrl = nil
            case "Z", "z":
                path.closeSubpath(); cur = start; lastCtrl = nil
                if hasNum() { cmd = rel ? "l" : "L" }   // numbers after Z continue as line-tos (never loop)
            default:
                i += 1
            }
        }
        return path
    }
}

/// One piece of artwork: path data plus circles, lines, and rects, in a design-space box.
struct BrandArt {
    enum Element {
        case path(String)
        case circle(CGFloat, CGFloat, CGFloat)
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    }
    var box: CGRect
    var strokes: [Element] = []
    var fills: [Element] = []
    var strokeWidth: CGFloat = 4.5
    /// Elements drawn only inside the region every `clip` element shares (the hatched Understand intersection:
    /// the part all three circles overlap, not their union).
    var clipped: [Element] = []
    var clip: [Element] = []
    var clippedWidth: CGFloat = 2.4

    static func cgPath(_ els: [Element]) -> CGMutablePath {
        let p = CGMutablePath()
        for e in els {
            switch e {
            case .path(let d): p.addPath(SVGPathData.parse(d))
            case .circle(let x, let y, let r): p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            case .rect(let x, let y, let w, let h, let rx): p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: rx, cornerHeight: rx)
            }
        }
        return p
    }
}

extension BrandArt {
    // The V mark: two pairs of wings meeting in a V (logo SVG, traced and refined by Tim, October 2026).
    static let mark = BrandArt(box: CGRect(x: 363.25, y: 407.09, width: 456.83, height: 346.06), fills: [
        .path("M569.72 558.55 C568.75 558.91 568.39 559.59 567.22 559.81 C562.43 560.72 551.77 555.03 549.12 551.09 L540.3 537.97 C528.45 520.34 518.57 503.48 497.48 495.66 C495.24 494.83 492.35 493.44 489.96 493.29 L470.22 492.01 L415.3 492.01 C410.73 492.0 403.7 486.59 401.54 482.73 L390.86 463.71 L364.01 413.92 C363.25 412.51 363.64 411.58 363.42 410.22 C364.11 409.83 364.18 409.26 365.08 409.26 L466.87 409.26 C482.71 410.13 497.11 418.71 505.42 432.22 L514.78 448.56 L549.24 516.88 L558.38 535.5 L569.72 558.55 Z"),
        .path("M819.49 410.1 C819.56 410.81 820.08 411.21 819.67 411.96 L781.79 481.62 C779.92 485.06 771.7 491.97 767.66 492.01 L698.84 492.01 C675.09 492.28 656.97 516.03 645.16 533.76 C637.2 545.72 630.19 560.5 613.45 559.61 C613.42 558.64 612.85 557.77 613.36 556.76 L633.38 516.89 L676.34 434.0 C681.94 423.19 695.41 413.14 707.19 410.49 C722.35 407.09 762.19 409.0 779.87 409.0 C790.81 409.0 809.76 407.28 819.49 410.1 Z"),
        .path("M768.88 517.05 C768.85 517.37 768.94 517.74 768.78 518.03 L738.31 577.03 C735.58 582.32 725.56 590.21 719.52 590.79 L697.91 592.87 C689.82 593.65 678.38 603.42 674.74 610.39 L664.16 630.68 L609.82 740.13 C608.99 741.82 607.25 743.34 605.89 744.6 C597.23 752.58 585.42 753.15 576.6 745.1 C575.54 744.13 573.82 742.78 573.15 741.5 L561.26 718.53 L506.56 609.08 C503.63 603.23 491.19 593.63 484.62 592.92 L462.08 590.48 C456.28 589.85 449.18 584.21 445.65 579.88 C439.17 571.93 428.63 547.03 423.3 536.66 C419.89 530.04 414.75 523.6 414.48 516.14 C424.84 512.12 437.81 514.0 448.91 514.0 C461.84 514.0 481.4 512.7 493.41 516.65 C516.41 524.22 525.56 545.71 535.69 565.39 L566.12 624.5 C567.93 628.03 571.3 630.6 574.32 632.99 C585.51 641.82 598.19 641.05 609.24 632.36 C612.27 629.97 615.35 627.19 617.19 623.7 L626.01 606.99 C633.1 593.54 640.27 580.01 646.84 566.32 C651.06 557.52 655.17 548.18 660.66 540.1 C666.59 531.37 675.38 523.08 685.0 518.61 C699.41 511.92 716.65 514.0 732.09 514.0 C738.86 514.0 759.82 512.76 764.99 514.55 C766.86 515.2 767.47 516.01 768.88 517.05 Z"),
    ])

    // Interface icons (icon_*.svg, 128 × 128, stroke 4.5, round caps and joins).
    static let iconBox = CGRect(x: 8, y: 8, width: 112, height: 112)
    static let capture = BrandArt(box: iconBox, strokes: [.rect(50, 21, 28, 51, 14), .path("M38 59c0 21 11 33 26 33s26-12 26-33 M64 92v16 M47 108h34")])
    static let refine = BrandArt(box: iconBox, strokes: [.path("M24 83h49 M24 69h59 M24 55h39 M27 41h54"), .path("M92 16l5.1 15.9L113 37l-15.9 5.1L92 58l-5.1-15.9L71 37l15.9-5.1z")])
    static let document = BrandArt(box: iconBox, strokes: [.path("M43 22h34l17 17v68H43z M77 22v19h17 M52 56h31 M52 71h31 M52 86h21")])
    static let search = BrandArt(box: iconBox, strokes: [.circle(57, 54, 28), .path("M78 76l27 27")])
    static let library = BrandArt(box: iconBox, strokes: [.rect(28, 38, 55, 70, 3), .path("M40 23h55v72 M53 10h53v72 M40 58h31 M40 71h31")])
    static let export = BrandArt(box: iconBox, strokes: [.path("M39 73v34h52V73 M65 83V15 M43 37l22-22 22 22")])
    static let bookmark = BrandArt(box: iconBox, strokes: [.path("M39 20h51v87L64 89l-25 18z")])
    static let play = BrandArt(box: iconBox, strokes: [.circle(64, 64, 42), .path("M55 43l29 21-29 21z")])

    // Process diagrams (diagram_*.svg, 600 × 500; boxes trimmed to the drawing).
    static let diagramCapture = BrandArt(box: CGRect(x: 168, y: 88, width: 264, height: 342), strokes: [
        .circle(300, 259, 124), .circle(300, 281, 102), .circle(300, 303, 80), .circle(300, 325, 58),
        .path("M300 96 L300 421"), .path("M280 93h40 M282 425h36"),
    ], fills: [.circle(300, 383, 6)], strokeWidth: 2.8)

    static let diagramRefine = BrandArt(box: CGRect(x: 70, y: 92, width: 426, height: 314), strokes: [
        .path("M75 128 C155 150, 185 100, 246 196 Q258 214 270 247"),
        .path("M75 168 C155 133, 185 203, 246 213 Q258 225 270 247"),
        .path("M75 207 C155 229, 185 179, 246 230 Q258 236 270 247"),
        .path("M75 247 C155 212, 185 282, 246 247 Q258 247 270 247"),
        .path("M75 287 C155 309, 185 259, 246 264 Q258 258 270 247"),
        .path("M75 327 C155 292, 185 362, 246 281 Q258 269 270 247"),
        .path("M75 367 C155 389, 185 339, 246 298 Q258 280 270 247"),
        .path("M325 128H490"), .path("M325 168H465"), .path("M325 207H440"), .path("M325 247H490"),
        .path("M325 287H465"), .path("M325 327H440"), .path("M325 367H490"), .path("M299 96 L299 402"),
    ], strokeWidth: 2.7)

    static let diagramUnderstand = BrandArt(box: CGRect(x: 100, y: 75, width: 400, height: 382), strokes: [
        .circle(300, 205, 126), .circle(230, 327, 126), .circle(370, 327, 126),
    ], strokeWidth: 2.7, clipped: understandHatch,
       clip: [.circle(300, 205, 126), .circle(230, 327, 126), .circle(370, 327, 126)])

    /// Evenly spaced diagonal hatch, every 22 units, wide enough to cover the triple intersection wherever the
    /// circles sit (the animated variant moves them). Clipping trims it to the shared region.
    static let understandHatch: [Element] = (0..<21).map { k in .path("M\(200 + 22 * k) 120l-200 290") }
}

/// Draws a BrandArt scaled to fit, keeping its stroke weight proportional (with a legibility floor).
struct BrandGlyph: View {
    var art: BrandArt
    var color: Color = Ink.ink
    var minLineWidth: CGFloat = 1.1

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / art.box.width, size.height / art.box.height)
            let dx = (size.width - art.box.width * s) / 2 - art.box.minX * s
            let dy = (size.height - art.box.height * s) / 2 - art.box.minY * s
            let t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
            let shading = GraphicsContext.Shading.color(color)
            if !art.fills.isEmpty { ctx.fill(Path(BrandArt.cgPath(art.fills)).applying(t), with: shading) }
            let style = StrokeStyle(lineWidth: max(minLineWidth, art.strokeWidth * s), lineCap: .round, lineJoin: .round)
            if !art.strokes.isEmpty { ctx.stroke(Path(BrandArt.cgPath(art.strokes)).applying(t), with: shading, style: style) }
            if !art.clipped.isEmpty {
                // Clip to each shape in turn: the hatch shows only where all of them overlap.
                var c = ctx
                for shape in art.clip { c.clip(to: Path(BrandArt.cgPath([shape])).applying(t)) }
                c.stroke(Path(BrandArt.cgPath(art.clipped)).applying(t), with: shading, style: StrokeStyle(lineWidth: max(minLineWidth * 0.8, art.clippedWidth * s)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The V mark, flat, in one color. (Named for the ribbon mark it replaced.)
struct RibbonMark: View {
    var color: Color = Ink.persimmon
    var body: some View { BrandGlyph(art: .mark, color: color).aspectRatio(456.83 / 346.06, contentMode: .fit).accessibilityLabel("Verbatim") }
}

// MARK: - Editorial structure

/// "01 / RECENT ··········· trailing": a mono index, a dotted rule, an optional serif title below.
struct EditorialSectionHeader<Trailing: View>: View {
    var index: String
    var label: String
    var title: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                Overline(text: label, color: Ink.dim)
                DottedRule().frame(height: 1)
                Overline(text: index, color: Ink.mute)
            }
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(Ink.serif(26)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: 12)
                    trailing()
                }
            }
        }
    }
}
extension EditorialSectionHeader where Trailing == EmptyView {
    init(index: String, label: String, title: String? = nil) { self.init(index: index, label: label, title: title, trailing: { EmptyView() }) }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath(); return p
    }
}

/// A fine dotted micro-rule.
struct DottedRule: View {
    var color: Color = Ink.faint
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: CGPoint(x: 0, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.5, 4]))
        }
    }
}

/// A small registration tick in a card's corner (editorial surfaces only).
struct CornerTick: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); return p
    }
}

/// Text that links somewhere: ink with an underline on hover.
struct InlineLink: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Text(title); Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
                .underline(hover, color: Ink.ink.opacity(0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - Feature cards (Capture / Refine / Understand)

enum BrandFeature: CaseIterable {
    case capture, refine, understand
    var index: String { switch self { case .capture: return "01"; case .refine: return "02"; case .understand: return "03" } }
    var title: String { switch self { case .capture: return "Capture"; case .refine: return "Refine"; case .understand: return "Understand" } }
    var fill: Color { switch self { case .capture: return Ink.persimmon; case .refine: return Ink.petal; case .understand: return Ink.sage } }
    var art: BrandArt { switch self { case .capture: return .diagramCapture; case .refine: return .diagramRefine; case .understand: return .diagramUnderstand } }
}

/// A flat colored card with a diagram, an index, a serif title, and one line. Real action, keyboard focusable.
/// Ink text on these fills: pink 7.5:1, sage 6.8:1, persimmon 4.45:1 (titles are large; descriptions semibold).
struct BrandFeatureCard: View {
    var feature: BrandFeature
    var line: String
    var meta: String
    var enabled = true
    /// iPhone Home: the diagram moves (`AnimatedFeatureArt`) and slides against the card's scroll (parallax).
    var animated = false
    var parallax = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // Index and diagram share the top row, so three cards fit across a typical window.
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(feature.index).font(Ink.mono(11, weight: .medium)).foregroundStyle(Ink.inkFixed)
                        Rectangle().fill(Ink.inkFixed.opacity(0.5)).frame(width: 14, height: 1)
                    }
                    Spacer(minLength: 8)
                    Group {
                        if animated { AnimatedFeatureArt(feature: feature, color: Ink.inkFixed, minLineWidth: 1) }
                        else { BrandGlyph(art: feature.art, color: Ink.inkFixed, minLineWidth: 1) }
                    }
                    .frame(width: 62, height: 62)
                    .modifier(ArtParallax(enabled: parallax, card: cardSpace))
                    .padding(.trailing, 14)
                }
                Text(feature.title).font(Ink.serif(26)).foregroundStyle(Ink.inkFixed).lineLimit(1).minimumScaleFactor(0.8).padding(.top, 2)
                Text(line).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                Spacer(minLength: 8)
                Text(meta.uppercased()).font(Ink.mono(10, weight: .medium)).tracking(0.9).foregroundStyle(Ink.inkFixed.opacity(0.85))
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
            .coordinateSpace(cardSpace)
        }
        .buttonStyle(FeatureCardStyle(fill: feature.fill))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel("\(feature.title). \(line). \(meta)")
    }

    private var cardSpace: NamedCoordinateSpace { .named("featureCard-\(feature.index)") }
}

/// How far a view sits from the middle of its scroll view, from -1 (a full width left) to 1 (right); 0 outside a
/// scroll view. `center` is the x to measure in the view's own coordinates (its middle by default). Read inside
/// `visualEffect`, so it follows scrolling without re-rendering.
func scrollDepth(_ proxy: GeometryProxy, center: CGFloat? = nil) -> CGFloat {
    guard let viewport = proxy.bounds(of: .scrollView), viewport.width > 0 else { return 0 }
    let mid = center ?? proxy.size.width / 2
    return max(-1, min(1, (mid - viewport.midX) / viewport.width))
}

/// The diagram slides against the card's position in the row (18 pt at a full width from the middle), so it
/// seems to sit a little deeper than the card. Nothing moves when motion is limited.
struct ArtParallax: ViewModifier {
    var enabled: Bool
    var card: NamedCoordinateSpace
    @Environment(\.limitMotion) private var limitMotion
    func body(content: Content) -> some View {
        if enabled && !limitMotion {
            let space = card
            content.visualEffect { c, proxy in
                // The card's middle (in the diagram's coordinates) sets the depth, so card and diagram agree.
                let cardMid = proxy.bounds(of: space)?.midX
                return c.offset(x: -18 * scrollDepth(proxy, center: cardMid))
            }
        } else {
            content
        }
    }
}

/// Feature cards keep the light-mode ink-on-color pairing in dark mode too (the fills are slightly muted there),
/// so contrast holds. Hover: 1 pt rise and a firmer edge; press: slight compression; focus: a visible ring.
// MARK: - Card motion (shared by Mac and iPhone)

/// Pointer-driven card motion, shared by every card in the app family.
/// - Tilt: the side under the pointer dips away, as if the pointer were resting on it (a few degrees at most).
/// - Lift: the card rises 2 pt and its shadow deepens, shifted away from the pointer.
/// - Edge light: a thin rim, brightest at the point nearest the pointer, over a hairline that firms on hover.
/// - Press: the card presses in (scale 0.98, a little more tilt) fast, and springs back over 300 ms.
/// Visual only. Callers keep hit-testing on a flat, untransformed layer, because a 3D-rotated view loses
/// clicks on macOS 26. On iPhone there is no hover, so only the press shows. Reduce Motion keeps the edge light and shadow and drops tilt, lift, and scale.
struct CardMotion: ViewModifier {
    var hover: CGPoint?
    var size: CGSize
    var pressed: Bool
    var radius: CGFloat
    var tilt: Double = 3
    var lift: Double = 2
    /// Rows that sit on paper use a quieter shadow than cards that float.
    var shadow: Bool = true
    @Environment(\.limitMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let w: CGFloat = max(size.width, 1)
        let h: CGFloat = max(size.height, 1)
        var nx: CGFloat = 0                                  // -0.5 … 0.5
        var ny: CGFloat = 0
        if let p = hover {
            nx = min(max(p.x / w, 0), 1) - 0.5
            ny = min(max(p.y / h, 0), 1) - 0.5
        }
        let on: Bool = hover != nil
        let move: Bool = !reduceMotion
        // Wide rows tilt less: the same angle moves a long edge much farther.
        let aspect: Double = Double(min(1, 2.2 * h / w + 0.25))
        let strength: Double = Double(min(1, 2 * (nx * nx + ny * ny).squareRoot()))
        let baseTilt: Double = tilt + (pressed ? 1 : 0)
        let angle: Double = (move && on) ? baseTilt * strength * aspect : 0
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let light = UnitPoint(x: Double(nx) + 0.5, y: Double(ny) + 0.5)
        let rimReach: CGFloat = max(w, h) * 0.55
        let dark: Bool = scheme == .dark
        let shadowOpacity: Double = on ? (dark ? 0.35 : 0.13) : 0
        let shadowX: CGFloat = move ? -nx * 6 : 0
        let liftY: CGFloat = (move && on && !pressed) ? -CGFloat(lift) : 0
        let hoverKey: String = hover.map { "\(Int($0.x / 2)),\(Int($0.y / 2))" } ?? ""

        return content
            // Sheen: a soft glow on the surface under the pointer.
            .overlay {
                shape.fill(RadialGradient(colors: [Color.white.opacity(dark ? 0.07 : 0.16), .clear],
                                          center: light, startRadius: 0, endRadius: rimReach))
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // Edge: the hairline firms up, and a light rim travels with the pointer.
            .overlay {
                shape.strokeBorder(Ink.outlineStrong.opacity(on ? 0.45 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(RadialGradient(colors: [Color.white.opacity(dark ? 0.55 : 0.95), Color.white.opacity(0)],
                                                  center: light, startRadius: 0, endRadius: rimReach), lineWidth: 1.25)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .background {
                if shadow {
                    shape.fill(Color.black.opacity(0.001))
                        .shadow(color: .black.opacity(shadowOpacity), radius: on ? 14 : 0, x: shadowX, y: on ? 8 : 0)
                }
            }
            .rotation3DEffect(.degrees(angle), axis: (x: -ny, y: nx, z: 0), perspective: 0.55)
            .offset(y: liftY)
            .scaleEffect(move && pressed ? 0.98 : 1)
            .animation(pressed ? Motion.press : Motion.card, value: pressed)
            .animation(Motion.card, value: hoverKey)
    }
}

extension View {
    func cardMotion(hover: CGPoint?, size: CGSize, pressed: Bool, radius: CGFloat, tilt: Double = 3, lift: Double = 2, shadow: Bool = true) -> some View {
        modifier(CardMotion(hover: hover, size: size, pressed: pressed, radius: radius, tilt: tilt, lift: lift, shadow: shadow))
    }
}

struct FeatureCardStyle: ButtonStyle {
    var fill: Color
    func makeBody(configuration: Configuration) -> some View { FeatureCardBody(configuration: configuration, fill: fill) }
    /// Tilts toward the pointer with an edge light (`CardMotion`). The moving visuals don't take the pointer;
    /// a flat layer on top does, so the Button keeps every click while the card is rotated.
    private struct FeatureCardBody: View {
        let configuration: ButtonStyleConfiguration
        var fill: Color
        @State private var hover: CGPoint? = nil
        @State private var size: CGSize = .zero
        @Environment(\.isFocused) private var focused
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            configuration.label
                .background(fill, in: shape)
                .overlay(alignment: .topTrailing) {
                    CornerTick().stroke(Ink.inkFixed, lineWidth: 1.2).frame(width: 9, height: 9).padding(12)
                }
                .cardMotion(hover: hover, size: size, pressed: configuration.isPressed, radius: 18, tilt: 4, lift: 2)
                .allowsHitTesting(false)
                .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3).padding(-3).opacity(focused ? 1 : 0))
                .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
                .overlay {
                    shape.fill(Color.white.opacity(0.001)).contentShape(shape)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hover = p
                            case .ended: hover = nil
                            }
                        }
                }
                .contentShape(shape)
        }
    }
}

// MARK: - Buttons

/// Ink fill, reader-white label (cream fill, ink label in dark). The reliable primary control.
struct BrandPrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, large: large) }
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        var large: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .foregroundStyle(Ink.onInteractive)
                .padding(.horizontal, large ? 16 : 12).frame(minHeight: large ? 34 : 28)
                .background(Ink.interactive.opacity(configuration.isPressed ? 0.85 : hover ? 0.92 : 1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.14), value: hover)
        }
    }
}

/// Reader-white surface, ink label, hairline edge.
struct BrandSecondaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, large: large) }
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        var large: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .medium))
                .foregroundStyle(Ink.ink)
                .padding(.horizontal, large ? 16 : 12).frame(minHeight: large ? 34 : 28)
                .background(configuration.isPressed ? Ink.wash : hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hover ? Ink.outlineStrong : Ink.hairline))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.14), value: hover)
        }
    }
}

extension ButtonStyle where Self == BrandPrimaryButtonStyle {
    static var brandPrimary: BrandPrimaryButtonStyle { BrandPrimaryButtonStyle() }
    static var brandPrimaryLarge: BrandPrimaryButtonStyle { BrandPrimaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == BrandSecondaryButtonStyle {
    static var brandSecondary: BrandSecondaryButtonStyle { BrandSecondaryButtonStyle() }
    static var brandSecondaryLarge: BrandSecondaryButtonStyle { BrandSecondaryButtonStyle(large: true) }
}

// MARK: - Status and empty states

/// Concentric rings (the Capture diagram's language) for recording and processing. Pulses outward while
/// active; a static set of rings under Reduce Motion.
struct SignalRings: View {
    var active = true
    var color: Color = Ink.persimmon
    @Environment(\.limitMotion) private var reduce
    @State private var phase = false
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(color.opacity(0.7 - Double(i) * 0.2), lineWidth: max(1, d * 0.045))
                        .frame(width: d * (0.42 + CGFloat(i) * 0.29), height: d * (0.42 + CGFloat(i) * 0.29))
                        .scaleEffect(active && !reduce && phase ? 1.06 : 1)
                        .opacity(active && !reduce && phase && i == 2 ? 0.35 : 1)
                }
                Circle().fill(color).frame(width: d * 0.22, height: d * 0.22)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .onAppear { if active && !reduce { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = true } } }
        .accessibilityHidden(true)
    }
}

/// A compact, task-related empty-state picture: a brand icon on a soft tinted disc.
struct EmptyStateArt: View {
    var art: BrandArt = .document
    var tint: Color = Ink.butterTint
    var body: some View {
        ZStack {
            Circle().fill(tint)
            BrandGlyph(art: art, color: Ink.ink, minLineWidth: 1.4).padding(13)
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }
}

// MARK: - Moving diagrams (iPhone Home)

/// Damped springs stepped once per frame (semi-implicit Euler). Each spring chases its own target, so several
/// driven by one signal still move independently. A reference type kept in @State: stepping it while drawing
/// doesn't invalidate the view.
final class SpringBank {
    struct Spring { var k: Double; var d: Double; var gain: Double; var x = 0.0; var v = 0.0 }
    private(set) var springs: [Spring]
    private var last: Date?

    init(_ specs: [(k: Double, d: Double, gain: Double)]) {
        springs = specs.map { Spring(k: $0.k, d: $0.d, gain: $0.gain) }
    }

    /// Seconds since the previous frame, at most 50 ms; a long gap (paused, off screen) counts as one frame.
    func tick(_ now: Date) -> Double {
        defer { last = now }
        guard let prev = last else { return 0 }
        let dt = now.timeIntervalSince(prev)
        if dt <= 0 { return 0 }
        return dt > 0.25 ? 1.0 / 60 : min(0.05, dt)
    }

    func step(_ dt: Double, targets: [Double]) {
        guard dt > 0 else { return }
        for i in springs.indices where i < targets.count {
            let a = springs[i].k * (targets[i] - springs[i].x) - springs[i].d * springs[i].v
            springs[i].v += a * dt
            springs[i].x += springs[i].v * dt
        }
    }

    /// 1 + displacement × gain: the scale for spring `i`.
    func scale(_ i: Int) -> CGFloat { 1 + CGFloat(springs[i].x * springs[i].gain) }
    func value(_ i: Int) -> Double { springs[i].x }
}

/// A simulated voice for the Capture card: a slow phrase envelope times a syllable rhythm, split into four
/// targets, one per ring (outer to inner: gain .12/.18/.24/.30, stiffer and quicker toward the middle).
final class CaptureVoice {
    let springs = SpringBank([(22, 5, 0.12), (34, 6, 0.18), (50, 7, 0.24), (70, 8, 0.30)])
    private var ct = 0.0

    func advance(_ now: Date) {
        let dt = springs.tick(now)
        ct += dt * 6
        let phrase = 0.5 + 0.5 * sin(ct / 6)
        let syll = 0.5 + 0.5 * sin(ct * 1.3 + sin(ct / 3))
        let env = 0.15 + 0.85 * phrase * (0.5 + 0.5 * syll)
        springs.step(dt, targets: [env * 0.9, env * (0.6 + 0.4 * syll), env * syll, env * (0.4 + 0.6 * abs(sin(ct * 2.1)))])
    }
}

/// CSS-style cubic-bezier easing, for drawings that animate by the clock.
enum CubicEase {
    /// cubic-bezier(x1, y1, x2, y2) at progress t (0…1).
    static func value(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Double) -> Double {
        let x = min(1, max(0, t))
        func bez(_ a: Double, _ b: Double, _ s: Double) -> Double { 3 * a * (1 - s) * (1 - s) * s + 3 * b * (1 - s) * s * s + s * s * s }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<24 {
            s = (lo + hi) / 2
            if bez(x1, x2, s) < x { lo = s } else { hi = s }
        }
        return bez(y1, y2, s)
    }
    /// The prototype's ease: cubic-bezier(.22, .7, .2, 1).
    static func gentle(_ t: Double) -> Double { value(0.22, 0.7, 0.2, 1, t) }
    static func inOut(_ t: Double) -> Double { value(0.42, 0, 0.58, 1, t) }
}

/// Maps a design-space box onto a canvas, aspect fit and centered (as BrandGlyph does).
struct ArtSpace {
    let s: CGFloat, dx: CGFloat, dy: CGFloat
    init(box: CGRect, size: CGSize) {
        s = min(size.width / box.width, size.height / box.height)
        dx = (size.width - box.width * s) / 2 - box.minX * s
        dy = (size.height - box.height * s) / 2 - box.minY * s
    }
    var transform: CGAffineTransform { CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: dx + (x - r) * s, y: dy + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
    }
}

/// The method diagrams, moving (iPhone Home cards):
/// - Capture: the four rings scale from their shared bottom point, each on its own spring, driven by a
///   simulated voice. They never rotate.
/// - Refine: strands flow into the bar as travelling dashes; the clean lines draw in one after another, hold,
///   and clear (7 s).
/// - Understand: the circles drift together and apart (7 s); only the region all three share is hatched.
/// Runs only while on screen. With motion limited it's the still diagram.
struct AnimatedFeatureArt: View {
    var feature: BrandFeature
    var color: Color = Ink.ink
    var minLineWidth: CGFloat = 1.1
    @Environment(\.limitMotion) private var limitMotion
    @State private var onScreen = false
    @State private var voice = CaptureVoice()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if limitMotion {
                BrandGlyph(art: feature.art, color: color, minLineWidth: minLineWidth)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !onScreen || scenePhase != .active)) { timeline in
                    let now = timeline.date
                    Canvas { ctx, size in
                        switch feature {
                        case .capture: drawCapture(ctx, size, now)
                        case .refine: drawRefine(ctx, size, now.timeIntervalSinceReferenceDate)
                        case .understand: drawUnderstand(ctx, size, now.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityHidden(true)
    }

    private func width(_ art: BrandArt, _ s: CGFloat) -> CGFloat { max(minLineWidth, art.strokeWidth * s) }

    // Capture

    private static let captureAxis = Path(SVGPathData.parse("M300 96 L300 421 M280 93h40 M282 425h36"))

    private func drawCapture(_ ctx: GraphicsContext, _ size: CGSize, _ now: Date) {
        voice.advance(now)
        let art = BrandArt.diagramCapture
        let sp = ArtSpace(box: art.box, size: size)
        let style = StrokeStyle(lineWidth: width(art, sp.s), lineCap: .round, lineJoin: .round)
        let shading = GraphicsContext.Shading.color(color)
        // Each ring keeps touching the shared point (300, 383) as it scales: center = 383 − r.
        var rings = Path()
        for (i, r0) in [CGFloat(124), 102, 80, 58].enumerated() {
            let r = r0 * voice.springs.scale(i)
            rings.addPath(sp.circle(300, 383 - r, r))
        }
        ctx.stroke(rings, with: shading, style: style)
        ctx.stroke(Self.captureAxis.applying(sp.transform), with: shading, style: style)
        ctx.fill(sp.circle(300, 383, 6), with: shading)
    }

    // Refine

    private static let strandPaths: [Path] = [
        "M75 128 C155 150, 185 100, 246 196 Q258 214 270 247",
        "M75 168 C155 133, 185 203, 246 213 Q258 225 270 247",
        "M75 207 C155 229, 185 179, 246 230 Q258 236 270 247",
        "M75 247 C155 212, 185 282, 246 247 Q258 247 270 247",
        "M75 287 C155 309, 185 259, 246 264 Q258 258 270 247",
        "M75 327 C155 292, 185 362, 246 281 Q258 269 270 247",
        "M75 367 C155 389, 185 339, 246 298 Q258 280 270 247",
    ].map { Path(SVGPathData.parse($0)) }
    /// Seconds per dash cycle, varied so the strands don't move in step.
    private static let strandPeriods: [Double] = [4.2, 5, 3.6, 5, 4.2, 3.6, 4.2]
    private static let cleanLines: [(y: CGFloat, end: CGFloat)] = [(128, 490), (168, 465), (207, 440), (247, 490), (287, 465), (327, 440), (367, 490)]

    private func drawRefine(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let art = BrandArt.diagramRefine
        let sp = ArtSpace(box: art.box, size: size)
        let w = width(art, sp.s)
        let shading = GraphicsContext.Shading.color(color)
        // Long dashes (72 on, 14 off) travel along each strand toward the bar.
        for (i, strand) in Self.strandPaths.enumerated() {
            let period = Self.strandPeriods[i]
            let f = t.truncatingRemainder(dividingBy: period) / period
            let phase = CGFloat(86 * (1 - f)) * sp.s
            ctx.stroke(strand.applying(sp.transform), with: shading,
                       style: StrokeStyle(lineWidth: w, lineCap: .round, dash: [72 * sp.s, 14 * sp.s], dashPhase: phase))
        }
        let round = StrokeStyle(lineWidth: w, lineCap: .round)
        var bar = Path()
        bar.move(to: CGPoint(x: 299, y: 96)); bar.addLine(to: CGPoint(x: 299, y: 402))
        ctx.stroke(bar.applying(sp.transform), with: shading, style: round)
        // Clean lines: draw in over the first quarter (0.15 s apart), hold, clear from the left in the last quarter.
        for (i, line) in Self.cleanLines.enumerated() {
            let len = line.end - 325
            var local = (t - Double(i) * 0.15).truncatingRemainder(dividingBy: 7)
            if local < 0 { local += 7 }
            let p = local / 7
            var from: CGFloat = 0, to: CGFloat = 1
            if p < 0.25 { to = min(1, 170 * CGFloat(CubicEase.gentle(p / 0.25)) / len) }
            else if p >= 0.75 { from = min(1, 170 * CGFloat(CubicEase.gentle((p - 0.75) / 0.25)) / len) }
            guard to > from else { continue }
            var path = Path()
            path.move(to: CGPoint(x: 325, y: line.y)); path.addLine(to: CGPoint(x: line.end, y: line.y))
            ctx.stroke(path.trimmedPath(from: from, to: to).applying(sp.transform), with: shading, style: round)
        }
    }

    // Understand

    /// A little roomier than the still diagram's box, so the circles have space to drift.
    private static let understandBox = CGRect(x: 80, y: 55, width: 440, height: 420)
    private static let hatch = Path(BrandArt.cgPath(BrandArt.understandHatch))

    private func drawUnderstand(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let art = BrandArt.diagramUnderstand
        let sp = ArtSpace(box: Self.understandBox, size: size)
        let shading = GraphicsContext.Shading.color(color)
        // Apart at the start of the cycle, together at the middle, apart again (ease-in-out each way).
        let p = t.truncatingRemainder(dividingBy: 7) / 3.5
        let apart = CGFloat(p < 1 ? 1 - CubicEase.inOut(p) : CubicEase.inOut(p - 1))
        let centers: [(CGFloat, CGFloat)] = [(300, 205 - 22 * apart), (230 - 20 * apart, 327 + 12 * apart), (370 + 20 * apart, 327 + 12 * apart)]
        let circles = centers.map { sp.circle($0.0, $0.1, 126) }
        // Only the region all three share is hatched, so it grows as they meet.
        var clipped = ctx
        for circle in circles { clipped.clip(to: circle) }
        clipped.stroke(Self.hatch.applying(sp.transform), with: shading, style: StrokeStyle(lineWidth: max(minLineWidth * 0.8, art.clippedWidth * sp.s)))
        var outline = Path()
        for circle in circles { outline.addPath(circle) }
        ctx.stroke(outline, with: shading, style: StrokeStyle(lineWidth: width(art, sp.s)))
    }
}

