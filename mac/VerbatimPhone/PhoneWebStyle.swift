import SwiftUI
import UIKit

// The iPhone in the website's clothes (mockup "Verbose iPhone, Website Style", October 23, 2026): paper, compact
// serif titles, mono labels, soft chips, flat rows with hairlines, and color panels with grain and one slowly moving
// line drawing per screen. Apple owns the chrome (tab bar, navigation buttons, sheets, menus); everything here is the
// content layer, opaque, and never sits under glass.
//
// Each component also draws the Native look (DESIGN.md §13, NativeLook.swift) when `@Environment(\.look)` says so:
// grouped cards for panels, no grain, line art, ink edges, or hard shadows, SF Pro for the serif and mono, capsules
// for chips, a segmented picker, and SF Symbols. The Native branches are marked `// brand: native`.

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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            // Native: a grouped card, no color and no grain.
            shape.fill(NativeInk.card).allowsHitTesting(false).accessibilityHidden(true)
        } else {
            verbose
        }
    }

    private var verbose: some View {
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
    /// A paper card with an ink outline (the website's `inset 0 0 0 1.5px ink`). Native: a grouped card, no outline.
    func phoneOutlined(radius: CGFloat, fill: Color = Ink.card, line: CGFloat = 1.5) -> some View {
        modifier(PhoneOutlined(radius: radius, fill: fill, line: line))
    }
}

