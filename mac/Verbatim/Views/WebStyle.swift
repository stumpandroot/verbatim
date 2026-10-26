import SwiftUI
import AppKit

// brand: web style
//
// The website style on Mac (mockup "The app, in the website's clothes", October 23, 2026; mac/DESIGN.md §11): the
// shared kit every Mac screen builds with. Compact page titles with a mono count, flat list rows that pick up an ink
// outline and a hard offset shadow on hover, pill buttons, soft filter chips, plain status text, a horizontal empty
// state, and color panels with paper grain and one slowly looping line drawing. Mac target only; the iPhone has its
// own kit. Mono text here is never smaller than 12 pt (brand-check enforces it in files marked `brand: web style`).
//
// Under the Native look (`@Environment(\.look)`) each component draws its stock macOS counterpart instead, from
// NativeLook.swift: grouped boxes for color panels, no grain, line art, ink edges, or hard shadows, title-case bordered
// buttons, capsule chips, plain section headers, and SF Symbols.

// MARK: - Type

/// Serif text with an optional italic second part: "Lapp *Wagons*", "Recent *recordings*".
enum WebText {
    static func serif(_ plain: String, italic: String? = nil, size: CGFloat) -> Text {
        guard let italic, !italic.isEmpty else { return Text(plain).font(Ink.serif(size)) }
        // Native: one upright run in SF Pro (Ink.serif), no italic second part.
        if NativeSwap.on { return Text(plain.isEmpty ? italic : plain + " " + italic).font(Ink.serif(size)) }
        let lead = plain.isEmpty ? "" : plain + " "
        return Text("\(Text(lead).font(Ink.serif(size)))\(Text(italic).font(Ink.serif(size).italic()))")
    }

    /// A title split for the italic treatment where the data allows: the part after a project's name
    /// ("Lapp Wagons *catalog call*"). Otherwise the whole title stays upright.
    static func split(_ title: String, after prefix: String?) -> (String, String?) {
        guard let prefix, !prefix.isEmpty, title.count > prefix.count + 1,
              title.lowercased().hasPrefix(prefix.lowercased() + " ") else { return (title, nil) }
        let rest = title.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (title, nil) : (String(title.prefix(prefix.count)), rest)
    }

    /// A name's last word in italic ("Catalog *shoot*"); one-word names stay upright.
    static func splitLastWord(_ name: String) -> (String, String?) {
        let words = name.split(separator: " ")
        guard words.count >= 2 else { return (name, nil) }
        return (words.dropLast().joined(separator: " "), String(words.last!))
    }
}

