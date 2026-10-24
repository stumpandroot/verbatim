import SwiftUI

/// The Library's instant filters, shared by the Library (Mac and iPhone) and the Add from Library sheet: a row of type
/// chips (All, Voice memos, Videos, …) with counts, and for Videos and Links a second row of platforms. Types with no
/// transcripts are hidden. Selected chips are ink with paper text; nothing sits on glass.
struct LibraryFilterBar: View {
    @Binding var filter: LibraryFilter
    /// The transcripts the counts cover (already narrowed by project, kind, and search).
    var items: [Transcript]
    var searching: Bool
    /// Mac: chips wrap onto more lines. iPhone: one line that scrolls sideways.
    var wraps: Bool
    /// ⌥⌘1–7 choose a type (the Library on Mac only; a sheet leaves them to the window behind it).
    var shortcuts = false
    var onChange: () -> Void = {}
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        let sources = filter.sourceCounts(items, searching: searching)
        let platforms = filter.platformCounts(items, searching: searching)
        VStack(alignment: .leading, spacing: 8) {
            row {
                ForEach(sources, id: \.0) { s, n in
                    chip(s.label, n, on: filter.source == s, source: s, target: "source-\(s.rawValue)") { choose(LibraryFilter(source: s)) }
                        .modifier(TypeShortcut(index: LibrarySource.allCases.firstIndex(of: s).map { $0 + 1 }, on: shortcuts))
                }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Type")
            if !platforms.isEmpty {
                row {
                    ForEach(platforms, id: \.0) { p, n in
                        chip(p, n, on: filter.platform == p, small: true, target: "platform-\(p)") {
                            choose(LibraryFilter(source: filter.source, platform: filter.platform == p ? nil : p))
                        }
                    }
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Platform")
                .transition(.opacity)
            }
        }
        .animation(limitMotion ? Motion.fade : Motion.snap, value: platforms.isEmpty)
    }

    private func choose(_ f: LibraryFilter) {
        guard f != filter else { return }
        filter = f
        onChange()
    }

    @ViewBuilder private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if wraps {
            FlowRow(spacing: Self.spacing, lineSpacing: Self.spacing) { content() }
        } else {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content() }.padding(.horizontal, 20) }
        }
    }

    #if os(macOS)
    private static let spacing: CGFloat = 8
    /// Website style on Mac (DESIGN.md §11): soft rounded chips, each type with its source's color as a dot (links an
    /// ink ring). Platforms have no dot.
    private func chip(_ label: String, _ n: Int, on: Bool, small: Bool = false, source: LibrarySource? = nil, target: String, action: @escaping () -> Void) -> some View {
        FilterChip(title: label, count: n, dot: Self.dot(source), ring: source == .links, selected: on, small: small, action: action)
            .uiTarget(target)
    }

    static func dot(_ s: LibrarySource?) -> Color? {
        switch s {
        case .voiceMemos?: return Ink.panelRecord
        case .videos?, .audioFiles?: return Ink.panelSage
        case .appAudio?: return Ink.panelPetal
        case .dictations?: return Ink.panelButter
        default: return nil
        }
    }
    #else
    private static let spacing: CGFloat = 6
    private func chip(_ label: String, _ n: Int, on: Bool, small: Bool = false, source: LibrarySource? = nil, target: String, action: @escaping () -> Void) -> some View {
        let size: CGFloat = small ? 13 : 14, height: CGFloat = small ? 30 : 32, pad: CGFloat = small ? 12 : 14
        return Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                Text("\(n)").font(.system(size: size - 1)).monospacedDigit().opacity(0.75)
            }
            .font(.system(size: size, weight: small ? .medium : .semibold))
            .foregroundStyle(on ? Ink.onInteractive : Ink.ink)
            .padding(.horizontal, pad).frame(minHeight: height)
            .background(on ? Ink.interactive : Ink.card, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Ink.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(n)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
    #endif
}

/// ⌥⌘ and the type's place in the list (All is 1).
struct TypeShortcut: ViewModifier {
    var index: Int?
    var on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        if on, let i = index, i <= 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: [.command, .option]).help("⌥⌘\(i)")
        } else {
            content
        }
        #else
        content
        #endif
    }
}
