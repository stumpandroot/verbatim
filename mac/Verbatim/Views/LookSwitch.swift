import SwiftUI
import CoreText
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Switching looks (Settings › Appearance on iPhone, Settings › General on Mac, and onboarding's Pick a look). Picking a
// look shows a small centered card in the new look ("Switching to Native…", its thumbnail, and a spinner) over a scrim
// of the new look's background. Once the card is on screen the look is stored, so everything rebuilds behind it; then
// the card and scrim fade out, which crossfades into the rebuilt screen. Limit animation: the card appears at once and
// leaves with a fade, with no scaling.
//
// Timing: a "Look.switch" signpost from the pick to the first turn of the main loop after the rebuild (its frame
// committed), logged as "look: switched to <look> in <ms> ms". Both self-tests log it as `UITEST TIMING look-switch`.

final class LookSwitch: ObservableObject {
    static let shared = LookSwitch()

    /// The look being switched to, while its card shows.
    @Published private(set) var card: AppLook?
    /// True from the rebuild until the card starts to fade: views made then skip their entrance animations (the rebuilt
    /// screen should be there when the card fades, not rise in again). Some onAppear calls land a turn after the
    /// update, so it stays on until the card goes.
    private(set) static var rebuilding = false
    /// The card stays up at least this long, so it reads as a step rather than a flash.
    static let minimumShown: TimeInterval = 0.35
    /// The card's fade in (none under Limit animation). The look is stored once it has finished, because the rebuild
    /// holds the main thread and SwiftUI's animations run there.
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.2

    /// The last switch's rebuild alone: from storing the look to the first turn of the main loop after it.
    private(set) var lastRebuildMs: Double = 0
    private var generation = 0

    /// Shows the card, stores `look` behind it, then fades the card. `done` gets the switch's time in milliseconds
    /// (the pick to the rebuild's first frame) once the card starts to fade. Ignored while a switch runs; picking the
    /// look that's on does nothing.
    func pick(_ look: AppLook, done: ((Double) -> Void)? = nil) {
        guard card == nil else { done?(0); return }
        guard look != AppLook.current else { done?(0); return }
        generation += 1
        let gen = generation
        let start = Date()
        let signpost = Perf.signposter.beginInterval("Look.switch", "\(look.rawValue)")
        let quiet = MotionPreference.isLimited
        Self.prewarm()
        card = look
        // The card's first frame (and its fade in) goes out before the rebuild takes the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + (quiet ? 0 : Self.fadeIn)) {
            guard gen == self.generation else { return }
            Self.rebuilding = true
            let written = Date()
            AppLook.current = look
            LookOverride.shared.look = look   // every root in this update, whenever the stored value's notice lands
            // The next turn of the main loop comes after SwiftUI's update and its commit: the rebuild is on screen.
            DispatchQueue.main.async {
                let ms = Date().timeIntervalSince(start) * 1000
                self.lastRebuildMs = Date().timeIntervalSince(written) * 1000
                Perf.signposter.endInterval("Look.switch", signpost)
                Log.note("look: switched to \(look.rawValue) in \(Int(ms.rounded())) ms (rebuild \(Int(self.lastRebuildMs.rounded())) ms)")
                let wait = max(0, Self.minimumShown - ms / 1000)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    guard gen == self.generation else { return }
                    Self.rebuilding = false
                    LookOverride.shared.look = nil
                    self.card = nil
                    done?(ms)
                }
            }
        }
    }

    /// The same switch for the self-tests: waits until the card starts to fade, and returns the time in milliseconds.
    func switchTo(_ look: AppLook) async -> Double {
        await withCheckedContinuation { c in
            DispatchQueue.main.async { self.pick(look) { c.resume(returning: $0) } }
        }
    }

    private static var prewarmed = false

    /// Loads both looks' type ahead of time, off the main thread: the serif and mono faces Verbose style uses (New York
    /// and SF Mono are their own font files) and SF Pro, with a line of each shaped once. On the Mac it also makes the
    /// grain tile. Called when a look picker appears and when a switch starts; runs once.
    static func prewarm() {
        guard !prewarmed else { return }
        prewarmed = true
        DispatchQueue.global(qos: .utility).async {
            let sample = "Switching to Verbose style… Native 0123456789"
            #if os(macOS)
            let base = NSFont.systemFont(ofSize: 15).fontDescriptor
            let designs: [NSFontDescriptor.SystemDesign] = [.default, .serif, .monospaced]
            for d in designs {
                guard let fd = base.withDesign(d), let font = NSFont(descriptor: fd, size: 15) else { continue }
                shape(sample, font)
            }
            _ = GrainTile.image
            #else
            let base = UIFont.systemFont(ofSize: 17).fontDescriptor
            let designs: [UIFontDescriptor.SystemDesign] = [.default, .serif, .monospaced]
            for d in designs {
                guard let fd = base.withDesign(d) else { continue }
                shape(sample, UIFont(descriptor: fd, size: 17))
            }
            #endif
        }
    }

    /// Lays out one line in `font` (a UIFont or NSFont, both toll-free bridged to CTFont).
    private static func shape(_ text: String, _ font: AnyObject) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        _ = CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}

