import SwiftUI
import PhotosUI

@main
struct VerbatimPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @StateObject private var app = PhoneState()
    /// The iCloud container lookup starts on a background thread before the Store loads (Cloud.prefetchContainer).
    /// First, iCloud sync gets an explicit setting: off for a new install, unchanged for everyone else.
    init() {
        Cloud.settleSyncDefault()
        Cloud.prefetchContainer()
    }
    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environmentObject(app)
                .preferredColorScheme(app.colorScheme)
                .tint(Ink.ink)
                .limitMotionRoot()   // Reduce Motion or Settings › Limit animation → \.limitMotion everywhere
        }
    }
}

/// Four tabs in the system tab bar (Liquid Glass on iOS 26). Paper underneath. The recorder covers the screen
/// until you minimize it; then a bar above the tab bar carries the recording on every tab (MiniRecorder.swift).
struct PhoneRoot: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.scenePhase) private var scenePhase
    @State private var newProjectName = ""
    @State private var photoPicks: [PhotosPickerItem] = []
    @ObservedObject private var rename = RenameCenter.shared
    /// The full-screen recorder zooms out of the bar and back into it.
    @Namespace private var recorderZoom

    var body: some View {
        TabView(selection: $app.tab) {
            NavigationStack(path: $app.homePath) {
                HomeScreen()
                    .navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
                    .navigationDestination(for: DocumentRoute.self) { TranscriptScreen(id: $0.id, startMode: .document) }
            }
            .miniRecorderInset(.home, zoom: recorderZoom)
            .tabItem { Label { Text("Home") } icon: { Image(uiImage: BrandArt.iconHome.templateImage(size: 26, key: "iconHome")) } }.tag(PhoneState.Tab.home)

            NavigationStack(path: $app.libraryPath) {
                LibraryScreen().navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
            }
            .miniRecorderInset(.library, zoom: recorderZoom)
            .tabItem { Label { Text("Library") } icon: { Image(uiImage: BrandArt.iconLibrary.templateImage(size: 26, key: "iconLibrary")) } }.tag(PhoneState.Tab.library)

            NavigationStack(path: $app.momentsPath) {
                MomentsScreen().navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
            }
            .miniRecorderInset(.moments, zoom: recorderZoom)
            .tabItem { Label { Text("Moments") } icon: { Image(uiImage: BrandArt.iconMoments.templateImage(size: 26, key: "iconMoments")) } }.tag(PhoneState.Tab.moments)

            NavigationStack { SettingsScreen() }
                .miniRecorderInset(.settings, zoom: recorderZoom)
                .tabItem { Label { Text("Settings") } icon: { Image(uiImage: BrandArt.iconSettings.templateImage(size: 26, key: "iconSettings")) } }.tag(PhoneState.Tab.settings)
        }
        .fullScreenCover(isPresented: $app.showRecorder) { RecordScreen(zoom: recorderZoom) }
        .fullScreenCover(isPresented: $app.showCaptions) {
            LiveCaptionsScreen(captions: app.captions, feed: app.captions.feed).environmentObject(app)
        }
        // The "link added" card and the Library tab's count badge, above the tab bar (PhoneLinkCard.swift).
        .overlay { PhoneLinkCardLayer() }
        .overlay { SessionStartLayer(session: app.session) }
        .overlay { SessionEndedLayer(session: app.session) }
        .onOpenURL { url in if !app.handleRecorderLink(url) { _ = app.session.handle(url) } }
        // Shared files and links, and Transcribe what's playing, come in each time Verbatim is opened (PhoneInbox.swift).
        .onChange(of: scenePhase) { _, phase in if phase == .active { app.importInbox() } }
        .alert("Before you record others", isPresented: $app.showConsentNotice) {
            Button("Not Now", role: .cancel) { app.dismissConsentNotice() }
            Button("Record") { app.acknowledgeConsentNotice() }
        } message: {
            Text("Many places require everyone's consent to record a conversation. Let people know before you record them.")
        }
        // Live captions or the keyboard while a recording runs behind the bar.
        .alert("Finish your recording first", isPresented: Binding(get: { app.finishRecordingFirst != nil }, set: { if !$0 { app.finishRecordingFirst = nil } })) {
            Button("Not Now", role: .cancel) {}
            Button("Open Recording") {
                // After the alert has gone, so the recorder's cover can present.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { app.openRecorder() }
            }
        } message: {
            Text("Stop or discard your recording to use \(app.finishRecordingFirst ?? "this"). It keeps recording until you do.")
        }
        // A recording in a language the English-only model can't hear, with Parakeet v3 not downloaded yet.
        .alert(app.v3Offer?.title ?? "", isPresented: Binding(get: { app.v3Offer != nil }, set: { if !$0 { app.v3Offer = nil } })) {
            Button("Not Now", role: .cancel) { app.v3Offer = nil }
            Button("Download") { app.acceptV3Offer() }
        } message: {
            Text(app.v3Offer?.message ?? "")
        }
        .alert("Microphone access is off", isPresented: $app.showMicDenied) {
            Button("Not Now", role: .cancel) {}
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
        .fullScreenCover(isPresented: $app.showOnboarding) { PhoneOnboarding(startStep: PhoneUITest.onboardingStep).environmentObject(app) }
        .sheet(isPresented: $app.showLinkSheet) { LinkSheet() }
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
                Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.readerFixed)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Ink.inkFixed, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.settle, value: app.toast)
    }
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
