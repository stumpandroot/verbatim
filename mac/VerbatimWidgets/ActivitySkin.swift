import SwiftUI
import WidgetKit

/// The Lock Screen's Live Activities (the session's and the recording's) follow the Lock Screen's appearance, not the
/// app's (DESIGN.md §13): paper with ink in light, and the app's near-black green (`darkPaperFixed`) with paper text
/// in dark, so a bright banner never sits on a dark Lock Screen. The persimmon Stop with ink stays the same in both;
/// the voice bars and the bars mark take `mark`. The Dynamic Island is always black and doesn't use this.
struct ActivitySkin {
    var dark: Bool

    var background: Color { dark ? Refined.darkPaperFixed : Refined.paperFixed }
    /// Titles, the timer, and glyphs.
    var ink: Color { dark ? Refined.onBlack : Refined.inkFixed }
    /// The line under the title (6.3:1 on paper, 6.2:1 on the dark paper).
    var dim: Color { dark ? Refined.onBlackDim : Refined.inkFixed.opacity(0.8) }
    /// Quiet data, such as how long the session has been on.
    var mute: Color { dark ? Refined.muteOnInk : Refined.muteOnPaper }
    /// The marks that carry "listening" (the bars mark, the voice bars): the text-safe persimmon on paper (5.6:1; the
    /// bright fill measured 2.4:1 there), the bright persimmon on the dark paper (SF-27).
    var mark: Color { dark ? Refined.persimmonFixed : Refined.accentTextOnPaper }
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
            // Text grows with Dynamic Type (`scaledFont`, SF-11), within the Lock Screen's height.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
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

// MARK: - Stale (LiveFreshness, SF-01)

/// Voice bars held still at a resting shape: a stale Live Activity draws no level, because it has none it can trust.
struct StaleBars: View {
    var color: Color
    var count = 5
    /// What VoiceOver reads when the bars stand alone (the minimal Island); nil hides them beside their words.
    var label: String? = nil
    private static let shape: [Double] = [0.45, 0.7, 0.55, 0.9, 1.0, 0.8, 0.6, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: count > 5 ? 3 : 2) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: count > 5 ? 3 : 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: max(0.15, Self.shape[(i * Self.shape.count) / max(1, count)] * 0.2), anchor: .center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }
}

/// A stale Live Activity on the Lock Screen: the bars mark, "Open Verbose to check your recording" (or session), and
/// "Verbose hasn't updated this in a while.", with still bars, no timer, and no buttons. Tapping it opens Verbose.
/// It never says the recording stopped.
struct StaleLockScreen: View {
    var title: String
    var skin: ActivitySkin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BarsMark(color: skin.mute).frame(width: 18, height: 18)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(skin.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            StaleBars(color: skin.mute, count: 34).frame(height: 22)
            Text(LiveFreshness.detail).font(.system(size: 13)).foregroundStyle(skin.dim).lineLimit(2)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

/// A stale Live Activity's expanded Dynamic Island, under its leading bars: the same words, and no buttons.
struct StaleIslandBottom: View {
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Refined.onBlack).lineLimit(2)
            Text(LiveFreshness.detail).font(.system(size: 13)).foregroundStyle(Refined.onBlackDim).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A stale Live Activity's compact trailing word, in place of a running timer.
struct StaleCompactWord: View {
    var title: String
    var body: some View {
        Text(LiveFreshness.compact).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.onBlack)
            .lineLimit(1).fixedSize()
            .accessibilityLabel(title)
    }
}