/// Small formatting helpers for the web-style screens.
enum WebFormat {
    /// "42s", "18m", "2h", "2h 14m".
    static func compactDuration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// A length in mono: "07:50", "15:39", "1:02:44".
    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

/// "◇ This week": a mono eyebrow with a small outlined diamond. One per card or panel at most.
struct Eyebrow: View {
    var text: String
    var color: Color = Ink.dim
    @Environment(\.look) private var look
    var body: some View {
        if look == .native {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
        } else {
            verbose
        }
    }
    @ViewBuilder private var verbose: some View {
        HStack(spacing: 9) {
            Diamond().stroke(color, lineWidth: 1.3).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(text).font(Ink.mono(12.5)).lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// A compact page title (every screen except Home, which keeps its big two-line greeting): the serif title, a mono
/// count beside it, controls on the right, and an optional lede line in dim text under it.
///
///     PageTitle(title: "Dictations", count: "128 kept", lede: "Everything you dictated into other apps.") { … }
struct PageTitle<Trailing: View>: View {
    var title: String
    var italic: String? = nil
    var count: String? = nil
    var lede: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.look) private var look

    var body: some View {
        if look == .native { native } else { verbose }
    }

    /// Native: a bold title with the count as its subtitle, as a toolbar title reads, controls on the right.
    private var native: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(italic.map { title.isEmpty ? $0 : title + " " + $0 } ?? title)
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                    if let count { Text(count).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                trailing()
            }
            if let lede {
                Text(lede).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var verbose: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    WebText.serif(title, italic: italic, size: 34)
                        .tracking(-0.5)
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                    if let count {
                        Text(count).font(Ink.mono(12.5)).foregroundStyle(Ink.mute).lineLimit(1).fixedSize()
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                trailing()
            }
            if let lede {
                Text(lede).font(.system(size: 14)).foregroundStyle(Ink.dim).lineSpacing(3)
                    .frame(maxWidth: 640, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension PageTitle where Trailing == EmptyView {
    init(title: String, italic: String? = nil, count: String? = nil, lede: String? = nil) {
        self.init(title: title, italic: italic, count: count, lede: lede, trailing: { EmptyView() })
    }
}

/// "Recent *recordings*  ·  Library →": a serif section title with an optional text link.
struct SectionTitle: View {
    var title: String
    var italic: String? = nil
    var link: String? = nil
    /// What VoiceOver says for the link when the visible text is short ("All").
    var linkLabel: String? = nil
    var linkHint: String = ""
    var action: () -> Void = {}
    @Environment(\.look) private var look

    var body: some View {
        if look == .native {
            // Native: a plain section header (`.headline`), the link as accent text.
            HStack(alignment: .firstTextBaseline) {
                Text(italic.map { title.isEmpty ? $0 : title + " " + $0 } ?? title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                if let link {
                    Button(NativeText.titleCase(link), action: action)
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.nativeAccent)
                        .accessibilityLabel(linkLabel ?? link)
                        .accessibilityHint(linkHint)
                }
            }
        } else {
            verbose
        }
    }

    @ViewBuilder private var verbose: some View {
        HStack(alignment: .firstTextBaseline) {
            WebText.serif(title, italic: italic, size: 26).foregroundStyle(Ink.ink).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if let link {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(link)
                        ArtIcon(art: .webArrow, size: 13, lineWidth: 1.5)
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(linkLabel ?? link)
                .accessibilityHint(linkHint)
            }
        }
    }
}

/// "Today · Fri Oct 23 - - - - -": a day header in mono with a dashed hairline.
struct DayHeader: View {
    var text: String
    @Environment(\.look) private var look
    var body: some View {
        if look == .native {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            verbose
        }
    }
    @ViewBuilder private var verbose: some View {
        HStack(spacing: 10) {
            Text(text).font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1).fixedSize()
                .accessibilityAddTraits(.isHeader)
            HRule().stroke(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

private struct HRule: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p
    }
}

// MARK: - Ink edge (outline and hard shadow)

/// The website's ink outline (1.5 pt, outside the shape) and hard offset shadow. Big cards (Record, tiles, panels,
/// Moments cards) get it on hover through `HomeCard`; flat rows get it on hover or selection (`FlatRowSurface`).
struct InkEdge: ViewModifier {
    var outline: Bool
    /// The shadow's offset; `.zero` hides it.
    var shadow: CGSize
    var radius: CGFloat
    var color: Color = Ink.ink

    /// Rows: (4, 5). Cards: (7, 9) under the pointer, (2, 3) while pressed.
    static let row = CGSize(width: 4, height: 5)
    static func card(hover: Bool, pressed: Bool, rest: CGSize = .zero) -> CGSize {
        guard hover else { return rest }
        return pressed ? CGSize(width: 2, height: 3) : CGSize(width: 7, height: 9)
    }

    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if look == .native {
            content   // Native: no ink outline, no hard shadow.
        } else {
        content
            .background {
                shape.fill(Ink.hard).offset(shadow).opacity(shadow == .zero ? 0 : 1).allowsHitTesting(false)
            }
            .overlay {
                shape.inset(by: -0.75).stroke(color, lineWidth: 1.5).opacity(outline ? 1 : 0).allowsHitTesting(false)
            }
            .animation(Motion.touch, value: outline)
            .animation(Motion.touch, value: shadow)
        }
    }
}

extension View {
    func inkEdge(outline: Bool, shadow: CGSize = .zero, radius: CGFloat, color: Color = Ink.ink) -> some View {
        modifier(InkEdge(outline: outline, shadow: shadow, radius: radius, color: color))
    }
}

// MARK: - Flat list rows

/// A list row on the paper (DESIGN.md §11): transparent with a hairline at the bottom; highlighted (hover or
/// selection) it takes the card fill, the 1.5 pt ink outline, and the (4, 5) hard shadow. Rows never tilt.
struct FlatRowSurface: ViewModifier {
    var highlighted: Bool
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        if look == .native {
            // Native: a list row. A soft wash under the pointer, a separator between rows.
            content
                .background(highlighted ? NativeInk.hover : Color.clear, in: shape)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(NativeInk.separator).frame(height: 1).padding(.leading, 12)
                        .opacity(highlighted ? 0 : 0.6).allowsHitTesting(false)
                }
        } else {
        content
            .background(highlighted ? Ink.card : Color.clear, in: shape)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Ink.hairline).frame(height: 1).opacity(highlighted ? 0 : 1).allowsHitTesting(false)
            }
            .inkEdge(outline: highlighted, shadow: highlighted ? InkEdge.row : .zero, radius: Radius.row)
            .animation(Motion.touch, value: highlighted)
        }
    }
}

extension View {
    func flatRow(highlighted: Bool) -> some View { modifier(FlatRowSurface(highlighted: highlighted)) }
}

/// A clickable flat row. The content draws underneath and a flat layer on top takes the pointer (as `CardButton`
/// does), so clicks never depend on a Button under a gesture (macOS 26). `accessory` sits above that layer at the
/// trailing edge, for a row's own controls (a "Clean up" pill, the ⋯ menu); hovering it keeps the row highlighted.
/// Reserve its width inside `content` (a hidden copy of the control works well).
struct FlatRowButton<Content: View, Accessory: View>: View {
    var selected = false
    /// When set, the row can be dragged (onto a project in the sidebar). Click uses a tap gesture then.
    var dragPayload: (() -> String)? = nil
    var action: () -> Void
    @ViewBuilder var content: (_ highlighted: Bool) -> Content
    @ViewBuilder var accessory: (_ highlighted: Bool) -> Accessory
    @State private var hover = false
    @State private var accessoryHover = false

    var body: some View {
        let lit = hover || accessoryHover || selected
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        content(lit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flatRow(highlighted: lit)
            .allowsHitTesting(false)
            .overlay {
                // The hit layer reads its own size, so no row state changes when a row appears or resizes (in a
                // long list that was one extra render per row).
                GeometryReader { g in
                    shape.fill(Color.white.opacity(0.001))
                        .contentShape(shape)
                        .onHover { hover = $0 }
                        .modifier(FlatRowHit(dragPayload: dragPayload, size: g.size, action: action))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .overlay(alignment: .trailing) {
                accessory(lit).onHover { accessoryHover = $0 }
            }
    }
}

extension FlatRowButton where Accessory == EmptyView {
    init(selected: Bool = false, dragPayload: (() -> String)? = nil, action: @escaping () -> Void,
         @ViewBuilder content: @escaping (_ highlighted: Bool) -> Content) {
        self.init(selected: selected, dragPayload: dragPayload, action: action, content: content, accessory: { _ in EmptyView() })
    }
}

private struct FlatRowHit: ViewModifier {
    var dragPayload: (() -> String)?
    var size: CGSize
    var action: () -> Void
    func body(content: Content) -> some View {
        if let payload = dragPayload {
            content
                .onTapGesture { action() }
                .onDrag { NSItemProvider(object: payload() as NSString) }
        } else {
            content.gesture(DragGesture(minimumDistance: 0).onEnded { v in
                if CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(v.location) { action() }
            })
        }
    }
}

/// A row's round kind marker (34–38 pt): the source's fill (voice notes Record, files sage, app audio petal,
/// dictations butter, links an ink ring on card) with an ink icon for what it is.
struct KindDot: View {
    var transcript: Transcript
    var size: CGFloat = 34
    @Environment(\.look) private var look

    var body: some View {
        if look == .native { NativeKindIcon(transcript: transcript, size: size) } else { dot }
    }

    @ViewBuilder private var dot: some View {
        let link = LibrarySource.isLink(transcript)
        ZStack {
            Circle().fill(link ? Ink.card : fill)
            if link { Circle().inset(by: 0.75).stroke(Ink.ink, lineWidth: 1.5) }
            IconGlyph(art: art, size: size * 0.53, color: link ? Ink.ink : Ink.inkFixed)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        if transcript.isDictation { return Ink.panelButter }
        switch transcript.source {
        case .app: return Ink.panelPetal
        case .file: return Ink.panelSage
        default: return Ink.panelRecord
        }
    }

    private var art: BrandArt {
        switch transcript.kind {
        case .meeting: return .iconSpeakers
        case .journal, .note: return .iconNotes
        case .idea: return .iconThought
        case .dictation: return .iconDictations
        case .podcast: return .iconSpeakers
        case .interview: return .iconQuote
        case .video: return .iconPlay
        case .talk: return .iconVoice
        case nil:
            if transcript.isDictation { return .iconDictations }
            if LibrarySource.isLink(transcript) { return .iconLinks }
            if transcript.source == .file { return .iconDownload }
            return transcript.speakers.count >= 2 ? .iconSpeakers : .iconVoice
        }
    }
}

// MARK: - Status text

/// What a status says, by color: accent (Cleaned, not pasted), dim (Original, counts), kept (a video kept), danger.
enum StatusTone { case accent, dim, kept, danger }

/// Status as plain colored text, never a capsule: "Cleaned" in accent text, "Original" dim, "✓ Video kept" in the
/// kept color, "14 filler words" dim. A check or an icon may lead it; the word always carries the meaning.
struct StatusText: View {
    var text: String
    var tone: StatusTone = .dim
    var check = false
    var icon: BrandArt? = nil
    /// Mono for statuses in a column next to a mono duration (Library); sans elsewhere.
    var mono = false
    @Environment(\.look) private var look

    var body: some View {
        if look == .native { native } else { verbose }
    }

    /// Native: plain text in system colors (the accent for Cleaned, the system red for errors), digits aligned.
    private var native: some View {
        HStack(spacing: 4) {
            if check { Text("✓") }
            Text(text)
        }
        .font(.system(size: 12, weight: tone == .accent || tone == .danger ? .medium : .regular).monospacedDigit())
        .foregroundStyle(tone == .accent ? AnyShapeStyle(Ink.nativeAccent) : tone == .danger ? AnyShapeStyle(NativeInk.danger) : AnyShapeStyle(.secondary))
        .lineLimit(1).fixedSize()
    }

    @ViewBuilder private var verbose: some View {
        HStack(spacing: 6) {
            if check { ArtIcon(art: .homeCheck, size: 13, lineWidth: 1.6).foregroundStyle(tone == .dim ? Ink.ink : color) }
            if let icon { ArtIcon(art: icon, size: 14, lineWidth: 1.3) }
            Text(text)
        }
        .font(mono ? Ink.mono(12) : .system(size: 12.5, weight: .semibold))
        .foregroundStyle(color)
        .lineLimit(1).fixedSize()
    }

    private var color: Color {
        switch tone {
        case .accent: return Ink.accentText
        case .dim: return Ink.dim
        case .kept: return Ink.keptText
        case .danger: return Ink.danger
        }
    }
}

/// Counts behind the status text.
enum WebStatus {
    static func fillerCount(_ text: String) -> Int {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "…" })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { Segment.fillerWords.contains($0) }.count
    }

    /// Filler words a recording's Original still has, when it hasn't been cleaned yet (Home offers Clean up).
    static func fillers(_ t: Transcript) -> Int {
        guard t.status == .ready, !t.isDictation, t.document == nil else { return 0 }
        return t.segments.reduce(0) { $0 + fillerCount($1.text) }
    }

    /// `fillers`, remembered per transcript until its words, cleanup, or status change: counting splits every segment,
    /// and Home's Recent rows asked on every render.
    static func cachedFillers(_ t: Transcript) -> Int {
        let key = FillerKey(id: t.id, segments: t.segments.count, chars: t.segments.reduce(0) { $0 + $1.text.utf8.count },
                            cleaned: t.document != nil, ready: t.status == .ready, dictation: t.isDictation)
        if let hit = fillerCache[key] { return hit }
        let n = fillers(t)
        if fillerCache.count > 256 { fillerCache.removeAll(keepingCapacity: true) }
        fillerCache[key] = n
        return n
    }
    private struct FillerKey: Hashable { var id: UUID; var segments: Int; var chars: Int; var cleaned: Bool; var ready: Bool; var dictation: Bool }
    private static var fillerCache: [FillerKey: Int] = [:]

    /// Moments (notes pinned to a time) in a transcript.
    static func moments(_ t: Transcript) -> Int { t.notes.filter { $0.at != nil }.count }

    /// What cleanup did to a dictation: "3 filler words removed", "Cleaned up", or nil when nothing changed.
    static func dictationCleanup(_ t: Transcript) -> String? {
        guard let f = t.flow, t.status == .ready else { return nil }
        let removed = fillerCount(f.raw) - fillerCount(f.pasted)
        if removed > 0 { return HomeCounts.countLabel(removed, "filler word", "filler words") + " removed" }
        let raw = f.raw.trimmingCharacters(in: .whitespacesAndNewlines), pasted = f.pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw != pasted && !pasted.isEmpty ? "Cleaned up" : nil
    }
}

// MARK: - Pill buttons

/// Pill buttons (DESIGN.md §11): dark (ink fill, paper text), line (a 1.5 pt ink inset outline), in regular (36 pt)
/// and mini (28 pt) sizes. Filters are soft chips, never pills.
enum PillKind { case dark, line }
enum PillSize {
    case regular, mini
    var height: CGFloat { self == .regular ? 36 : 28 }
    var padding: CGFloat { self == .regular ? 16 : 12 }
    var font: CGFloat { self == .regular ? 13.5 : 12 }
    var icon: CGFloat { self == .regular ? 16 : 14 }
}
/// A drawn glyph after the title: an arrow ("Start recording →"), a plus ("New project +"), or a chevron.
enum PillTrailing { case arrow, plus, chevron
    var art: BrandArt { switch self { case .arrow: return .webArrow; case .plus: return .webPlus; case .chevron: return .webChevronDown } }
}

/// The pill's face, for buttons and for cards that show a pill as part of their face (the whole card is the button).
struct PillLabel: View {
    var title: String
    var kind: PillKind = .dark
    var size: PillSize = .regular
    var icon: BrandArt? = nil
    var trailing: PillTrailing? = nil
    /// Ink and paper that don't change with the appearance, for pills on color panels (the Record panel).
    var fixedInk = false
    var fullWidth = false
    var hover = false
    var pressed = false
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look

    var body: some View {
        if look == .native {
            NativeButtonFace(title: title, prominent: kind == .dark, size: size == .mini ? .mini : .regular,
                             fullWidth: fullWidth, hover: hover, pressed: pressed)
        } else {
            verbose
        }
    }

    @ViewBuilder private var verbose: some View {
        let ink = fixedInk ? Ink.inkFixed : Ink.ink
        let paper = fixedInk ? Ink.paperFixed : Ink.paper
        HStack(spacing: 8) {
            if let icon { ArtIcon(art: icon, size: size.icon, lineWidth: 1.4) }
            Text(title).lineLimit(1)
            if let trailing { ArtIcon(art: trailing.art, size: size.icon, lineWidth: 1.5) }
        }
        .font(.system(size: size.font, weight: .semibold))
        .foregroundStyle(kind == .dark ? paper : ink)
        .padding(.horizontal, size.padding)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .frame(height: size.height)
        .background {
            if kind == .dark {
                Capsule().fill(ink).opacity(hover ? 0.88 : 1)
            } else {
                ZStack {
                    Capsule().fill(ink.opacity(hover ? 0.07 : 0))
                    Capsule().strokeBorder(ink, lineWidth: 1.5)
                }
            }
        }
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .scaleEffect(pressed && !limitMotion ? 0.97 : 1)
        .opacity(pressed && limitMotion ? 0.8 : 1)
        .animation(Motion.touch, value: hover)
        .animation(pressed ? Motion.press : Motion.card, value: pressed)
        .contentShape(Capsule())
    }
}

/// A pill button that takes clicks through a direct gesture (safe under parent gestures and in panels on macOS 26).
struct PillButton: View {
    var title: String
    var kind: PillKind = .dark
    var size: PillSize = .regular
    var icon: BrandArt? = nil
    var trailing: PillTrailing? = nil
    var fixedInk = false
    var fullWidth = false
    var enabled = true
    var hint: String? = nil
    var action: () -> Void
    @State private var hover = false
    @State private var down = false
    /// The pill's size for the click test, kept without state (`HitBox`, Theme.swift).
    @State private var area = HitBox()

    var body: some View {
        PillLabel(title: title, kind: kind, size: size, icon: icon, trailing: trailing, fixedInk: fixedInk, fullWidth: fullWidth,
                  hover: hover && enabled, pressed: down && enabled)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hover = $0 }
            .hitArea(area, enabled: enabled, pressed: { p in if down != p { down = p } }, action: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint ?? "")
            .accessibilityAction { if enabled { action() } }
    }
}

/// The pill look for a real `Button` (where a keyboard shortcut or menu needs one). Gives the label the pill's
/// font, padding, and fill.
struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .line
    var size: PillSize = .mini
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, kind: kind, size: size) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        var kind: PillKind
        var size: PillSize
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.limitMotion) private var limitMotion
        @Environment(\.look) private var look
        var body: some View {
            if look == .native {
                NativeButtonStyleFace(configuration: configuration, prominent: kind == .dark, size: size == .mini ? .mini : .regular)
            } else {
                verbose
            }
        }
        @ViewBuilder private var verbose: some View {
            configuration.label
                .font(.system(size: size.font, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(kind == .dark ? Ink.paper : Ink.ink)
                .padding(.horizontal, size.padding)
                .frame(height: size.height)
                .background {
                    if kind == .dark {
                        Capsule().fill(Ink.ink).opacity(hover ? 0.88 : 1)
                    } else {
                        ZStack {
                            Capsule().fill(Ink.ink.opacity(hover ? 0.07 : 0))
                            Capsule().strokeBorder(Ink.ink, lineWidth: 1.5)
                        }
                    }
                }
                .fixedSize()
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.97 : 1)
                .opacity(enabled ? (configuration.isPressed && limitMotion ? 0.8 : 1) : 0.4)
                .onHover { hover = $0 }
                .animation(Motion.touch, value: hover)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

// MARK: - Filter chips

/// A filter chip (DESIGN.md §11): a soft rounded rectangle with the 4 pt button radius, a wash fill, and no border;
/// selected, it's ink with paper text. Never a capsule. An optional dot shows a source's color (an ink ring for links).
struct FilterChipLabel: View {
    var title: String
    var count: Int? = nil
    var dot: Color? = nil
    var ring = false
    var selected: Bool
    var small = false
    var hover = false
    @Environment(\.look) private var look

    var body: some View {
        if look == .native {
            NativeChipFace(title: title, count: count, selected: selected, small: small, hover: hover)
        } else {
            verbose
        }
    }

    @ViewBuilder private var verbose: some View {
        HStack(spacing: 7) {
            if ring {
                Circle().strokeBorder(selected ? Ink.paper : Ink.ink, lineWidth: 1.5).frame(width: 9, height: 9)
            } else if let dot {
                Circle().fill(dot).frame(width: 9, height: 9)
            }
            Text(title)
            if let count { Text("· \(count)").monospacedDigit() }
        }
        .font(.system(size: small ? 12 : 12.5, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(selected ? Ink.paper : Ink.ink)
        .padding(.horizontal, small ? 10 : 12)
        .frame(height: small ? 26 : 30)
        .background(selected ? Ink.ink : (hover ? Ink.chipHover : Ink.chip),
                    in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .animation(Motion.touch, value: hover)
        .animation(Motion.touch, value: selected)
    }
}

/// A filter chip as a button. Takes `.keyboardShortcut` from outside.
struct FilterChip: View {
    var title: String
    var count: Int? = nil
    var dot: Color? = nil
    var ring = false
    var selected: Bool
    var small = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            FilterChipLabel(title: title, count: count, dot: dot, ring: ring, selected: selected, small: small, hover: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Search field

/// A pill search field with an ink outline, for a screen's header ("Find the line you need").
struct WebSearchField: View {
    @Binding var text: String
    var prompt: String
    var height: CGFloat = 40
    @FocusState private var focused: Bool
    @Environment(\.look) private var look

    var body: some View {
        if look == .native {
            NativeSearchField(text: $text, prompt: prompt, height: min(height, 30))
        } else {
            verbose
        }
    }

    @ViewBuilder private var verbose: some View {
        HStack(spacing: 10) {
            IconGlyph(art: .iconNotes, size: 16, color: Ink.mute)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Ink.ink)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: height)
        .background(Ink.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: focused ? 2 : 1.5))
    }
}

// MARK: - Empty state

/// An empty screen (DESIGN.md §11): one horizontal card with an 80 pt butter plate (ink outline, the screen's icon),
/// a serif title, one or two sentences, and one button.
struct EmptyStateCard: View {
    var art: BrandArt
    var title: String
    var message: String
    var button: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.look) private var look

    var body: some View {
        if look == .native {
            NativeEmptyState(art: art, title: title, message: message, button: button, action: action)
        } else {
            verbose
        }
    }

    @ViewBuilder private var verbose: some View {
        let plate = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        HStack(alignment: .center, spacing: 26) {
            ZStack {
                plate.fill(Ink.panelButter)
                IconGlyph(art: art, size: 34, color: Ink.inkFixed)
            }
            .frame(width: 80, height: 80)
            .overlay(plate.inset(by: -0.75).stroke(Ink.inkFixed, lineWidth: 1.5))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Ink.serif(26)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.system(size: 14)).foregroundStyle(Ink.dim).lineSpacing(3)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                if let button, let action {
                    PillButton(title: button, kind: .dark, size: .regular, action: action).padding(.top, 16)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .inkEdge(outline: true, radius: Radius.record)
    }
}

// MARK: - Color panels: grain and line art

/// The website's paper grain, for color panels only (never under text on a blur, never on paper). A 256-pixel noise
/// tile made once and drawn at the display's scale, so one noise pixel is one screen pixel (the website's grain is that
/// fine). Normal blending at 32%: the tile is premultiplied ink with alpha, which reads like the website's multiply,
/// and it never forces an offscreen pass when a panel's drawing moves. Off under Increase Contrast and Reduce
/// Transparency.
struct GrainOverlay: View {
    var opacity: Double = 0.32
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.look) private var look

    var body: some View {
        // Native draws no grain.
        if look != .native, !reduceTransparency, contrast != .increased, let tile = GrainTile.image {
            Image(decorative: tile, scale: max(1, displayScale))
                .resizable(resizingMode: .tile)
                .interpolation(.none)
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The grain tile: deterministic noise in ink, mostly faint, as the website's feTurbulence filter reads.
enum GrainTile {
    static let image: CGImage? = make(size: 256)

    static func make(size n: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 0x9E37_79B9
        for i in 0..<(n * n) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let r = Double(seed >> 8) / Double(1 << 24)
            let a = r * r * 0.55 * 255
            // Premultiplied ink (0.15, 0.2, 0.18).
            px[i * 4] = UInt8(min(255, 0.15 * a))
            px[i * 4 + 1] = UInt8(min(255, 0.2 * a))
            px[i * 4 + 2] = UInt8(min(255, 0.18 * a))
            px[i * 4 + 3] = UInt8(min(255, a))
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension View {
    /// A color panel (DESIGN.md §11): an opaque brand fill with paper grain and, optionally, one line drawing behind
    /// the content, clipped to the panel. Position the art from the top trailing corner with `frame` and `offset`
    /// (positive x pushes it past the right edge, as the mockup's `right: -50px`).
    ///
    /// The fill takes exactly the content's size; the grain and the art are overlays on it, clipped to its shape, so a
    /// drawing larger than the panel (Home's 250-pt rings in a 196-pt card) can never make the panel bigger.
    ///
    /// Native: a plain group box (`nativeBox`), with no fill color, grain, or drawing.
    func colorPanel<Art: View>(_ fill: Color, radius: CGFloat = Radius.record, grain: Bool = true,
                               @ViewBuilder art: () -> Art) -> some View {
        modifier(ColorPanelSurface(fill: fill, radius: radius, grain: grain, art: art()))
    }

    func colorPanel(_ fill: Color, radius: CGFloat = Radius.record, grain: Bool = true) -> some View {
        colorPanel(fill, radius: radius, grain: grain) { EmptyView() }
    }
}

/// A color panel's surface (see `colorPanel`), or the Native group box.
struct ColorPanelSurface<Art: View>: ViewModifier {
    var fill: Color
    var radius: CGFloat
    var grain: Bool
    var art: Art
    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if look == .native {
            content.nativeBox(radius: radius)
        } else {
            content.background {
                shape.fill(fill)
                    .overlay { if grain { GrainOverlay() } }
                    .overlay(alignment: .topTrailing) { art }
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The line drawings on color panels, from the website.
enum PanelArtKind {
    /// Concentric circles anchored at the bottom that breathe (2.6 s, ±7 %), with a vertical axis. Record, voice.
    case rings
    /// Horizontal lines that draw in, hold, and draw out, staggered (7 s), beside a vertical rule. Projects, Dictionary.
    case lines
    /// Three circles that drift apart and back (7 s). Projects, Moments.
    case circles
    /// Two curved strands with flowing dashes into short lines (dashes 4.2 s, lines 7 s). Summaries.
    case strands
}

/// One panel drawing, looping gently on a `LoopTimeline` (30 fps at most, paused off screen and while the app is
/// inactive). Still under Reduce Motion, Limit animation, the screenshot tour, or `running: false`. Ink strokes,
/// 2.2 units wide in the drawing's own box. Decorative. At most one moving drawing per screen: pass `running: false`
/// to the rest.
struct PanelArt: View {
    var kind: PanelArtKind
    var running = true
    var color: Color = Ink.inkFixed
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look

    var body: some View {
        Group {
            if look == .native {
                EmptyView()   // Native draws no line art.
            } else if limitMotion || !LoopingArt.enabled || !running {
                Canvas { ctx, size in PanelArtDrawing.draw(kind, ctx, size, t: nil, color: color) }
            } else {
                LoopTimeline(running: true) { now in
                    Canvas { ctx, size in PanelArtDrawing.draw(kind, ctx, size, t: now.timeIntervalSinceReferenceDate, color: color) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The drawings' geometry (the mockup's SVG, in its own view boxes) and motion. `t` nil draws the still frame.
enum PanelArtDrawing {
    static func box(_ kind: PanelArtKind) -> CGRect {
        switch kind {
        case .rings: return CGRect(x: 0, y: 0, width: 300, height: 300)
        case .circles: return CGRect(x: 0, y: 0, width: 300, height: 260)
        case .lines, .strands: return CGRect(x: 0, y: 0, width: 300, height: 200)
        }
    }

    /// Cubic ease in and out.
    static func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }

    static func wrap(_ x: Double, _ period: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    /// A line's visible span (from, to), 0…1: draws in over the first quarter, holds, clears from the start over the
    /// last quarter; each line 0.15 s after the one before.
    static func span(_ t: Double?, _ i: Int, period: Double = 7) -> (CGFloat, CGFloat) {
        guard let t else { return (0, 1) }
        let q = wrap(t - Double(i) * 0.15, period) / period
        if q < 0.25 { return (0, CGFloat(ease(q / 0.25))) }
        if q >= 0.75 { return (CGFloat(ease((q - 0.75) / 0.25)), 1) }
        return (0, 1)
    }

    private static func pt(_ sp: ArtSpace, _ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: sp.dx + x * sp.s, y: sp.dy + y * sp.s) }

    private static func segment(_ sp: ArtSpace, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Path {
        var p = Path(); p.move(to: pt(sp, x1, y1)); p.addLine(to: pt(sp, x2, y2)); return p
    }

    private static let strandPaths: [Path] = [
        "M40 30 C120 50 140 0 200 96 Q210 112 220 140",
        "M40 80 C120 50 140 130 200 120 Q210 128 220 140",
    ].map { Path(SVGPathData.parse($0)) }

    static func draw(_ kind: PanelArtKind, _ ctx: GraphicsContext, _ size: CGSize, t: Double?, color: Color) {
        let sp = ArtSpace(box: box(kind), size: size)
        let style = StrokeStyle(lineWidth: max(1, 2.2 * sp.s), lineCap: .round, lineJoin: .round)
        let shading = GraphicsContext.Shading.color(color)

        // Short horizontal lines that draw in and out, from x1 to x2.
        func lines(_ items: [(CGFloat, CGFloat, CGFloat)]) {
            for (i, l) in items.enumerated() {
                let (from, to) = span(t, i)
                guard to - from > 0.01 else { continue }
                let len = l.2 - l.0
                ctx.stroke(segment(sp, l.0 + len * from, l.1, l.0 + len * to, l.1), with: shading, style: style)
            }
        }

        switch kind {
        case .rings:
            var p = Path()
            for (i, r0) in [CGFloat(120), 90, 60].enumerated() {
                // Every ring keeps touching the shared bottom point (150, 270).
                let r = t.map { r0 * CGFloat(1 + 0.07 * sin(2 * Double.pi * $0 / 2.6 - Double(i) * 0.55)) } ?? r0
                p.addPath(sp.circle(150, 270 - r, r))
            }
            p.addPath(segment(sp, 150, 0, 150, 300))
            ctx.stroke(p, with: shading, style: style)

        case .lines:
            ctx.stroke(segment(sp, 155, 0, 155, 200), with: shading, style: style)
            lines([(170, 24, 300), (190, 58, 300), (210, 92, 300), (170, 126, 300)])

        case .circles:
            var v: CGFloat = 0
            if let t {
                let p = wrap(t, 7) / 3.5
                v = CGFloat(p < 1 ? 1 - ease(p) : ease(p - 1))
            }
            let base: [(CGFloat, CGFloat)] = [(200, 90), (150, 170), (250, 170)]
            let drift: [(CGFloat, CGFloat)] = [(0, -16), (-16, 9), (16, 9)]
            var p = Path()
            for (b, d) in zip(base, drift) { p.addPath(sp.circle(b.0 + d.0 * v, b.1 + d.1 * v, 80)) }
            ctx.stroke(p, with: shading, style: style)

        case .strands:
            ctx.stroke(segment(sp, 230, 0, 230, 200), with: shading, style: style)
            for (i, strand) in strandPaths.enumerated() {
                let path = strand.applying(sp.transform)
                guard let t else { ctx.stroke(path, with: shading, style: style); continue }
                // One 16 % gap travels along each strand (dashes 84 on, 16 off, in path-length units of 100).
                let phase = wrap((100 * (1 - wrap(t, 4.2) / 4.2) + Double(i) * 9) / 100, 1)
                let start = CGFloat(wrap(1 - phase, 1)), end = start + 0.84
                if end <= 1 {
                    ctx.stroke(path.trimmedPath(from: start, to: end), with: shading, style: style)
                } else {
                    ctx.stroke(path.trimmedPath(from: start, to: 1), with: shading, style: style)
                    ctx.stroke(path.trimmedPath(from: 0, to: end - 1), with: shading, style: style)
                }
            }
            lines([(240, 30, 300), (240, 80, 300)])
        }
    }
}

// MARK: - App icons

/// The app a dictation went to, as its own icon (16 pt in Home's Last dictation), from `AppIconCache`; a neutral
/// square while it loads and when the app isn't on this Mac.
struct AppIconView: View {
    var bundleID: String?

    var body: some View {
        AppIcon(key: bundleID.flatMap { $0.isEmpty ? nil : .bundleID($0) }) {
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.neutralChip)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Glyphs

extension BrandArt {
    /// Small drawn glyphs for pills and links, in the icon grammar (24-unit grid, 1.5 stroke).
    static let webArrow = BrandArt(box: iconGrid, strokes: [.path("M5 12H19M13 6L19 12L13 18")], strokeWidth: 1.5)
    static let webPlus = BrandArt(box: iconGrid, strokes: [.path("M12 5V19M5 12H19")], strokeWidth: 1.5)
    static let webChevronDown = BrandArt(box: iconGrid, strokes: [.path("M7 10L12 15L17 10")], strokeWidth: 1.5)
}
