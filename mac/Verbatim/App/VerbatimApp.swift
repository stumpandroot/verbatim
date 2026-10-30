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
        // The self-test's big library goes in before the Store loads, so launch is timed with it (LibraryLoading.swift).
        if UITest.enabled { BigLibrarySeed.write() }
        LaunchClock.markStart()
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
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { Log.note("window appeared") }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: UITest.enabled ? 1000 : 1200, height: UITest.enabled ? 700 : 800)
        .commands {
            // About Verbose: the standard panel, with the channel in the version, "Version 1.0 beta (217)"
            // (VERSIONING.md). Without the option it shows only CFBundleShortVersionString, "1.0".
            CommandGroup(replacing: .appInfo) {
                Button("About Verbose") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: AppVersion.name, .version: AppVersion.build])
                }
            }
            CommandGroup(after: .appInfo) {
                // Settings › What's new (Views/WhatsNewPane.swift), then Sparkle's check.
                WhatsNewMenuButton { app.dictation.openSettings(tab: .whatsNew) }
                CheckForUpdatesButton()
            }
            CommandGroup(replacing: .newItem) {
                // One Import (consolidation, October 28, 2026): files, a folder, or a link, in one panel. ⌘O opens it
                // with the link field ready; ⌘N (New Transcript) is a second way to the same panel.
                Button("New Transcript") { app.openImport() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import…") { app.openImport() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Import Multi-track Recording…") { app.chooseMultitrack() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Record Voice Memo") { app.requestRecord() }
                    .keyboardShortcut("r", modifiers: [.option, .shift])
                // The six ways to record, as on Record's right-click menu (CaptureBar.swift): a picked kind is yours, so
                // AutoLabel leaves it and Run automatically uses it (Templates.swift). Meeting… is the meeting capture,
                // which files its transcript as a Meeting; Stop Meeting and Pause Meeting show below while one runs.
                Menu("Record As") { RecordKindMenuItems(titles: \.commandTitle).environmentObject(app) }
                // Today's page in note mode (Views/DayNote.swift): the day's note, where ⌃⌥ dictation goes, and Plan my
                // day. It took the Brain dump window's place (consolidation, October 28, 2026).
                Button("Today's Note") { DayNote.open() }
                Button("Live Captions") { app.toggleLiveCaptions() }
                    .keyboardShortcut("c", modifiers: [.option, .command])
                // Meeting capture (App/MeetingCoordinator.swift): every start goes through the consent sheet. Its
                // section shows only while a meeting records.
                MeetingCaptureCommands()
            }
            CommandGroup(after: .importExport) {
                // Every Library transcript as a Markdown note with properties (Views/TrustViews.swift).
                Button("Export Library as Markdown…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
            }
            CommandGroup(after: .textEditing) {
                // One search field (consolidation, October 28, 2026): ⌘F opens the same panel as ⌘K, on Search.
                Button("Find in Transcripts") {
                    app.mainWindow?.makeKeyAndOrderFront(nil)
                    AskNav.shared.open(mode: .search)
                }
                .keyboardShortcut("f", modifiers: .command)
                // Search or ask: the panel over the main window (Views/AskViews.swift).
                Button("Search or Ask…") {
                    app.mainWindow?.makeKeyAndOrderFront(nil)
                    if AskNav.shared.panelOpen { AskNav.shared.close() } else { AskNav.shared.open() }
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            // View › Edit Home: outlines Home's sections and opens Edit Home's inspector (Views/EditHome.swift).
            CommandGroup(after: .sidebar) {
                Button("Edit Home") { app.goHome(); HomeEditSession.shared.editing = true }
                // View › Back and Forward (⌘[ and ⌘]) follow as AppKit items (NavMenuItems, App/NavTrail.swift).
            }
        }

        Settings {
            SettingsView().environmentObject(app).limitMotionRoot()
        }

        MenuBarExtra(isInserted: holder.menuBarBinding) {
            // Live captions sits below the panel's own rows (kept out of SettingsView.swift).
            VStack(spacing: 0) {
                MenuBarPanel()
                DictationsMenuRow().padding(.horizontal, 12).padding(.bottom, 10)
                LiveCaptionsMenuRow().padding(.horizontal, 12).padding(.bottom, 12)
            }
            .frame(width: 320).background(Refined.paper)
            .environmentObject(app).limitMotionRoot()
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

/// Stop Meeting, and Pause or Resume, while a meeting records. File › Record As › Meeting… starts one (the consent
/// sheet, then a two-track recording of the call).
struct MeetingCaptureCommands: View {
    @ObservedObject private var session = MeetingSession.shared
    var body: some View {
        // Starting one is File › Record As › Meeting…, one item for the meeting capture (it was also Record Meeting…).
        if session.isActive {
            Divider()
            Button("Stop Meeting") { MeetingCoordinator.shared.stopFromMenu() }
                .disabled(session.phase == .starting || session.phase == .stopping)
        }
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
