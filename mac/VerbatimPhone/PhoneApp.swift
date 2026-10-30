import SwiftUI
import PhotosUI

@main
struct VerbatimPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    /// PhoneState, held without observing it (as on the Mac, VerbatimApp.swift): a PhoneState publish used to
    /// re-evaluate the scene, then PhoneRoot's TabView with every tab's stack. PhoneRoot observes it and applies the
    /// color scheme itself.
    @StateObject private var holder = PhoneHolder()
    private var app: PhoneState { holder.app }
    /// The iCloud container lookup starts on a background thread before the Store loads (Cloud.prefetchContainer).
    /// First, iCloud sync gets an explicit setting: off for a new install, unchanged for everyone else.
    init() {
        Cloud.settleSyncDefault()
        Cloud.prefetchContainer()
        // The self-test's big library goes in before the Store loads, so launch is timed with it (LibraryLoading.swift).
        if PhoneUITest.enabled { BigLibrarySeed.write() }
        LaunchClock.markStart()
        // The consolidation (October 28, 2026): settings for merged or retired features move once, before What's new
        // writes anything, so a new install is never taken for an existing one (PhoneConsolidation.swift).
        PhoneConsolidation.migrateSettings()
        // What's new: a new install starts at its own build, so Home's note waits for the next update.
        ReleaseNotes.settleLastSeen(ranBefore: Onboarding.finishedBefore)
    }
    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environmentObject(app)
                .tint(Refined.accentText)   // the accent outside the tabs (DESIGN.md §13)
                .limitMotionRoot()   // Reduce Motion or Settings › Limit animation → \.limitMotion everywhere
        }
    }
}

