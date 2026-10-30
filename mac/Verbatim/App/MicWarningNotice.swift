#if os(macOS)
import AppKit
import UserNotifications

/// A muted mic while Verbose isn't in front (DESIGN.md §6.10, A muted microphone). During a call you're looking at the call, so the
/// Record card's warning goes unseen: a notification says it, at most once every 30 seconds. It waits a second
/// first, so silence that the backup turns into "Using MacBook Pro Microphone" in the same moment posts once, as the
/// move. Notifications are asked for the first time a warning needs one.
@MainActor
enum MicWarningNotice {
    static let identifier = "co.stumpandroot.verbatim.mic-warning"
    private static var lastPosted: TimeInterval = -100
    private static var pending: MicWarning?
    private static var token = 0

    /// Call on every change of a recorder's `micWarning`.
    static func changed(_ w: MicWarning?) {
        token += 1
        pending = w
        guard let w else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        guard !UITest.enabled, Bundle.main.bundleIdentifier != nil else { return }
        let mine = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard token == mine, pending == w, !NSApp.isActive else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPosted >= 30 else { return }
            lastPosted = now
            post(w)
        }
    }

    /// The notification's title and body.
    static func text(_ w: MicWarning) -> (title: String, body: String) {
        switch w {
        case .usingBuiltIn(let builtIn, let chosen, let certain):
            return (certain ? "Your mic is muted" : "Your mic seems to be muted",
                    "Verbose is recording from \(builtIn) instead. Unmute \(MicWarning.phrase(chosen)) to switch back.")
        case .muted(let name):
            return ("Your mic is muted", "Unmute \(MicWarning.phrase(name)) to keep recording your voice.")
        case .silent(let name):
            return ("Not hearing your mic", "Is \(MicWarning.phrase(name)) muted? Verbose is still recording.")
        }
    }

    private static func post(_ w: MicWarning) {
        let (title, body) = text(w)
        let center = UNUserNotificationCenter.current()
        let id = identifier
        // Runs on the notification center's queue.
        let send: @Sendable () -> Void = {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { error in
                Log.note(error.map { "recorder: mic warning notification not posted (\($0.localizedDescription))" } ?? "recorder: mic warning notification posted")
            }
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
            case .denied:
                Log.note("recorder: mic warning not posted; notifications are off for Verbose")
            default:
                send()
            }
        }
    }
}
#endif
