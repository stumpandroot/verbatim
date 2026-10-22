import Foundation
import AppIntents

/// Starts a keyboard session without the keyboard opening Verbatim: from the Control Center control
/// (`StartSessionControl`), the Action button, and Shortcuts (`VerbatimAppShortcuts`). Compiled into the app and
/// into the VerbatimWidgets extension, which shows the control.
///
/// iOS doesn't let an app start recording from the background, so the intent opens Verbatim for a moment
/// (`openAppWhenRun`), and `perform` runs in the app's process: it hands the start to the session through
/// `SessionStartSignal`. The start screen then says how to go back to your app.
struct StartKeyboardSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start dictation session"
    static var description = IntentDescription("Opens Verbatim and turns on the microphone for the Verbatim keyboard, so you can dictate in any app.")
    static var openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !VERBATIM_WIDGETS
        SessionStartSignal.fire(.shortcut)
        #endif
        return .result()
    }
}
