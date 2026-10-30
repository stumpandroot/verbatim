import SwiftUI
#if os(iOS)
import UIKit
#endif

// The refined look's kit (DESIGN.md §13), shared by the Mac and iPhone apps: the content layer that Verbose draws
// while Apple draws the chrome. Warm paper, off-white cards with no outlines or hard shadows, butter, sage, and petal
// tiles, the persimmon Record card with its rings, colored kind badges and speaker chips, colored icon squares, and
// the serif for large titles, section titles, and reading text. Colors come from `Refined` (Tokens.swift) through
// `RefinedRules`; nothing here picks a hex value or a Verbose-style token. The player bar, the recorder's clock panel,
// and reading text are in RefinedPlayback.swift.
//
// Every size scales with Dynamic Type on iPhone, tap targets are 44 pt or larger, Limit animation stills the rings and
// presses, and Increase Contrast gives cards a hairline edge.

/// Which device's sizes the kit uses.
enum RefinedPlatform {
    #if os(macOS)
    static let mac = true
    #else
    static let mac = false
    #endif
    static func radius(_ role: RefinedRules.RadiusRole) -> CGFloat { CGFloat(RefinedRules.radius(role, mac: mac)) }
}

// MARK: - Palette

/// Where this device keeps its appearance settings (Palette), never synced: the App Group on iPhone, so the widgets
/// could read it; the Mac's own defaults. One instance for the process, so every `@AppStorage` reading a setting
/// observes the same object it's written through.
enum AppearanceStore {
    static let defaults: UserDefaults = {
        #if os(iOS)
        return UserDefaults(suiteName: "group.co.stumpandroot.verbatim.ios") ?? .standard
        #else
        return .standard
        #endif
    }()
}

extension AppPalette {
    /// The palette chosen on this device. Setting it updates every kit view at once (they observe the same store).
    static var current: AppPalette {
        get { AppPalette(stored: AppearanceStore.defaults.string(forKey: key)) }
        set { AppearanceStore.defaults.set(newValue.rawValue, forKey: key) }
    }
}

private struct PaletteOverrideKey: EnvironmentKey {
    static let defaultValue: AppPalette? = nil
}

extension EnvironmentValues {
    /// Draws the kit in this palette instead of the stored one: Settings' palette thumbnails and the previews.
    var paletteOverride: AppPalette? {
        get { self[PaletteOverrideKey.self] }
        set { self[PaletteOverrideKey.self] = newValue }
    }
}

/// The palette a kit view draws in: the override if one is set, otherwise the stored setting, live.
@propertyWrapper
struct CurrentPalette: DynamicProperty {
    @AppStorage(AppPalette.key, store: AppearanceStore.defaults) private var raw = AppPalette.full.rawValue
    @Environment(\.paletteOverride) private var override
    init() {}
    var wrappedValue: AppPalette { override ?? AppPalette(stored: raw) }
}

extension Refined {
    private static func table<V>(_ f: (RefinedHue, AppPalette) -> V) -> [AppPalette: [RefinedHue: V]] {
        Dictionary(uniqueKeysWithValues: AppPalette.allCases.map { p in
            (p, Dictionary(uniqueKeysWithValues: RefinedHue.allCases.map { ($0, f($0, p)) }))
        })
    }
    private static let fills = Refined.table { Refined.color(RefinedRules.fill($0, palette: $1)) }
    private static let onFills = Refined.table { Refined.color(RefinedRules.onFill($0, palette: $1)) }
    private static let badges = Dictionary(uniqueKeysWithValues: RefinedHue.allCases.map { ($0, Refined.color(RefinedRules.badgeFill($0))) })
    private static let onBadges = Dictionary(uniqueKeysWithValues: RefinedHue.allCases.map { ($0, Refined.color(RefinedRules.onBadge($0))) })
    private static let ringColors = Dictionary(uniqueKeysWithValues: AppPalette.allCases.map { ($0, Refined.color(RefinedRules.rings($0))) })
    private static let chipColors = Dictionary(uniqueKeysWithValues: AppPalette.allCases.map { ($0, Refined.color(RefinedRules.readyChip($0))) })
    private static let patternInks = Refined.table { Refined.color(RefinedRules.tilePatternInk($0, palette: $1)) }

    /// A palette surface's fill (the Record card, a tile) and what sits on it.
    static func fill(_ hue: RefinedHue, _ palette: AppPalette) -> Color { fills[palette]?[hue] ?? card }
    static func onFill(_ hue: RefinedHue, _ palette: AppPalette) -> Color { onFills[palette]?[hue] ?? ink }
    /// A badge, chip, or icon square's fill (Full in both palettes) and its glyph or text.
    static func badge(_ hue: RefinedHue) -> Color { badges[hue] ?? neutralSquare }
    static func onBadge(_ hue: RefinedHue) -> Color { onBadges[hue] ?? ink }
    /// The Record card's rings and ready chip.
    static func rings(_ palette: AppPalette) -> Color { ringColors[palette] ?? separator }
    static func readyChip(_ palette: AppPalette) -> Color { chipColors[palette] ?? neutral }
    /// A tile's line pattern: ink at 13% on a Full fill, 9% on a Soft tint or the off-white tile.
    static func tilePattern(_ hue: RefinedHue, _ palette: AppPalette) -> Color { patternInks[palette]?[hue] ?? separator }
}

// MARK: - Type

extension RefinedRules.TextRole {
    /// The Dynamic Type style a role scales with on iPhone.
    var textStyle: Font.TextStyle {
        switch self {
        case .largeTitle, .clock: return .largeTitle
        case .transcriptTitle, .recordTitle: return .title
        case .sectionTitle: return .title2
        case .reading, .body, .rowTitle, .tileName: return .body
        case .hint: return .callout
        case .meta, .chip: return .footnote
        case .caption: return .caption
        }
    }
}

/// A role's font at its size, scaled with Dynamic Type, with reading text's line spacing.
struct RefinedFont: ViewModifier {
    let role: RefinedRules.TextRole
    let weight: Font.Weight
    @ScaledMetric private var size: CGFloat

    init(_ role: RefinedRules.TextRole, weight: Font.Weight) {
        self.role = role
        self.weight = weight
        _size = ScaledMetric(wrappedValue: CGFloat(role.size(mac: RefinedPlatform.mac)), relativeTo: role.textStyle)
    }

    func body(content: Content) -> some View {
        let base = CGFloat(role.size(mac: RefinedPlatform.mac))
        let spacing = CGFloat(RefinedRules.lineSpacing(role, mac: RefinedPlatform.mac)) * size / base
        content
            .font(.system(size: size, weight: weight, design: role.serif ? .serif : .default))
            .lineSpacing(spacing)
    }
}

extension View {
    /// Sets text in one of the kit's roles: `.refinedFont(.sectionTitle)`.
    func refinedFont(_ role: RefinedRules.TextRole, weight: Font.Weight = .regular) -> some View {
        modifier(RefinedFont(role, weight: weight))
    }
}

// MARK: - Surfaces and presses

/// A press that lands fast and lets go smoothly: scale 0.98, or a dim under Limit animation.
struct RefinedPress: ButtonStyle {
    @Environment(\.limitMotion) private var limitMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !limitMotion ? 0.98 : 1)
            .opacity(configuration.isPressed && limitMotion ? 0.8 : 1)
            .animation(limitMotion ? Motion.fade : Motion.press, value: configuration.isPressed)
    }
}

/// An opaque content surface: a fill in a continuous rounded rectangle, with no outline or shadow, and a hairline
/// edge only under Increase Contrast (an off-white card on paper measures about 1.1:1).
struct RefinedSurface: ViewModifier {
    var fill: Color
    var radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill, in: shape)
            .overlay { if contrast == .increased { shape.strokeBorder(Refined.separator, lineWidth: 1) } }
            .clipShape(shape)
    }
}

