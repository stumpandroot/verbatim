import SwiftUI
import AppKit

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
    /// Elements drawn only inside the union of `clip` circles (the hatched Understand intersection).
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
    // Ribbon mark: three folded strips (logo_mark_*.svg, group space).
    static let mark = BrandArt(box: CGRect(x: 9, y: 15, width: 78, height: 81), fills: [
        .path("M18 15 L84 15 L84 31 L36 31 L36 38 L18 38 Z"),
        .path("M9 42 L72 42 L72 58 L25 58 L25 66 L9 59 Z"),
        .path("M18 69 L87 69 L87 85 L38 85 L18 96 Z"),
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
    ], strokeWidth: 2.7, clipped: (0..<15).map { k in .path("M\(235 + 17 * k) 180l-180 260") },
       clip: [.circle(300, 205, 126), .circle(230, 327, 126), .circle(370, 327, 126)])
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
                var c = ctx
                c.clip(to: Path(BrandArt.cgPath(art.clip)).applying(t))
                c.stroke(Path(BrandArt.cgPath(art.clipped)).applying(t), with: shading, style: StrokeStyle(lineWidth: max(minLineWidth * 0.8, art.clippedWidth * s)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The ribbon mark, flat, in one color.
struct RibbonMark: View {
    var color: Color = Ink.persimmon
    var body: some View { BrandGlyph(art: .mark, color: color).aspectRatio(78.0 / 81.0, contentMode: .fit).accessibilityLabel("Verbatim") }
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
                    BrandGlyph(art: feature.art, color: Ink.inkFixed, minLineWidth: 1)
                        .frame(width: 62, height: 62).padding(.trailing, 14)
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
        }
        .buttonStyle(FeatureCardStyle(fill: feature.fill))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel("\(feature.title). \(line). \(meta)")
    }
}

/// Feature cards keep the light-mode ink-on-color pairing in dark mode too (the fills are slightly muted there),
/// so contrast holds. Hover: 1 pt rise and a firmer edge; press: slight compression; focus: a visible ring.
struct FeatureCardStyle: ButtonStyle {
    var fill: Color
    func makeBody(configuration: Configuration) -> some View { FeatureCardBody(configuration: configuration, fill: fill) }
    private struct FeatureCardBody: View {
        let configuration: ButtonStyleConfiguration
        var fill: Color
        @State private var hover = false
        @Environment(\.accessibilityReduceMotion) private var reduce
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    CornerTick().stroke(Ink.inkFixed, lineWidth: 1.2).frame(width: 9, height: 9).padding(12)
                }
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.inkFixed.opacity(hover ? 0.35 : 0), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(-3).opacity(focused ? 1 : 0))
                .offset(y: hover && !reduce ? -1 : 0)
                .scaleEffect(configuration.isPressed ? 0.99 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.16), value: hover)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
    @Environment(\.accessibilityReduceMotion) private var reduce
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

// MARK: - Document row

/// One transcript as an index entry: source glyph, title, mono metadata, state, date. Hover tint, keyboard
/// focusable, drag to a project, context menu. No tilt.
struct DocumentRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            sourceGlyph
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute).accessibilityLabel("Pinned") }
                    Text(transcript.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(sourceName)
                    Text("·")
                    Text(transcript.duration.timecode).font(Ink.mono(12))
                    if transcript.speakers.count >= 2 { Text("·"); Text("\(transcript.speakers.count) speakers") }
                    if transcript.notes.contains(where: \.isBookmark) { Text("·"); BrandGlyph(art: .bookmark, color: Ink.mute).frame(width: 11, height: 11).accessibilityLabel("Has saved moments") }
                }
                .font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 10)
            state
            Text(dateLine).font(Ink.mono(12)).foregroundStyle(Ink.mute).frame(width: 84, alignment: .trailing).lineLimit(1)
            RowMenuButton(transcript: transcript)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 9)
        .background(hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Ink.outlineStrong.opacity(0.7) : Ink.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.16), value: hover)
        .onTapGesture(perform: open)
        .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
        .contextMenu { RowMenu(transcript: transcript) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private var sourceName: String {
        switch transcript.source { case .dictation: return "Dictation"; case .voiceMemo: return "Voice note"; default: return transcript.sourceLabel }
    }

    private var sourceGlyph: some View {
        let (art, tint): (BrandArt?, Color) = {
            switch transcript.source {
            case .voiceMemo, .dictation: return (.capture, Ink.persimmonTint)
            case .link: return (nil, Ink.sageTint)
            case .app: return (nil, Ink.petalTint)
            default: return (.document, Ink.butterTint)
            }
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint)
            if let art { BrandGlyph(art: art, color: Ink.ink, minLineWidth: 1.2).padding(7) }
            else { Image(systemName: transcript.source.symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(Ink.ink) }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var state: some View {
        if transcript.status == .processing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(transcript.stage ?? "Transcribing").font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            .accessibilityLabel("Processing: \(transcript.stage ?? "Transcribing")")
        } else if transcript.status == .failed {
            Label("Needs retry", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Ink.danger)
        }
    }

    private var dateLine: String {
        let f = DateFormatter(); let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { return "Today" }
        if cal.isDateInYesterday(transcript.createdAt) { return "Yesterday" }
        f.dateFormat = cal.isDate(transcript.createdAt, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: transcript.createdAt)
    }
}
