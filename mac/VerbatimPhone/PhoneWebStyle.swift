import SwiftUI
import UIKit

// The iPhone in the website's clothes (mockup "Verbose iPhone, Website Style", October 23, 2026): paper, compact
// serif titles, mono labels, soft chips, flat rows with hairlines, and color panels with grain and one slowly moving
// line drawing per screen. Apple owns the chrome (tab bar, navigation buttons, sheets, menus); everything here is the
// content layer, opaque, and never sits under glass.

// MARK: - Phone names for shared tokens

/// The website style's names on the iPhone, as aliases of `Ink` (Tokens.swift, shared with the Mac and the keyboard),
/// so every color value lives in that one file.
enum PhoneInk {
    /// Color panels: the bright fills on paper, slightly deeper in dark mode so they don't glow on the near-black
    /// green. Text and line art on them is always `Ink.inkFixed`.
    static var record: Color { Ink.panelRecord }
    static var butter: Color { Ink.panelButter }
    static var sage: Color { Ink.panelSage }
    static var petal: Color { Ink.panelPetal }
    /// Soft chips, segmented tracks, and search fields: a warmer, deeper wash than `Ink.wash`.
    static var wash: Color { Ink.chip }
    /// The hard offset shadow under the Record panel (4, 5).
    static var hard: Color { Ink.hard }
    /// A switch that's on: ink on paper, a lighter sage on dark so the white knob always shows.
    static var switchOn: Color { Ink.switchOnInk }
    /// Selected chips and segments: ink with paper text (paper with ink text in dark).
    static var chipOn: Color { Ink.ink }
    static var chipOnText: Color { Ink.paper }
}

// MARK: - Grain

/// The website's paper noise as a tile, made once: ink-colored specks at random strength, used only on color panels.
enum PhoneGrainTile {
    static let image: UIImage = make()

    private static func make() -> UIImage {
        let n = 256
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 2_654_435_769
        for i in 0..<(n * n) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let v = Double(seed >> 8) / Double(1 << 24)
            let a = v * 0.55
            // Premultiplied ink (38, 51, 46).
            bytes[i * 4] = UInt8(38 * a)
            bytes[i * 4 + 1] = UInt8(51 * a)
            bytes[i * 4 + 2] = UInt8(46 * a)
            bytes[i * 4 + 3] = UInt8(255 * a)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return UIImage() }
        return UIImage(cgImage: cg, scale: 3, orientation: .up)
    }
}

/// A color panel's fill: the color, its grain (premultiplied ink at 30%, one speck per screen pixel), and the shape. Grain is left off under Increase
/// Contrast and Reduce Transparency, where texture costs legibility.
struct PhonePanelFill<S: Shape>: View {
    var color: Color
    var shape: S
    var grain = true
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        shape.fill(color)
            .overlay {
                if grain, contrast != .increased, !reduceTransparency {
                    Image(uiImage: PhoneGrainTile.image).resizable(resizingMode: .tile)
                        .opacity(0.3)
                        .clipShape(shape)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A paper card with an ink outline (the website's `inset 0 0 0 1.5px ink`).
    func phoneOutlined(radius: CGFloat, fill: Color = Ink.card, line: CGFloat = 1.5) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Ink.ink, lineWidth: line))
    }
}

// MARK: - Line art

/// A clock for the panel drawings: a TimelineView at most 30 frames a second that runs only while the view is on
/// screen and the app is active, and holds its frame otherwise. Draw with a Canvas inside; a loop never drives state.
struct PhoneLoopClock<Content: View>: View {
    @ViewBuilder var content: (Date) -> Content
    @State private var onScreen = false
    @State private var scrolledIn = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(onScreen && scrolledIn && scenePhase == .active))) { tl in
            content(tl.date)
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .modifier(PhoneScrollVisibility(visible: $scrolledIn))
    }
}

private struct PhoneScrollVisibility: ViewModifier {
    @Binding var visible: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        } else {
            content
        }
    }
}