/// The tabs in the system tab bar (Liquid Glass on iOS 26, standard before; DESIGN.md §13 and §16): Home, up to three you pick (Library and Thoughts unless you change them in Settings › Personalization
/// and preferences › Tab bar), and Settings, each with its fine-line glyph, the selected tab in the accent. Paper
/// underneath. Record sits in the tab bar's bottom accessory on every tab but Home's own screen while its Record card
/// is there, and the recording rides in it once minimized (RecordAccessory.swift); the recorder is a sheet
/// (RecorderSheet.swift).
struct PhoneRoot: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.scenePhase) private var scenePhase
    @State private var newProjectName = ""
    @State private var photoPicks: [PhotosPickerItem] = []
    @ObservedObject private var rename = RenameCenter.shared
    /// The tabs in the bar (PhoneTabBar.swift); the TabView follows a change at once.
    @ObservedObject private var tabBar = PhoneTabBarStore.shared
    /// Home's layout: Record's accessory steps aside on Home while its Record card is there.
    @ObservedObject private var layouts = HomeLayoutStore.shared

    /// Each tab's icon: its fine-line glyph as a template image, so the tab bar tints it (the accent when selected).
    private func tabIcon(_ t: PhoneState.Tab) -> Image { Image(uiImage: t.art.templateImage(size: 26, key: "tab-\(t.rawValue)")) }

    /// The tabs in the bar, left to right.
    private var tabs: some View {
        TabView(selection: $app.tab) {
            ForEach(tabBar.bar.tabs, id: \.self) { t in
                tabRoot(t)
                    .tabItem { Label { Text(t.title) } icon: { tabIcon(t) } }
                    // What's queued, transcribing, or downloading: the system badge, on Library or on Home when
                    // Library isn't in the bar (review P-12). Zero hides it.
                    .badge(t == tabBar.bar.host(for: .library) ? app.libraryBadgeCount : 0)
                    .tag(t)
            }
        }
        // Record in the tab bar's bottom accessory, and a tab bar that shrinks on scroll down (iOS 26;
        // RecordAccessory.swift). With nothing recording, off while you read a transcript and on Home's own screen
        // while its Record card is there; while a recording exists, on every screen (`RecordChromeRule`).
        .recordTabChrome(hidden: HomeSpacing.hidesRecordChrome(app, tab: app.tab, layout: layouts.layout))
        // The selected tab, and the chrome's buttons, take the accent (DESIGN.md §13). iPhone switches keep the
        // system's green (`refinedSwitchTint()`).
        .tint(Refined.accentText)
        // Until the library has loaded at launch: the paper and, after a moment, a small spinner.
        .overlay { loadingCover }
        .onAppear { LaunchClock.rootAppeared() }
    }

    /// A tab and its own navigation stack; the paths live in PhoneState. Every stack can push every screen
    /// (`phoneRoutes`), so a screen whose tab isn't in the bar opens inside Library or Home.
    @ViewBuilder private func tabRoot(_ t: PhoneState.Tab) -> some View {
        if t == .settings {
            NavigationStack { SettingsScreen() }
                .miniRecorderInset(.settings)
        } else {
            NavigationStack(path: app.pathBinding(t)) { rootScreen(t).phoneRoutes() }
                .tint(Refined.accentText)
                .miniRecorderInset(t)
        }
    }

    @ViewBuilder private func rootScreen(_ t: PhoneState.Tab) -> some View {
        switch t {
        case .home: HomeScreen()
        case .library: LibraryScreen()
        // Today's Thoughts page; its calendar button opens By day.
        case .thoughts: DayPageScreen(kind: .idea, day: app.todayPage)
        // Journal By day (Thoughts phase B).
        case .journal: ByDayScreen(kind: .journal, fixed: true)
        case .dictations: DictationsListScreen()
        case .projects: ProjectsScreen()
        case .settings: SettingsScreen()
        }
    }

    @ViewBuilder private var loadingCover: some View {
        if !app.store.isLoaded {
            LibraryLoadingView().background(Refined.paper).ignoresSafeArea()
        }
    }

    var body: some View {
        tabs
        // The recorder: one sheet with a grabber (RecorderSheet.swift). Swiping it down minimizes it; the
        // recording goes on.
        .sheet(isPresented: $app.showRecorder) {
            RecorderSheet().environmentObject(app)
        }
        // Record as's Import, from Photos, files, or a link (RecordAccessory.swift).
        .confirmationDialog("Import", isPresented: $app.showImportChoices, titleVisibility: .hidden) {
            Button("Choose from Photos") { app.showPhotoPicker = true }
            Button("Choose files…") { app.showImporter = true }
            Button("Paste a link") { app.showLinkSheet = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $app.showCaptions) {
            LiveCaptionsScreen(captions: app.captions, feed: app.captions.feed).environmentObject(app)
        }
        // The "link added" card, above the tab bar (PhoneLinkCard.swift).
        .overlay { PhoneLinkCardLayer() }
        .overlay { SessionStartLayer(session: app.session) }
        .overlay { SessionEndedLayer(session: app.session) }
        // Record as: the tray a long press on Record opens, over the tab bar too (RecordTray.swift).
        .overlay { RecordTrayLayer() }
        .onOpenURL { url in if !app.handleRecorderLink(url) { _ = app.session.handle(url) } }
        // Shared files and links, and Transcribe what's playing, come in each time Verbatim is opened (PhoneInbox.swift).
        // Recipes owed a scheduled run since iOS last gave Verbose time run when it opens (AskEngine.swift).
        // The Action button's control is named for the choice in Settings › Action button (ActionButtonScreen.swift).
        .onChange(of: scenePhase) { _, phase in if phase == .active { app.importInbox(); app.importWatchInbox(); AskRecipeCenter.shared.runDue(); ActionChoiceMirror.sync() } }
        .alert("Before you record others", isPresented: $app.showConsentNotice) {
            Button("Not now", role: .cancel) { app.dismissConsentNotice() }
            Button("Record") { app.acknowledgeConsentNotice() }
        } message: {
            Text("Many places require everyone's consent to record a conversation. Let people know before you record them.")
        }
        // Live captions or the keyboard while a recording runs behind the bar.
        .alert("Finish your recording first", isPresented: Binding(get: { app.finishRecordingFirst != nil }, set: { if !$0 { app.finishRecordingFirst = nil } })) {
            Button("Not now", role: .cancel) {}
            Button("Open recording") {
                // After the alert has gone, so the recorder's cover can present.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { app.openRecorder() }
            }
        } message: {
            Text("Stop or discard your recording to use \(app.finishRecordingFirst ?? "this"). It keeps recording until you do.")
        }
        // A recording in a language the English-only model can't hear, with Parakeet v3 not downloaded yet.
        .alert(app.v3Offer?.title ?? "", isPresented: Binding(get: { app.v3Offer != nil }, set: { if !$0 { app.v3Offer = nil } })) {
            Button("Not now", role: .cancel) { app.v3Offer = nil }
            Button("Download") { app.acceptV3Offer() }
        } message: {
            Text(app.v3Offer?.message ?? "")
        }
        .alert("Microphone access is off", isPresented: $app.showMicDenied) {
            Button("Not now", role: .cancel) {}
            Button("Open Settings") { app.openAppSettings() }
        } message: {
            Text("To record, turn on Microphone for Verbose in Settings.")
        }
        .alert("New project", isPresented: Binding(get: { app.newProjectFor != nil }, set: { if !$0 { app.newProjectFor = nil } })) {
            TextField("Name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") {
                let n = newProjectName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty, let id = app.newProjectFor { app.addToProject([id], app.store.addProject(n).id) }
                newProjectName = ""
            }
        } message: { Text("The transcript moves into it.") }
        .alert("Rename transcript", isPresented: Binding(get: { rename.target != nil }, set: { if !$0 { rename.target = nil } })) {
            TextField("Title", text: $rename.draft)
            Button("Cancel", role: .cancel) { rename.target = nil }
            Button("Rename") { rename.commit(app.store); app.say("Renamed") }
        }
        .fullScreenCover(isPresented: $app.showOnboarding) {
            PhoneOnboarding(startStep: PhoneUITest.onboardingStep).environmentObject(app)
                .tint(Refined.accentText)
        }
        .sheet(isPresented: $app.showLinkSheet) { LinkSheet() }
        .sheet(isPresented: $app.showRecordAsEditor) { PhoneRecordAsEditor() }
        .sheet(isPresented: $app.showPlayingSheet) { WhatsPlayingSheet().environmentObject(app) }
        .sheet(item: $app.exportRequest) { r in PhoneExportSheet(ids: r.ids).environmentObject(app) }
        // A pasted link that turned out to be a whole show or feed: pick the episode.
        .sheet(item: $app.episodeChoice) { choice in
            NavigationStack {
                EpisodePicker(link: choice.link, show: choice.show,
                              onPick: { ep in app.episodeChoice = nil; app.addLink(ep.link) },
                              onNotAShow: { app.episodeChoice = nil })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { app.episodeChoice = nil } } }
            }
            .presentationDetents([.large])
        }
        .fileImporter(isPresented: $app.showImporter, allowedContentTypes: MediaImport.pickerTypes, allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { app.importPicked(urls) }
        }
        .photosPicker(isPresented: $app.showPhotoPicker, selection: $photoPicks, maxSelectionCount: 5,
                      matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoPicks) { _, picks in
            guard !picks.isEmpty else { return }
            app.importPhotos(picks)
            photoPicks = []
        }
        .overlay(alignment: .top) {
            if let t = app.toast {
                Text(t).refinedFont(.hint, weight: .medium).foregroundStyle(Refined.paper)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Refined.ink, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.settle, value: app.toast)
        // Settings › Appearance: read here rather than in the App struct, which doesn't observe PhoneState.
        .preferredColorScheme(app.colorScheme)
    }
}

