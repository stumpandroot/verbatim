import SwiftUI
import WatchKit
import WatchConnectivity

// Verbose on Apple Watch (DESIGN.md §20; mockup "Library features", section 4): Record and New thought, a recording
// screen with Mark and Stop, and Sent to iPhone. The watch records and sends; the iPhone transcribes and syncs to the
// Mac. Watch Connectivity is activated at launch, so files queued earlier go out and the iPhone's thought count
// arrives even when the app was opened by a complication or woken in the background.

@main
struct VerbatimWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchRoot(recorder: recorder, link: WatchLink.shared)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchLink.shared.activate()
    }

    func applicationDidBecomeActive() {
        WatchLink.shared.resendPending()
    }

    /// The iPhone sent something while the app wasn't running: held until Watch Connectivity has delivered it.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let wc = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchLink.shared.hold(wc)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
