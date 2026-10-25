import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers
import os

enum Screen: Equatable {
    case home
    case library
    case links
    case queue
    case trash
    case moments
    case transcript(UUID)
    case dictionary
    case dictations
    case activity
}

/// Which way the next screen slides in. Sidebar order decides up/down; opening a transcript pushes.
enum SlideDirection: Equatable { case push, pop, up, down }

/// The Mac app's state. Recording and app audio live in AppState+Capture, files and links in AppState+Import,
/// organizing, editing, and Keep in AppState+Library, and the transcription queue in AppState+Pipeline.
@MainActor
final class AppState: ObservableObject {
    /// Where we are, how we got here, and how many times we've moved: one value, one publish per navigation.
    /// On macOS 26 a view flushed by `withAnimation` with half-updated state keeps showing the old screen
    /// (the publish that follows is dropped), so navigation never changes two properties in a row.
    struct Nav: Equatable { var screen: Screen; var direction: SlideDirection; var count: Int }
    @Changed var nav = Nav(screen: .home, direction: .up, count: 0)
    var screen: Screen { nav.screen }
    var direction: SlideDirection { nav.direction }
    var navCount: Int { nav.count }
    var navStartedAt = Date()
    /// The open "Navigate" signpost (Perf), from `go` to the new screen's root `onAppear`. Not published.
    private var navInterval: OSSignpostIntervalState?
    @Changed var search = ""
    @Changed var projectFilter: UUID? = nil
    /// Library › kind chips: nil is All.
    @Changed var libraryKind: RecordingKind? = nil
    /// Library › type and platform chips, remembered on this Mac ("videos|YouTube"). See LibraryFilter.
    @Changed(LibraryFilter.libraryKey) var libraryFilterRaw = "all"
    var libraryFilter: LibraryFilter {
        get { LibraryFilter(raw: libraryFilterRaw) }
        set { libraryFilterRaw = newValue.raw }
    }
    /// The Add from Library sheet, open for this project.
    @Changed var addFromLibrary: UUID? = nil
    /// "New project…" from a row's Add to project menu: these transcripts join the project once it's named.
    @Changed var newProjectFor: [UUID]? = nil
    @Changed var focusLink = false
    @Changed var showMicSheet = false
    @Changed var showAppPicker = false
    /// The export sheet, for one transcript or a Library selection (ExportSheet).
    @Changed var exportRequest: ExportRequest? = nil
    @Changed var toast: Toast? = nil

    // Preferences, persisted in UserDefaults by key. Never @AppStorage or @Published here: see Changed.swift.
    @Changed("showMenuBar") var showMenuBar = true
    @Changed("preset") var presetRaw = QualityPreset.defaultPreset.rawValue
    @Changed("advEngine") var advEngine = "fluid"
    @Changed("advModel") var advModel = "v2"
    @Changed("identifySpeakers") var identifySpeakers = true
    @Changed("applyDictionary") var applyDictionary = true
    /// Settings › General › Show This week on Home: whether This week is among Home's shown sections in the current
    /// look (Edit Home's layout, HomeLayout.swift, which read the old `home.showWeek` value once).
    var showHomeWeek: Bool {
        get { HomeLayoutStore.shared.layout(AppLook.current.homeLook).isVisible(.week) }
        set {
            guard newValue != showHomeWeek else { return }
            objectWillChange.send()
            HomeLayoutStore.shared.update(AppLook.current.homeLook) { $0.setVisible(.week, newValue, inPlace: true) }
        }
    }
    @Changed("projectVocab") var projectScopedVocabulary = false
    @Changed("captureMode") var captureMode = "voice"
    /// "system" | "light" | "dark"
    @Changed("appearance") var appearance = "system"      // "voice" | "dictate"
    @Changed("sounds") var sounds = true { didSet { Sounds.enabled = sounds } }
    /// Keep: also save the video (MP4) of every link you transcribe.
    @Changed("keepVideoByDefault") var keepVideoByDefault = false
    /// Keep jobs in flight, by transcript, with a short status ("Keeping video 42%").
    @Changed var keeping: [UUID: String] = [:]

    let store = Store()
    let recorder = Recorder()
    /// Show words while you record: live words from the recorder's own buffers, a preview only (RecordingWords.swift).
    let recordingWords = RecordingWords()
    let player = Player()
    let capture = AppAudioCapture()
    let dictation = DictationController()
    /// The transcription queue, shared with the iPhone. Lazy so it can be handed the Store.
    private(set) lazy var coordinator = TranscriptionCoordinator(store: store, config: .mac)

