import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers

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
    @Changed var search = ""
    @Changed var projectFilter: UUID? = nil
    /// Library › kind chips: nil is All.
    @Changed var libraryKind: RecordingKind? = nil
    @Changed var focusLink = false
    @Changed var showMicSheet = false
    @Changed var showAppPicker = false
    @Changed var toast: Toast? = nil
    @Changed var verbiePose: VerbiePose = .ready

    // Preferences, persisted in UserDefaults by key. Never @AppStorage or @Published here: see Changed.swift.
    @Changed("showMenuBar") var showMenuBar = true
    @Changed("preset") var presetRaw = QualityPreset.balanced.rawValue
    @Changed("advEngine") var advEngine = "fluid"
    @Changed("advModel") var advModel = "v3"
    @Changed("identifySpeakers") var identifySpeakers = true
    @Changed("applyDictionary") var applyDictionary = true
    @Changed("heroDismissed") var heroDismissed = false
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
        Log.note("AppState init; transcripts=\(store.transcripts.count)")
        for o in [store.objectWillChange.eraseToAnyPublisher(), recorder.objectWillChange.eraseToAnyPublisher(),
                  player.objectWillChange.eraseToAnyPublisher(), capture.objectWillChange.eraseToAnyPublisher(),
                  dictation.objectWillChange.eraseToAnyPublisher(), coordinator.objectWillChange.eraseToAnyPublisher()] {
            o.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        coordinator.host = self
        recorder.onAutoPaused = { [weak self] reason in self?.toast = Toast(reason) }
        recorder.onResumed = { [weak self] in self?.verbiePose = .listening }
        HangWatch.start()
        dictation.attach(self)
        applyAppearance()
        if Onboarding.shouldShow { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showOnboarding = true } }
        // Anything still queued or mid-transcription when Verbatim last quit picks up where it left off.
        // Only jobs this Mac started: the iPhone's jobs show as "Transcribing on iPhone" and stay its own.
        coordinator.resume(includeUnowned: true)
        // Links added on the iPhone wait for a Mac: claim them now and whenever more arrive.
        store.onRemoteChange = { [weak self] t in self?.claimIfPendingLink(t) }
        DispatchQueue.main.async { for t in self.store.live where t.pendingLink { self.claimIfPendingLink(t) } }
        if !UITest.enabled { DispatchQueue.main.async { self.resumeLinkFetches() } }
        if !queue.isEmpty { Log.note("resuming queue: \(queue.count)"); DispatchQueue.main.async { self.pump() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.backfillFrames() }
    }

    var preset: QualityPreset { QualityPreset(rawValue: presetRaw) ?? .balanced }
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
            let a = Self.order[key(screen)] ?? 0, b = Self.order[key(next)] ?? 0
            direction = b > a ? .up : .down
        }
        if UITest.enabled { Log.note("UITEST go \(key(next)) nav=\(nav.count + 1)") }
        // No withAnimation here: the container animates on `navCount`, so a publish made just before this
        // (a project filter, a search) can't trigger a flush that strands the screen change.
        navStartedAt = Date()
        nav = Nav(screen: next, direction: direction, count: nav.count + 1)
    }

    func goHome() { go(.home) }

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