extension View {
    func refinedSurface(_ fill: Color, radius: CGFloat) -> some View { modifier(RefinedSurface(fill: fill, radius: radius)) }
}

// MARK: - Record card

/// A named action on the Record card for VoiceOver's actions rotor ("Record a meeting").
struct RecordCardAction: Identifiable {
    var name: String
    var perform: () -> Void
    var id: String { name }
}

/// The Record card (mockup: Home): the persimmon card with the ring drawing, the ready chip ("Ready · iPhone
/// microphone"), the serif "Record", its hint, and the record disc. iPhone 168 pt tall with a 22 pt radius, Mac 150 pt
/// with 18. Soft palette: the persimmon tint with ink and persimmon rings. VoiceOver reads it as one button: activating
/// it is the plain Record, and each way to record is a named action. Touch and hold (iPhone) or right-click (Mac) for
/// Record as stays with the screen that places the card; use `RecordCardFace` under a custom gesture.
struct RecordCard: View {
    var status: String
    var hint: String
    var title = "Record"
    var accessibilityHint: String? = nil
    var compact = false
    var actions: [RecordCardAction] = []
    var action: () -> Void

    var body: some View {
        Button(action: action) { RecordCardFace(status: status, title: title, hint: hint, compact: compact) }
            .buttonStyle(RefinedPress())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(status)
            .accessibilityHint(accessibilityHint ?? hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityActions {
                ForEach(actions) { a in Button(a.name, action: a.perform) }
            }
    }
}

/// The Record card's drawing, with no button of its own. Compact (Edit Home's size) is one slim row: the serif title
/// over the status, and a smaller disc.
struct RecordCardFace: View {
    var status: String
    var title = "Record"
    var hint: String
    var compact = false
    @CurrentPalette private var palette: AppPalette
    private let mac = RefinedPlatform.mac

    /// Spelled out: the palette's wrapper is private, which would keep the synthesized one to this file.
    init(status: String, title: String = "Record", hint: String, compact: Bool = false) {
        self.status = status; self.title = title; self.hint = hint; self.compact = compact
    }

    var body: some View {
        let ink = Refined.onFill(.persimmon, palette)
        let art = RefinedRules.recordArt(mac: mac, compact: compact)
        Group {
            if compact {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).refinedFont(.sectionTitle)
                        Text(status).refinedFont(.chip, weight: .semibold).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    // Room for the disc, which the art draws in the rings' own coordinates.
                    Color.clear.frame(width: art.textReserve, height: art.disc)
                }
                .padding(.horizontal, art.padding).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ReadyChip(text: status)
                    Spacer(minLength: 14)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: mac ? 3 : 2) {
                            Text(title).refinedFont(.recordTitle)
                            // Full ink, not the mockup's 80%: ink at 80% on the fill measures 3.6:1.
                            Text(hint).refinedFont(.hint).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        // The text stops short of the disc (the mockup's 90 pt), at every text size.
                        Color.clear.frame(width: max(0, art.textReserve - 12), height: 1)
                    }
                }
                .padding(.horizontal, art.padding).padding(.vertical, mac ? 18 : 16)
                .frame(maxWidth: .infinity, minHeight: mac ? 150 : 168, alignment: .leading)
            }
        }
        .foregroundStyle(ink)
        .background { RecordArtLayer(art: art, color: Refined.rings(palette), lineWidth: mac ? 2.2 : 2.4) }
        .refinedSurface(Refined.fill(.persimmon, palette), radius: RefinedPlatform.radius(.record))
        .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.record), style: .continuous))
    }
}

/// The Record card's rings and record disc in one coordinate system: the disc is drawn inside the rings' square at
/// the innermost ring's center, and the square is placed so that point lands where `RefinedRules.RecordArt` puts the
/// disc on this card. Clipped by the card's surface.
struct RecordArtLayer: View {
    var art: RefinedRules.RecordArt
    var color: Color
    var lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let side = CGFloat(art.side)
            let origin = art.ringOrigin(width: Double(geo.size.width), height: Double(geo.size.height))
            ZStack(alignment: .topLeading) {
                RecordRings(color: color, lineWidth: lineWidth)
                    .frame(width: side, height: side)
                RecordDiscMark(size: CGFloat(art.disc))
                    .position(x: side * CGFloat(RefinedRules.RecordArt.innerCenter.x), y: side * CGFloat(RefinedRules.RecordArt.innerCenter.y))
            }
            .frame(width: side, height: side)
            .position(x: CGFloat(origin.x) + side / 2, y: CGFloat(origin.y) + side / 2)
        }
        .accessibilityHidden(true)
    }
}

/// The small status chip on the Record card and the recorder: a dot and a word ("Ready · iPhone microphone",
/// "Recording").
struct ReadyChip: View {
    var text: String
    @CurrentPalette private var palette: AppPalette
    var body: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 7, height: 7)
            Text(text).refinedFont(.chip, weight: .semibold).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Refined.readyChip(palette), in: Capsule())
    }
}

/// The record disc: an ink circle with the system's red dot (the only place red appears at rest). Ink fixed on the
/// Full card; the reading ink on Soft, so it still shows on the dark tint.
struct RecordDiscMark: View {
    var size: CGFloat = 56
    @CurrentPalette private var palette: AppPalette
    var body: some View {
        Circle()
            .fill(palette == .full ? Refined.onFill : Refined.ink)
            .frame(width: size, height: size)
            .overlay(Circle().fill(Refined.recordRed).frame(width: size * 0.39, height: size * 0.39))
            .accessibilityHidden(true)
    }
}