private struct PhoneOutlined: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var line: CGFloat
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.isNative {
            content.background(NativeInk.card, in: RoundedRectangle(cornerRadius: max(radius, 12), style: .continuous))
        } else {
            content.background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Ink.ink, lineWidth: line))
        }
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
    @Environment(\.look) private var look

    var body: some View {
        Group {
            if look.isNative {
                // Native: no line drawings.
                Color.clear
            } else if limitMotion || !PhoneMotion.on {
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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            // Native: a plain secondary line, no diamond and no mono.
            Text(text).font(.subheadline).foregroundStyle(NativeInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            verbose
        }
    }

    private var verbose: some View {
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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            // Native: a large title, with the count as its subtitle.
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.largeTitle.bold()).foregroundStyle(NativeInk.label)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let count { Text(Self.nativeCount(title, count)).font(.subheadline).foregroundStyle(NativeInk.secondary).lineLimit(1) }
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            verbose
        }
    }

    /// "46 transcripts" under Library, "128 dictations" under Dictations; a bare number elsewhere.
    static func nativeCount(_ title: String, _ count: String) -> String {
        guard Int(count) != nil else { return count }
        switch title {
        case "Library": return count == "1" ? "1 transcript" : "\(count) transcripts"
        case "Moments": return count == "1" ? "1 moment" : "\(count) moments"
        default: return count
        }
    }

    private var verbose: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(Ink.serif(size)).foregroundStyle(.lookInk)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let count { Text(count).font(Ink.mono(countSize)).foregroundStyle(.lookMute).lineLimit(1) }
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
    @Environment(\.look) private var look
    var body: some View {
        if look.isNative {
            // Native: a section header ("Today"), sentence case, no mono.
            Text(Self.nativeLabel(text)).font(.footnote).foregroundStyle(NativeInk.secondary)
                .padding(.top, 16).padding(.bottom, 2).padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(text).font(Ink.mono(size)).foregroundStyle(.lookMute)
                .padding(.top, 16).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// "Today · Fri Oct 23" → "Today"; other days keep their date.
    static func nativeLabel(_ text: String) -> String {
        text.components(separatedBy: " · ").first ?? text
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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative { native } else { verbose }
    }

    /// Native (Premium): a 34 pt capsule, gray at rest and the label color with the page's color for text when
    /// selected. No color dot: hue no longer names a source.
    private var native: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                if let count { Text("\(count)").monospacedDigit().opacity(0.7) }
            }
            .font(.system(size: size + 2, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(selected ? NativeInk.paper : NativeInk.label)
            .padding(.horizontal, 14).frame(minHeight: height + 2)
            .background(selected ? NativeInk.label : NativeInk.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(label), \($0)" } ?? label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var verbose: some View {
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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            // Native: the system's segmented picker.
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, label in Text(label).tag(value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            verbose
        }
    }

    private var verbose: some View {
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
        @Environment(\.look) private var look
        var body: some View {
            configuration.label
                // Native: the system's highlight (a dim), never a press-in.
                .scaleEffect(configuration.isPressed && !limitMotion && !look.isNative ? 0.98 : 1)
                .opacity(configuration.isPressed && (limitMotion || look.isNative) ? 0.6 : 1)
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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative { field.nativeSearchField(focused: focused) } else { field.verboseSearchField(focused: focused, height: height, empty: text.isEmpty) }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(.lookMute)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(.lookMute))
                .font(.system(size: look.isNative ? 17 : 15)).dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .foregroundStyle(.lookInk)
                .tint(look.isNative ? NativeInk.accent : Ink.accentText)
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
                        .foregroundStyle(.lookFaint)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
    }
}

private extension View {
    func verboseSearchField(focused: Bool, height: CGFloat, empty: Bool) -> some View {
        padding(.leading, 14).padding(.trailing, empty ? 14 : 0)
            .frame(minHeight: height)
            .background(PhoneInk.wash, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Ink.ink.opacity(0.35) : Color.clear, lineWidth: 1))
    }

    /// Native: the system search field's gray rounded rectangle.
    func nativeSearchField(focused: Bool) -> some View {
        padding(.leading, 10).padding(.trailing, 2)
            .frame(minHeight: 36)
            .background(NativeInk.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Rows

/// How a row's round mark looks: the source's panel color with its brand icon in ink, as on Home. Links are paper
/// with an ink outline (the Live captions treatment is the tile, not the row; links read as "kept from the web").
struct PhoneKindDot: View {
    var transcript: Transcript
    var size: CGFloat = 36
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            // Native: the kind's SF Symbol, tinted; no circle.
            Image(systemName: NativeSymbol.kind(transcript))   // brand: native
                .font(.system(size: size * 0.5))
                .foregroundStyle(NativeInk.accent)
                .frame(width: size * 0.75, height: size * 0.75)
                .accessibilityHidden(true)
        } else {
            verbose
        }
    }

    private var verbose: some View {
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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative { native } else { verbose }
    }

    /// Native: a standard list row (the container draws the card and separators): the tinted symbol, the title, the
    /// meta line in secondary, and the trailing state.
    private var native: some View {
        HStack(spacing: 12) {
            PhoneKindDot(transcript: transcript, size: min(dot, 48))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if transcript.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(NativeInk.secondary).accessibilityLabel("Pinned")   // brand: native
                    }
                    Text(transcript.title).font(.body).foregroundStyle(NativeInk.label).lineLimit(1)
                }
                Text(meta).font(.subheadline).foregroundStyle(NativeInk.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var verbose: some View {
        HStack(spacing: 12) {
            PhoneKindDot(transcript: transcript, size: min(dot, 48))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if transcript.pinned { IconGlyph(art: .iconPin, size: 12, color: Ink.mute).accessibilityLabel("Pinned") }
                    Text(transcript.title)
                        .font(serif ? Ink.serif(titleSize) : .system(size: sansSize, weight: .semibold))
                        .foregroundStyle(.lookInk).lineLimit(1)
                }
                Text(meta).font(.system(size: metaSize)).foregroundStyle(.lookMute).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 10).padding(.horizontal, 2)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(.lookHairline).frame(height: 1) }
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
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative { native } else { verbose }
    }

    /// Native: the length in monospaced digits over the state, both small; Cleaned in the accent.
    private var native: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if transcript.duration > 0 {
                Text(transcript.duration.timecode).font(.subheadline).monospacedDigit().foregroundStyle(NativeInk.secondary)
            }
            switch transcript.status {
            case .processing:
                HStack(spacing: 4) {
                    if transcript.processingDevice == Device.id { ProgressView().controlSize(.mini) }
                    Text(Self.shortStage(transcript)).lineLimit(1)
                }
                .font(.caption).foregroundStyle(NativeInk.secondary)
            case .failed:
                Label("Retry", systemImage: "exclamationmark.triangle")   // brand: native
                    .font(.caption.weight(.semibold)).foregroundStyle(NativeInk.danger)
            case .ready:
                Text(Self.cleaned(transcript) ? "Cleaned" : "Original").font(.caption)
                    .foregroundStyle(Self.cleaned(transcript) ? NativeInk.accent : NativeInk.secondary)
            }
        }
        .fixedSize()
    }

    private var verbose: some View {
        VStack(alignment: .trailing, spacing: 3) {
            switch transcript.status {
            case .processing:
                HStack(spacing: 5) {
                    if transcript.processingDevice == Device.id { ProgressView().controlSize(.mini) } else { IconGlyph(art: .iconWaitingForMac, size: 14, color: Ink.dim) }
                    Text(Self.shortStage(transcript)).lineLimit(1)
                }
                .font(.system(size: size, weight: .semibold)).foregroundStyle(.lookDim)
            case .failed:
                HStack(spacing: 4) { IconGlyph(art: .iconAttention, size: 13, color: Ink.danger); Text("Retry") }
                    .font(.system(size: size, weight: .semibold)).foregroundStyle(Ink.danger)
            case .ready:
                Text(Self.cleaned(transcript) ? "Cleaned" : "Original")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Self.cleaned(transcript) ? Ink.accentText : Ink.dim)
            }
            if transcript.duration > 0 {
                Text(transcript.duration.timecode).font(Ink.mono(mono)).foregroundStyle(.lookDim)
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