/// Owns PhoneState for the `App` struct without forwarding its changes (it publishes nothing), so the scene is built
/// once instead of on every publish. The Mac does the same with `AppHolder`.
@MainActor
final class PhoneHolder: ObservableObject {
    let app: PhoneState
    init() { app = PhoneState() }
}

/// The Library's search and filter, kept when its screen is built again (its tab leaves the bar or comes back). In
/// memory only; nothing new is stored.
enum LibraryKeep {
    static var librarySearch = ""
    static var libraryFilter: LibraryScreen.Filter = .all
}

/// "Session ended" after a call or another app's audio ended the session, with Restart session. Under the start
/// screen, so a restart shows that instead.
private struct SessionEndedLayer: View {
    @ObservedObject var session: KeyboardSession
    var body: some View {
        if let notice = session.endedNotice, !session.showScreen {
            SessionEndedScreen(session: session, notice: notice)
                .transition(.opacity)
                .zIndex(9)
        }
    }
}

/// The keyboard session's start screen. A plain overlay rather than a second full-screen cover, so it shows even
/// when another sheet is up.
private struct SessionStartLayer: View {
    @ObservedObject var session: KeyboardSession
    var body: some View {
        if session.showScreen {
            SessionStartScreen(session: session)
                .transition(.opacity)
                .zIndex(10)
        }
    }
}

/// Background link downloads (LinkDownloads.swift): iOS wakes Verbatim when they finish while it's closed.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LinkDownloads.shared.activate()
        // Ask's recipes on their schedule: iOS's background refresh, registered before launch finishes.
        AskBackgroundRefresh.register()
        // Apple Watch recordings (PhoneWatch.swift): activated before launch finishes, so iOS can hand over a file from
        // the watch while Verbose runs in the background.
        PhoneWatchLink.shared.activate()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == LinkDownloads.identifier else { completionHandler(); return }
        LinkDownloads.backgroundCompletion = completionHandler
        LinkDownloads.shared.activate()
    }
}

extension Cloud {
    /// iCloud sync is off on a new iPhone install until you turn it on (onboarding's last step, or Settings › Sync
    /// and data). It was on unless turned off, so an install that already ran keeps what it had: anyone who never
    /// touched the switch had sync on, and still does. Runs first thing at launch, before `Cloud.root` is read.
    ///
    /// An install already ran when any of these exist: the onboarding was finished, the iCloud container was looked
    /// up (cached path), the library was moved into iCloud (`cloud.migrated`), or Verbose's local folder.
    static func settleSyncDefault() {
        let d = UserDefaults.standard
        guard d.object(forKey: syncKey) == nil else { return }
        let ranBefore = d.integer(forKey: "onboarding.seenVersion") > 0
            || d.string(forKey: "cloud.containerPath") != nil
            || d.object(forKey: "cloud.migrated") != nil
            || FileManager.default.fileExists(atPath: Paths.local.path)
        d.set(ranBefore, forKey: syncKey)
        Log.note("iCloud sync: no setting yet; " + (ranBefore ? "an earlier install, so it stays on" : "a new install, so it starts off"))
    }
}
