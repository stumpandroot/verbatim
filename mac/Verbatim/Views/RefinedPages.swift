import SwiftUI

// The refined look's page parts (DESIGN.md §13), shared by the Mac and iPhone apps: the pieces the remaining screens
// share beyond RefinedKit.swift. A page's header (the large serif title, its count, a line under it, and its controls),
// the empty state, a selectable row in a card, a group of rows with a label, a status word, a sheet's frame on the Mac,
// and a checkbox for lists you tick. Colors come from `Refined` only; every size scales with Dynamic Type on iPhone,
// tap targets are 44 pt there, and Limit animation holds presses still.

// MARK: - Page header

/// A screen's header (the Mac's Templates, Ask, Dictations, Dictionary, Queue, and Recently Deleted; the iPhone's
/// lists): the large serif title with its count, an optional line under it in `dim`, and the screen's controls at the
/// trailing edge (they wrap under the title when the window is narrow).
struct RefinedPageHeader<Trailing: View>: View {
    var title: String
    var count: String? = nil
    var lede: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: RefinedPlatform.mac ? 6 : 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    LargeSerifTitle(title: title, count: count).accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) { trailing }
                }
                VStack(alignment: .leading, spacing: 10) {
                    LargeSerifTitle(title: title, count: count).accessibilityElement(children: .combine)
                    HStack(spacing: 8) { trailing }
                }
            }
            if let lede {
                Text(lede).refinedFont(.body).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RefinedPageHeader where Trailing == EmptyView {
    init(title: String, count: String? = nil, lede: String? = nil) {
        self.init(title: title, count: count, lede: lede) { EmptyView() }
    }
}

// MARK: - Empty state

/// An empty screen or section (no projects, no recipes, nothing deleted): one card with the place's icon square, the
/// serif title, a sentence or two, and an optional strong action.
struct RefinedEmptyState: View {
    var art: BrandArt
    var hue: RefinedHue = .neutral
    var title: String
    var message: String
    var action: String? = nil
    var perform: (() -> Void)? = nil

    init(art: BrandArt, hue: RefinedHue = .neutral, title: String, message: String, action: String? = nil, perform: (() -> Void)? = nil) {
        self.art = art; self.hue = hue; self.title = title; self.message = message; self.action = action; self.perform = perform
    }

    var body: some View {
        PaperCard {
            HStack(alignment: .top, spacing: 14) {
                IconSquare(art: art, hue: hue)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                    Text(message).refinedFont(.body).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action, let perform {
                        Button(action, action: perform)
                            .buttonStyle(RefinedActionStyle(kind: .strong))
                            .padding(.top, 6)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(RefinedPlatform.mac ? 18 : 16)
        }
    }
}

// MARK: - Rows

/// A row in a card that you select or open (a template, a recipe, a recent question, a dictation, a queued file): the
/// content you pass, the persimmon tint when selected, the quiet stripe under the pointer, and a press. A Button, so
/// it takes the keyboard (Full Keyboard Access, Space and Return) and VoiceOver reads it selected when it is.
struct PaperRowButton<Content: View>: View {
    var selected = false
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    init(selected: Bool = false, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected; self.action = action; self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: RefinedPlatform.mac ? 36 : CGFloat(RefinedRules.minTapTarget))
                .background(selected ? Refined.persimmonTint : (hover ? Refined.stripe : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(RefinedRowPress())
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row's press: a dim while held, never a scale (rows don't move).
struct RefinedRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A group of rows under a label (Templates' groups, a day's thoughts, Recent questions): the label in the meta style
/// in `mute` (or the serif section title), an optional trailing control, then a card of rows.
struct PaperGroup<Content: View, Trailing: View>: View {
    var title: String?
    var serif = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    private let mac = RefinedPlatform.mac

    init(_ title: String?, serif: Bool = false, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.serif = serif; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: serif ? 8 : (mac ? 8 : 7)) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if serif {
                        Text(title).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                    } else {
                        Text(title).refinedFont(.meta, weight: mac ? .semibold : .regular).foregroundStyle(Refined.mute)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.horizontal, serif ? 0 : (mac ? 4 : 14))
            }
            PaperCard { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PaperGroup where Trailing == EmptyView {
    init(_ title: String?, serif: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title, serif: serif, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Status and checks

/// A status word at the end of a row ("Answered", "Ready", "Needs retry"): plain text, never a capsule. Accent for
/// what's done or chosen, `mute` for the rest; the word carries the meaning.
struct RefinedStatus: View {
    var text: String
    var accent = false
    var body: some View {
        Text(text).refinedFont(.meta, weight: accent ? .semibold : .regular)
            .foregroundStyle(accent ? Refined.accentText : Refined.mute)
            .lineLimit(1)
    }
}

/// A box you tick (a plan's tasks, Send to Reminders' rows): the accent's filled check when on, an empty ring in
/// `faint` when off. 44 pt to tap on iPhone. VoiceOver reads the label you give the row, with the checked trait.
struct RefinedCheckbox: View {
    var on: Bool
    var size: CGFloat = 20
    var body: some View {
        ZStack {
            if on {
                Circle().fill(Refined.accentText)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Refined.paper)
            } else {
                Circle().strokeBorder(Refined.faint, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Menus

/// A menu's face on the page (Try on a recording, a list's More): the quiet action's wash and ink text with a small
/// chevron, the same size as `RefinedActionStyle`'s buttons. Put it in a `Menu`'s label with the plain button style.
struct RefinedMenuLabel: View {
    var title: String
    private let mac = RefinedPlatform.mac
    var body: some View {
        HStack(spacing: 6) {
            Text(title).refinedFont(.hint, weight: .semibold).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
        }
        .foregroundStyle(Refined.ink)
        .padding(.horizontal, mac ? 14 : 16)
        .frame(minHeight: mac ? 32 : CGFloat(RefinedRules.minTapTarget))
        .background(Refined.neutral, in: RoundedRectangle(cornerRadius: mac ? 8 : 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: mac ? 8 : 22, style: .continuous))
    }
}

/// A text field's box on the page or in a sheet (a template's instruction, a note): the field color with the field
/// radius, and a hairline under Increase Contrast.
struct RefinedFieldBox: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous)
        content
            .background(Refined.field, in: shape)
            .overlay { if contrast == .increased { shape.strokeBorder(Refined.separator, lineWidth: 1) } }
    }
}

extension View {
    func refinedFieldBox() -> some View { modifier(RefinedFieldBox()) }
}

// MARK: - Sheets (Mac)

#if os(macOS)
/// A sheet's frame on the Mac (Export, Add from Library, a recipe, Edit Record As, the link card's sign-in): paper, the
/// title in the serif section size, an optional line under it, the content, and the buttons at the foot, which are the
/// system's (Cancel, then the default action, `.borderedProminent` in the accent). Escape and Return work as usual.
struct RefinedSheet<Content: View, Footer: View>: View {
    var title: String
    var message: String? = nil
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(title: String, message: String? = nil, width: CGFloat = 520, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title; self.message = message; self.width = width; self.content = content(); self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message).refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: 8) { footer }
                .controlSize(.large)
        }
        .padding(24)
        .frame(width: width)
        .background(Refined.paper)
        .tint(Refined.accentText)
    }
}
#endif

// MARK: - List pages (iPhone)

#if os(iOS)
/// An iPhone screen built on a system List (Dictionary, Snippets, Recently Deleted, Import): the paper behind it, the
/// list's own background hidden, the kit's separators, and the name inline in the bar while the serif title sits on
/// the page (`RefinedListTitle`). Give each section `.listRowBackground(Refined.card)` so its rows sit on cards.
struct RefinedListPage: ViewModifier {
    var title: String
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Refined.paper.ignoresSafeArea())
            .environment(\.defaultMinListRowHeight, CGFloat(RefinedRules.minTapTarget))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
    }
}

extension View {
    func refinedListPage(_ title: String) -> some View { modifier(RefinedListPage(title: title)) }
}

/// The large serif title (and an optional line under it) as a List's first section, on the paper with no card.
struct RefinedListTitle: View {
    var title: String
    var count: String? = nil
    var lede: String? = nil
    var body: some View {
        Section {
            RefinedPageHeader(title: title, count: count, lede: lede)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                .listRowSeparator(.hidden)
        }
    }
}
#endif

// MARK: - Ways to record

// Record as's rows on both apps (the iPhone's tray, Edit Record As on both): each way's glyph and its kind's color.

extension RecordChoice {
    /// The fine-line glyph (the Mac menus' custom symbols are made from the same ones).
    var art: BrandArt {
        switch self {
        case .voiceNote: return .iconMic
        case .kind(.meeting): return .iconSpeakers
        case .kind(.interview): return .iconQuote
        case .kind(.journal): return .iconNotes
        case .kind(.talk): return .iconVoice
        case .kind(.brainDump): return .iconBrainDump
        case .kind(.audio): return .iconAudio
        case .kind: return .iconMic
        case .thought: return .iconThought
        }
    }
}

extension RecordChoice {
    /// The kind's color on its icon square (DESIGN.md §13's kinds): a voice note persimmon, a thought butter, and each
    /// kind its own.
    var refinedHue: RefinedHue {
        switch self {
        case .voiceNote: return RefinedRules.kindHue(nil)
        case .kind(let k): return k.refinedHue
        case .thought: return RecordingKind.idea.refinedHue
        }
    }
}

// MARK: - Previews

#if DEBUG
struct RefinedPageHeader_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            RefinedPageHeader(title: "Templates", count: "14 templates", lede: "Turn a transcript into notes, a plan, or a draft.") {
                Button("New template") {}.buttonStyle(RefinedActionStyle(kind: .strong))
            }
        }
    }
}

struct RefinedEmptyState_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            RefinedEmptyState(art: .iconProject, hue: .sage, title: "No projects yet",
                              message: "Projects group recordings. Make one here, or from a recording's menu.", action: "New project") {}
        }
    }
}

struct PaperRowButton_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            PaperGroup("Scenario templates") {
                PaperRowButton(selected: true, action: {}) {
                    Text("Meeting notes").refinedFont(.rowTitle, weight: .semibold).padding(.horizontal, 14)
                }
                PaperDivider()
                PaperRowButton(action: {}) {
                    Text("Plan my day").refinedFont(.rowTitle, weight: .semibold).padding(.horizontal, 14)
                }
            }
        }
    }
}

struct PaperGroup_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            PaperGroup("Today", serif: true) {
                IconSquareRow(art: .iconThought, hue: .butter, title: "6 thoughts", value: "9:40 AM")
            }
        }
    }
}

struct RefinedMenuLabel_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            RefinedMenuLabel(title: "Try on a recording")
            Text("A field").padding(8).refinedFieldBox()
        }
    }
}

struct RefinedStatus_Previews: PreviewProvider {
    static var previews: some View {
        RefinedPreviewPage {
            HStack { RefinedStatus(text: "Answered", accent: true); RefinedStatus(text: "No answer") }
            HStack { RefinedCheckbox(on: true); RefinedCheckbox(on: false) }
        }
    }
}
#endif
