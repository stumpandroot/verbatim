import SwiftUI

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

extension AppPalette {
    /// The palette chosen on this device. Setting it updates every kit view at once (they observe the same store).
    static var current: AppPalette {
        get { AppPalette(stored: AppLook.store.string(forKey: key)) }
        set { AppLook.store.set(newValue.rawValue, forKey: key) }
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
    @AppStorage(AppPalette.key, store: AppLook.store) private var raw = AppPalette.full.rawValue
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

    /// A palette surface's fill (the Record card, a tile) and what sits on it.
    static func fill(_ hue: RefinedHue, _ palette: AppPalette) -> Color { fills[palette]?[hue] ?? card }
    static func onFill(_ hue: RefinedHue, _ palette: AppPalette) -> Color { onFills[palette]?[hue] ?? ink }
    /// A badge, chip, or icon square's fill (Full in both palettes) and its glyph or text.
    static func badge(_ hue: RefinedHue) -> Color { badges[hue] ?? neutralSquare }
    static func onBadge(_ hue: RefinedHue) -> Color { onBadges[hue] ?? ink }
    /// The Record card's rings and ready chip.
    static func rings(_ palette: AppPalette) -> Color { ringColors[palette] ?? separator }
    static func readyChip(_ palette: AppPalette) -> Color { chipColors[palette] ?? neutral }
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
    var actions: [RecordCardAction] = []
    var action: () -> Void

    var body: some View {
        Button(action: action) { RecordCardFace(status: status, title: title, hint: hint) }
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

/// The Record card's drawing, with no button of its own.
struct RecordCardFace: View {
    var status: String
    var title = "Record"
    var hint: String
    @CurrentPalette private var palette: AppPalette
    private let mac = RefinedPlatform.mac

    var body: some View {
        let ink = Refined.onFill(.persimmon, palette)
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
                RecordDiscMark(size: 56)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, mac ? 22 : 18).padding(.vertical, mac ? 18 : 16)
        .frame(maxWidth: .infinity, minHeight: mac ? 150 : 168, alignment: .leading)
        .background(alignment: .topTrailing) {
            RecordRings(color: Refined.rings(palette), lineWidth: mac ? 2.2 : 2.4)
                .frame(width: mac ? 260 : 210, height: mac ? 260 : 210)
                .offset(x: mac ? -90 : 46, y: mac ? -40 : -14)
        }
        .refinedSurface(Refined.fill(.persimmon, palette), radius: RefinedPlatform.radius(.record))
        .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.record), style: .continuous))
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
/// Dictate, sage Import, petal What's playing or App audio, the card for anything else). The Mac shows the shortcut
/// at the trailing edge of the name. iPhone 74 pt tall with a 16 pt radius, Mac 84 pt with 14.
struct ColorTile: View {
    var title: String
    var art: BrandArt
    var hue: RefinedHue
    var shortcut: String? = nil
    var action: () -> Void
    @CurrentPalette private var palette: AppPalette
    private let mac = RefinedPlatform.mac

    var body: some View {
        Button(action: action) {
            let ink = Refined.onFill(hue, palette)
            VStack(alignment: .leading, spacing: 0) {
                IconGlyph(art: art, size: 22, color: ink)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).refinedFont(.tileName, weight: .semibold).lineLimit(2)
                    Spacer(minLength: 4)
                    if let shortcut { Text(shortcut).refinedFont(.caption).accessibilityHidden(true) }
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 14).padding(.vertical, mac ? 14 : 12)
            .frame(maxWidth: .infinity, minHeight: mac ? 84 : 74, alignment: .leading)
            .refinedSurface(Refined.fill(hue, palette), radius: RefinedPlatform.radius(.tile))
            .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.tile), style: .continuous))
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(title)
        .accessibilityHint(shortcut.map { "Shortcut: " + Keycap.spoken($0) } ?? "")
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

// MARK: - Kinds, speakers, and squares

extension RecordingKind {
    /// The kind's color in the refined look (DESIGN.md §13): kinds get colors again, each with its glyph and name.
    var refinedHue: RefinedHue { RefinedRules.kindHue(rawValue) }

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
struct KindColorChip: View {
    var title: String
    var hue: RefinedHue

    init(title: String, hue: RefinedHue) { self.title = title; self.hue = hue }
    init(kind: RecordingKind?) {
        self.init(title: kind.map { $0 == .note ? "Voice note" : $0.label } ?? "Voice note", hue: RefinedRules.kindHue(kind?.rawValue))
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

    init(art: BrandArt, hue: RefinedHue) {
        self.art = art
        self.hue = hue
        _side = ScaledMetric(wrappedValue: CGFloat(RefinedRules.squareSize(mac: RefinedPlatform.mac).side), relativeTo: .body)
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
struct SerifSectionTitle<Trailing: View>: View {
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

extension SerifSectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

extension SerifSectionTitle where Trailing == RefinedLink {
    /// A section title with a text link at the trailing edge: `SerifSectionTitle("Recent", link: "See all") { … }`.
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
    /// Switches in the refined look: the system's green on iPhone (as in Apple's own apps), the accent on the Mac.
    #if os(macOS)
    func refinedSwitchTint() -> some View { tint(Refined.macSwitch) }
    #else
    func refinedSwitchTint() -> some View { self }
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
                    ColorTile(title: "Dictate", art: .iconDictations, hue: .butter, shortcut: RefinedPlatform.mac ? "⌃⌥" : nil) {}
                    ColorTile(title: "Import", art: .iconDownload, hue: .sage) {}
                    ColorTile(title: "What's playing", art: .iconVoice, hue: .petal) {}
                    ColorTile(title: "New thought", art: .iconThought, hue: .neutral) {}
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
            SerifSectionTitle("Recent", link: "See all") {}
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

struct KindColorChip_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            HStack { KindColorChip(kind: .meeting); KindColorChip(kind: .interview); KindColorChip(title: "Lapp Wagons", hue: .butter) }
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

struct SerifSectionTitle_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            SerifSectionTitle("Today")
            SerifSectionTitle("Recent", link: "See all") {}
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