/// The Record card's drawing: three rings anchored low on one axis, and the axis. They breathe slowly (5.2 s, a few
/// percent) while on screen; Limit animation holds them still.
struct RecordRings: View {
    var color: Color
    var lineWidth: CGFloat = 2.4
    var breathing = true
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        LoopTimeline(running: breathing && !limitMotion) { date in
            Canvas { ctx, size in
                let s = min(size.width, size.height) / 300
                let t = breathing && !limitMotion ? date.timeIntervalSinceReferenceDate : 0
                var p = Path()
                for (i, ring) in [(150.0, 120.0), (180.0, 90.0), (210.0, 60.0)].enumerated() {
                    let breath = breathing && !limitMotion ? 1 + 0.035 * sin(2 * .pi * t / 5.2 - Double(i) * 0.6) : 1
                    let r = ring.1 * breath
                    p.addEllipse(in: CGRect(x: (150 - r) * s, y: (ring.0 - r) * s, width: 2 * r * s, height: 2 * r * s))
                }
                p.move(to: CGPoint(x: 150 * s, y: 0)); p.addLine(to: CGPoint(x: 150 * s, y: 300 * s))
                ctx.stroke(p, with: .color(color), lineWidth: lineWidth * s)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tiles

/// A Home tile (mockup: Home's four): a bare glyph top left and the name at the foot, on its hue's fill (butter
/// Dictate, sage Import, petal What's playing or App audio, the card for anything else), with a quiet line pattern in
/// its top-right corner for what it does (`RefinedRules.tilePattern(forTile:)`). The Mac shows the shortcut at the
/// trailing edge of the name. iPhone 74 pt tall with a 16 pt radius, Mac 84 pt with 14. Compact (Edit Home's size,
/// and the Mac recorder mockup's row) is 58 pt: the name alone on the Mac, a smaller glyph over it on iPhone.
struct ColorTile: View {
    var title: String
    var art: BrandArt
    var hue: RefinedHue
    var pattern: RefinedRules.TilePattern? = nil
    var shortcut: String? = nil
    var compact = false
    var action: () -> Void

    init(title: String, art: BrandArt, hue: RefinedHue, pattern: RefinedRules.TilePattern? = nil, shortcut: String? = nil,
         compact: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.art = art; self.hue = hue; self.pattern = pattern; self.shortcut = shortcut
        self.compact = compact; self.action = action
    }

    var body: some View {
        Button(action: action) { ColorTileFace(title: title, art: art, hue: hue, pattern: pattern, shortcut: shortcut, compact: compact) }
            .buttonStyle(RefinedPress())
            .accessibilityLabel(title)
            .accessibilityHint(shortcut.map { "Shortcut: " + Keycap.spoken($0) } ?? "")
    }
}

/// A tile's drawing, with no button of its own: for a tile that's a menu (Import on iPhone) or that carries a popover.
struct ColorTileFace: View {
    var title: String
    var art: BrandArt
    var hue: RefinedHue
    var pattern: RefinedRules.TilePattern? = nil
    var shortcut: String? = nil
    var compact = false
    @CurrentPalette private var palette: AppPalette
    @Environment(\.colorSchemeContrast) private var contrast
    private let mac = RefinedPlatform.mac

    init(title: String, art: BrandArt, hue: RefinedHue, pattern: RefinedRules.TilePattern? = nil, shortcut: String? = nil,
         compact: Bool = false) {
        self.title = title; self.art = art; self.hue = hue; self.pattern = pattern; self.shortcut = shortcut; self.compact = compact
    }

    var body: some View {
        let ink = Refined.onFill(hue, palette)
        VStack(alignment: .leading, spacing: 0) {
            if !(compact && mac) { IconGlyph(art: art, size: compact ? 18 : 22, color: ink) }
            Spacer(minLength: compact ? 4 : 8)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).refinedFont(.tileName, weight: .semibold).lineLimit(2).minimumScaleFactor(compact ? 0.8 : 1)
                Spacer(minLength: 4)
                if let shortcut { Text(shortcut).refinedFont(.caption).accessibilityHidden(true) }
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, compact && !mac ? 10 : 14).padding(.vertical, compact ? 10 : (mac ? 14 : 12))
        .frame(maxWidth: .infinity, minHeight: compact ? 58 : (mac ? 84 : 74), alignment: .leading)
        // The pattern sits on the fill, under the glyph and name, clipped to the tile. Off under Increase Contrast.
        .background(alignment: .topTrailing) {
            if let pattern, contrast != .increased {
                TilePatternArt(pattern: pattern, color: Refined.tilePattern(hue, palette), scale: compact ? 0.75 : 1)
            }
        }
        .refinedSurface(Refined.fill(hue, palette), radius: RefinedPlatform.radius(.tile))
        .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.tile), style: .continuous))
    }
}

/// A tile's line pattern (mockup: Home): thin round-capped lines in the pattern's own box, placed past the tile's
/// top-right corner as the mockup does, so the tile's clip cuts it. No animation, hidden from VoiceOver.
struct TilePatternArt: View {
    var pattern: RefinedRules.TilePattern
    var color: Color
    var scale: CGFloat = 1

    /// The box the pattern is drawn in, its size on the tile, and how far past the top-right corner it sits.
    struct Spec {
        var box: CGSize
        var size: CGSize
        var dx: CGFloat
        var dy: CGFloat
    }

    static func spec(_ p: RefinedRules.TilePattern) -> Spec {
        switch p {
        case .waves: return Spec(box: CGSize(width: 120, height: 90), size: CGSize(width: 80, height: 60), dx: 14, dy: -8)
        case .chevrons: return Spec(box: CGSize(width: 110, height: 100), size: CGSize(width: 72, height: 66), dx: 10, dy: -18)
        case .offsetCircles: return Spec(box: CGSize(width: 110, height: 110), size: CGSize(width: 74, height: 74), dx: 18, dy: -22)
        case .shortLines: return Spec(box: CGSize(width: 100, height: 90), size: CGSize(width: 64, height: 58), dx: 6, dy: -2)
        case .captionLines: return Spec(box: CGSize(width: 110, height: 90), size: CGSize(width: 70, height: 58), dx: 8, dy: -4)
        case .pageLines: return Spec(box: CGSize(width: 110, height: 80), size: CGSize(width: 72, height: 52), dx: 8, dy: -4)
        case .pageCurl: return Spec(box: CGSize(width: 110, height: 90), size: CGSize(width: 66, height: 54), dx: 8, dy: -8)
        case .checklist: return Spec(box: CGSize(width: 110, height: 80), size: CGSize(width: 72, height: 52), dx: 8, dy: -4)
        case .folderTab: return Spec(box: CGSize(width: 110, height: 90), size: CGSize(width: 72, height: 58), dx: 12, dy: -10)
        case .bubbles: return Spec(box: CGSize(width: 110, height: 100), size: CGSize(width: 70, height: 64), dx: 10, dy: -10)
        case .dictationLines: return Spec(box: CGSize(width: 120, height: 90), size: CGSize(width: 76, height: 57), dx: 12, dy: -6)
        }
    }