    /// Transcripts waiting to run, oldest first. One runs at a time.
    var queue: [UUID] { coordinator.queue }
    var runningID: UUID? { coordinator.runningID }
    /// Continue recording: the transcript the current recording will be added to.
    @Changed var continuing: UUID? = nil
    /// Stop was pressed and the recording is being saved (segments joined off the main thread): Home says "Saving…".
    @Changed var savingRecording = false
    /// The welcome tour sheet.
    @Changed var showOnboarding = false
    /// Import › Multi-track recording: the sheet's tracks while it's open (AppState+Multitrack).
    @Changed var multitrackDraft: MultitrackDraft? = nil
    /// Multi-track recordings being prepared (working copies, line-up, mix) before they join the queue.
    var multitrackTasks: [UUID: Task<Void, Never>] = [:]
    /// The transcript the next recording start will add to (set by Continue, cleared by any other Record).
    var pendingContinue: UUID? = nil
    /// A passage to scroll to and select when the next transcript opens (from search, a note, a link).
    var focusSegment: UUID? = nil
    /// iPhone links this Mac is fetching right now.
    var claiming: Set<UUID> = []
    /// A private or signed-in video waiting for you to choose a browser's sign-in (Views/SignInSheet.swift).
    @Changed var signInRequest: LinkSignInRequest? = nil

    // The "link added" card (AppState+LinkCard).
    /// Links this Mac is fetching, by transcript; the card observes one of them.
    var linkImports: [UUID: LinkImport] = [:]
    var linkTasks: [UUID: Task<Void, Never>] = [:]
    /// The link whose card is showing.
    @Changed var linkCardID: UUID? = nil
    /// Links already counted by the queue but not yet shown in its badge: their card hasn't landed.
    @Changed var linkBadgeHeld: Set<UUID> = []
    /// Goes up each time a card lands in Queue, so the badge pops.
    @Changed var queueBadgePops = 0
    /// ⌘V on Home, Library, and Links (AppState+LinkCard).
    var linkPasteMonitor: Any?
    weak var mainWindow: NSWindow?

    private var bag = Set<AnyCancellable>()

