import SwiftUI

// The title row of a tab's first screen, as in Verbose Tasks: the line above (the date or a count), the serif title,
// and round buttons at the trailing edge, pinned at the top while the page scrolls under it. A pushed screen keeps
// Apple's bar, for Back, with its title on the page.

extension View {
    /// Pins `header` at the top and hides the system bar when `pinned`; otherwise leaves the screen as it is. Paper
    /// fills the status bar and the title's strip with a clean edge (Tasks found a fade read as a shadow over colored
    /// cards in dark mode).
    @ViewBuilder func pinnedTitle<Header: View>(_ pinned: Bool, @ViewBuilder header: () -> Header) -> some View {
        if pinned {
            let h = header()
            self.toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    h.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Refined.paper.ignoresSafeArea(edges: .top))
                }
        } else {
            self
        }
    }
}

/// A round button's face in a title row (Home's Settings button): the glyph on a card-colored circle, in a full tap
/// target. Use it as a Button's or a Menu's label.
struct TitleCircle<Glyph: View>: View {
    @ViewBuilder var glyph: Glyph
    var body: some View {
        glyph
            .frame(width: 36, height: 36)
            .background(Refined.card, in: Circle())
            .frame(width: CGFloat(RefinedRules.minTapTarget), height: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Circle())
    }
}

/// The page title with its round buttons: `LargeSerifTitle` on the leading side, the buttons trailing, tops aligned.
struct TitleRow<Trailing: View>: View {
    var title: String
    var eyebrow: String? = nil
    var count: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LargeSerifTitle(title: title, eyebrow: eyebrow, count: count)
                .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            HStack(spacing: 4) { trailing }
        }
    }
}
