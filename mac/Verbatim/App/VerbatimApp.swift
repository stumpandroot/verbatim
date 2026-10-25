import SwiftUI
import Combine

@main
struct VerbatimApp: App {
    /// AppState, held without observing it: an AppState publish (each navigation, each Store, Recorder, Player, or
    /// transcription tick) used to re-evaluate every scene and the main menu's commands before any window. The
    /// holder publishes only the menu bar switch (`AppHolder`).
    @StateObject private var holder = AppHolder()
    private var app: AppState { holder.app }
    /// Asks before quitting cuts off a recording (QuitGuard.swift).
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard

    init() {
        // The iCloud container lookup starts on a background thread before the Store loads (Cloud.prefetchContainer).
        Cloud.prefetchContainer()
        Log.note("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        // `-bench <clips dir> -benchOut <report.json>`: run the accuracy and latency bench, then quit (Bench.swift).
        if Bench.isRequested { Bench.start() }
        // Sparkle automatic updates; stays off without SUPublicEDKey and in UI-test or bench mode (Updater.swift).
        Updater.shared.start()
    }

    var body: some Scene {
        WindowGroup("Verbose") {
            ContentView()
                .environmentObject(app)
                .limitMotionRoot()
                .lookRoot()
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { Log.note("window appeared") }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: UITest.enabled ? 1000 : 1200, height: UITest.enabled ? 700 : 800)
        .commands {
            CommandGroup(after: .appInfo) {
                // Settings › What's new (Views/WhatsNewPane.swift), then Sparkle's check.
                WhatsNewMenuButton { app.dictation.openSettings(tab: .whatsNew) }
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
                Button("Live Captions") { app.toggleLiveCaptions() }
                    .keyboardShortcut("c", modifiers: [.option, .command])
                // Meeting capture (App/MeetingCoordinator.swift): every start goes through the consent sheet.
                Divider()
                MeetingCaptureCommands()
            }
            CommandGroup(after: .importExport) {
                // Every Library transcript as a Markdown note with properties (Views/TrustViews.swift).
                Button("Export Library as Markdown…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Transcripts") { app.goHome() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            // View › Edit Home: outlines Home's sections and opens Edit Home's inspector (Views/EditHome.swift).
            CommandGroup(after: .sidebar) {
                Button("Edit Home") { app.goHome(); HomeEditSession.shared.editing = true }
            }
        }

        Settings {
            SettingsView().environmentObject(app).limitMotionRoot().lookRoot()
        }

        MenuBarExtra(isInserted: holder.menuBarBinding) {
            // Live captions sits below the panel's own rows (kept out of SettingsView.swift).
            VStack(spacing: 0) {
                MenuBarPanel()
                RecallMenuSection().padding(.horizontal, 12).padding(.bottom, 10)
                LiveCaptionsMenuRow().padding(.horizontal, 12).padding(.bottom, 12)
            }
            .frame(width: 320).background(Ink.paper)
            .lookRebuild()
            .environmentObject(app).limitMotionRoot().lookRoot()
        } label: {
            // The bars mark as a template image, so the menu bar tints it (DESIGN.md §3, §4).
            Image(nsImage: BrandArt.markBars.templateImage(size: 16, key: "menubar"))
                .accessibilityLabel("Verbose")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the app's AppState for the `App` struct without forwarding its changes, so the scenes and commands are built
/// once instead of on every publish. Commands only call into AppState; anything a menu shows live observes its own
/// object (`MeetingCaptureCommands`, `CheckForUpdatesButton`). The one value a scene reads, Settings › General ›
/// Show in menu bar, is mirrored in `showMenuBar` and announced only when it changes.
@MainActor
final class AppHolder: ObservableObject {
    let app: AppState
    @Published private(set) var showMenuBar: Bool
    private var bag: AnyCancellable?

    init() {
        let state = AppState()
        app = state
        showMenuBar = state.showMenuBar
        // objectWillChange comes before the change, so the value is read on the next turn of the main queue.
        bag = state.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMenuBar() }
        }
    }

    private func syncMenuBar() {
        if showMenuBar != app.showMenuBar { showMenuBar = app.showMenuBar }
    }

    /// The menu bar item's binding. MenuBarExtra writes it back on every update (Changed.swift); AppState's
    /// `@Changed` and `syncMenuBar` both ignore a write of the same value, so a write-back publishes nothing.
    var menuBarBinding: Binding<Bool> {
        Binding(get: { [unowned self] in self.showMenuBar },
                set: { [unowned self] v in
                    self.app.showMenuBar = v
                    self.syncMenuBar()
                })
    }
}

/// Record Meeting… (the consent sheet, then a two-track recording of the call) or Stop Meeting, and Pause or
/// Resume while recording.
struct MeetingCaptureCommands: View {
    @ObservedObject private var session = MeetingSession.shared
    var body: some View {
        Button(session.isActive ? "Stop Meeting" : "Record Meeting…") {
            if session.isActive { MeetingCoordinator.shared.stopFromMenu() } else { MeetingCoordinator.shared.recordFromMenu() }
        }
        .disabled(session.phase == .starting || session.phase == .stopping)
        if session.canPause {
            Button(session.phase == .paused ? "Resume Meeting" : "Pause Meeting") { session.togglePause() }
        }
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