extension MotionPreference {
    /// Limit animation as stored (Settings) or asked for by the system (Reduce Motion).
    static var isLimited: Bool {
        #if os(macOS)
        let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        let system = UIAccessibility.isReduceMotionEnabled
        #endif
        return system || UserDefaults.standard.bool(forKey: key)
    }
}

// MARK: - The card

/// The scrim and the card, over a window's content (or a sheet's). Hit testing stays on while it shows, so nothing
/// underneath can be picked mid-switch.
struct LookSwitchLayer: View {
    @ObservedObject private var model = LookSwitch.shared
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        ZStack {
            if let target = model.card {
                LookSwitchScrim(look: target)
                    .transition(.opacity)
                LookSwitchCard(look: target)
                    .transition(limitMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(animation, value: model.card)
    }

    /// In with a short fade (at once under Limit animation, so it's up before the rebuild); out with a fade.
    private var animation: Animation? {
        if model.card == nil { return .easeOut(duration: LookSwitch.fadeOut) }
        return limitMotion ? nil : .easeOut(duration: LookSwitch.fadeIn)
    }
}

extension View {
    /// The look-switch card over this content, for surfaces that aren't rebuilt by `lookRebuild()` (the iPhone's root
    /// and its onboarding cover).
    func lookSwitchLayer() -> some View { overlay { LookSwitchLayer() } }
}

/// The new look's background, nearly opaque, so the rebuild underneath doesn't show through.
private struct LookSwitchScrim: View {
    var look: AppLook
    var body: some View {
        Rectangle()
            .fill(LookSwitchColors.background(look))
            .opacity(0.92)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

/// "Switching to Native…" with the look's thumbnail and a spinner, drawn in the look it names.
private struct LookSwitchCard: View {
    var look: AppLook

    private var title: String { "Switching to \(look.label)…" }
    private var native: Bool { look == .native }

    var body: some View {
        HStack(spacing: 16) {
            thumbnail
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(LookSwitchColors.text(look))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(LookSwitchColors.spinner(look))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: 320)
        .background { surface }
        .padding(.horizontal, 32)
        .environment(\.look, look)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isModal)
        .onAppear { AccessibilityNotification.Announcement("Switching to \(look.label)").post() }
    }

    #if os(macOS)
    private var thumbnail: some View { LookThumbnail(look: look, width: 84) }
    private var titleFont: Font { native ? .system(size: 14, weight: .semibold) : SurfaceFont.serif(19) }
    #else
    private var thumbnail: some View { LookThumbnail(look: look, width: 36) }
    private var titleFont: Font { native ? .system(size: 17, weight: .semibold) : Ink.serif(21) }
    #endif

    /// Verbose style: card white with an ink hairline and the hard shadow. Native: a plain rounded card with a soft
    /// system shadow.
    @ViewBuilder private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: native ? 16 : Radius.record, style: .continuous)
        if native {
            shape.fill(LookSwitchColors.card(look))
                .shadow(color: Color.black.opacity(0.16), radius: 18, y: 6)
        } else {
            shape.fill(LookSwitchColors.card(look))
                .overlay(shape.strokeBorder(LookSwitchColors.edge, lineWidth: 1.5))
                .background(shape.fill(LookSwitchColors.hard).offset(x: 3, y: 4))
        }
    }
}

/// The card's colors for the look it names, whichever look is stored: on the Mac the Ink tokens follow the stored look
/// (NativeSwap), so the card uses Verbose style's fixed values and the system colors directly.
enum LookSwitchColors {
    static func background(_ look: AppLook) -> Color {
        #if os(macOS)
        return look == .native ? NativeInk.window : Ink.paperVerbose
        #else
        return look == .native ? NativeInk.paper : Ink.paper
        #endif
    }
    static func card(_ look: AppLook) -> Color {
        #if os(macOS)
        return look == .native ? NativeInk.content : Ink.cardVerbose
        #else
        return look == .native ? NativeInk.card : Ink.card
        #endif
    }
    static func text(_ look: AppLook) -> Color {
        #if os(macOS)
        return look == .native ? Color.primary : Ink.inkVerbose
        #else
        return look == .native ? NativeInk.label : Ink.ink
        #endif
    }
    static func spinner(_ look: AppLook) -> Color {
        return look == .native ? Ink.nativeAccent : text(look)
    }
    static let edge = Ink.inkVerbose
    static let hard = Ink.hardVerbose
}