    var body: some View {
        let spec = Self.spec(pattern)
        TilePatternShape(pattern: pattern, box: spec.box)
            // The mockup's 2.2-unit stroke, in the box's units.
            .stroke(color, style: StrokeStyle(lineWidth: 2.2 * spec.size.width / spec.box.width * scale, lineCap: .round, lineJoin: .round))
            .frame(width: spec.size.width * scale, height: spec.size.height * scale)
            .offset(x: spec.dx * scale, y: spec.dy * scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A tile pattern's lines, drawn in its box's coordinates and scaled to the frame.
struct TilePatternShape: Shape {
    var pattern: RefinedRules.TilePattern
    var box: CGSize

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / box.width, sy = rect.height / box.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var p = Path()
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            p.move(to: pt(first.0, first.1))
            for q in points.dropFirst() { p.addLine(to: pt(q.0, q.1)) }
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            p.addEllipse(in: CGRect(x: rect.minX + (cx - r) * sx, y: rect.minY + (cy - r) * sy, width: 2 * r * sx, height: 2 * r * sy))
        }
        /// A sine line across the box, in four half-waves of 30 units (the mockup's "c10-12 20-12 30 0 s…").
        func wave(_ y: CGFloat, _ a: CGFloat, width: CGFloat = 120) {
            p.move(to: pt(0, y))
            var x: CGFloat = 0, up = true
            while x < width - 0.5 {
                let d: CGFloat = up ? -a : a
                p.addCurve(to: pt(x + 30, y), control1: pt(x + 10, y + d), control2: pt(x + 20, y + d))
                x += 30; up.toggle()
            }
        }
        switch pattern {
        case .waves:
            for y: CGFloat in [18, 36, 54, 72] { wave(y, 12) }
        case .chevrons:
            for d: CGFloat in [0, 18, 36, 54] { line([(15, 10 + d), (55, 40 + d), (95, 10 + d)]) }
        case .offsetCircles:
            for c: (CGFloat, CGFloat) in [(55, 50), (69, 36), (83, 22), (95, 9)] { circle(c.0, 55, c.1) }
        case .shortLines:
            for l: (CGFloat, CGFloat) in [(16, 96), (32, 84), (48, 96), (64, 70), (80, 90)] { line([(20, l.0), (l.1, l.0)]) }
        case .captionLines:
            for l: (CGFloat, CGFloat) in [(22, 40), (38, 26), (62, 44), (78, 30)] { line([(55 - l.1, l.0), (55 + l.1, l.0)]) }
        case .pageLines:
            line([(55, 8), (55, 76)])
            for l: (CGFloat, CGFloat) in [(18, 39), (32, 34), (46, 39), (60, 26)] {
                line([(47 - l.1, l.0), (47, l.0)]); line([(63, l.0), (63 + l.1, l.0)])
            }
        case .pageCurl:
            line([(22, 84), (22, 6), (98, 6), (98, 62)])
            p.move(to: pt(98, 62)); p.addQuadCurve(to: pt(76, 84), control: pt(94, 80)); p.addLine(to: pt(22, 84))
            p.move(to: pt(98, 62)); p.addQuadCurve(to: pt(76, 84), control: pt(78, 64))
            for l: (CGFloat, CGFloat) in [(26, 86), (40, 86), (54, 70)] { line([(34, l.0), (l.1, l.0)]) }
        case .checklist:
            for (i, y) in ([18, 42, 66] as [CGFloat]).enumerated() {
                line([(10, y), (16, y + 6), (28, y - 6)])
                line([(40, y), (102 - CGFloat(i) * 14, y)])
            }
        case .folderTab:
            line([(22, 30), (22, 18), (50, 18), (58, 28), (106, 28), (106, 74)])
            line([(10, 36), (42, 36), (50, 46), (98, 46), (98, 86), (10, 86), (10, 36)])
        case .bubbles:
            circle(22, 86, 6); circle(42, 66, 10); circle(74, 34, 24)
        case .dictationLines:
            wave(18, 10)
            for l: (CGFloat, CGFloat) in [(44, 120), (62, 96), (80, 112)] { line([(6, l.0), (l.1, l.0)]) }
        }
        return p
    }
}

// MARK: - Actions

/// The kit's buttons on its own surfaces (the recording card's Mark moment, Pause, and Stop and transcribe; New thought,
/// a journal entry's play, Edit Home): quiet is a wash with ink text (the neutral wash on paper and cards; on the
/// Record card's fill, pass the ready chip's, since the neutral wash falls under 4.5:1 there with Increase Contrast),
/// strong is ink with light text. `ink` is the text color where the button sits (the palette's ink on a fill), and
/// `light` the strong button's text. Mac 32 pt with an 8 pt radius, iPhone a capsule at least 44 pt tall. System
/// chrome keeps the system's own buttons.
struct RefinedActionStyle: ButtonStyle {
    enum Kind { case quiet, strong }
    var kind: Kind = .quiet
    var ink: Color = Refined.ink
    var light: Color = Refined.paper
    var wash: Color = Refined.neutral

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, style: self)
    }

    private struct ActionBody: View {
        let configuration: ButtonStyleConfiguration
        let style: RefinedActionStyle
        @Environment(\.isEnabled) private var enabled
        @Environment(\.limitMotion) private var limitMotion
        private let mac = RefinedPlatform.mac

        var body: some View {
            let strong = style.kind == .strong
            let shape = RoundedRectangle(cornerRadius: mac ? 8 : 22, style: .continuous)
            configuration.label
                .refinedFont(.hint, weight: .semibold)
                .lineLimit(1)
                .foregroundStyle(strong ? style.light : style.ink)
                .padding(.horizontal, mac ? 14 : 16)
                .frame(minHeight: mac ? 32 : CGFloat(RefinedRules.minTapTarget))
                .background(strong ? style.ink : style.wash, in: shape)
                .contentShape(shape)
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.98 : 1)
                .animation(limitMotion ? Motion.fade : Motion.press, value: configuration.isPressed)
        }
    }
}

/// A compact text action at a row's trailing edge (Recent's Clean up): the label in the accent text color, semibold,
/// at the subheadline size (it scales with Dynamic Type), with no fill. The hit area is the content shape, not the
/// text: 44 by 44 pt on iPhone, the row's height on the Mac. Put it over a row's button, never inside its label (macOS
/// 26 click safety), and align it with the row's title (`.rowTitle`).
struct RefinedTextActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TextActionBody(configuration: configuration) }

    private struct TextActionBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        private let mac = RefinedPlatform.mac

        var body: some View {
            configuration.label
                .modifier(RefinedTextActionFont())
                .lineLimit(1)
                .foregroundStyle(Refined.accentText)
                .padding(.horizontal, mac ? 4 : 8)
                .frame(minWidth: mac ? 0 : CGFloat(RefinedRules.minTapTarget), minHeight: mac ? 28 : CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
        }
    }
}

/// The text action's type: subheadline semibold on iPhone, the Mac's hint size semibold.
struct RefinedTextActionFont: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if RefinedPlatform.mac {
            content.refinedFont(.hint, weight: .semibold)
        } else {
            content.font(.subheadline.weight(.semibold))
        }
    }
}

extension VerticalAlignment {
    private enum RowTitle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// The middle of a row's title line (`PaperRow` sets it), so a trailing text action lines up with the title, not
    /// with the middle of a two-line row. Elsewhere it's the middle.
    static let rowTitle = VerticalAlignment(RowTitle.self)
}

// MARK: - Filters and search

/// A filter chip (the Library's All, Voice notes, Meetings, …): a capsule on the neutral wash with ink text at rest,
/// and the persimmon tint with accent text in semibold when chosen. No outline. On iPhone the tap target is 44 pt
/// tall around the capsule. VoiceOver reads it as a button, selected when chosen; put chips in a `RefinedChipRow`.
struct RefinedChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    private let mac = RefinedPlatform.mac

    var body: some View {
        Button(action: action) {
            Text(title).refinedFont(.hint, weight: selected ? .semibold : .regular).lineLimit(1)
                .foregroundStyle(selected ? Refined.accentText : Refined.ink)
                .padding(.horizontal, mac ? 12 : 14).padding(.vertical, mac ? 5 : 7)
                .background(selected ? Refined.persimmonTint : Refined.neutral, in: Capsule())
                .frame(minHeight: mac ? 26 : CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row of filter chips, read by VoiceOver as one group ("Filter"): one line that scrolls sideways, with the page's
/// margin inside it so the first chip lines up with the content and the last one scrolls clear of the edge.
struct RefinedChipRow<Content: View>: View {
    var label = "Filter"
    var margin: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, margin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A search field on the page, for a screen whose window has no system search field (the Mac Library in Verbose
/// style): the field color, a magnifying glass, the prompt, an optional shortcut at the end ("⌘K"), and a clear
/// button. Return runs `onSubmit`.
struct RefinedSearchField: View {
    @Binding var text: String
    var prompt: String
    var shortcut: String?
    var onSubmit: () -> Void
    @FocusState private var focused: Bool
    private let mac = RefinedPlatform.mac

    init(text: Binding<String>, prompt: String, shortcut: String? = nil, onSubmit: @escaping () -> Void = {}) {
        _text = text; self.prompt = prompt; self.shortcut = shortcut; self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: mac ? 12 : 15, weight: .medium)).foregroundStyle(Refined.mute)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Refined.mute))
                .textFieldStyle(.plain)
                .refinedFont(.body)
                .foregroundStyle(Refined.ink)
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: mac ? 12 : 15)).foregroundStyle(Refined.mute)
                        .frame(minWidth: mac ? 20 : 44, minHeight: mac ? 20 : 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else if let shortcut {
                Text(shortcut).refinedFont(.caption).foregroundStyle(Refined.mute).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, mac ? 8 : 10)
        .frame(minHeight: mac ? 30 : 38)
        .background(Refined.field, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous))
    }
}

#if os(iOS)
/// The system's search field (`UISearchTextField`, the field `.searchable` draws) placed on the page under a screen's
/// serif title (the iPhone Library), where the navigation bar's drawer would put it above the title: the system's
/// magnifying glass, clear button, keyboard, and Dynamic Type, on the field color. Return runs `onSubmit`.
struct SystemSearchField: UIViewRepresentable {
    @Binding var text: String
    var prompt: String
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> UISearchTextField {
        let f = UISearchTextField()
        f.placeholder = prompt
        f.accessibilityLabel = prompt
        f.font = .preferredFont(forTextStyle: .body)
        f.adjustsFontForContentSizeCategory = true
        f.backgroundColor = Refined.uiColor(RefinedHex.field)
        f.textColor = Refined.uiColor(RefinedHex.ink)
        f.returnKeyType = .search
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.text = text
        return f
    }

