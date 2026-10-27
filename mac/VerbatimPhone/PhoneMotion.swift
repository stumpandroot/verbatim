import SwiftUI
import UIKit

// Motion for the iPhone screens, matched to the approved web prototype (timings in `Motion`, Tokens.swift).
// Rules from the design system: never animate keyboard-initiated or high-frequency actions; screens, tabs, and
// rows arrive at once, with no rise-in, stagger, or tab entrance (DESIGN.md §7, §13.3.9); delight stays small
// and rare. Everything here reads `\.limitMotion` (Reduce Motion or Settings › Limit animation): movement becomes
// a short fade and nothing loops.

enum PhoneMotion {
    /// The screenshot tour (VERBATIM_UITEST=1) wants settled screens, so ambient loops stay off there.
    static let on = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1"
}

// MARK: - Controls

/// Press: scale 0.97 in and out over 320 ms. With motion limited, a brief dim instead.
struct SoftPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressable(configuration: configuration) }
    private struct Pressable: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.97 : 1)
                .opacity(configuration.isPressed && limitMotion ? 0.7 : 1)
                .animation(limitMotion ? Motion.fade : Motion.pressSoft, value: configuration.isPressed)
        }
    }
}

// MARK: - Haptics

/// Every haptic in the app goes through here, so one switch turns them all off: Settings › Personalization and
/// preferences › Haptics (on by default, kept per device). Haptics stay occasional: copies and saves get a
/// selection tick or a light tap, and `.success` is kept for rare milestones such as finishing Your voice
/// (review P-04). Always pair a haptic with something you can see.
enum Haptics {
    static let enabledKey = "haptics.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    enum Kind { case selection, light, medium, success }

    static func play(_ kind: Kind) {
        guard enabled else { return }
        switch kind {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// For `.sensoryFeedback(trigger:_:)`: the feedback while haptics are on, nil (none) while they're off.
    static func feedback(_ f: SensoryFeedback) -> SensoryFeedback? { enabled ? f : nil }

    /// A haptic that has to land with a gesture (the Record as tray opening under a held finger): the caller keeps its
    /// own generator and prepares it on touch down. These prepare and play it only while haptics are on.
    static func prepare(_ generator: UIFeedbackGenerator) { if enabled { generator.prepare() } }
    static func impact(_ generator: UIImpactFeedbackGenerator) { if enabled { generator.impactOccurred() } }
    static func selection(_ generator: UISelectionFeedbackGenerator) { if enabled { generator.selectionChanged() } }
}
