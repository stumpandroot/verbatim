import SwiftUI
import AppKit

// Pieces the notch and the floating button share: their panel, the voice bars, the spinner, and the glyphs.

/// A borderless, non-activating panel for a dictation surface: it never becomes key or main, never moves itself onto
/// the visible frame (the notch's panel sits over the menu bar), and is kept out of screenshots and screen sharing
/// (except in the UI self-test, whose screenshots need it).
final class SurfacePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Above the menu bar and its status items, below menus (so a menu opened from the menu bar, or our own right-click
    /// menu, still draws over the notch). On macOS 26 `.statusBar` draws under the menu bar, which hid the pill's
    /// first row on displays without a notch (build 200).
    static let aboveMenuBar = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    @MainActor static func make(size: CGSize, level: NSWindow.Level = .statusBar) -> SurfacePanel {
        let p = SurfacePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = level
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.sharingType = UITest.enabled ? .readOnly : .none
        return p
    }
}

/// Where a surface's drawn content is, in its panel's coordinates (top-left origin): clicks inside reach it, clicks
/// outside pass through to the apps behind. Mid-transition both states draw, so the area covers both.
struct SurfaceFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.isEmpty { return }
        value = value.isEmpty ? next : value.union(next)
    }
}

extension View {
    /// Reports this view's frame in the named panel space for the surface's clickable area.
    func surfaceFrame(in space: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: SurfaceFrameKey.self, value: g.frame(in: .named(space))) })
    }
}

/// Voice bars, centered on a line: live from the mic level, or a still pattern at rest.
struct VoiceBars: View {
    var levels: [Double]
    var height: CGFloat
    var barWidth: CGFloat = 2.5
    var gap: CGFloat = 2
    var color: Color = Ink.persimmonFixed

    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: barWidth, height: max(barWidth, height * CGFloat(levels[i])))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }

    /// The last `count` mic levels, oldest first, never below a resting sliver.
    static func live(_ levels: [Float], count: Int) -> [Double] {
        let l = levels.map(Double.init)
        guard l.count >= count else { return Array(repeating: 0.2, count: count) }
        return l.suffix(count).map { min(1, max(0.14, $0 * 1.15)) }
    }

    /// A still, even pattern for rest states (a mark, not a level).
    static func still(_ count: Int) -> [Double] {
        let pattern: [Double] = [0.45, 0.8, 1, 0.65, 0.9, 0.5, 0.75, 0.95, 0.55]
        return (0..<count).map { pattern[$0 % pattern.count] }
    }
}

/// A small spinner: a quarter arc going round a faint track. Under Reduce Motion and Limit animation it holds still
/// and the words beside it carry the state. A TimelineView at most 30 frames a second, never a repeatForever
/// animation (DESIGN.md §7).
struct SurfaceSpinner: View {
    var size: CGFloat = 13
    var color: Color = Ink.persimmonFixed
    var track: Color = Ink.onBlackHair
    var still = false

    var body: some View {
        Group {
            if still {
                arc(0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { t in
                    arc(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func arc(_ degrees: Double) -> some View {
        let w = max(1.5, size / 7)
        return ZStack {
            Circle().stroke(track, lineWidth: w)
            Circle().trim(from: 0, to: 0.25).stroke(color, style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(degrees - 90))
        }
        .padding(w / 2)
    }
}

/// A keycap on a dark surface (the notch, the ink pills): mono 12 inside a hairline outline.
struct DarkKeycap: View {
    var text: String
    var color: Color = Ink.onBlack
    var edge: Color = Ink.onBlackHair
    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(Ink.mono(12)).foregroundStyle(color)
            if text == "fn" { Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(color) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(edge, lineWidth: 1))
        .fixedSize()
        .accessibilityLabel(Keycap.spoken(text))
    }
}

extension BrandArt {
    /// Attention: a circle with a line and a dot (errors pair it with a word, never color alone).
    static let webAttention = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5), .path("M12 7V13")], fills: [.circle(12, 16.3, 1.1)], strokeWidth: 1.6)
    /// A check, for "Pasted into Notes".
    static let webCheck = BrandArt(box: iconGrid, strokes: [.path("M5 12.5L10 17.5L19 7")], strokeWidth: 2.4)
}

/// The elapsed time as the surfaces show it: "0:07".
enum SurfaceClock {
    static func text(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