    func updateUIView(_ f: UISearchTextField, context: Context) {
        context.coordinator.parent = self
        if f.text != text { f.text = text }
        if f.placeholder != prompt { f.placeholder = prompt; f.accessibilityLabel = prompt }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SystemSearchField
        init(_ parent: SystemSearchField) { self.parent = parent }
        @objc func changed(_ f: UITextField) { parent.text = f.text ?? "" }
        func textFieldShouldClear(_ f: UITextField) -> Bool { parent.text = ""; return true }
        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            f.resignFirstResponder()
            parent.onSubmit()
            return true
        }
    }
}
#endif

// MARK: - Segmented control

/// A transcript's views (Original, Cleaned, Summary, …) as the mockup's segmented control: the `track` with the chosen
/// segment on the card. iPhone shares the width equally while the titles fit and scrolls sideways when they don't (a
/// template's result adds a segment named for it); the Mac sizes each segment to its title. VoiceOver reads a group of
/// buttons with the chosen one selected; iPhone's tap targets are 44 pt tall around the 32 pt track.
struct RefinedSegmented<Value: Hashable>: View {
    var label = "View"
    var options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.limitMotion) private var limitMotion
    private var mac: Bool { RefinedPlatform.mac }

    init(label: String = "View", options: [(Value, String)], selection: Binding<Value>) {
        self.label = label; self.options = options; _selection = selection
    }

    var body: some View {
        Group {
            if mac {
                track(equal: false)
            } else {
                ViewThatFits(in: .horizontal) {
                    track(equal: true)
                    ScrollView(.horizontal, showsIndicators: false) { track(equal: false) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func track(equal: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                segment(value, title, equal: equal)
            }
        }
        .padding(2)
        .background(Refined.track, in: RoundedRectangle(cornerRadius: mac ? 8 : 9, style: .continuous))
    }

    private func segment(_ value: Value, _ title: String, equal: Bool) -> some View {
        let on = selection == value
        let shape = RoundedRectangle(cornerRadius: mac ? 6 : 7, style: .continuous)
        return Button {
            guard selection != value else { return }
            if limitMotion { selection = value } else { withAnimation(Motion.snap) { selection = value } }
        } label: {
            Text(title).refinedFont(mac ? .meta : .hint, weight: .semibold).lineLimit(1)
                .foregroundStyle(on ? Refined.ink : Refined.dim)
                .padding(.horizontal, mac ? 14 : 12).padding(.vertical, mac ? 4 : 6)
                .frame(maxWidth: equal ? .infinity : nil)
                .background {
                    if on { shape.fill(Refined.card).shadow(color: Refined.separator, radius: 1.5, y: 1) }
                }
                .contentShape(Rectangle().inset(by: mac ? 0 : -6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Kinds and tags in a header

/// A transcript's kind as its colored chip, which opens a menu of every kind (the header's meta line): "Suggested by
/// Verbose" while Verbose picked it. iPhone's tap target is 44 pt tall.
struct KindPickerChip: View {
    var kind: RecordingKind?
    var isAuto: Bool
    var onPick: (RecordingKind) -> Void

    var body: some View {
        Menu {
            Section(isAuto ? "Suggested by Verbose. Pick another and it stays." : "You picked this. Verbose won\u{2019}t change it.") {
                ForEach(RecordingKind.pickable) { k in
                    Button { onPick(k) } label: {
                        if k == kind { Label(k.label, systemImage: "checkmark") } else { Text(k.label) }
                    }
                }
            }
        } label: {
            KindChip(kind: kind)
                .frame(minHeight: RefinedPlatform.mac ? 0 : CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change the kind")
        .accessibilityLabel("Kind: \(RecordingKind.refinedName(kind)). Change")
    }
}

/// A transcript's tags as quiet capsules (right-click or touch and hold one to remove it), then "+ Tag". Put them in a
/// `FlowRow` with the rest of the meta line.
struct RefinedTagChips: View {
    var tags: [String]
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void
    @State private var adding = false
    @State private var draft = ""

    init(tags: [String], onAdd: @escaping (String) -> Void, onRemove: @escaping (String) -> Void) {
        self.tags = tags; self.onAdd = onAdd; self.onRemove = onRemove
    }

    var body: some View {
        ForEach(tags, id: \.self) { tag in
            Text(tag).refinedFont(.chip).foregroundStyle(Refined.ink).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Refined.neutral, in: Capsule())
                .contextMenu { Button(role: .destructive) { onRemove(tag) } label: { Label("Remove tag", systemImage: "xmark") } }
                .accessibilityLabel("Tag: \(tag)")
        }
        Button { draft = ""; adding = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("Tag").refinedFont(.chip)
            }
            .foregroundStyle(Refined.dim)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Refined.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Add a tag")
        .accessibilityLabel("Add a tag")
        .alert("Add a tag", isPresented: $adding) {
            TextField("Tag", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !t.isEmpty { onAdd(t) }
            }
        }
    }
}

/// A round button on the page with a glyph and no title (the Mac transcript's Back in Verbose style, where the window
/// has no toolbar items of its own): the card in a 30 pt circle.
struct RefinedCircleButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Refined.ink)
                .frame(width: 30, height: 30)
                .background(Refined.card, in: Circle())
                .shadow(color: Refined.separator, radius: 1.5, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(label)
    }
}

// MARK: - Cards and rows

/// The off-white grouped container (Recent, Library's rows, Settings' groups): no outline, no shadow, the card
/// radius. Put `PaperDivider`s between rows, or use `PaperList`.
struct PaperCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }
}

/// The hairline between rows in a card, inset to where the row's text starts (iPhone), or from both sides (Mac).
struct PaperDivider: View {
    var leading: CGFloat = 14
    var trailing: CGFloat = 0
    var body: some View {
        Rectangle().fill(Refined.separator).frame(height: 1)
            .padding(.leading, leading).padding(.trailing, trailing)
            .accessibilityHidden(true)
    }
}

/// A card of rows with a hairline between each: `PaperList(recent, id: \.id, inset: 60) { RowView($0) }`.
struct PaperList<Data: RandomAccessCollection, ID: Hashable, Row: View>: View {
    var data: Data
    var id: KeyPath<Data.Element, ID>
    var inset: CGFloat = 14
    var trailingInset: CGFloat = 0
    var row: (Data.Element) -> Row

    init(_ data: Data, id: KeyPath<Data.Element, ID>, inset: CGFloat = 14, trailingInset: CGFloat = 0,
         @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data; self.id = id; self.inset = inset; self.trailingInset = trailingInset; self.row = row
    }

    var body: some View {
        let first = data.first.map { $0[keyPath: id] }
        PaperCard {
            ForEach(data, id: id) { element in
                if element[keyPath: id] != first { PaperDivider(leading: inset, trailing: trailingInset) }
                row(element)
            }
        }
    }
}

/// A recording as a row in a card (Home's Recent, the iPhone Library): on iPhone the kind's badge (34 pt on Home, 32 in
/// the Library), the title over its meta line, and a trailing length; on the Mac one line, the kind's dot, the title,
/// the meta, and the trailing length. `trailing` takes the place of the length when it's set (a stage while it
/// transcribes). A pinned recording shows the pin before its title.
struct PaperRow<Trailing: View>: View {
    var kind: RecordingKind?
    var title: String
    var meta: String
    var badge: CGFloat = 34
    var pinned = false
    @ViewBuilder var trailing: Trailing
    private let mac = RefinedPlatform.mac

    var body: some View {
        if mac {
            HStack(spacing: 12) {
                KindBadge(kind: kind, size: 8)
                if pinned { IconGlyph(art: .iconPin, size: 12, color: Refined.mute).accessibilityHidden(true) }
                Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta).refinedFont(.rowTitle).foregroundStyle(Refined.mute).lineLimit(1)
                trailing.frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 12) {
                KindBadge(kind: kind, size: badge)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if pinned { IconGlyph(art: .iconPin, size: 13, color: Refined.mute).accessibilityHidden(true) }
                        Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                    }
                    .alignmentGuide(.rowTitle) { d in d[VerticalAlignment.center] }
                    Text(meta).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

/// A card with a header that stays at the top of the scroll view while its rows scroll under it (the Mac Library's
/// table: the column titles over the recordings). Lazy, so a library of hundreds builds only the rows on screen. Put
/// it in a vertical scroll view.
struct PaperTable<Header: View, Rows: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var rows: Rows

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                rows
            } header: {
                VStack(spacing: 0) {
                    header
                    PaperDivider(leading: 0)
                }
                .background(Refined.card)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }
}

/// One row's share of a card in a system `List` (the iPhone Library, whose rows keep swipe actions and selection): the
/// card fill, rounded at the group's first row's top corners and its last row's bottom corners, inset from the
/// screen's edges. Under Increase Contrast it takes the card's hairline edge. Use it as `.listRowBackground(…)`, and
/// draw `PaperDivider`s between rows yourself.
struct PaperRowBackground: View {
    var first: Bool
    var last: Bool
    var inset: CGFloat = 20
    @Environment(\.colorSchemeContrast) private var contrast

    init(first: Bool, last: Bool, inset: CGFloat = 20) { self.first = first; self.last = last; self.inset = inset }

    var body: some View {
        let r = RefinedPlatform.radius(.card)
        let shape = UnevenRoundedRectangle(topLeadingRadius: first ? r : 0, bottomLeadingRadius: last ? r : 0,
                                           bottomTrailingRadius: last ? r : 0, topTrailingRadius: first ? r : 0, style: .continuous)
        shape.fill(Refined.card)
            .overlay { if contrast == .increased { shape.strokeBorder(Refined.separator, lineWidth: 1) } }
            .padding(.horizontal, inset)
    }
}

/// A row that opens a place (the Library's Dictations, By day, Templates, Ask, and Projects): an `IconSquare`, the
/// name, an optional value in the meta color ("3", "7 today"), and a chevron. It draws no button of its own: put it
/// in one, or in a NavigationLink. VoiceOver reads the name and the value.
struct IconSquareRow: View {
    var art: BrandArt
    var hue: RefinedHue
    var title: String
    var value: String? = nil
    private let mac = RefinedPlatform.mac

    var body: some View {
        HStack(spacing: 12) {
            IconSquare(art: art, hue: hue)
            Text(title).refinedFont(.body).foregroundStyle(Refined.ink).lineLimit(1)
            Spacer(minLength: 8)
            if let value { Text(value).refinedFont(.body).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.faint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.vertical, mac ? 6 : 7)
        .frame(maxWidth: .infinity, minHeight: mac ? 34 : CGFloat(RefinedRules.minTapTarget), alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A length or a count at the end of a row, in the meta style with tabular digits ("0:42").
struct RowLength: View {
    var text: String
    var body: some View {
        Text(text).refinedFont(RefinedPlatform.mac ? .rowTitle : .meta).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1)
    }
}

// MARK: - This week

/// This week (mockup: the Mac's Home): the label, the week's words big with tabular digits, what else happened
/// ("words, 20 recordings"), the time saved, and seven small bars, today's in persimmon, days to come as stubs. Large
/// is the card (on the Mac a column with the bars at its foot, on iPhone the bars beside the numbers); Compact is one
/// line. Decorative bars: the caller gives the card one VoiceOver label.
struct WeekCard: View {
    struct Day: Hashable {
        /// The day's words as a share of the week's busiest day, 0...1; 0 for a day with none.
        var share: Double
        var isToday: Bool
        var isFuture: Bool
    }
    var words: Int
    /// "words, 20 recordings"
    var detail: String
    /// "25 min saved"
    var saved: String
    var days: [Day]
    var large = true
    private let mac = RefinedPlatform.mac

    var body: some View {
        Group {
            if !large { compact } else if mac { macCard } else { phoneCard }
        }
        // Fills the band's height beside Recent recordings on the Mac; its own height in a scroll view.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
    }

    private var label: some View { Text("This week").refinedFont(.meta).foregroundStyle(Refined.mute) }
    private var number: some View {
        Text(words.formatted()).font(.system(size: mac ? 28 : 30, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Refined.ink).lineLimit(1).minimumScaleFactor(0.6)
    }

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
            number
            Text(detail).refinedFont(.body).foregroundStyle(Refined.dim)
            Text(saved).refinedFont(.meta).foregroundStyle(Refined.mute)
            Spacer(minLength: 10)
            RefinedWeekBars(days: days, height: 40)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var phoneCard: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                label
                number
                Text(detail).refinedFont(.hint).foregroundStyle(Refined.dim)
                Text(saved).refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            Spacer(minLength: 8)
            RefinedWeekBars(days: days, height: 52)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var compact: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                label
                Text("\(words.formatted()) \(words == 1 ? "word" : "words")").refinedFont(.rowTitle, weight: .semibold)
                    .monospacedDigit().foregroundStyle(Refined.ink).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                RefinedWeekBars(days: days, height: 22)
                Text(saved).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1).fixedSize()
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    label
                    Text("\(words.formatted()) \(words == 1 ? "word" : "words")").refinedFont(.rowTitle, weight: .semibold)
                        .monospacedDigit().foregroundStyle(Refined.ink)
                    Text(saved).refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                Spacer(minLength: 8)
                RefinedWeekBars(days: days, height: 30)
            }
        }
        .padding(.horizontal, mac ? 16 : 14).padding(.vertical, mac ? 10 : 12)
        .frame(minHeight: CGFloat(mac ? 40 : RefinedRules.minTapTarget))
    }
}

/// This week's seven bars: today in persimmon, other days in the rest color, days to come as short stubs.
struct RefinedWeekBars: View {
    var days: [WeekCard.Day]
    var height: CGFloat
    var body: some View {
        let width: CGFloat = height > 30 ? 10 : 7
        HStack(alignment: .bottom, spacing: height > 30 ? 6 : 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                RoundedRectangle(cornerRadius: min(3, width / 2), style: .continuous)
                    .fill(d.isToday ? Refined.persimmon : d.isFuture ? Refined.neutralSquare : Refined.waveRest)
                    .frame(width: width, height: d.isFuture || d.share <= 0 ? 3 : max(4, height * CGFloat(min(1, d.share))))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Kinds, speakers, and squares

extension RecordingKind {
    /// The kind's color in the refined look (DESIGN.md §13): kinds get colors again, each with its glyph and name.
    var refinedHue: RefinedHue { RefinedRules.kindHue(rawValue) }

    /// A kind as one recording of it says it, in the refined look's rows and chips: "Meeting", "Voice note" (a note,
    /// and nil), "Thought", "Audio only".
    static func refinedName(_ kind: RecordingKind?) -> String {
        switch kind {
        case nil, .note?: return "Voice note"
        case .idea?: return "Thought"
        case let k?: return k.label
        }
    }

    /// The kind's fine-line glyph on its badge (the Record as glyphs where the kind has one).
    var refinedArt: BrandArt {
        switch self {
        case .meeting: return .iconOneOnOne
        case .interview: return .iconQuote
        case .journal: return .iconNotes
        case .talk: return .iconVoice
        case .idea: return .iconThought
        case .brainDump: return .iconBrainDump
        case .audio: return .iconAudio
        case .note: return .iconMic
        case .dictation: return .iconDictations
        case .podcast: return .iconSpeak
        case .video: return .iconFilm
        }
    }
}

/// A kind as a colored circle with its ink glyph (Recent and Library rows): 34 pt on iPhone's Home, 32 in the
/// Library. Under 16 pt it's a plain dot (the Mac's Recent rows). Nil is a voice note. Decorative: the row's meta
/// line says the kind.
struct KindBadge: View {
    var kind: RecordingKind?
    @ScaledMetric private var side: CGFloat

    init(kind: RecordingKind?, size: CGFloat = 34) {
        self.kind = kind
        _side = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        let hue = RefinedRules.kindHue(kind?.rawValue)
        Circle().fill(Refined.badge(hue))
            .frame(width: side, height: side)
            .overlay {
                if side >= 16 { IconGlyph(art: kind?.refinedArt ?? .iconMic, size: side * 0.47, color: Refined.onBadge(hue)) }
            }
            .accessibilityHidden(true)
    }
}

/// A speaker's name on a capsule in their hue, by speaker order (persimmon, petal, sage, butter, and around again).
struct SpeakerChip: View {
    var name: String
    var index: Int
    var body: some View {
        let hue = RefinedRules.speakerHue(index)
        Text(name).refinedFont(.chip, weight: .semibold).lineLimit(1)
            .foregroundStyle(Refined.onBadge(hue))
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Refined.badge(hue), in: Capsule())
    }
}

/// A kind (or a project) as a colored capsule with its name, in a transcript's header: "Meeting".
struct KindChip: View {
    var title: String
    var hue: RefinedHue

    init(title: String, hue: RefinedHue) { self.title = title; self.hue = hue }
    init(kind: RecordingKind?) {
        self.init(title: RecordingKind.refinedName(kind), hue: RefinedRules.kindHue(kind?.rawValue))
    }

    var body: some View {
        Text(title).refinedFont(.chip, weight: .semibold).lineLimit(1)
            .foregroundStyle(Refined.onBadge(hue))
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Refined.badge(hue), in: Capsule())
    }
}

/// A colored rounded square with an ink glyph, leading a Settings or Library row: 30 pt with an 18 pt glyph on
/// iPhone, 22 with 16 on the Mac. Neutral is the quiet square for rows that aren't one of the four.
struct IconSquare: View {
    var art: BrandArt
    var hue: RefinedHue
    @ScaledMetric private var side: CGFloat

    /// `side` overrides the device's size: the Mac Settings pane's 40 pt square beside its title. The corner and the
    /// glyph keep their proportions.
    init(art: BrandArt, hue: RefinedHue, side: CGFloat? = nil) {
        self.art = art
        self.hue = hue
        _side = ScaledMetric(wrappedValue: side ?? CGFloat(RefinedRules.squareSize(mac: RefinedPlatform.mac).side), relativeTo: .body)
    }

    var body: some View {
        let sizes = RefinedRules.squareSize(mac: RefinedPlatform.mac)
        RoundedRectangle(cornerRadius: RefinedPlatform.radius(.square) * side / CGFloat(sizes.side), style: .continuous)
            .fill(Refined.badge(hue))
            .frame(width: side, height: side)
            .overlay(IconGlyph(art: art, size: side * CGFloat(sizes.glyph / sizes.side), color: Refined.onBadge(hue)))
            .accessibilityHidden(true)
    }
}

/// Your initial on a persimmon circle (the You card in Settings, the You page), in the fill's ink; a person's glyph
/// when there's no name yet. Decorative: the name beside it is what VoiceOver reads.
struct InitialBadge: View {
    var name: String
    @ScaledMetric private var side: CGFloat

    init(name: String, size: CGFloat = 44) {
        self.name = name
        _side = ScaledMetric(wrappedValue: size, relativeTo: .title2)
    }

    var body: some View {
        Circle().fill(Refined.badge(.persimmon))
            .frame(width: side, height: side)
            .overlay {
                if let letter = RefinedRules.initial(name) {
                    Text(letter).font(.system(size: side * 0.43, weight: .semibold)).foregroundStyle(Refined.onBadge(.persimmon))
                } else {
                    IconGlyph(art: .iconAboutMe, size: side * 0.5, color: Refined.onBadge(.persimmon))
                }
            }
            .accessibilityHidden(true)
    }
}

/// A group of rows in a card with an optional label over it and a note under it (Settings' groups on both devices,
/// the You page): the label in the meta style (iPhone) or semibold (Mac) in `mute`, sentence case, then a `PaperCard`,
/// then the note in `mute`. VoiceOver reads the label as a header.
struct PaperSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    private let mac = RefinedPlatform.mac

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: mac ? 8 : 7) {
            if let title {
                Text(title).refinedFont(.meta, weight: mac ? .semibold : .regular).foregroundStyle(Refined.mute)
                    .padding(.horizontal, mac ? 4 : 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            PaperCard { content }
            if let footer {
                Text(footer).refinedFont(.meta).foregroundStyle(Refined.mute)
                    .padding(.horizontal, mac ? 4 : 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: mac ? 600 : .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Titles

/// A screen's large title in the serif (Home's greeting, Library, Settings), with an optional line above it (the
/// date) and a count beside it ("47 recordings").
struct LargeSerifTitle: View {
    var title: String
    var eyebrow: String? = nil
    var count: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: RefinedPlatform.mac ? 4 : 2) {
            if let eyebrow { Text(eyebrow).refinedFont(.meta).foregroundStyle(Refined.mute) }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).refinedFont(.largeTitle).foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let count { Text(count).refinedFont(.hint).foregroundStyle(Refined.mute) }
            }
        }
    }
}

/// A section's title in the serif ("Recent", "Today"), with an optional trailing link ("See all").
struct SectionTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

extension SectionTitle where Trailing == RefinedLink {
    /// A section title with a text link at the trailing edge: `SectionTitle("Recent", link: "See all") { … }`.
    init(_ title: String, link: String, action: @escaping () -> Void) {
        self.init(title: title) { RefinedLink(title: link, action: action) }
    }
}

/// A text link in the accent ("See all", "Library"), with a 44 pt tap target.
struct RefinedLink: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).refinedFont(.hint).foregroundStyle(Refined.accentText)
                .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Switches

extension View {
    /// Switches in the refined look: the system's green on iPhone (as in Apple's own apps), the accent on the Mac. On
    /// iPhone it clears any tint the screen sets (Verbose style's root tints ink), so the switch takes the system's own.
    #if os(macOS)
    func refinedSwitchTint() -> some View { tint(Refined.macSwitch) }
    #else
    func refinedSwitchTint() -> some View { tint(Color?.none) }
    #endif
}

// MARK: - Previews

#if DEBUG
struct RefinedPreviewPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) { content }.padding(20) }
            .frame(width: RefinedPlatform.mac ? 760 : 390)
            .background(Refined.paper)
    }
}

