import SwiftUI

@main
struct VerbatimApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("Verbatim") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transcript") { app.goHome(); app.focusLink.toggle() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Record Voice Memo") { app.requestRecord() }
                    .keyboardShortcut("r", modifiers: [.option, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Transcripts") { app.focusSearch.toggle() }
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
