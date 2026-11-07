import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers
import os

enum Screen: Equatable {
    case home
    case library
    /// Shown in the sidebar only while something is queued or transcribing (`queueShowsInSidebar`).
    case queue
    case trash
    case transcript(UUID)
    case dictionary
    case dictations
    case activity
    /// Library › By day: Thoughts (`.idea`) or Journal, a month calendar and one page a day (Views/ByDayView.swift).
    case byDay(RecordingKind)
    /// Make › Templates: the template library and Run automatically (Views/TemplatesView.swift).
    case templates
    /// Make › Ask: questions about your library and recipes (Views/AskViews.swift).
    case ask
}

/// Which way the next screen slides in. Sidebar order decides up/down; opening a transcript pushes.
enum SlideDirection: Equatable { case push, pop, up, down }

/// The Mac app's state. Recording and app audio live in AppState+Capture, files and links in AppState+Import,
/// organizing, editing, and Keep in AppState+Library, and the transcription queue in AppState+Pipeline.
@MainActor @Observable
final class AppState: DistinctTracking {
    /// Where we are, how we got here, and how many times we've moved: one value, one publish per navigation.
    /// On macOS 26 a view flushed by `withAnimation` with half-updated state keeps showing the old screen
    /// (the publish that follows is dropped), so navigation never changes two properties in a row.
    /// `keyboard`: the navigation came from a key (⌘[ and ⌘], Return or Space on a selected row, Return in Search,
    /// ⌘N and ⌘O), so the new screen shows at once instead of sliding in (DESIGN.md §7, `NavEntrance`).
    struct Nav: Equatable { var screen: Screen; var direction: SlideDirection; var count: Int; var keyboard = false }
    @ObservationIgnored @Distinct var nav = Nav(screen: .home, direction: .up, count: 0)
    var screen: Screen { nav.screen }
    var direction: SlideDirection { nav.direction }
    var navCount: Int { nav.count }
    /// Set by a keyboard path for the navigations it makes (`fromKeyboard`); `go` copies it into `nav`. Not published.
    @ObservationIgnored private(set) var navFromKeyboard = false
    @ObservationIgnored var navStartedAt = Date()
    /// The open "Navigate" signpost (Perf), from `go` to the new screen's root `onAppear`. Not published.
    @ObservationIgnored private var navInterval: OSSignpostIntervalState?
    @ObservationIgnored @Distinct var search = ""
    @ObservationIgnored @Distinct var projectFilter: UUID? = nil
    /// Library › kind chips: nil is All.
    @ObservationIgnored @Distinct var libraryKind: RecordingKind? = nil
    /// Library › type and platform chips, remembered on this Mac ("videos|YouTube"). See LibraryFilter.
    @ObservationIgnored @Distinct(LibraryFilter.libraryKey) var libraryFilterRaw = "all"
    var libraryFilter: LibraryFilter {
        get { LibraryFilter(raw: libraryFilterRaw) }
        set { libraryFilterRaw = newValue.raw }
    }
    /// The Add from Library sheet, open for this project.
    @ObservationIgnored @Distinct var addFromLibrary: UUID? = nil
    /// "New project…" from a row's Add to project menu: these transcripts join the project once it's named.
    @ObservationIgnored @Distinct var newProjectFor: [UUID]? = nil
    @ObservationIgnored @Distinct var focusLink = false
    @ObservationIgnored @Distinct var showMicSheet = false
    @ObservationIgnored @Distinct var showAppPicker = false
    /// The export sheet, for one transcript or a Library selection (ExportSheet).
    @ObservationIgnored @Distinct var exportRequest: ExportRequest? = nil
    @ObservationIgnored @Distinct var toast: Toast? = nil