/// The website's panel drawings, in ink on a color panel. One per screen, looping gently; still under Reduce Motion
/// or Limit animation, and in the screenshot tour.
/// - rings (Record): three circles sharing a bottom point swell in turn (2.6 s).
/// - strands (Summary): two strands flow toward the bar as travelling dashes; two clean lines draw in, hold, and clear (7 s).
/// - circles (Moments stills): three circles drift together and apart (7 s).
/// - lines (Keyboard): three lines draw in one after another, hold, and clear (7 s).
struct PhonePanelArt: View {
    enum Kind { case rings, strands, circles, lines }
    var kind: Kind
    var color: Color = Ink.inkFixed
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        Group {
            if limitMotion || !PhoneMotion.on {
                Canvas { ctx, size in Self.draw(kind, in: ctx, size: size, t: nil, color: color) }
            } else {
                PhoneLoopClock { now in
                    Canvas { ctx, size in Self.draw(kind, in: ctx, size: size, t: now.timeIntervalSinceReferenceDate, color: color) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The drawing's design box (the mockup's SVG viewBox).
    static func box(_ kind: Kind) -> CGSize {
        switch kind {
        case .rings: return CGSize(width: 300, height: 300)
        case .strands, .lines: return CGSize(width: 300, height: 200)
        case .circles: return CGSize(width: 300, height: 260)
        }
    }

    static func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }

    /// How much of line `i` shows at time `t`: draws in over the first quarter, holds, clears over the last quarter.
    static func span(_ t: Double, _ i: Int, period: Double) -> (Double, Double) {
        let x = t - Double(i) * 0.15
        let q = (x.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        if q < 0.25 { return (0, ease(q / 0.25)) }
        if q >= 0.75 { return (ease((q - 0.75) / 0.25), 1) }
        return (0, 1)
    }

    static func draw(_ kind: Kind, in ctx: GraphicsContext, size: CGSize, t: Double?, color: Color) {
        let b = box(kind)
        let s = min(size.width / b.width, size.height / b.height)
        let dx = (size.width - b.width * s) / 2, dy = (size.height - b.height * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + x * s, y: dy + y * s) }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: dx + (cx - r) * s, y: dy + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Path {
            var path = Path(); path.move(to: p(x1, y1)); path.addLine(to: p(x2, y2)); return path
        }
        let style = StrokeStyle(lineWidth: max(1.2, 2.2 * s), lineCap: .round, lineJoin: .round)
        let shade = GraphicsContext.Shading.color(color)
        /// A line that draws in from its left end and clears from it (`span`).
        func drawnLine(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat, _ i: Int) {
            let (f, to) = t.map { span($0, i, period: 7) } ?? (0, 1)
            guard to - f > 0.01 else { return }
            let len = x2 - x1
            ctx.stroke(line(x1 + len * CGFloat(f), y, x1 + len * CGFloat(to), y), with: shade, style: style)
        }

        switch kind {
        case .rings:
            let rings: [(cy: CGFloat, r: CGFloat)] = [(150, 120), (180, 90), (210, 60)]
            for (i, ring) in rings.enumerated() {
                let bottom = ring.cy + ring.r
                var r = ring.r
                if let t { r = ring.r * CGFloat(1 + 0.07 * sin(2 * Double.pi * t / 2.6 - Double(i) * 0.55)) }
                ctx.stroke(circle(150, bottom - r, r), with: shade, style: style)
            }
            ctx.stroke(line(150, 0, 150, 300), with: shade, style: style)

        case .strands:
            var a = Path()
            a.move(to: p(40, 30)); a.addCurve(to: p(200, 96), control1: p(120, 50), control2: p(140, 0)); a.addQuadCurve(to: p(220, 140), control: p(210, 112))
            var c = Path()
            c.move(to: p(40, 80)); c.addCurve(to: p(200, 120), control1: p(120, 50), control2: p(140, 130)); c.addQuadCurve(to: p(220, 140), control: p(210, 128))
            for (i, strand) in [a, c].enumerated() {
                guard let t else { ctx.stroke(strand, with: shade, style: style); continue }
                // A dash of 84 and a gap of 16 (of 100) travelling along the strand every 4.2 s.
                let o = 100 * (1 - t.truncatingRemainder(dividingBy: 4.2) / 4.2) + Double(i) * 9
                for k in -1...2 {
                    let start = Double(k) * 100 - o
                    let lo = max(0, start), hi = min(100, start + 84)
                    if hi > lo { ctx.stroke(strand.trimmedPath(from: CGFloat(lo / 100), to: CGFloat(hi / 100)), with: shade, style: style) }
                }
            }
            drawnLine(240, 300, 30, 0)
            drawnLine(240, 300, 80, 1)
            ctx.stroke(line(230, 0, 230, 200), with: shade, style: style)

        case .circles:
            var v = 0.0
            if let t {
                let q = t.truncatingRemainder(dividingBy: 7) / 3.5
                v = q < 1 ? 1 - ease(q) : ease(q - 1)
            }
            let base: [(CGFloat, CGFloat)] = [(200, 90), (150, 170), (250, 170)]
            let drift: [(CGFloat, CGFloat)] = [(0, -16), (-16, 9), (16, 9)]
            for (i, c) in base.enumerated() {
                ctx.stroke(circle(c.0 + drift[i].0 * CGFloat(v), c.1 + drift[i].1 * CGFloat(v), 80), with: shade, style: style)
            }

        case .lines:
            drawnLine(170, 300, 30, 0)
            drawnLine(190, 300, 64, 1)
            drawnLine(210, 300, 98, 2)
            ctx.stroke(line(155, 0, 155, 200), with: shade, style: style)
        }
    }
}

// MARK: - Type

/// The website's eyebrow: a small outlined diamond and a mono label ("Friday, October 23", "Meeting · Thu Oct 22").
struct PhoneEyebrow: View {
    var text: String
    var color: Color = Ink.dim
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().strokeBorder(color, lineWidth: 1.3)
                .frame(width: 7, height: 7).rotationEffect(.degrees(45))
                .accessibilityHidden(true)
            Text(text).font(Ink.mono(size)).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A compact screen title: the serif name with a mono count beside it on the baseline ("Library 46").
struct PhoneCompactTitle: View {
    var title: String
    var count: String? = nil
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 34
    @ScaledMetric(relativeTo: .caption) private var countSize: CGFloat = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(Ink.serif(size)).foregroundStyle(Ink.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let count { Text(count).font(Ink.mono(countSize)).foregroundStyle(Ink.mute).lineLimit(1) }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A day header over a list: mono, mute ("Today · Fri Oct 23").
struct PhoneDayHeader: View {
    var text: String
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12
    var body: some View {
        Text(text).font(Ink.mono(size)).foregroundStyle(Ink.mute)
            .padding(.top, 16).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// "Today · Fri Oct 23", "Yesterday · Thu Oct 22", or "Mon Oct 19".
    static func label(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Formats.pattern(calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEE MMM d" : "EEE MMM d, yyyy").string(from: day)
        if calendar.isDate(day, inSameDayAs: now) { return "Today · \(date)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday · \(date)" }
        return date
    }
}

// MARK: - Controls

/// A soft filter chip: a rounded rectangle on the wash, ink with paper text when selected. Not a capsule. An optional
/// color dot names the source it filters by.
struct PhoneChip: View {
    var label: String
    var selected: Bool
    var dot: Color? = nil
    var count: Int? = nil
    var action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 32

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(label)
                if let count { Text("\(count)").monospacedDigit().opacity(0.7) }
            }
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(selected ? PhoneInk.chipOnText : Ink.ink)
            .padding(.horizontal, 12).frame(minHeight: height)
            .background(selected ? PhoneInk.chipOn : PhoneInk.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(label), \($0)" } ?? label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The website's two-part switch (Original / Cleaned): a wash capsule track with the chosen part in ink.
struct PhoneSegmented<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { withAnimation(limitMotion ? Motion.fade : Motion.snap) { selection = value } } label: {
                    Text(label).font(.system(size: size, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .foregroundStyle(selection == value ? PhoneInk.chipOnText : Ink.ink)
                        .background { if selection == value { Capsule().fill(PhoneInk.chipOn) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(PhoneInk.wash, in: Capsule())
    }
}

/// Cards press in a little (0.98, quick ease-out). With motion limited, a brief dim instead.
struct PhoneCardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration) }
    private struct Pressed: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.98 : 1)
                .opacity(configuration.isPressed && limitMotion ? 0.75 : 1)
                .animation(limitMotion ? Motion.fade : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// The website's search field: a wash capsule with the search glyph, typed into in place (no navigation bar).
struct PhoneSearchField: View {
    @Binding var text: String
    var prompt: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 15

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(Ink.mute)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Ink.mute))
                .font(.system(size: 15)).dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .foregroundStyle(Ink.ink)
                .tint(Ink.accentText)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: glyph + 1))
                        .foregroundStyle(Ink.faint)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14).padding(.trailing, text.isEmpty ? 14 : 0)
        .frame(minHeight: height)
        .background(PhoneInk.wash, in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Ink.ink.opacity(0.35) : Color.clear, lineWidth: 1))
    }
}

// MARK: - Rows

/// How a row's round mark looks: the source's panel color with its brand icon in ink, as on Home. Links are paper
/// with an ink outline (the Live captions treatment is the tile, not the row; links read as "kept from the web").
struct PhoneKindDot: View {
    var transcript: Transcript
    var size: CGFloat = 36

    var body: some View {
        let style = Self.style(transcript)
        return BrandGlyph(art: style.art, color: style.onFill, minLineWidth: 1.3)
            .padding(size * 0.25)
            .frame(width: size, height: size)
            .background(Circle().fill(style.fill))
            .overlay { if style.outline { Circle().strokeBorder(Ink.ink, lineWidth: 1.5) } }
            .accessibilityHidden(true)
    }

    struct Style { var fill: Color; var onFill: Color; var art: BrandArt; var outline = false }

    static func style(_ t: Transcript) -> Style {
        if t.isDictation { return Style(fill: PhoneInk.butter, onFill: Ink.inkFixed, art: .iconDictations) }
        if LibrarySource.isLink(t) { return Style(fill: Ink.card, onFill: Ink.ink, art: .iconLinks, outline: true) }
        switch t.source {
        case .app: return Style(fill: PhoneInk.petal, onFill: Ink.inkFixed, art: .iconVoice)
        case .file: return Style(fill: PhoneInk.sage, onFill: Ink.inkFixed, art: .document)
        default: return Style(fill: PhoneInk.record, onFill: Ink.inkFixed, art: .capture)
        }
    }
}

/// One recording as a flat row on the paper (Library, Home): the round source mark, the title (serif in Library,
/// semibold sans on Home), a meta line, and on the right the state as a plain word and the length in mono. A
/// hairline below; no card.
struct PhoneFlatRow<Trailing: View>: View {
    var transcript: Transcript
    var serif = true
    var meta: String
    @ViewBuilder var trailing: () -> Trailing
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 19
    @ScaledMetric(relativeTo: .body) private var sansSize: CGFloat = 15.5
    @ScaledMetric(relativeTo: .footnote) private var metaSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            PhoneKindDot(transcript: transcript, size: min(dot, 48))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if transcript.pinned { IconGlyph(art: .iconPin, size: 12, color: Ink.mute).accessibilityLabel("Pinned") }
                    Text(transcript.title)
                        .font(serif ? Ink.serif(titleSize) : .system(size: sansSize, weight: .semibold))
                        .foregroundStyle(Ink.ink).lineLimit(1)
                }
                Text(meta).font(.system(size: metaSize)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 10).padding(.horizontal, 2)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The right side of a Library row: the state as a word ("Cleaned" in the accent, "Original" dim, progress, or a
/// retry) over the length in mono.
struct PhoneRowState: View {
    var transcript: Transcript
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12.5
    @ScaledMetric(relativeTo: .caption) private var mono: CGFloat = 12

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            switch transcript.status {
            case .processing:
                HStack(spacing: 5) {
                    if transcript.processingDevice == Device.id { ProgressView().controlSize(.mini) } else { IconGlyph(art: .iconWaitingForMac, size: 14, color: Ink.dim) }
                    Text(Self.shortStage(transcript)).lineLimit(1)
                }
                .font(.system(size: size, weight: .semibold)).foregroundStyle(Ink.dim)
            case .failed:
                HStack(spacing: 4) { IconGlyph(art: .iconAttention, size: 13, color: Ink.danger); Text("Retry") }
                    .font(.system(size: size, weight: .semibold)).foregroundStyle(Ink.danger)
            case .ready:
                Text(Self.cleaned(transcript) ? "Cleaned" : "Original")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Self.cleaned(transcript) ? Ink.accentText : Ink.dim)
            }
            if transcript.duration > 0 {
                Text(transcript.duration.timecode).font(Ink.mono(mono)).foregroundStyle(Ink.dim)
            }
        }
        .fixedSize()
    }

    /// The Cleaned text exists: someone (or Clean up) made it.
    static func cleaned(_ t: Transcript) -> Bool { t.documentCleanedBy != nil || t.document != nil }

    static func shortStage(_ t: Transcript) -> String {
        if t.processingDevice != nil, t.processingDevice != Device.id { return "On Mac" }
        let s = t.stage ?? "Working"
        return s.count > 16 ? String(s.prefix(15)) + "…" : s
    }
}