struct RecordCard_Previews: PreviewProvider {
    static var previews: some View {
        ForEach(AppPalette.allCases) { p in
            RefinedPreviewPage {
                RecordCard(status: "Ready · iPhone microphone", hint: "Tap for a voice note, hold for more",
                           actions: [RecordCardAction(name: "Record a meeting") {}]) {}
            }
            .environment(\.paletteOverride, p)
            .previewDisplayName("Record card, \(p.label)")
        }
    }
}

struct ColorTile_Previews: PreviewProvider {
    static var previews: some View {
        ForEach(AppPalette.allCases) { p in
            RefinedPreviewPage {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ColorTile(title: "Dictate", art: .iconDictations, hue: .butter, pattern: .waves, shortcut: RefinedPlatform.mac ? "⌃⌥" : nil) {}
                    ColorTile(title: "Import", art: .iconDownload, hue: .sage, pattern: .chevrons) {}
                    ColorTile(title: "What's playing", art: .iconVoice, hue: .petal, pattern: .offsetCircles) {}
                    ColorTile(title: "New thought", art: .iconThought, hue: .neutral, pattern: .shortLines) {}
                }
            }
            .environment(\.paletteOverride, p)
            .previewDisplayName("Tiles, \(p.label)")
        }
    }
}

struct PaperCard_Previews: PreviewProvider {
    static let kinds: [RecordingKind] = [.meeting, .audio, .brainDump, .interview]
    static var previews: some View {
        RefinedPreviewPage {
            SectionTitle("Recent", link: "See all") {}
            PaperList(kinds, id: \.self, inset: 60) { k in
                HStack(spacing: 12) {
                    KindBadge(kind: k)
                    VStack(alignment: .leading) {
                        Text(k.label).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        Text("\(k.label) · Today, 8:35 PM").refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                    Spacer()
                    Text("0:42").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}

struct KindBadge_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            HStack(spacing: 10) {
                KindBadge(kind: nil)
                ForEach(RecordingKind.allCases) { KindBadge(kind: $0) }
            }
            HStack(spacing: 10) { ForEach(RecordingKind.allCases) { KindBadge(kind: $0, size: 8) } }
        }
    }
}

struct SpeakerChip_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            HStack { ForEach(0..<5) { SpeakerChip(name: ["Tim", "Jonathan", "Chris", "Ginna", "Sam"][$0], index: $0) } }
        }
    }
}

