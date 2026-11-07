import SwiftUI

/// Two columns on a top-level Mac page (approved mockup "Verbose Mac Columns", November 3, 2026): the main column
/// takes the width, a 320 pt side column sits beside it, and the page keeps 32–36 pt margins, so there are no wide
/// empty gutters. Each column scrolls on its own, so a long list keeps the side cards in view and stays lazy. Below
/// `stackBelow` points of page width, the side column moves under the main one in a single scroll.
///
/// The side column starts level with the main column's first card, not with the page's heading (Tim, November 3:
/// This week sits beside the Record card). A page marks that card with `.macColumnsTop()`; without a mark, the side
/// column starts at the top. The heading gets `top` points of headroom.
enum MacColumnsMetrics {
    static let side: CGFloat = 320
    static let gap: CGFloat = 28
    static let leading: CGFloat = 36
    static let trailing: CGFloat = 32
    /// Below this page width, one column (main, then side).
    static let stackBelow: CGFloat = 1000
    /// Reading pages (Thoughts, Journal, Ask) stop their main column here; tables don't.
    static let readingMax: CGFloat = 900
    /// Headroom over a page's heading, under the toolbar.
    static let top: CGFloat = 32
    /// The main column's coordinate space, which `.macColumnsTop()` measures in.
    static let space = "macColumnsMain"

    /// Whether a page this wide shows two columns.
    static func twoColumns(_ width: CGFloat) -> Bool { width >= stackBelow }
    /// The main column's width on a page this wide, capped at `mainMax`.
    static func mainWidth(_ width: CGFloat, mainMax: CGFloat? = nil) -> CGFloat {
        let w = max(0, width - leading - trailing - gap - side)
        return mainMax.map { min($0, w) } ?? w
    }
}

/// Where the main column's first card starts, below the heading: the side column starts there too.
struct MacColumnsTopKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let n = nextValue() else { return }
        value = min(value ?? n, n)
    }
}

extension View {
    /// Marks the main column's first card (the Record card, the first table or day page), so the side column starts
    /// level with it. Measured in the main column's `.coordinateSpace(name: MacColumnsMetrics.space)`, which scrolling
    /// doesn't move.
    @ViewBuilder func macColumnsTop(_ on: Bool = true) -> some View {
        if on {
            background {
                GeometryReader { g in
                    Color.clear.preference(key: MacColumnsTopKey.self, value: g.frame(in: .named(MacColumnsMetrics.space)).minY)
                }
            }
        } else {
            self
        }
    }
}

struct MacColumns<Main: View, Side: View>: View {
    /// Caps the main column (reading pages); extra space goes to the margins evenly.
    var mainMax: CGFloat? = nil
    /// In one column, the side comes first. No page uses it now: By day keeps its heading and the day's writing first
    /// and shows a compact day stepper instead (MAC-29, GPT-16).
    var sideFirstWhenStacked = false
    @ViewBuilder var main: () -> Main
    @ViewBuilder var side: () -> Side
    /// The main column's first card's top (`.macColumnsTop()`).
    @State private var sideTop: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            if MacColumnsMetrics.twoColumns(g.size.width) {
                let mainW = MacColumnsMetrics.mainWidth(g.size.width, mainMax: mainMax)
                let used = mainW + MacColumnsMetrics.gap + MacColumnsMetrics.side
                let extra = max(0, g.size.width - MacColumnsMetrics.leading - MacColumnsMetrics.trailing - used) / 2
                HStack(alignment: .top, spacing: MacColumnsMetrics.gap) {
                    ScrollView {
                        main()
                            .frame(width: mainW, alignment: .topLeading)
                            .coordinateSpace(name: MacColumnsMetrics.space)
                            .padding(.top, MacColumnsMetrics.top).padding(.bottom, 40)
                    }
                    .scrollIndicators(.automatic)
                    .softScrollEdges(.top)
                    .frame(width: mainW)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { side() }
                            .frame(width: MacColumnsMetrics.side, alignment: .topLeading)
                            .padding(.top, MacColumnsMetrics.top + sideTop).padding(.bottom, 40)
                    }
                    .scrollIndicators(.never)
                    .frame(width: MacColumnsMetrics.side)
                }
                .onPreferenceChange(MacColumnsTopKey.self) { v in
                    let t = max(0, (v ?? 0).rounded())
                    if sideTop != t { sideTop = t }
                }
                .padding(.leading, MacColumnsMetrics.leading + extra)
                .padding(.trailing, MacColumnsMetrics.trailing + extra)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if sideFirstWhenStacked {
                            VStack(alignment: .leading, spacing: 12) { side() }
                            main()
                        } else {
                            main()
                            VStack(alignment: .leading, spacing: 12) { side() }
                        }
                    }
                    .frame(maxWidth: mainMax ?? .infinity, alignment: .topLeading)
                    .padding(.horizontal, 32).padding(.top, MacColumnsMetrics.top).padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
                .softScrollEdges(.top)
                .environment(\.macColumnsStacked, true)
            }
        }
    }
}

private struct MacColumnsStackedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside a `MacColumns` page that stacks in one column (a narrow window), so a page can show a compact
    /// stand-in for its side column where the reading starts.
    var macColumnsStacked: Bool {
        get { self[MacColumnsStackedKey.self] }
        set { self[MacColumnsStackedKey.self] = newValue }
    }
}

/// A card in a page's side column: a small uppercase label, an optional link on its right, and its content.
struct MacSideCard<Content: View>: View {
    var title: String
    var link: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Refined.mute)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let link, let action {
                    Button(link, action: action).buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Refined.accentText)
                }
            }
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .contain)
    }
}

/// One line in a side card: a label and a quiet value on the right.
struct MacSideLine: View {
    var label: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Refined.ink).lineLimit(1)
            Spacer(minLength: 8)
            if let value { Text(value).font(.system(size: 11.5)).foregroundStyle(Refined.mute).monospacedDigit() }
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }
}
