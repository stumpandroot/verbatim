import Foundation

/// When the welcome tour shows. Shared by the Mac and the iPhone; each device keeps its own answer.
///
/// It shows once after an update that raises `version` (so everyone sees a new tour once), and again whenever
/// "Show the welcome tour when Verbatim opens" is on in Settings. Finishing or skipping turns that switch off.
enum Onboarding {
    static let version = 1
    private static let d = UserDefaults.standard
    private static let seenKey = "onboarding.seenVersion"
    static let showKey = "onboarding.showOnLaunch"

    static var showOnLaunch: Bool {
        get { d.bool(forKey: showKey) }
        set { d.set(newValue, forKey: showKey) }
    }

    static var shouldShow: Bool {
        guard ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1" else { return false }
        return showOnLaunch || d.integer(forKey: seenKey) < version
    }

    static func finish() {
        d.set(version, forKey: seenKey)
        showOnLaunch = false
    }
}
