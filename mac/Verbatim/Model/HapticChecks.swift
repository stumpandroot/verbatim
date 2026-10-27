import Foundation

/// The haptics policy (HapticPolicy.swift), checked by the Linux tests (`mac/tools/test-haptics.sh`) and by the
/// iPhone's self-test. `check` logs PASS or FAIL.
enum HapticChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let phone = HapticPolicy(enabled: true)
        check("haptics: start is a medium tap at 0.7, stop a soft tap at 0.8",
              phone.haptic(for: .recordStart) == .impact(.medium, intensity: 0.7) && phone.haptic(for: .recordStop) == .impact(.soft, intensity: 0.8))
        check("haptics: start and stop feel different", phone.haptic(for: .recordStart) != phone.haptic(for: .recordStop))
        check("haptics: pause and resume are a light tap", phone.haptic(for: .pause) == .impact(.light, intensity: 1) && phone.haptic(for: .resume) == phone.haptic(for: .pause))
        check("haptics: mark is a light tap at 0.5 while marks buzz",
              phone.haptic(for: .mark) == (HapticPolicy.markBuzzes ? .impact(.light, intensity: 0.5) : nil))
        check("haptics: transcript ready and Your voice are success", phone.haptic(for: .transcriptReady) == .success && phone.haptic(for: .milestone) == .success)
        check("haptics: errors are error", phone.haptic(for: .failed) == .error)
        check("haptics: an automatic pause and low storage are warning", phone.haptic(for: .autoPaused) == .warning && phone.haptic(for: .lowStorage) == .warning)
        check("haptics: every copy and Inserted is one selection tick", phone.haptic(for: .copied) == .selection)
        check("haptics: small saves and the tray are a light tap", phone.haptic(for: .smallSave) == .impact(.light, intensity: 1)
              && phone.haptic(for: .trayOpened) == .impact(.light, intensity: 1))
        check("haptics: the app plays no typing tap", phone.haptic(for: .typingKey) == nil)
        check("haptics: success is only for a finished transcript, Your voice, and Send to Reminders",
              HapticEvent.allCases.filter { phone.haptic(for: $0) == .success } == [.transcriptReady, .milestone, .sentToReminders])
        check("haptics: the iPhone never plays a watch haptic",
              HapticEvent.allCases.compactMap { phone.haptic(for: $0) }.allSatisfy { !Self.isWatch($0) })

        // The switch turns every one of them off, everywhere.
        let off: [HapticPolicy] = [HapticPolicy(enabled: false), HapticPolicy(enabled: false, typingKeys: true, platform: .keyboard),
                                   HapticPolicy(enabled: false, platform: .watch)]
        check("haptics: with the switch off, nothing plays (iPhone, keyboard, watch)",
              off.allSatisfy { p in HapticEvent.allCases.allSatisfy { p.haptic(for: $0) == nil } })

        // The keyboard: the app's start and stop, typing taps off unless turned on.
        let keyboard = HapticPolicy(enabled: HapticSettings.enabled(in: nil), typingKeys: HapticSettings.typingKeys(in: nil), platform: .keyboard)
        check("haptics: on by default; keyboard typing taps off by default",
              HapticSettings.enabled(in: nil) && !HapticSettings.typingKeys(in: nil) && keyboard.haptic(for: .typingKey) == nil)
        check("haptics: the keyboard's start and Done are the app's start and stop",
              keyboard.haptic(for: .recordStart) == phone.haptic(for: .recordStart) && keyboard.haptic(for: .recordStop) == phone.haptic(for: .recordStop))
        check("haptics: the keyboard's Inserted, Copied, and format chip are a selection tick",
              keyboard.haptic(for: .copied) == .selection && keyboard.haptic(for: .picked) == .selection)
        var typing = keyboard
        typing.typingKeys = true
        check("haptics: with Typing haptics on, each key is a light tap at 0.6", typing.haptic(for: .typingKey) == .impact(.light, intensity: 0.6))
        check("haptics: the keyboard plays nothing for the app's other events",
              [HapticEvent.pause, .mark, .transcriptReady, .failed, .autoPaused, .smallSave].allSatisfy { keyboard.haptic(for: $0) == nil })

        // The watch: start, click, stop, failure, and nothing else.
        let watch = HapticPolicy(enabled: true, platform: .watch)
        check("haptics: the watch plays start, click, stop, and failure",
              watch.haptic(for: .recordStart) == .watchStart && watch.haptic(for: .mark) == .watchClick
              && watch.haptic(for: .recordStop) == .watchStop && watch.haptic(for: .failed) == .watchFailure)
        check("haptics: the watch plays only its own haptics",
              HapticEvent.allCases.compactMap { watch.haptic(for: $0) }.allSatisfy(Self.isWatch) && watch.haptic(for: .transcriptReady) == nil)

        // Transcript ready: once per recording, only in front, only with the message.
        let a = UUID(), b = UUID()
        var once = ReadyOnce()
        check("haptics: ready plays the first time, in front", once.ready(a, foreground: true, queueEmpty: true))
        check("haptics: ready doesn't play twice for one recording (Transcribe again)", !once.ready(a, foreground: true, queueEmpty: true))
        check("haptics: ready in the background plays nothing, and not later either",
              !once.ready(b, foreground: false, queueEmpty: true) && !once.ready(b, foreground: true, queueEmpty: true))
        once.newRecording(a)
        check("haptics: a recording added to the transcript plays its own ready", once.ready(a, foreground: true, queueEmpty: true))
        let c = UUID()
        check("haptics: ready waits for the last in a batch (no message, no haptic)", !once.ready(c, foreground: true, queueEmpty: false))

        // The stored switches round trip through defaults.
        let suite = "haptic-checks-\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            let defaultsOK = HapticSettings.enabled(in: d) && !HapticSettings.typingKeys(in: d)
            d.set(false, forKey: HapticSettings.enabledKey)
            d.set(true, forKey: HapticSettings.typingKey)
            check("haptics: the switches are read from the shared defaults",
                  defaultsOK && !HapticSettings.enabled(in: d) && HapticSettings.typingKeys(in: d))
            d.removePersistentDomain(forName: suite)
        }
    }

    private static func isWatch(_ h: Haptic) -> Bool {
        switch h {
        case .watchStart, .watchClick, .watchStop, .watchFailure: return true
        default: return false
        }
    }
}