    // Preferences, persisted in UserDefaults by key. Never @AppStorage or a plain tracked property here: see Changed.swift.
    @ObservationIgnored @Distinct("showMenuBar") var showMenuBar = true
    @ObservationIgnored @Distinct("preset") var presetRaw = QualityPreset.defaultPreset.rawValue
    @ObservationIgnored @Distinct("advEngine") var advEngine = "fluid"
    @ObservationIgnored @Distinct("advModel") var advModel = "v2"
    @ObservationIgnored @Distinct("identifySpeakers") var identifySpeakers = true
    @ObservationIgnored @Distinct("applyDictionary") var applyDictionary = true
    /// Settings › General › Show This week on Home: whether This week is among Home's shown sections (Edit Home's
    /// layout, HomeLayout.swift, which read the old `home.showWeek` value once).
    var showHomeWeek: Bool {
        get {
            access(keyPath: \.showHomeWeek)
            return HomeLayoutStore.shared.layout.isVisible(.week)
        }
        set {
            guard newValue != showHomeWeek else { return }
            withMutation(keyPath: \.showHomeWeek) {
                HomeLayoutStore.shared.update { $0.setVisible(.week, newValue, inPlace: true) }
            }
        }
    }
    @ObservationIgnored @Distinct("projectVocab") var projectScopedVocabulary = false
    @ObservationIgnored @Distinct("captureMode") var captureMode = "voice"
    /// "system" | "light" | "dark"
    @ObservationIgnored @Distinct("appearance") var appearance = "system"      // "voice" | "dictate"
    @ObservationIgnored @Distinct("sounds") var sounds = true { didSet { Sounds.enabled = sounds } }
    /// Keep: also save the video (MP4) of every link you transcribe.
    @ObservationIgnored @Distinct("keepVideoByDefault") var keepVideoByDefault = false
    /// Keep jobs in flight, by transcript, with a short status ("Keeping video 42%").
    @ObservationIgnored @Distinct var keeping: [UUID: String] = [:]

    let store = Store()
    let recorder = Recorder()
    /// Show words while you record: live words from the recorder's own buffers, a preview only (RecordingWords.swift).
    let recordingWords = RecordingWords()
    let player = Player()
    let capture = AppAudioCapture()
    let dictation = DictationController()
    /// The transcription queue, shared with the iPhone. Lazy so it can be handed the Store.
    @ObservationIgnored private(set) lazy var coordinator = TranscriptionCoordinator(store: store, config: .mac)

    /// Transcripts waiting to run, oldest first. One runs at a time.
    var queue: [UUID] { coordinator.queue }
    var runningID: UUID? { coordinator.runningID }
    /// Continue recording: the transcript the current recording will be added to.
    @ObservationIgnored @Distinct var continuing: UUID? = nil
    /// Stop was pressed and the recording is being saved (segments joined off the main thread): Home says "Saving…".
    @ObservationIgnored @Distinct var savingRecording = false
    /// The welcome tour sheet.
    @ObservationIgnored @Distinct var showOnboarding = false
    /// Import › Multi-track recording: the sheet's tracks while it's open (AppState+Multitrack).
    @ObservationIgnored @Distinct var multitrackDraft: MultitrackDraft? = nil
    /// Multi-track recordings being prepared (working copies, line-up, mix) before they join the queue.
    @ObservationIgnored var multitrackTasks: [UUID: Task<Void, Never>] = [:]
    /// The transcript the next recording start will add to (set by Continue, cleared by any other Record).
    @ObservationIgnored var pendingContinue: UUID? = nil
    /// The kind picked when the recording started (Record a meeting, an interview, …, from a right-click): the new
    /// transcript takes it as yours, so AutoLabel never replaces it and Run automatically uses it.
    @ObservationIgnored var recordKind: RecordingKind? = nil
    /// A passage to scroll to and select when the next transcript opens (from search, a note, a link).
    @ObservationIgnored var focusSegment: UUID? = nil
    /// iPhone links this Mac is fetching right now.
    @ObservationIgnored var claiming: Set<UUID> = []
    /// The transcript whose Transcribe again with Whisper Turbo question is showing (AppState+Turbo).
    @ObservationIgnored @Distinct var turboAsk: UUID? = nil
    /// A private or signed-in video waiting for you to choose a browser's sign-in (Views/SignInSheet.swift).
    @ObservationIgnored @Distinct var signInRequest: LinkSignInRequest? = nil

    // The "link added" card (AppState+LinkCard).
    /// Links this Mac is fetching, by transcript; the card observes one of them.
    @ObservationIgnored var linkImports: [UUID: LinkImport] = [:]
    /// Bumped when a link fetch finishes or fails, so the sidebar's Queue row and badge (which read `linkImports`,
    /// not observed) update without waiting for the next navigation.
    var linkImportsChanged = 0
    @ObservationIgnored var linkTasks: [UUID: Task<Void, Never>] = [:]
    /// The link whose card is showing.
    @ObservationIgnored @Distinct var linkCardID: UUID? = nil
    /// The card on screen came from a key (⌘V): it shows at once (Views/LinkAddedCard.swift). Set with `linkCardID`.
    @ObservationIgnored var linkCardFromKeyboard = false
    /// Links already counted by the queue but not yet shown in its badge: their card hasn't landed.
    @ObservationIgnored @Distinct var linkBadgeHeld: Set<UUID> = []
    /// Goes up each time a card lands in Queue, so the badge pops.
    @ObservationIgnored @Distinct var queueBadgePops = 0
    /// ⌘V on Home, Library, and Links (AppState+LinkCard).
    @ObservationIgnored var linkPasteMonitor: Any?
    @ObservationIgnored weak var mainWindow: NSWindow?

