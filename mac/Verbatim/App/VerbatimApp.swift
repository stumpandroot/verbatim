import SwiftUI

@main
struct VerbatimApp: App {
    @StateObject private var app = AppState()

    init() {
        Log.note("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        // `-bench <clips dir> -benchOut <report.json>`: run the accuracy and latency bench, then quit (Bench.swift).
        if Bench.isRequested { Bench.start() }
        // Sparkle automatic updates; stays off without SUPublicEDKey and in UI-test or bench mode (Updater.swift).
        Updater.shared.start()
    }

    var body: some Scene {
        WindowGroup("Verbatim") {
            ContentView()
                .environmentObject(app)
                .limitMotionRoot()
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { Log.note("window appeared") }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: UITest.enabled ? 1000 : 1200, height: UITest.enabled ? 700 : 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
            CommandGroup(replacing: .newItem) {
                Button("New Transcript") { app.goHome(); app.focusLink.toggle() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import Files…") { app.chooseFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Import Multi-track Recording…") { app.chooseMultitrack() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Record Voice Memo") { app.requestRecord() }
                    .keyboardShortcut("r", modifiers: [.option, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Transcripts") { app.goHome() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView().environmentObject(app).limitMotionRoot()
        }

        MenuBarExtra(isInserted: $app.showMenuBar) {
            MenuBarPanel().environmentObject(app).limitMotionRoot()
        } label: {
            Image(systemName: "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

/// "Check for Updates…" in the app menu, after About. Disabled while the updater is off or a check is running.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.isRunning || !updater.canCheckForUpdates)
    }
}
