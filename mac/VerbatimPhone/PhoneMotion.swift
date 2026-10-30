import SwiftUI
import UIKit

// Motion for the iPhone screens, matched to the approved web prototype (timings in `Motion`, Tokens.swift).
// Rules from the design system: never animate keyboard-initiated or high-frequency actions; screens, tabs, and
// rows arrive at once, with no rise-in, stagger, or tab entrance (DESIGN.md §7); delight stays small
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
/// preferences › Haptics (on by default, kept per device in the App Group, so the keyboard follows it, and sent to the
/// Apple Watch). Which haptic an event plays is `HapticPolicy` (DESIGN.md §7); they follow the iPhone's System Haptics
/// on their own. Always pair a haptic with something you can see.
enum Haptics {
    static let enabledKey = HapticSettings.enabledKey

    /// The App Group's defaults, where the keyboard can read the switch. A choice made before it moved there (in the
    /// app's own defaults) is carried over once.
    static let store: UserDefaults = {
        guard let group = KeyboardBridge.defaults else { return .standard }
        if group.object(forKey: enabledKey) == nil, let old = UserDefaults.standard.object(forKey: enabledKey) {
            group.set(old, forKey: enabledKey)
        }
        return group
    }()

    static var enabled: Bool { HapticSettings.enabled(in: store) }
    static var policy: HapticPolicy { HapticPolicy(enabled: enabled) }

    /// Plays the event's haptic, if it has one and haptics are on.
    static func play(_ event: HapticEvent) {
        guard let h = policy.haptic(for: event) else { return }
        HapticPlayer.play(h)
    }

    /// For `.sensoryFeedback(trigger:_:)`: the event's feedback while haptics are on, nil (none) while they're off.
    static func feedback(_ event: HapticEvent) -> SensoryFeedback? {
        switch policy.haptic(for: event) {
        case .impact(.light, let i)?: return .impact(weight: .light, intensity: i)
        case .impact(.medium, let i)?: return .impact(weight: .medium, intensity: i)
        case .impact(.soft, let i)?: return .impact(flexibility: .soft, intensity: i)
        case .selection?: return .selection
        case .success?: return .success
        case .warning?: return .warning
        case .error?: return .error
        default: return nil
        }
    }

    /// A haptic that has to land with a gesture (the Record as tray opening under a held finger): the caller keeps its
    /// own generator and prepares it on touch down. These prepare and play it only while haptics are on.
    static func prepare(_ generator: UIFeedbackGenerator) { if enabled { generator.prepare() } }
    static func impact(_ generator: UIImpactFeedbackGenerator) { if enabled { generator.impactOccurred() } }
    static func selection(_ generator: UISelectionFeedbackGenerator) { if enabled { generator.selectionChanged() } }
}

/// Settings › Keyboard: Typing haptics, in the App Group, where the keyboard reads it. Off unless turned on.
struct KeyboardTypingHapticsRow: View {
    @AppStorage(HapticSettings.typingKey, store: KeyboardBridge.defaults) private var on = false
    var body: some View {
        SettingsToggleRow(title: "Typing haptics",
                          subtitle: "A light tap with each key you type. Needs Allow Full Access. Start and Done tap either way while Haptics is on.", isOn: $on)
            .cardSurface(radius: Radius.row)
    }
}