struct KindChip_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            HStack { KindChip(kind: .meeting); KindChip(kind: .interview); KindChip(title: "Lapp Wagons", hue: .butter) }
        }
    }
}

struct IconSquare_Previews: PreviewProvider {
    static let rows: [(title: String, art: BrandArt, hue: RefinedHue)] = [
        ("Appearance", .iconAppearance, .persimmon), ("Customize Home", .iconHome, .butter), ("Tab bar", .iconTabBar, .sage),
        ("Dictionary", .iconDictionary, .petal), ("Privacy", .iconPrivacy, .neutral),
    ]
    static var previews: some View {
        RefinedPreviewPage {
            PaperCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { PaperDivider(leading: 56) }
                    HStack(spacing: 12) {
                        IconSquare(art: row.art, hue: row.hue)
                        Text(row.title).refinedFont(.body).foregroundStyle(Refined.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
            }
        }
    }
}

struct SectionTitle_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            SectionTitle("Today")
            SectionTitle("Recent", link: "See all") {}
        }
    }
}

struct PaperRow_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            SectionTitle("Recent", link: "See all") {}
            PaperCard {
                PaperRow(kind: .meeting, title: "Lapp Wagons catalog call", meta: "Meeting · Today, 8:35 PM") { RowLength(text: "0:42") }
                PaperDivider(leading: RefinedPlatform.mac ? 16 : 60, trailing: RefinedPlatform.mac ? 16 : 0)
                PaperRow(kind: .audio, title: "Melody for the second verse", meta: "Audio only · Today, 2:14 PM") { RowLength(text: "1:12") }
            }
        }
    }
}