    @ObservationIgnored private var bag = Set<AnyCancellable>()

    init() {
        Sounds.enabled = sounds
        // Every interface sound loaded now, so the first dictation's tick plays at once (SoundPlayer.swift).
        DispatchQueue.main.async { Sounds.preload() }
        // Settings › Privacy: the network activity log, before anything can use the network.
        NetworkActivityLog.install()
        Log.note("AppState init")
        // Verbose for Mac's license: enforced in the public build only (MacLicenseStore.swift). A locked feature opens
        // Settings › Account and plan › License.
        MacLicenseStore.shared.start()
        // Record a call from the iPhone: the Mac's side of the relay (CallRelayHost.swift).
        DispatchQueue.main.async { CallRelayHost.shared.start() }
        FeatureGate.onDenied = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dictation.openSettings(tab: .account) } }
        }
        // Nothing is forwarded. AppState is @Observable, so a view re-renders when a value it reads changes; the Store
        // is Observable too (Store.swift); and the recorder, the player, the app capture, dictation, and the queue are
        // watched directly by the views that show them (`appState(_:)` puts them in the environment).
        coordinator.host = self
        recorder.onAutoPaused = { [weak self] reason in self?.toast = Toast(reason) }
        recorder.onInputSwitched = { [weak self] note in self?.toast = Toast(note) }
        // A muted mic while Verbose isn't in front: a notification (DESIGN.md §6.10, A muted microphone).
        recorder.onMicWarning = { MicWarningNotice.changed($0) }
        AudioDucker.shared.follow(.voiceNote, recorder.$isRecording.combineLatest(recorder.$isPaused, recorder.$isStarting).map { $0.0 && !$0.1 && !$0.2 })
        HangWatch.start()
        // The consolidation (October 28, 2026) moves settings for features that merged or retired, once per Mac.
        ConsolidationMac.migrateSettings()
        dictation.attach(self)
        // Thoughts: ⌃⌥P, the bubble, and the pad's pieces moving in once (Flow/Thoughts.swift).
        ThoughtCapture.shared.attach(self)
        // Mark a moment: the record panel's and the bubble's Mark, and ⌃⌥B while something records (App/MarkCenter.swift).
        MarkCenter.shared.attach(self)
        mirrorSnippets()
        // Watched folders compare new files with the library, so they start once it has loaded.
        store.whenLoaded { [weak self] in if let self { FolderWatcher.shared.attach(self) } }
        // Which kept and imported files are still there, checked off the main thread for rows and menus.
        KeptMedia.shared.attach(store)
        applyAppearance()
        // What's new: a new install starts at its own build, so Home's note waits for the next update.
        ReleaseNotes.settleLastSeen(ranBefore: Onboarding.finishedBefore)
        if Onboarding.shouldShow { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showOnboarding = true } }
        // Recordings recovered once launch recovery finishes in the background: transcribe them too.
        store.onRecovered = { [weak self] ids, announce in self?.queueRecovered(ids, announce: announce) }
        // Notices calls and asks to record them; never records on its own (App/MeetingCoordinator.swift).
        DispatchQueue.main.async { MeetingCoordinator.shared.attach(self) }
        QuitGuard.app = self
        // Services, Spotlight, and Shortcuts (App/SystemHooks.swift).
        SystemHooks.attach(self)
        // Links added on the iPhone wait for a Mac: claimed once the library has loaded, and whenever more arrive.
        // So do Whisper Turbo requests (Transcribe again on the iPhone, AppState+Turbo).
        store.onRemoteChange = { [weak self] t in self?.claimIfPendingLink(t); self?.claimIfPendingRerun(t) }
        // The queue, unfinished imports, link claims, and stills start once the library has loaded (the transcripts
        // are decoded off the main thread, after the first frame).
        store.whenLoaded { [weak self] in self?.resumeAfterLoad() }
    }

    /// What launch starts once the library has loaded (`Store.whenLoaded`), in the order it always ran.
    private func resumeAfterLoad() {
        Log.note("library loaded; transcripts=\(store.transcripts.count)")
        // The consolidation: Record as's rows this Mac starts with, once (ConsolidationMac.swift).
        ConsolidationMac.afterLibraryLoaded(store)
        // Anything still queued or mid-transcription when Verbatim last quit picks up where it left off.
        // Only jobs this Mac started: the iPhone's jobs show as "Transcribing on iPhone" and stay its own.
        coordinator.resume(includeUnowned: true)
        // Templates: a toast when Run automatically finishes, and runs that hadn't finished when Verbose quit.
        TemplateCenter.shared.automatic = !UITest.enabled
        TemplateCenter.shared.announce = { [weak self] msg in self?.toast = Toast(msg) }
        TemplateCenter.shared.resumeWaiting(store: store)
        // Ask: the passage index catches up in the background, never while something records or transcribes; recipes
        // run on their weekly schedule while Verbose is open, or at the next launch after their time.
        AskCenter.shared.automatic = !UITest.enabled
        AskCenter.shared.attach(store) { [weak self] in
            guard let self else { return true }
            return self.recorder.isRecording || self.capture.isCapturing || self.runningID != nil || self.dictation.isListening
                || ThoughtCapture.shared.isRecording
        }
        AskRecipeCenter.shared.automatic = !UITest.enabled
        AskRecipeCenter.shared.attach(store)
        // A meeting capture (App/MeetingSession.swift) a crash left behind comes back as one two-track transcript.
        if !UITest.enabled { DispatchQueue.main.async { MeetingSession.recoverLeftovers(app: self) } }
        DispatchQueue.main.async { for t in self.store.live where t.pendingLink { self.claimIfPendingLink(t) } }
        DispatchQueue.main.async { for t in self.store.live where t.rerunRequest != nil { self.claimIfPendingRerun(t) } }
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
        store.snippetsPublisher.dropFirst().removeDuplicates().sink { v in
            MainActor.assumeIsolated {
                if FlowSettings.shared.snippets != v { FlowSettings.shared.snippets = v }
            }
        }.store(in: &bag)
    }

    // `@Distinct` (Changed.swift) reads and announces through the registrar @Observable writes.
    func distinctAccess<Member>(_ keyPath: KeyPath<AppState, Member>) { access(keyPath: keyPath) }
    func distinctMutation<Member>(_ keyPath: KeyPath<AppState, Member>, _ mutation: () -> Void) { withMutation(keyPath: keyPath, mutation) }

    var preset: QualityPreset { QualityPreset(rawValue: presetRaw) ?? .defaultPreset }

    var engineChoice: (engine: String, model: String) {
        preset == .advanced ? (advEngine, advModel) : (preset.config.0, preset.config.1)
    }

    // MARK: Navigation

    private static let order: [String: Int] = ["home": 0, "library": 1, "queue": 4, "dictations": 5, "activity": 6, "dictionary": 7, "trash": 8, "byday-thoughts": 8, "byday-journal": 8]

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
        // No withAnimation here: the screen swaps in an unanimated transaction (ContentView's `detail`), so the old screen
        // leaves at once, and a publish made just before this (a project filter, a search) can't trigger a flush that
        // strands the screen change.
        navStartedAt = Date()
        if UITest.enabled { NavMarks.begin() }
        if let open = navInterval { Perf.signposter.endInterval("Navigate", open) }
        navInterval = Perf.signposter.beginInterval("Navigate", "\(self.key(next), privacy: .public)")
        // Back and Forward's trail and what the screen you're leaving comes back to (App/NavTrail.swift). Plain
        // storage; only Back and Forward's enabled state publishes, and only when it changes.
        let trail = NavTrail.shared
        trail.record(from: NavStop(screen, project: projectFilter), to: NavStop(next, project: projectFilter))
        ScreenPlaces.shared.navigating(from: screen, to: next, app: self)
        nav = Nav(screen: next, direction: direction, count: nav.count + 1, keyboard: navFromKeyboard)
        trail.publish()
    }

    /// Runs `body` as a keyboard action when `yes`: any navigation it makes shows the new screen at once, without the
    /// slide. The flag is cleared as `body` returns, so a later click still slides.
    @discardableResult
    func fromKeyboard<T>(_ yes: Bool = true, _ body: () -> T) -> T {
        let was = navFromKeyboard
        navFromKeyboard = yes
        defer { navFromKeyboard = was }
        return body()
    }

    /// True while AppKit is handling a key press (a menu item's key equivalent), false for a click on the same item.
    static var handlingKeyPress: Bool { NSApp.currentEvent?.type == .keyDown }
    /// True while a mouse click is being handled (a button's action from a click, not its keyboard shortcut): only a
    /// click celebrates (RecordingFinish, DESIGN.md §7).
    static var clickedNow: Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseUp?, .leftMouseDown?: return true
        default: return false
        }
    }

    func goHome() { go(.home) }

    /// File › Import… (⌘O) and New Transcript (⌘N): Home's Import panel, with the link field ready (CaptureBar.swift).
    func openImport() {
        mainWindow?.makeKeyAndOrderFront(nil)
        goHome()
        focusLink.toggle()
    }

    /// The Library on one of its type chips (Marked took the Moments screen's place, Links the Links screen's).
    func goLibrary(_ source: LibrarySource) {
        projectFilter = nil
        libraryFilter = LibraryFilter(source: source)
        go(.library)
    }

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
        switch s { case .home: return "home"; case .library: return "library"; case .queue: return "queue"; case .trash: return "trash"; case .dictionary: return "dictionary"; case .dictations: return "dictations"; case .activity: return "activity"; case .transcript: return "transcript"
        case .byDay(let k): return k == .journal ? "byday-journal" : "byday-thoughts"
        case .templates: return "templates"
        case .ask: return "ask" }
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    // MARK: Search

    /// The live library narrowed by the sidebar project and the search, worked out once per library change and search
    /// (Store+Memo.swift), not on every render of every screen that reads it.
    var filtered: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let project = projectFilter
        return store.memo("filtered|\(project?.uuidString ?? "-")|\(q)") {
            store.live.filter { t in
                (project == nil || t.projectId == project) &&
                (q.isEmpty || t.title.lowercased().contains(q) || store.searchText(t).contains(q))
            }
        }
    }

    /// The Library and Home's Recent: `filtered` without dictations, which live in Dictations. While searching,
    /// dictations are included (each row says "Dictation"), so nothing becomes unfindable.
    var archive: [Transcript] {
        let all = filtered
        guard search.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return store.memo("archive|\(projectFilter?.uuidString ?? "-")") { all.filter { !$0.isDictation } }
    }

    /// The Library's lists (LibraryView): `filtered` (`base`), what the type filter shows of it (`all`), `base` narrowed
    /// to the kind chip (`byKind`), both together (`list`) and its IDs, and the chips' counts. Worked out once per library
    /// change, search, project, type filter, and kind (Store+Memo.swift); the Library redid them, about ten passes over
    /// the library, on every render.
    struct LibraryLists {
        var base: [Transcript]
        var all: [Transcript]
        var byKind: [Transcript]
        var list: [Transcript]
        var ids: [UUID]
        /// Chips: All's count, each type with its count (All left out), the kinds' counts, and the platforms.
        var total: Int
        var sources: [(LibrarySource, Int)]
        var kindCounts: [RecordingKind: Int]
        var platforms: [(String, Int)]
    }

    func libraryLists(kind: RecordingKind?) -> LibraryLists {
        let base = filtered
        let q = search.trimmingCharacters(in: .whitespaces)
        let searching = !q.isEmpty
        let filter = libraryFilter
        let key = "library-lists|\(projectFilter?.uuidString ?? "-")|\(q.lowercased())|\(libraryFilterRaw)|\(kind.map { "\($0)" } ?? "-")"
        return store.memo(key) {
            let all = filter.apply(base, searching: searching)
            let byKind = kind.map { k in base.filter { $0.kind == k } } ?? base
            let list = kind.map { k in all.filter { $0.kind == k } } ?? all
            var kindCounts: [RecordingKind: Int] = [:]
            for t in all { if let k = t.kind { kindCounts[k, default: 0] += 1 } }
            return LibraryLists(base: base, all: all, byKind: byKind, list: list, ids: list.map(\.id),
                                total: LibraryFilter.all.apply(base, searching: searching).count,
                                sources: filter.sourceCounts(byKind, searching: searching).filter { $0.0 != .all },
                                kindCounts: kindCounts,
                                platforms: filter.platformCounts(byKind, searching: searching))
        }
    }
}
