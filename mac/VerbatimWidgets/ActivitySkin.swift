import SwiftUI
import WidgetKit

/// The Lock Screen's Live Activities (the session's and the recording's) follow the Lock Screen's appearance, not the
/// app's (DESIGN.md §13): paper with ink in light, and the app's near-black green (`darkPaperFixed`) with paper text
/// in dark, so a bright banner never sits on a dark Lock Screen. The persimmon Stop with ink, the persimmon voice bars,
/// and the bars mark stay the same in both. The Dynamic Island is always black and doesn't use this.
struct ActivitySkin {
    var dark: Bool

    var background: Color { dark ? Refined.darkPaperFixed : Refined.paperFixed }
    /// Titles, the timer, and glyphs.
    var ink: Color { dark ? Refined.onBlack : Refined.inkFixed }
    /// The line under the title (6.3:1 on paper, 6.2:1 on the dark paper).
    var dim: Color { dark ? Refined.onBlackDim : Refined.inkFixed.opacity(0.8) }
    /// Quiet data, such as how long the session has been on.
    var mute: Color { dark ? Refined.muteOnInk : Refined.muteOnPaper }
    /// The outlined buttons' ring (Mark, Pause or Resume): full ink on paper, full paper on the dark paper.
    var outline: Color { dark ? Refined.onBlack : Refined.inkFixed }
}

/// Reads the Lock Screen's appearance and sets the activity's background and its system dismiss button to match.
struct ActivityLockSurface<Content: View>: View {
    @ViewBuilder var content: (ActivitySkin) -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let skin = ActivitySkin(dark: scheme == .dark)
        content(skin)
            .activityBackgroundTint(skin.background)
            .activitySystemActionForegroundColor(skin.ink)
    }
}

/// The outlined Live Activity buttons' colors and height: in the Dynamic Island (paper on black, a hairline ring) or on
/// the Lock Screen (the skin's ink and ring).
struct ActivityButtonTone {
    var foreground: Color
    var outline: Color
    var height: CGFloat

    static let island = ActivityButtonTone(foreground: Refined.onBlack, outline: Refined.onBlackHair, height: 38)
    static func lock(_ skin: ActivitySkin) -> ActivityButtonTone {
        ActivityButtonTone(foreground: skin.ink, outline: skin.outline, height: 40)
    }
}
