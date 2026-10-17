import SwiftUI

@main
struct VerbatimApp: App {
    @StateObject private var app = AppState()

    init() {
        Log.note("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        // `-bench <clips dir> -benchOut <report.json>`: run the accuracy and latency bench, then quit (Bench.swift).
        if Bench.isRequested { Bench.start() }
    }

    var body: some Scene {
        WindowGroup("Verbatim") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { Log.note("window appeared") }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: UITest.enabled ? 1000 : 1200, height: UITest.enabled ? 700 : 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transcript") { app.goHome(); app.focusLink.toggle() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import Files…") { app.chooseFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Record Voice Memo") { app.requestRecord() }
                    .keyboardShortcut("r", modifiers: [.option, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Transcripts") { app.goHome() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView().environmentObject(app)
        }

        MenuBarExtra(isInserted: $app.showMenuBar) {
            MenuBarPanel().environmentObject(app)
        } label: {
            Image(systemName: "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