struct WeekCard_Previews: PreviewProvider {
    static let days: [WeekCard.Day] = [0.5, 1, 0.35, 0, 0, 0, 0].enumerated().map {
        WeekCard.Day(share: $0.element, isToday: $0.offset == 2, isFuture: $0.offset > 2)
    }
    static var previews: some View {
        RefinedPreviewPage {
            WeekCard(words: 1414, detail: "words, 20 recordings", saved: "25 min saved", days: days)
                .frame(width: RefinedPlatform.mac ? 260 : nil, height: RefinedPlatform.mac ? 190 : nil)
            WeekCard(words: 1414, detail: "words, 20 recordings", saved: "25 min saved", days: days, large: false)
        }
    }
}

struct RefinedActionStyle_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            HStack {
                Button("Mark moment") {}.buttonStyle(RefinedActionStyle())
                Button("Stop and transcribe") {}.buttonStyle(RefinedActionStyle(kind: .strong))
            }
        }
    }
}

struct RefinedChip_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            RefinedChipRow {
                ForEach(["All", "Voice notes", "Meetings", "Thoughts", "Audio", "Links", "Marked"], id: \.self) { c in
                    RefinedChip(title: c, selected: c == "All") {}
                }
            }
        }
    }
}

struct RefinedSearchField_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            RefinedSearchField(text: .constant(""), prompt: "Search or ask", shortcut: RefinedPlatform.mac ? "⌘K" : nil)
            RefinedSearchField(text: .constant("wagons"), prompt: "Search or ask")
        }
    }
}

struct IconSquareRow_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            PaperCard {
                IconSquareRow(art: .iconDictations, hue: .butter, title: "Dictations", value: "3")
                PaperDivider(leading: 56)
                IconSquareRow(art: .iconCalendar, hue: .sage, title: "By day", value: "7 today")
                PaperDivider(leading: 56)
                IconSquareRow(art: .iconSummaries, hue: .petal, title: "Templates", value: "14")
            }
        }
    }
}

struct PaperTable_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            PaperTable {
                Text("Name").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                    .padding(.horizontal, 16).padding(.vertical, 9)
            } rows: {
                ForEach(0..<4) { i in
                    Text("Recording \(i + 1)").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(i == 0 ? Refined.persimmonTint : i.isMultiple(of: 2) ? Refined.stripe : Color.clear)
                }
            }
        }
    }
}

struct PaperRowBackground_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            Text("First").padding(14).frame(maxWidth: .infinity, alignment: .leading).background(PaperRowBackground(first: true, last: false, inset: 0))
            Text("Last").padding(14).frame(maxWidth: .infinity, alignment: .leading).background(PaperRowBackground(first: false, last: true, inset: 0))
        }
        .padding(20)
        .background(Refined.paper)
    }
}

struct RefinedSegmented_Previews: PreviewProvider {
    struct Demo: View {
        @State var pick = "Original"
        var body: some View {
            RefinedSegmented(options: ["Original", "Cleaned", "Summary"].map { ($0, $0) }, selection: $pick)
        }
    }
    static var previews: some View {
        RefinedPreviewPage { Demo() }
    }
}

struct KindPickerChip_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            FlowRow {
                KindPickerChip(kind: .meeting, isAuto: false) { _ in }
                KindChip(title: "Lapp Wagons", hue: .butter)
                RefinedTagChips(tags: ["catalog", "lapp"], onAdd: { _ in }, onRemove: { _ in })
            }
        }
    }
}

struct RefinedTagChips_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            FlowRow { RefinedTagChips(tags: [], onAdd: { _ in }, onRemove: { _ in }) }
        }
    }
}

struct RefinedCircleButton_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage { RefinedCircleButton(symbol: "chevron.left", label: "Back") {} }
    }
}

struct InitialBadge_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            HStack(spacing: 12) { InitialBadge(name: "Tim Medina"); InitialBadge(name: ""); InitialBadge(name: "Ginna", size: 64) }
        }
    }
}

struct PaperSection_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            PaperSection("Personalization and preferences", footer: "Kept on this device.") {
                IconSquareRow(art: .iconAppearance, hue: .persimmon, title: "Appearance", value: "Match the system")
                PaperDivider(leading: 56)
                IconSquareRow(art: .iconHome, hue: .butter, title: "Customize Home")
            }
        }
    }
}

struct LargeSerifTitle_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            LargeSerifTitle(title: "Good evening, Tim.", eyebrow: "Tuesday, October 27")
            LargeSerifTitle(title: "Library", count: "47 recordings")
        }
    }
}
#endif