    init() {
        Sounds.enabled = sounds
        // Settings › Privacy: the network activity log, before anything can use the network.
        NetworkActivityLog.install()
        Log.note("AppState init; transcripts=\(store.transcripts.count)")
        for o in [store.objectWillChange.eraseToAnyPublisher(), recorder.objectWillChange.eraseToAnyPublisher(),
                  player.objectWillChange.eraseToAnyPublisher(), capture.objectWillChange.eraseToAnyPublisher(),
                  dictation.objectWillChange.eraseToAnyPublisher(), coordinator.objectWillChange.eraseToAnyPublisher()] {
            o.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        coordinator.host = self
        recorder.onAutoPaused = { [weak self] reason in self?.toast = Toast(reason) }
        recorder.onInputSwitched = { [weak self] note in self?.toast = Toast(note) }
        AudioDucker.shared.follow(.voiceNote, recorder.$isRecording.combineLatest(recorder.$isPaused, recorder.$isStarting).map { $0.0 && !$0.1 && !$0.2 })
        HangWatch.start()
        dictation.attach(self)
        mirrorSnippets()
        FolderWatcher.shared.attach(self)
        // Which kept and imported files are still there, checked off the main thread for rows and menus.
        KeptMedia.shared.attach(store)
        applyAppearance()
        // What's new: a new install starts at its own build, so Home's note waits for the next update.
        ReleaseNotes.settleLastSeen(ranBefore: Onboarding.finishedBefore)
        if Onboarding.shouldShow { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showOnboarding = true } }
        // Anything still queued or mid-transcription when Verbatim last quit picks up where it left off.
        // Only jobs this Mac started: the iPhone's jobs show as "Transcribing on iPhone" and stay its own.
        coordinator.resume(includeUnowned: true)
        // Recordings recovered once launch recovery finishes in the background: transcribe them too.
        store.onRecovered = { [weak self] ids, announce in self?.queueRecovered(ids, announce: announce) }
        // A meeting capture (App/MeetingSession.swift) a crash left behind comes back as one two-track transcript.
        if !UITest.enabled { DispatchQueue.main.async { MeetingSession.recoverLeftovers(app: self) } }
        // Notices calls and asks to record them; never records on its own (App/MeetingCoordinator.swift).
        DispatchQueue.main.async { MeetingCoordinator.shared.attach(self) }
        QuitGuard.app = self
        // Services, Spotlight, and Shortcuts (App/SystemHooks.swift).
        SystemHooks.attach(self)
        // Links added on the iPhone wait for a Mac: claim them now and whenever more arrive.
        store.onRemoteChange = { [weak self] t in self?.claimIfPendingLink(t) }
        DispatchQueue.main.async { for t in self.store.live where t.pendingLink { self.claimIfPendingLink(t) } }
        if !UITest.enabled { DispatchQueue.main.async { self.resumeLinkFetches() } }
        if !queue.isEmpty { Log.note("resuming queue: \(queue.count)"); DispatchQueue.main.async { self.pump() } }
        // Imports the app quit in the middle of start again (their placeholders are still "Importing").
        let resumable = store.takeResumableImports()
        if !resumable.isEmpty { DispatchQueue.main.async { self.runImports(resumable) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.backfillFrames() }
    }

    /// Snippets sync through the Store (snippets.json, like the Dictionary), so the iPhone has them too. Settings
    /// and dictation keep using `FlowSettings.snippets`; the two mirror each other. The first launch with this
    /// merges the snippets saved on this Mac into the synced list once.
    private func mirrorSnippets() {
        let flow = FlowSettings.shared
        let migratedKey = "flow.snippetsSynced"
        if !store.snippetsReadable {
            // The synced file is there but can't be read yet (not downloaded, or damaged): this Mac's own snippets
            // stay as they are and are used meanwhile; the Store merges them with the file once it reads.
            store.seedSnippetsWhileUnreadable(flow.snippets)
        } else if !UserDefaults.standard.bool(forKey: migratedKey) {
            var all = store.snippets
            for s in flow.snippets where !all.contains(where: { $0.id == s.id }) { all.append(s) }
            if all != store.snippets { store.snippets = all }
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
        if flow.snippets != store.snippets { flow.snippets = store.snippets }
        flow.$snippets.dropFirst().removeDuplicates().sink { [weak self] v in
            MainActor.assumeIsolated {
                guard let self, self.store.snippets != v else { return }
                self.store.snippets = v
            }
        }.store(in: &bag)
        store.$snippets.dropFirst().removeDuplicates().sink { v in
            MainActor.assumeIsolated {
                if FlowSettings.shared.snippets != v { FlowSettings.shared.snippets = v }
            }
        }.store(in: &bag)
    }

    var preset: QualityPreset { QualityPreset(rawValue: presetRaw) ?? .defaultPreset }

    var engineChoice: (engine: String, model: String) {
        preset == .advanced ? (advEngine, advModel) : (preset.config.0, preset.config.1)
    }

    // MARK: Navigation

    private static let order: [String: Int] = ["home": 0, "library": 1, "links": 2, "moments": 3, "queue": 4, "dictations": 5, "activity": 6, "dictionary": 7, "trash": 8]

    func go(_ next: Screen) {
        guard next != screen else { return }
        let direction: SlideDirection
        switch (screen, next) {
        case (_, .transcript): direction = .push
        case (.transcript, _): direction = .pop
        default:
            let a = rank(screen), b = rank(next)
            direction = b > a ? .up : .down
        }
        if UITest.enabled { Log.note("UITEST go \(key(next)) nav=\(nav.count + 1)") }
        // No withAnimation here: the container animates on `navCount`, so a publish made just before this
        // (a project filter, a search) can't trigger a flush that strands the screen change.
        navStartedAt = Date()
        if let open = navInterval { Perf.signposter.endInterval("Navigate", open) }
        navInterval = Perf.signposter.beginInterval("Navigate", "\(self.key(next), privacy: .public)")
        nav = Nav(screen: next, direction: direction, count: nav.count + 1)
    }

    func goHome() { go(.home) }

    /// Ends the "Navigate" signpost; ContentView calls it from the new screen's root `onAppear`.
    func screenAppeared() {
        guard let open = navInterval else { return }
        navInterval = nil
        Perf.signposter.endInterval("Navigate", open)
    }

    /// Where a screen sits in your sidebar order (SidebarLayout), so screens slide the way the sidebar reads.
    private func rank(_ s: Screen) -> Int {
        let k = key(s)
        if let id = SidebarItemID(rawValue: k == "activity" ? "you" : k) { return SidebarLayout.shared.index(id) }
        return Self.order[k] ?? 0
    }

    private func key(_ s: Screen) -> String {
        switch s { case .home: return "home"; case .library: return "library"; case .queue: return "queue"; case .links: return "links"; case .trash: return "trash"; case .moments: return "moments"; case .dictionary: return "dictionary"; case .dictations: return "dictations"; case .activity: return "activity"; case .transcript: return "transcript" }
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    // MARK: Search

    var filtered: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.live.filter { t in
            (projectFilter == nil || t.projectId == projectFilter) &&
            (q.isEmpty || t.title.lowercased().contains(q) || store.searchText(t).contains(q))
        }
    }

    /// The Library and Home's Recent: `filtered` without dictations, which live in Dictations. While searching,
    /// dictations are included (each row says "Dictation"), so nothing becomes unfindable.
    var archive: [Transcript] {
        let all = filtered
        return search.trimmingCharacters(in: .whitespaces).isEmpty ? all.filter { !$0.isDictation } : all
    }
}
