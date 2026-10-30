import SwiftUI

/// The instant type filters of the Add from Library sheet: a row of type chips (All, Voice notes, Videos, …) with
/// counts, and for Videos and Links a second row of platforms, on the refined kit (`RefinedChip`). Types with no
/// transcripts are hidden.
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

    private static let spacing: CGFloat = 8
    private func chip(_ label: String, _ n: Int, on: Bool, small: Bool = false, source: LibrarySource? = nil, target: String, action: @escaping () -> Void) -> some View {
        RefinedChip(title: "\(label) \u{00B7} \(n)", selected: on, action: action)
            .accessibilityLabel(label)
            .accessibilityValue("\(n)")
            #if os(macOS)
            .uiTarget(target)
            #endif
    }
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
