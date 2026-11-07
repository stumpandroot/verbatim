import SwiftUI
import Combine

@main
struct VerbatimApp: App {
    /// AppState, held without observing it: an AppState publish (each navigation, each Store, Recorder, Player, or
    /// transcription tick) used to re-evaluate every scene and the main menu's commands before any window. The
    /// holder publishes only the menu bar switch (`AppHolder`). The scenes read nothing AppState tracks.
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
                .appState(app)
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
                // From ⌘N or ⌘O, Home shows at once; from a click on the menu, it slides in (DESIGN.md §7).
                Button("New Transcript") { app.fromKeyboard(AppState.handlingKeyPress) { app.openImport() } }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import…") { app.fromKeyboard(AppState.handlingKeyPress) { app.openImport() } }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Import Multi-track Recording…") { app.chooseMultitrack() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Record Voice Note") { app.requestRecord() }
                    .keyboardShortcut("r", modifiers: [.option, .shift])
                // The six ways to record, as on Record's right-click menu (CaptureBar.swift): a picked kind is yours, so
                // AutoLabel leaves it and Run automatically uses it (Templates.swift). Meeting… is the meeting capture,
                // which files its transcript as a Meeting; Stop Meeting and Pause Meeting show below while one runs.
                Menu("Record As") { RecordKindMenuItems(titles: \.commandTitle).appState(app) }
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
                // ⌘F finds in the open transcript and opens Search or ask elsewhere; ⌘G and ⇧⌘G step; ⌘K opens Search or
                // ask on every screen (App/AppCommands.swift).
                FindMenuItems(app: app)
            }
            // Recording and Dictation: the main actions with their shortcuts, on every screen (App/AppCommands.swift).
            CommandMenu("Recording") {
                RecordingMenuItems(app: app, recorder: app.recorder, capture: app.capture, thoughts: ThoughtCapture.shared)
            }
            CommandMenu("Dictation") {
                DictationMenuItems(app: app, thoughts: ThoughtCapture.shared)
            }
            // View › Edit Home: outlines Home's sections and opens Edit Home's inspector (Views/EditHome.swift).
            CommandGroup(after: .sidebar) {
                Button("Edit Home") { app.goHome(); HomeEditSession.shared.editing = true }
                // View › Back and Forward (⌘[ and ⌘]) follow as AppKit items (NavMenuItems, App/NavTrail.swift), then
                // Bigger Text, Smaller Text, and Mark This Moment (TranscriptMenuItems, App/AppCommands.swift).
            }
        }

        Settings {
            SettingsView().appState(app).limitMotionRoot()
        }

        MenuBarExtra(isInserted: holder.menuBarBinding) {
            // Live captions sits below the panel's own rows (kept out of SettingsView.swift).
            VStack(spacing: 0) {
                MenuBarPanel()
                DictationsMenuRow().padding(.horizontal, 12).padding(.bottom, 10)
                LiveCaptionsMenuRow().padding(.horizontal, 12).padding(.bottom, 12)
            }
            .frame(width: 320).background(Refined.paper)
            .appState(app).limitMotionRoot()
        } label: {
            MenuBarMark(recorder: holder.app.recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item's image: the bars mark as a template image, so the menu bar tints it (DESIGN.md §3, §4). While
/// a recording's mic is muted or silent, the attention mark instead, so it shows from any app (DESIGN.md §6.10, A muted microphone). Only
/// this view watches the recorder, so the scenes aren't rebuilt.
struct MenuBarMark: View {
    @ObservedObject var recorder: Recorder
    /// Waiting for your call: the bars with a dot (CallViews.swift).
    @ObservedObject private var calls = MeetingCoordinator.shared

    var body: some View {
        let warn = recorder.isRecording && recorder.micWarning != nil
        let armed = calls.wait != nil
        Image(nsImage: warn ? BrandArt.iconAttention.templateImage(size: 16, key: "menubar-mic-warning")
                            : armed ? CallMenuBarMark.armed() : BrandArt.markBars.templateImage(size: 16, key: "menubar"))
            .accessibilityLabel(warn ? "Verbose, your mic seems to be muted" : armed ? "Verbose, waiting for your call" : "Verbose")
    }
}

/// Owns the app's AppState for the `App` struct without observing it, so the scenes and commands are built once
/// instead of on every change. Commands only call into AppState; anything a menu shows live observes its own object
/// (`MeetingCaptureCommands`, `CheckForUpdatesButton`). The one value a scene reads, Settings › General › Show in menu
/// bar, is mirrored in `showMenuBar` and announced only when it changes.
@MainActor
final class AppHolder: ObservableObject {
    let app: AppState
    @Published private(set) var showMenuBar: Bool

    init() {
        let state = AppState()
        app = state
        showMenuBar = state.showMenuBar
        watchMenuBar()
    }

    /// Follows Show in menu bar alone. Observation announces a change before it's stored, so the value is read on the
    /// next turn of the main queue, and watched again from there (each watch fires once).
    private func watchMenuBar() {
        withObservationTracking { _ = app.showMenuBar } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncMenuBar(); self?.watchMenuBar() } }
        }
    }

    private func syncMenuBar() {
        if showMenuBar != app.showMenuBar { showMenuBar = app.showMenuBar }
    }

    /// The menu bar item's binding. MenuBarExtra writes it back on every update (Changed.swift); AppState's
    /// `@Distinct` and `syncMenuBar` both ignore a write of the same value, so a write-back announces nothing.
    var menuBarBinding: Binding<Bool> {
        Binding(get: { [unowned self] in self.showMenuBar },
                set: { [unowned self] v in
                    self.app.showMenuBar = v
                    self.syncMenuBar()
                })
    }
}

extension View {
    /// AppState for the views below (`@Environment(AppState.self)`), with the recorder, the player, the app capture,
    /// dictation, and the transcription queue beside it. AppState is @Observable and doesn't pass their changes on, so
    /// a view that shows one of them watches it itself (`@EnvironmentObject private var recorder: Recorder`).
    func appState(_ app: AppState) -> some View {
        environment(app)
            .environmentObject(app.recorder)
            .environmentObject(app.player)
            .environmentObject(app.capture)
            .environmentObject(app.dictation)
            .environmentObject(app.coordinator)
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
