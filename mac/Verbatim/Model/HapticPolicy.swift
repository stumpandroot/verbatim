import Foundation
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

// Which haptic each event plays (DESIGN.md §7, Haptics), for the iPhone app, the keyboard, and the Apple Watch. The
// policy is pure, so the Linux tests (mac/tools/test-haptics.sh) and the iPhone's self-test check it (HapticChecks.swift).
// The iPhone app plays through `Haptics` (Haptics.swift), the keyboard through `KeyboardModel`, and the watch
// through `WatchRecorder`; all three ask this policy first. The Mac plays none.
//
// One cause, one haptic. Start and stop are clear system taps, frequent actions a selection tick or a light tap, and
// `.success` marks a finished transcript once per recording. Every haptic comes with something you can see. The system
// skips a haptic it can't play (System Haptics off, Vibration off, an iPad, or Verbose in the background), so callers
// never check for that; nothing here tries to play from the background.

/// Something that happened, in the words of the people who feel it.
enum HapticEvent: String, CaseIterable {
    /// A recording, thought, Live captions, or keyboard dictation is about to start: played just before the microphone
    /// opens, so it isn't in the recording.
    case recordStart
    /// Stop, Stop & add, Discard, Live captions' Stop or Save, the keyboard's Done: at the tap, not after saving.
    case recordStop
    case pause
    case resume
    /// Mark a moment while recording (`HapticPolicy.markBuzzes`).
    case mark
    /// The transcript is ready (a template that runs after it adds none): once per recording, Verbose in front.
    case transcriptReady
    /// Microphone not allowed, couldn't start, couldn't save, transcription failed.
    case failed
    /// A call or a route change paused the recording, or its audio can't be saved.
    case autoPaused
    /// Little space left when a recording starts.
    case lowStorage
    /// Every copy, and a ribbon take Copied or Inserted; the keyboard's Inserted and Copied.
    case copied
    /// A note or bookmark added, a speaker suggestion used, moved to a project.
    case smallSave
    /// A rare milestone: Your voice set up.
    case milestone
    /// Send to Reminders added a plan's tasks (DayPlan.swift): `.success`, with "Added 9 reminders to Studio" showing.
    case sentToReminders
    /// A choice in a list, a scrubber line, a row under the finger, the keyboard's format chip or polished swap.
    case picked
    /// The Record as tray opens under a held finger.
    case trayOpened
    /// A typing key in the Verbose keyboard (off unless Settings › Keyboard › Typing haptics is on).
    case typingKey
}

enum HapticWeight: String { case light, medium, soft }

/// What plays. The watch has its own vocabulary (`WKHapticType`).
enum Haptic: Equatable {
    case impact(HapticWeight, intensity: Double)
    case selection
    case success
    case warning
    case error
    case watchStart
    case watchClick
    case watchStop
    case watchFailure
}

struct HapticPolicy {
    enum Platform { case phone, keyboard, watch }

    /// Settings › Personalization and preferences › Haptics (the watch follows the iPhone's).
    var enabled: Bool
    /// Settings › Keyboard › Typing haptics.
    var typingKeys = false
    var platform: Platform = .phone

    /// Mark buzzes while recording (light, 0.5). Set to false if a test recording shows the tap can be heard; Mark then
    /// confirms with "Marked 4:12" only. The watch's mark click is separate.
    static let markBuzzes = true

    static let start = Haptic.impact(.medium, intensity: 0.7)
    static let stop = Haptic.impact(.soft, intensity: 0.8)
    static let pauseTap = Haptic.impact(.light, intensity: 1)
    static let markTap = Haptic.impact(.light, intensity: 0.5)
    static let typingTap = Haptic.impact(.light, intensity: 0.6)

    /// The haptic for an event, or nil for none (haptics off, or nothing for this event here).
    func haptic(for event: HapticEvent) -> Haptic? {
        guard enabled else { return nil }
        switch platform {
        case .watch:
            switch event {
            case .recordStart: return .watchStart
            case .mark: return .watchClick
            case .recordStop: return .watchStop
            case .failed: return .watchFailure
            default: return nil
            }
        case .keyboard:
            switch event {
            case .recordStart: return Self.start
            case .recordStop: return Self.stop
            case .copied, .picked: return .selection
            case .typingKey: return typingKeys ? Self.typingTap : nil
            default: return nil
            }
        case .phone:
            switch event {
            case .recordStart: return Self.start
            case .recordStop: return Self.stop
            case .pause, .resume: return Self.pauseTap
            case .mark: return Self.markBuzzes ? Self.markTap : nil
            case .transcriptReady, .milestone, .sentToReminders: return .success
            case .failed: return .error
            case .autoPaused, .lowStorage: return .warning
            case .copied, .picked: return .selection
            case .smallSave, .trayOpened: return .impact(.light, intensity: 1)
            case .typingKey: return nil
            }
        }
    }
}

/// Transcript ready's `.success`: once per recording, only with Verbose in front and nothing else waiting (when the
/// "Transcript ready" message shows). Transcribe again doesn't play it a second time; a recording added to the same
/// transcript can.
struct ReadyOnce {
    private(set) var played: Set<UUID> = []

    /// A new recording joins this transcript (Stop & add): its ready can play again.
    mutating func newRecording(_ id: UUID) { played.remove(id) }

    /// True when `.success` plays now. The ready moment counts as used even when it can't play.
    mutating func ready(_ id: UUID, foreground: Bool, queueEmpty: Bool) -> Bool {
        let first = played.insert(id).inserted
        return first && foreground && queueEmpty
    }
}

/// Where the switches live: the App Group, so the keyboard reads them too (KeyboardBridge's group).
enum HapticSettings {
    /// Settings › Personalization and preferences › Haptics. On unless turned off.
    static let enabledKey = "haptics.enabled"
    /// Settings › Keyboard › Typing haptics. Off unless turned on.
    static let typingKey = "kb.typingHaptics"

    static func enabled(in d: UserDefaults?) -> Bool { d?.object(forKey: enabledKey) as? Bool ?? true }
    static func typingKeys(in d: UserDefaults?) -> Bool { d?.object(forKey: typingKey) as? Bool ?? false }
}

#if os(iOS)
/// Plays a haptic with the system's feedback generators, which follow System Haptics and Vibration on their own.
enum HapticPlayer {
    static func play(_ h: Haptic) {
        switch h {
        case .impact(let weight, let intensity): UIImpactFeedbackGenerator(style: weight.style).impactOccurred(intensity: CGFloat(intensity))
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .watchStart, .watchClick, .watchStop, .watchFailure: break
        }
    }
}

extension HapticWeight {
    var style: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .soft: return .soft
        }
    }
}
#elseif os(watchOS)
extension Haptic {
    /// The watch's haptic for this one; nil for the iPhone's.
    var watchType: WKHapticType? {
        switch self {
        case .watchStart: return .start
        case .watchClick: return .click
        case .watchStop: return .stop
        case .watchFailure: return .failure
        default: return nil
        }
    }
}
#endif
