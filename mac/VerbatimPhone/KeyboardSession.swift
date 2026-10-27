import SwiftUI
import AVFoundation
import ActivityKit
import UIKit
import WidgetKit

/// The app's half of keyboard dictation (see `KeyboardBridge` for the whole flow).
///
/// A *session* keeps the microphone open and the speech model loaded so the keyboard can dictate without
/// switching apps. It starts when the keyboard opens `verbatim://session?start=1…` (the app comes forward for
/// under a second, then switches back to the app you came from). With Start dictating when you come back on, the
/// link names a dictation too, and the app begins it as soon as the microphone is on. The session ends after an
/// idle timeout, from the Live Activity or Settings › Keyboard, or for a call. Each dictation is marked in the
/// running capture, transcribed straight away with the warm model (not through the transcription queue), handed
/// to the keyboard, and then saved as a dictation in Library › Dictations.
///
/// The recording ribbon (`Ribbon`, RibbonRules.swift) builds on the session: the Action button, the Control Center
/// switch, Shortcuts, and the Live Activity's Dictate, Done, and Cancel start and stop takes here without switching
/// apps (`toggleTake`, `startTake`, `stopTake`, `cancelTake`, through `RibbonSignal`). A take's words go into the
/// text field when the Verbose keyboard is on screen, otherwise to the clipboard and the keyboard's Recent row.
@MainActor
final class KeyboardSession: ObservableObject {
    enum Stage: Equatable {
        case off
        /// Asking for the microphone and starting the capture (the app is in front).
        case starting
        case on
    }

    /// Settings › Keyboard and Settings › Action button › End the session after (idle): 10 or 30 minutes, 1, 2 (the
    /// default), or 4 hours, or Until I end it (`Ribbon.timeoutChoices`). An older stored choice moves to the nearest
    /// one. `timeoutUserSetKey` says the value came from a pick, so a later default change leaves it alone
    /// (`Ribbon.launchTimeout`).
    static let timeoutKey = "keyboard.sessionTimeout"
    static let timeoutUserSetKey = "keyboard.sessionTimeoutUserSet"
    static let timeoutChoices: [(seconds: Int, label: String)] = Ribbon.timeoutChoices.map { ($0, Ribbon.timeoutLabel($0)) }

    /// Where a take started, for the log.
    enum TakeSource: String { case intent, liveActivity, app, test }

    enum TakeOutcome: Equatable {
        case started, stopped, cancelled
        /// Nothing to do (Done with no take running, Start during a take).
        case ignored
        /// No session holds the microphone. iOS won't turn it on from the background, so Verbose must come forward;
        /// nothing touched the audio session.
        case needsForeground
    }

    /// The "Session ended" screen after a call or another app's audio ended the session.
    struct EndedNotice: Equatable {
        var reason: String
        /// The last take's words, shown in the app only (never on the Lock Screen), and when it was made.
        var lastTake: String?
        var lastTakeAt: Date?
    }

    @Published private(set) var stage: Stage = .off
    /// The start screen over the app: shown while starting, and when switching back to your app didn't work.
    @Published var showScreen = false
    /// True when Verbatim couldn't switch back by itself, so the screen asks you to swipe back.
    @Published private(set) var needsManualReturn = false
    /// Where this session was started when it wasn't the keyboard (Control Center, the Action button or
    /// Shortcuts, the Lock Screen widget, Settings › Keyboard). Nil for a keyboard start. Such a session never
    /// switches back by itself: there's no app to go back to, so the screen says what to do next.
    @Published private(set) var startSource: KeyboardBridge.StartSource? = nil
    @Published private(set) var dictating = false {
        didSet { if dictating != oldValue { PhoneDucker.set(dictating) } }   // Lower other audio while listening.
    }
    @Published private(set) var endsAt: Date? = nil
    /// True when this session started from the Action button's first press: the start screen says it's listening.
    @Published private(set) var startedForTake = false
    /// A session link that didn't come from the keyboard just now (a widget, or another app): the start screen asks
    /// "Start a keyboard session?", and the microphone stays off until you tap Start session.
    @Published private(set) var confirming: KeyboardBridge.StartSource? = nil
    /// Set when a call or another app's audio ended the session; the Session ended screen shows it.
    @Published var endedNotice: EndedNotice? = nil
    /// Assigned only by the pickers (never at launch), so each assignment is your pick.
    @Published var timeoutSeconds: Int = Ribbon.launchTimeout(stored: UserDefaults.standard.object(forKey: KeyboardSession.timeoutKey) as? Int,
                                                              userSet: UserDefaults.standard.object(forKey: KeyboardSession.timeoutUserSetKey) as? Bool) {
        didSet {
            UserDefaults.standard.set(timeoutSeconds, forKey: Self.timeoutKey)
            UserDefaults.standard.set(true, forKey: Self.timeoutUserSetKey)
            if stage == .on { touch() }
        }
    }
    /// True while a phone or FaceTime call (or Siri) has the audio: the session waits and picks up when it ends
    /// (`Ribbon.audio`). The keyboard and the Dynamic Island say "Paused for a call".
    @Published private(set) var paused = false
    /// False while the speech model loads for the keyboard's first dictation: the keyboard and the Dynamic Island
    /// say "Getting ready · the first one takes a few seconds". Mirrored to the App Group (`Key.engineReady`).
    @Published private(set) var engineReady = true
    /// The start screen's way back for this session start: the full coach card for the first five, then a line.
    @Published private(set) var coach: Ribbon.Coach = .full
    /// Settings › Keyboard and the start screen show the first dictation note until this is set.
    @Published private(set) var firstDictationDone = UserDefaults.standard.bool(forKey: Ribbon.firstDictationDoneKey)

    private weak var app: PhoneState?
    private let capture = SessionCapture()
    private var heartbeat: Timer?
    private var meter: Timer?
    private var lastActivity = Date()
    /// The dictation being captured, and the last one handled (so a repeated command is ignored).
    private var current: UUID?
    private var handled: Set<UUID> = []
    private var host: String?
    private var request: UUID?
    /// The dictation the keyboard's first tap asked for (Start dictating when you come back), until it begins.
    private var firstTapDictation: UUID?
    /// When a first-tap dictation began, until a keyboard shows it; it stops after `unseenTakeLimit` without one.
    private var unseenSince: Date?
    private var observing = false
    private var observers: [NSObjectProtocol] = []
    private var activity: Activity<VerbatimSessionAttributes>?
    private var background: UIBackgroundTaskIdentifier = .invalid
    /// Live words for the keyboard while you talk (Settings › Keyboard › Show words as you speak), and for the
    /// expanded Dynamic Island (Show words in the Dynamic Island).
    private let live = LiveTranscriber()
    private var liveWritten = LiveWords()
    /// Polish after inserting: the saved dictation for each keyboard dictation, and polished text that arrived
    /// before its dictation was saved.
    private var savedTranscripts: [UUID: UUID] = [:]
    private var pendingPolish: [UUID: String] = [:]

    // The recording ribbon.
    /// Takes the app started itself (not the keyboard), so their words are routed by `Ribbon.route`.
    private var ribbonTakes: Set<UUID> = []
    /// Ribbon takes still being transcribed (the Live Activity says "Writing your words…").
    private var transcribingTakes: Set<UUID> = []
    /// Start a take as soon as the microphone is on (the Action button's first press).
    private var pendingRibbonTake = false
    private var sessionStartedAt: Date?
    private var takeStartedAt: Date?
    private var takes = 0
    /// Copied, Inserted, or a failure, shown in the Live Activity until `until`.
    private var result: (phase: Ribbon.Phase, words: Int, message: String?, until: Date)?
    private var lastLevelPush = Date.distantPast
    /// A ribbon take whose clipboard write didn't take (Verbose in the background): copied when Verbose opens.
    private(set) var pendingCopy: String?
    /// The last take's words and time, for the Session ended screen.
    private(set) var lastTake: (text: String, at: Date)?
    private var activityWatch: Task<Void, Never>?
    /// Commands from the widget's process already read from the App Group, and keyboard requests already used.
    private var consumedCommands: Set<UUID> = []
    private var consumedRequests: Set<UUID> = []
    /// The keyboard request a link to confirm named, when it matched the one in the App Group (answered on Start).
    private var confirmingRequest: UUID?
    /// The start being confirmed also starts a take (the Action button's Dictate, asked in Verbose instead).
    private var confirmingTake = false
    /// This start came from an audio recording intent (the Action button, Restart): its Live Activity must start
    /// before the microphone, and without one the microphone stays off (`beginCapture`, `InPlaceRecording`).
    private var startedByRecordingIntent = false
    /// The session's audio across calls (`Ribbon.audio`).
    private var audioState: Ribbon.AudioState = .running
    /// The Parakeet model that's loaded and warm in this process, as far as the session knows (nil after a memory
    /// warning released it). Set by a warm-up or a finished dictation.
    private var warmedModel: String?
    /// A warm-up started when Verbose came to the foreground (one at a time).
    private var foregroundWarm: Task<Void, Never>?
    /// A Session ended Live Activity kept in the Dynamic Island and on the Lock Screen, with Restart, until this
    /// time (`Ribbon.endedHold`). Restart reuses nothing from it; a new session ends it.
    private var endedActivity: (activity: Activity<VerbatimSessionAttributes>, until: Date)?

    init(app: PhoneState) {
        self.app = app
        // A session never outlives the app: a Live Activity left by a crash or a force quit goes now.
        endStaleActivities()
        if let d = defaults, d.bool(forKey: KeyboardBridge.Key.sessionActive) {
            d.set(false, forKey: KeyboardBridge.Key.sessionActive)
            d.removeObject(forKey: KeyboardBridge.formatKey)
            KeyboardBridge.post(KeyboardBridge.Note.state)
        }
        // Control Center, the Action button, and Shortcuts (StartKeyboardSessionIntent, DictateIntent, ActionButtonIntent,
        // SetSessionIntent) start sessions here.
        SessionStartSignal.attach { [weak self] s in self?.startFromOutside(s.source, take: s.take, recordingIntent: s.recordingIntent) }
        // The ribbon's intents run in this process (LiveActivityIntent) and call the session directly; from the
        // widget's process they leave the command in the App Group and post a content-free Darwin notification.
        // Any app can post that notification, so it only means "look again" (`checkMailbox`).
        RibbonSignal.handler = { [weak self] c in self?.handleRibbon(c) ?? .ignored }
        KeyboardBridge.observe(KeyboardBridge.commandNote) { [weak self] in self?.checkMailbox() }
        // A command written before this launch isn't for this session.
        _ = KeyboardBridge.takeCommand(consumed: &consumedCommands, now: .distantFuture)
        // Recent dictations older than a day leave the App Group.
        KeyboardBridge.pruneRecent()
        // Settings › Action button: Record a voice note or Live captions, once Verbose is in front.
        ActionButtonSignal.attach { [weak self] choice in self?.runAction(choice) }
        ActionButtonSignal.voiceNoteInPlace = { [weak app] in app?.startVoiceNoteInPlace() ?? false }
        // A take whose clipboard write failed in the background is copied as soon as Verbose opens. Then the speech
        // model starts loading at low priority, so the first dictation is usually warm, and a Session ended Live
        // Activity past its 15 minutes goes.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.copyPending()
                self?.endExpiredEndedActivity()
                self?.warmAhead()
            }
        }
        // Memory: the model is released on a warning unless a session or a transcription needs it.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        }
    }

    private var defaults: UserDefaults? { KeyboardBridge.defaults }
    var isOn: Bool { stage == .on }

    // MARK: Start

    /// Handles a link the app was opened with. True when it was a keyboard session link.
    ///
    /// Any app can open `verbatim://session`, so the link only starts the microphone when its request matches the
    /// fresh one the keyboard wrote to the App Group just before (`BridgeTrust.decide`). Then the dictation it names
    /// begins only if the keyboard asked for it, and Verbose switches back only to the app the keyboard recorded.
    /// Any other link (the Lock Screen widget, a stale request, another app) asks first.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = KeyboardBridge.sessionLink(in: url) else { return false }
        let stored = KeyboardBridge.storedRequest()
        switch BridgeTrust.decide(linkRequest: link.request, linkDictation: link.dictation, stored: stored,
                                  consumed: consumedRequests, now: Date().timeIntervalSince1970) {
        case .start(let host, let dictation):
            if let r = link.request { consumedRequests.insert(r) }
            start(request: link.request, host: host, dictation: dictation, source: nil, fromLink: true)
        case .confirm:
            let source = link.source ?? .app
            // The keyboard's own request that arrived late: answered once you choose, so the keyboard stops waiting.
            let request = link.request.flatMap { $0 == stored.id && !stored.answered ? $0 : nil }
            if stage == .on {
                // Already on: nothing to start; the screen says what to do next.
                start(request: nil, host: nil, dictation: nil, source: source, fromLink: true)
                return true
            }
            // Already starting: the start in progress carries on as it was.
            guard stage == .off else { return true }
            Log.note("keyboard session: a link without a fresh keyboard request; asking before turning on the microphone")
            confirmingRequest = request
            confirmingTake = false
            confirming = source
            needsManualReturn = false
            showScreen = true
        }
        return true
    }

    /// Delete all data: the last take's words leave memory too (the Session ended screen, a copy still waiting).
    func forgetTakes() {
        lastTake = nil
        pendingCopy = nil
        endedNotice = nil
    }

    /// Start session on the confirmation screen.
    func confirmStart() {
        guard let source = confirming else { return }
        confirming = nil
        let r = confirmingRequest
        confirmingRequest = nil
        let take = confirmingTake
        confirmingTake = false
        if let r { consumedRequests.insert(r) }
        start(request: r, host: nil, dictation: nil, source: source, take: take, fromLink: true)
    }

    /// Not now on the confirmation screen: nothing starts.
    func declineStart() {
        confirming = nil
        confirmingTake = false
        if let r = confirmingRequest, stage == .off {
            confirmingRequest = nil
            request = r
            answer(ok: false, "You didn't start a session in Verbose.")
            request = nil
        }
        confirmingRequest = nil
        showScreen = false
    }

    /// Starts a session from outside the keyboard: Control Center, the Action button or Shortcuts
    /// (`StartKeyboardSessionIntent`), the Lock Screen widget, or Settings › Keyboard.
    func startFromOutside(_ source: KeyboardBridge.StartSource, take: Bool = false, recordingIntent: Bool = false) {
        start(request: nil, host: nil, dictation: nil, source: source, take: take, recordingIntent: recordingIntent)
    }

    /// `take`: also start a ribbon take as soon as the microphone is on (the Action button's first press).
    /// `fromLink`: a `verbatim://` link asked, so onboarding stays up if it's showing.
    /// `recordingIntent`: an audio recording intent asked (the Action button, Restart). iOS 27 closes the app when
    /// such an intent turns the audio session on with no Live Activity showing, so the session's Live Activity starts
    /// first, and when none can, the microphone stays off and Verbose asks instead (`askInVerbose`).
    func start(request r: UUID?, host h: String?, dictation d: UUID? = nil, source: KeyboardBridge.StartSource? = nil, take: Bool = false,
               recordingIntent: Bool = false, fromLink: Bool = false) {
        guard let app else { return }
        confirming = nil
        confirmingRequest = nil
        confirmingTake = false
        request = r
        host = h
        firstTapDictation = d
        startSource = source
        let hostNote = h.map { "names the host app " + $0 } ?? "names no host app (the keyboard couldn't read it)"
        let dictationNote = d == nil ? "" : ", starts a dictation"
        if let source {
            Log.note("keyboard session: started from " + source.rawValue + (take ? ", with a take" : ""))
            if stage == .on {
                observe()
                // Already on and asked for a take: start one (or leave the running one alone), no screen.
                if take { if current == nil { startTake(source: .intent) }; return }
                // Already on: nothing to start, so the screen says what to do next.
                showManualReturn(); return
            }
        } else {
            Log.note("keyboard session: link " + hostNote + dictationNote)
        }
        observe()
        if stage == .on {
            // Already on (a second tap, or a keyboard that missed the heartbeat): start the dictation, then go back.
            beginFirstTapDictation()
            answer(ok: true)
            goBack()
            return
        }
        if take { pendingRibbonTake = true; startedForTake = true }
        guard stage == .off else { return }
        guard !app.recorder.isRecording else {
            pendingRibbonTake = false
            startedForTake = false
            answer(ok: false, "Verbose is recording a voice memo. Stop it first.")
            app.askToFinishRecording(for: "the keyboard")
            return
        }
        // No Live Activity can show (Live Activities are off): nothing turns on, not even the permission question.
        if recordingIntent && !activitiesAllowed {
            askInVerbose(source: source ?? .shortcut, take: take, why: "Live Activities can't show here")
            return
        }
        startedByRecordingIntent = recordingIntent
        stage = .starting
        needsManualReturn = false
        if !fromLink { app.showOnboarding = false }
        coach = Ribbon.coach(shown: UserDefaults.standard.integer(forKey: Ribbon.coachCountKey))
        coachCounted = false
        showScreen = true
        defaults?.removeObject(forKey: KeyboardBridge.Key.endReason)
        defaults?.set(PhoneDictation.level.title, forKey: KeyboardBridge.Key.levelLabel)
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                guard self.stage == .starting else { return }
                if ok { self.beginCapture() } else {
                    self.stage = .off
                    self.pendingRibbonTake = false
                    self.startedForTake = false
                    self.showScreen = false
                    self.answer(ok: false, "Microphone access is off. Turn it on in Settings › Verbose.")
                    app.say("Microphone access is off. Turn it on in Settings › Verbose.")
                }
            }
        }
    }

    /// Turns on the audio session and the capture. Throws when iOS refuses (for example, recording from the
    /// background without an intent that allows it).
    private func startAudio() throws {
        let s = AVAudioSession.sharedInstance()
        // Mixes with other audio, so a session doesn't stop your music or podcast.
        // AirPods record over their high-quality link on iOS 26 (RecordingRoute), falling back to HFP.
        try s.setCategory(.playAndRecord, mode: .spokenAudio, options: RecordingRoute.options(mixWithOthers: true))
        // No pinned input from an earlier recording: the system's current microphone (AirPods when they're in,
        // the iPhone's otherwise), and the capture follows it when that changes.
        try? s.setPreferredInput(nil)
        try s.setActive(true)
        capture.onFailure = { [weak self] message in
            MainActor.assumeIsolated { self?.captureFailed(message) }
        }
        try capture.start()
        RecordingRoute.noteStart("keyboard session", format: nil)
    }

    private func beginCapture() {
        // The Live Activity before the microphone, every time (as for voice notes and thoughts, `InPlaceRecording`).
        // From an audio recording intent there's no microphone without one: Verbose, already in front, asks instead.
        if !startActivity() && startedByRecordingIntent {
            askInVerbose(source: startSource ?? .shortcut, take: pendingRibbonTake, why: "its Live Activity didn't start")
            return
        }
        do {
            try startAudio()
        } catch {
            capture.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            endActivity()
            startedByRecordingIntent = false
            stage = .off
            showScreen = false
            pendingRibbonTake = false
            startedForTake = false
            answer(ok: false, "Couldn't turn on the microphone: \(error.localizedDescription)")
            app?.say("Couldn't turn on the microphone.")
            return
        }
        captureStarted()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Back to your app as soon as the capture is running. A short beat lets the screen draw first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.goBack() }
    }

    /// An audio recording intent's start that can't have its Live Activity: the microphone stays off, and the start
    /// screen asks "Start a keyboard session?" in Verbose. Start session there is your tap, outside the intent.
    private func askInVerbose(source: KeyboardBridge.StartSource, take: Bool, why: String) {
        Log.note("keyboard session: \(why); asking in Verbose before turning on the microphone")
        stage = .off
        startedByRecordingIntent = false
        pendingRibbonTake = false
        startedForTake = false
        confirmingRequest = nil
        confirmingTake = take
        confirming = source
        needsManualReturn = false
        showScreen = true
    }

    /// Everything after the capture is running: the session is on.
    private func captureStarted() {
        stage = .on
        paused = false
        audioState = .running
        lastActivity = Date()
        sessionStartedAt = Date()
        takes = 0
        result = nil
        ribbonTakes = []
        transcribingTakes = []
        endedNotice = nil
        // The model's state first, so a dictation that begins right away says "Getting ready" if it isn't warm.
        warmModel()
        // A start command left from before this launch isn't for this session.
        if let old = KeyboardBridge.uuid(KeyboardBridge.Key.startID), old != firstTapDictation { handled.insert(old) }
        touch()
        writeSession()
        // Listening before the keyboard hears the session is on, so it shows the dictation the moment you're back.
        beginFirstTapDictation()
        // The Action button's first press: listening before you swipe back to your app.
        if pendingRibbonTake { pendingRibbonTake = false; startTake(source: .intent) }
        answer(ok: true)
        startHeartbeat()
        // Normally already showing (`beginCapture`, `restartInPlace` start it before the microphone).
        if activity == nil { startActivity() }
        startedByRecordingIntent = false
        reloadControl()
    }

    /// Restart in the Dynamic Island or on the Lock Screen (`RestartSessionIntent`): turns the session back on
    /// without opening Verbose when iOS allows it. Returns false, with the microphone off and no Live Activity left,
    /// when it can't (no microphone permission, a voice memo recording, no Live Activity, or iOS refusing to start
    /// recording from the background); the intent then opens Verbose straight into the session
    /// (`SessionStartSignal.fire(.island)`). Restart is an audio recording intent, so its Live Activity starts before
    /// the microphone, and without one the microphone is never touched (`InPlaceRecording`).
    func restartInPlace() -> Bool {
        if stage != .off { return true }
        guard let app, !app.recorder.isRecording, AVAudioApplication.shared.recordPermission == .granted else { return false }
        let outcome = InPlaceRecording.start(
            startActivity: { startActivity() },
            startRecording: {
                do {
                    try startAudio()
                    return true
                } catch {
                    capture.stop()
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    Log.note("keyboard session: Restart couldn't turn on the microphone in place (\(error.localizedDescription))")
                    return false
                }
            },
            endActivity: { endActivity() })
        if case .openVerbose(let why) = outcome {
            Log.note("keyboard session: Restart: \(why); opening Verbose")
            return false
        }
        observe()
        confirming = nil
        confirmingRequest = nil
        request = nil
        host = nil
        firstTapDictation = nil
        startSource = .island
        needsManualReturn = false
        defaults?.removeObject(forKey: KeyboardBridge.Key.endReason)
        defaults?.set(PhoneDictation.level.title, forKey: KeyboardBridge.Key.levelLabel)
        captureStarted()
        Log.note("keyboard session: restarted in place from the Live Activity (app \(UIApplication.shared.applicationState == .active ? "in front" : "in the background"))")
        return true
    }

    /// Loads the speech model and runs one warm-up inference, so the first dictation pays nothing for it. Also
    /// starts loading the speech detector (silence trimming), the vocabulary booster for your Dictionary words,
    /// and Apple's language model for cleanup, none of which a dictation ever waits for.
    private func warmModel() {
        FlowCleanup.prewarm(level: PhoneDictation.level)
        // Live words: asks for Apple's on-device speech model to be installed. Never prompts for permission here.
        if KeyboardBridge.liveWords || Self.islandWordsOn { live.prepare() }
        guard let app else { return }
        let s = app.jobSettings()
        // Other engines load on the first dictation, as before; only Parakeet reports its state.
        guard s.engineId == "fluid" else { setEngineReady(true); return }
        let model = Engines.fluidModel(s.model)
        setEngineReady(warmedModel == model)
        let terms = boostTerms()
        Task.detached(priority: .utility) {
            // The model and its warm-up inference first (no vocabulary yet), so "Getting ready" ends as soon as a
            // dictation would run at full speed; then the vocabulary booster, which no dictation waits for.
            await FluidEngine.shared.prewarm(model: model, boostTerms: [], dictation: true)
            let warm = await FluidEngine.shared.isWarm(model)
            await MainActor.run { self.modelWarmed(model, warm: warm) }
            await FluidEngine.shared.prewarm(model: model, boostTerms: terms, dictation: true)
        }
    }

    /// A warm-up finished. A failed one (Local Only refused a download, say) still ends "Getting ready": the
    /// dictation then loads the model itself or reports why it can't.
    private func modelWarmed(_ model: String, warm: Bool) {
        if warm { warmedModel = model }
        if !warm { Log.note("keyboard session: the speech model didn't warm up; the first dictation loads it") }
        setEngineReady(true)
    }

    /// Mirrors the model's state to the keyboard (App Group) and the Dynamic Island, when it changed.
    private func setEngineReady(_ ready: Bool) {
        let changed = ready != engineReady || defaults?.object(forKey: KeyboardBridge.Key.engineReady) as? Bool != ready
        engineReady = ready
        guard changed else { return }
        defaults?.set(ready, forKey: KeyboardBridge.Key.engineReady)
        KeyboardBridge.post(KeyboardBridge.Note.state)
        updateActivity()
    }

    /// Verbose came to the foreground: start loading the speech model at low priority, a few seconds later, so the
    /// first keyboard dictation is usually warm. Never blocks the interface or launch, never starts a download (a
    /// model that isn't on this iPhone yet downloads when a session first needs it, as before), and loads into the
    /// one shared engine, so there's never a second copy.
    func warmAhead() {
        guard !PhoneUITest.enabled, foregroundWarm == nil, let app else { return }
        let s = app.jobSettings()
        guard s.engineId == "fluid" else { return }
        let model = Engines.fluidModel(s.model)
        guard warmedModel != model else { return }
        guard FluidEngine.isDownloaded(model) else {
            Log.note("speech model warm-up skipped: \(model) isn't downloaded yet (no download from a warm-up)")
            return
        }
        foregroundWarm = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { self?.foregroundWarm = nil; return }
            let warm = await Task.detached(priority: .background) { () -> Bool in
                await FluidEngine.shared.prewarm(model: model, boostTerms: [])
                return await FluidEngine.shared.isWarm(model)
            }.value
            guard let self else { return }
            self.foregroundWarm = nil
            if warm {
                self.warmedModel = model
                Log.note("speech model warm ahead of the first dictation (\(model))")
            }
        }
    }

    /// A memory warning: with no session and no transcription running, the speech model goes (it loads again,
    /// warm-up and all, when it's next needed). During a session it stays, because dictation needs it.
    private func memoryWarning() {
        guard stage == .off, app?.runningID == nil else {
            Log.note("memory warning: the speech model stays (a session or a transcription is using it)")
            // The language check's model kept beside it goes (FluidEngine.releaseSpareModel).
            Task.detached(priority: .utility) { await FluidEngine.shared.releaseSpareModel() }
            return
        }
        foregroundWarm?.cancel()
        foregroundWarm = nil
        warmedModel = nil
        Task.detached(priority: .utility) { await FluidEngine.shared.releaseModel() }
    }

    /// Dictionary words for vocabulary boosting, ranked as on the Mac (newest first, up to 100). Only words for
    /// every transcript: the iPhone has no active project. Empty when Apply Dictionary is off, or when boosting is
    /// turned off (`flow.boost`, the Mac's key; on unless set). Built-in vocabulary terms follow your words.
    private func rankedBoostTerms() -> [(text: String, aliases: [String])] {
        guard let app, UserDefaults.standard.object(forKey: "flow.boost") as? Bool ?? true else { return [] }
        let mine = app.applyDictionary ? app.store.dictionary : []
        return BoostVocabulary.rank(mine + BuiltInVocabulary.boostEntries(excluding: app.store.dictionary), project: nil)
    }

    /// `rankedBoostTerms` oldest first, the order `FluidEngine.prewarm(boostTerms:)` expects.
    private func boostTerms() -> [(text: String, aliases: [String])] {
        Array(rankedBoostTerms().reversed())
    }

    private func answer(ok: Bool, _ message: String? = nil) {
        guard let d = defaults, let r = request else { return }
        if ok {
            d.set(r.uuidString, forKey: KeyboardBridge.Key.requestDone)
        } else {
            d.set(message, forKey: KeyboardBridge.Key.requestMessage)
            d.set(r.uuidString, forKey: KeyboardBridge.Key.requestFailed)
        }
        KeyboardBridge.post(KeyboardBridge.Note.state)
    }

    // MARK: Going back to your app

    /// Begins the dictation the keyboard's first tap asked for, unless the keyboard cancelled it meanwhile or it
    /// already began. Includes the pre-roll, so words said as Verbatim switches back are kept.
    private func beginFirstTapDictation() {
        guard let d = firstTapDictation else { return }
        firstTapDictation = nil
        guard stage == .on, KeyboardBridge.autoStart, current != d, !handled.contains(d),
              KeyboardBridge.uuid(KeyboardBridge.Key.cancelID) != d else { return }
        Log.note("keyboard session: first tap starts the dictation; listening before switching back")
        beginDictation(d, firstTap: true)
    }

    /// Switches back to the app the keyboard was in. If that isn't possible, the screen tells you how to go back
    /// yourself. Never blocks. The breadcrumb iOS uses for "◀ <app>" can appear a moment after Verbatim comes
    /// forward, so a miss is retried a few times before the screen shows.
    private func goBack(attempt: Int = 1) {
        // Started from Control Center, a shortcut, the widget, or Verbatim: no app to switch back to.
        if startSource != nil { showManualReturn(); return }
        let result = Self.returnToHostApp(linkHost: host)
        switch result {
        case .opened(let id, let source):
            Log.note("keyboard session: switched back to \(id) (host from \(source))")
            // iOS said yes but Verbatim is still in front a moment later: fall back to the manual screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.stage == .on, UIApplication.shared.applicationState == .active, self.showScreen else { return }
                Log.note("keyboard session: still in front 1.5 s after opening \(id); showing the way back")
                self.showManualReturn()
            }
        case .failed(let why, let retry):
            if retry, attempt < 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.stage == .on, UIApplication.shared.applicationState == .active else { return }
                    self.goBack(attempt: attempt + 1)
                }
                return
            }
            Log.note("keyboard session: can't switch back by itself (\(why)); showing the way back")
            showManualReturn()
        }
    }

    private func showManualReturn() {
        needsManualReturn = true
        showScreen = true
        // One count per session start that showed the way back (`Ribbon.coach`): the full card five times, then a line.
        if !coachCounted {
            coachCounted = true
            let d = UserDefaults.standard
            d.set(Ribbon.coachCount(after: d.integer(forKey: Ribbon.coachCountKey)), forKey: Ribbon.coachCountKey)
        }
    }

    /// Whether this session start already counted toward the coach card.
    private var coachCounted = false

    /// The screenshot tour only (no microphone in the simulator): shows the start screen as it looks once a session
    /// is on and you have to go back yourself, with the full coach or the reminder; nil puts everything back.
    func previewStartScreen(coach: Ribbon.Coach?, host h: String?) {
        guard PhoneUITest.enabled else { return }
        if let coach {
            self.coach = coach
            host = h
            startSource = nil
            stage = .on
            needsManualReturn = true
            showScreen = true
        } else {
            showScreen = false
            needsManualReturn = false
            stage = .off
            host = nil
        }
    }

    /// The app you came from, by name ("Messages"), when this build knows it; nil in App Store builds and for an
    /// app Verbose doesn't know, so the start screen says "the app you were in".
    var sourceAppName: String? {
        guard Distribution.current.readsHostApp, startSource == nil else { return nil }
        return KeyboardFormat.classify(host: host)?.name
    }

    /// Settings › Keyboard and the start screen stop showing the first dictation note.
    private func noteDictation(words: Int) {
        let done = Ribbon.firstDictationDone(was: firstDictationDone, words: words)
        guard done != firstDictationDone else { return }
        firstDictationDone = done
        UserDefaults.standard.set(done, forKey: Ribbon.firstDictationDoneKey)
    }

    enum ReturnResult: Equatable {
        /// iOS accepted the request to open `bundleID`; `source` says where the ID came from.
        case opened(bundleID: String, source: String)
        /// Nothing was opened; `retry` when the host app isn't known yet and may be in a moment.
        case failed(String, retry: Bool)
    }

    // MARK: Private API seam (the only place the app uses undocumented iOS interfaces)

    /// Opens the app you were typing in.
    ///
    /// Where the host app's bundle ID comes from, in order:
    /// 1. `linkHost`: the keyboard read it (`KeyboardViewController.hostBundleID()`). iOS has returned nil there
    ///    since iOS 18 in most reports, and on iOS 26.4 and later every known key returns nil or `<null>`.
    /// 2. The status bar breadcrumb ("◀ Messages") that iOS shows when another app opened Verbatim. UIKit keeps it
    ///    on the app's `UIApplication` as `_systemNavigationAction`, a `UISystemNavigationAction` with
    ///    `destinations` and `bundleIdForDestination:` (see the Apple Wiki "Dev:Breadcrumbs" page and the
    ///    Homemade-Bread tweak's header). Whether iOS 26.4 and later redacts it here is unverified; the log says.
    ///
    /// It then opens that app with `LSApplicationWorkspace.openApplicationWithBundleID:`, because there's no
    /// public API that opens another app by bundle ID, or returns to the app that opened yours (Apple DTS
    /// confirmed both on the Apple Developer Forums, thread 826851).
    ///
    /// App Review risk: high. Both calls are undocumented, made through the Objective-C runtime after
    /// `responds(to:)` checks, so a missing selector fails safely instead of crashing. A reviewer can reject the
    /// build under guideline 2.5.1 (public APIs only), and any iOS release can make them fail. Everything that
    /// depends on them goes through this one function: making it return `.failed("disabled", retry: false)` keeps
    /// the app working, with the manual screen ("Tap ◀ <app> at the top left").
    ///
    /// App Store builds (`APP_STORE`, mac/APP_STORE.md) compile both calls out and always return
    /// `unavailableInAppStore`. `appStore` defaults to the build's flag; the self-tests pass `true` to check the
    /// seam without calling anything private.
    static func returnToHostApp(linkHost: String?, appStore: Bool = Distribution.isAppStore) -> ReturnResult {
        guard Distribution.abilities(appStore: appStore).returnsToHostApp else { return unavailableInAppStore }
        #if APP_STORE
        return unavailableInAppStore
        #else
        guard !PhoneUITest.enabled else { return .failed("UI test", retry: false) }
        var target: (id: String, source: String)?
        if let h = linkHost { target = (h, "the keyboard") }
        else if let crumb = breadcrumbHostBundleID() { target = (crumb.id, "the back breadcrumb " + (crumb.title ?? "(no title)")) }
        guard let target else { return .failed("no host bundle ID from the keyboard or the back breadcrumb", retry: true) }
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return .failed("LSApplicationWorkspace is missing", retry: false) }
        let workspaceSel = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: workspaceSel),
              let workspace = cls.perform(workspaceSel)?.takeUnretainedValue() as? NSObject else { return .failed("no default workspace", retry: false) }
        let openSel = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSel) else { return .failed("openApplicationWithBundleID: is missing", retry: false) }
        typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let open = unsafeBitCast(workspace.method(for: openSel), to: Open.self)
        guard open(workspace, openSel, target.id as NSString) else {
            return .failed("iOS refused to open \(target.id) (host from \(target.source))", retry: false)
        }
        return .opened(bundleID: target.id, source: target.source)
        #endif
    }

    /// What the seam returns in App Store builds: the manual screen shows, with no retries.
    static let unavailableInAppStore = ReturnResult.failed("not available in App Store builds", retry: false)

    #if !APP_STORE
    /// The app the status bar's back breadcrumb leads to, and its title, when iOS shows one. Part of the seam above.
    private static func breadcrumbHostBundleID() -> (id: String, title: String?)? {
        let app = UIApplication.shared
        let actionSel = NSSelectorFromString("_systemNavigationAction")
        guard app.responds(to: actionSel), let action = app.perform(actionSel)?.takeUnretainedValue() as? NSObject else {
            Log.note("keyboard session: no back breadcrumb")
            return nil
        }
        let destinationsSel = NSSelectorFromString("destinations")
        if action.responds(to: destinationsSel) {
            let destinations = action.perform(destinationsSel)?.takeUnretainedValue() as? NSArray
            guard (destinations?.count ?? 0) > 0 else { Log.note("keyboard session: back breadcrumb has no destinations"); return nil }
        }
        typealias ForDestination = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>?
        func string(_ name: String) -> String? {
            let sel = NSSelectorFromString(name)
            guard action.responds(to: sel) else { return nil }
            let call = unsafeBitCast(action.method(for: sel), to: ForDestination.self)
            guard let s = call(action, sel, 0)?.takeUnretainedValue() as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t == "<null>" ? nil : t
        }
        let title = string("titleForDestination:")
        guard let id = string("bundleIdForDestination:"), id != Bundle.main.bundleIdentifier else {
            Log.note("keyboard session: back breadcrumb " + (title ?? "(no title)") + " gives no bundle ID")
            return nil
        }
        return (id, title)
    }
    #endif

    // MARK: Dictation (no app switch)

    private func observe() {
        guard !observing else { return }
        observing = true
        KeyboardBridge.observe(KeyboardBridge.Note.command) { [weak self] in self?.checkCommands() }
        SessionEndSignal.handler = { [weak self] in self?.end(reason: nil) }
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        // A phone or FaceTime call, or Siri: pause, then pick up when it ends (`Ribbon.audio`). A route that went
        // away (a Bluetooth headset) ends the session as before; no "ended" follows that one.
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    if #available(iOS 17.0, *), reason == AVAudioSession.InterruptionReason.routeDisconnected.rawValue {
                        self.interrupted(Ribbon.callEndedMessage, call: false)
                        return
                    }
                    self.audioEvent(.interruptionBegan)
                case .ended:
                    let resume = options.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
                    self.audioEvent(.interruptionEnded(shouldResume: resume))
                @unknown default:
                    break
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted("The session ended. Tap to start a new one.", call: false) }
        })
        observers.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(reason: "Verbose was closed. Tap to start a new session.") }
        })
        // Back in your app: the start screen's job is done.
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stage == .on else { return }
                self.showScreen = false
                self.needsManualReturn = false
            }
        })
    }

    /// Commands from the keyboard. Separate keys for start, done, and cancel, so none overwrites another.
    private func checkCommands() {
        logPolishOutcome()
        guard stage == .on, !paused else { return }
        if let start = KeyboardBridge.uuid(KeyboardBridge.Key.startID), start != current, !handled.contains(start),
           KeyboardBridge.uuid(KeyboardBridge.Key.cancelID) != start {
            beginDictation(start)
        }
        guard let c = current else { return }
        if KeyboardBridge.uuid(KeyboardBridge.Key.cancelID) == c {
            cancelDictation()
        } else if KeyboardBridge.uuid(KeyboardBridge.Key.doneID) == c {
            finishDictation()
        }
    }

    private func beginDictation(_ id: UUID, firstTap: Bool = false) {
        if current != nil { cancelDictation() }
        handled.insert(id)
        current = id
        unseenSince = firstTap ? Date() : nil
        startLive()
        capture.beginTake()
        // Apple's model loads while you talk, so cleanup starts warm (one prewarmed session serves one dictation).
        FlowCleanup.prewarm(level: PhoneDictation.level)
        takeStartedAt = Date()
        takes += 1
        result = nil
        dictating = true
        lastActivity = Date()
        touch()
        write(.listening, for: id)
        updateActivity()
        startMeter()
    }

    /// About 10 times a second while dictating: level and time for the keyboard, and the 5-minute cap.
    private func startMeter() {
        meter?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tickMeter() } }
        RunLoop.main.add(t, forMode: .common)
        meter = t
    }

    private func tickMeter() {
        guard dictating, current != nil, let d = defaults else { meter?.invalidate(); meter = nil; return }
        let seconds = capture.takeSeconds
        d.set(Double(capture.level), forKey: KeyboardBridge.Key.level)
        d.set(seconds, forKey: KeyboardBridge.Key.elapsed)
        writeLive(d)
        KeyboardBridge.post(KeyboardBridge.Note.state)
        // The Live Activity's level, about once a second (ActivityKit isn't for 10 updates a second).
        if Date().timeIntervalSince(lastLevelPush) >= 1 { lastLevelPush = Date(); updateActivity() }
        checkCommands()
        if dictating, seconds >= KeyboardBridge.maxSeconds { finishDictation() }
        // A first-tap dictation nobody came back to: stop listening after a minute.
        if dictating, let since = unseenSince, let id = current {
            if KeyboardBridge.uuid(KeyboardBridge.Key.seenID) == id {
                unseenSince = nil
            } else if KeyboardBridge.shouldStopUnseenTake(startedAt: since, seen: false, now: Date()) {
                Log.note("keyboard session: no keyboard showed the first-tap dictation within \(Int(KeyboardBridge.unseenTakeLimit)) s; stopping it")
                cancelDictation(message: "Verbose stopped listening because you didn't come back within a minute. Tap the record button to dictate.")
            }
        }
    }

    /// Cancels the dictation. With a message, the keyboard shows it (as a failure) instead of going quietly idle.
    private func cancelDictation(message: String? = nil) {
        guard let id = current else { return }
        capture.cancelTake()
        stopLive()
        unseenSince = nil
        current = nil
        dictating = false
        meter?.invalidate(); meter = nil
        lastActivity = Date()
        touch()
        if let message { write(.failed, for: id, message: message) } else { write(.cancelled, for: id) }
        updateActivity()
    }

    /// Done: stops the mark, transcribes right away on a high-priority task with the warm model (not through the
    /// transcription queue), writes the text for the keyboard, then saves the dictation.
    private func finishDictation() {
        guard let id = current, let app else { return }
        let samples = capture.endTake()
        stopLive()
        unseenSince = nil
        current = nil
        dictating = false
        meter?.invalidate(); meter = nil
        lastActivity = Date()
        let ribbon = ribbonTakes.contains(id)
        if ribbon { transcribingTakes.insert(id) }
        touch()
        updateActivity()
        let duration = Double(samples.count) / SessionCapture.sampleRate
        guard duration >= 0.4 else {
            write(.failed, for: id, message: "No words were heard.")
            if ribbon { showResult(.failed, for: id, words: 0, message: Ribbon.nothingHeardMessage) }
            return
        }
        write(.transcribing, for: id)
        beginBackground()
        let settings = app.jobSettings()
        let dictionary = settings.applyDictionary ? app.store.dictionary : []
        let ranked = rankedBoostTerms()
        let vocabulary = dictionary.filter { $0.enabled && $0.projectId == nil }.map(\.preferred)
        let snippets = app.store.snippets
        let level = PhoneDictation.level
        // The keyboard's format chip (Auto, Email, Message, Note), as the keyboard resolved it for this dictation.
        let category = PhoneDictation.category(host: host, chosen: KeyboardBridge.category(for: id))
        let polishAfter = KeyboardBridge.polishAfter
        let t0 = Date()
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await Self.transcribe(samples, engineId: settings.engineId, model: settings.model, ranked: ranked)
                let heard = Date()
                let original = result.segments
                var fixed = original
                let corrections = dictionary.isEmpty && !BuiltInVocabulary.isActive ? [] : DictionaryApplier.apply(dictionary, to: &fixed)
                let raw = fixed.filter { !$0.isFillerOnly }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                // The Mac's cleanup at your level: Apple's model on iOS 26 when it's available and answers within the
                // keyboard's budget, otherwise the rules (prepass, then lists and paragraphs). Plain bullets.
                // Polish after inserting: the model gets a longer budget and keeps going after the rule-based text
                // goes in; the keyboard swaps in its text when it arrives (`awaitPolish`).
                let out: FlowCleanup.Result
                var later: Task<FlowCleanup.Result, Never>? = nil
                if polishAfter {
                    let budget = KeyboardBridge.polishBudget(words: raw.split(whereSeparator: { $0.isWhitespace }).count)
                    let request = PhoneDictation.request(raw: raw, level: level, category: category, vocabulary: vocabulary,
                                                         snippets: snippets, budget: budget)
                    let pair = await Self.cleanThenPolish(request, budget: budget)
                    out = pair.0
                    later = pair.1
                } else {
                    let request = PhoneDictation.request(raw: raw, level: level, category: category, vocabulary: vocabulary,
                                                         snippets: snippets, budget: PhoneDictation.keyboardBudget)
                    out = await PhoneDictation.clean(request, budget: PhoneDictation.keyboardBudget)
                }
                let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let polishing = later != nil && !text.isEmpty
                let polishJob = later
                let info = FlowInfo(app: category == .other ? "Verbatim" : "Keyboard", bundleID: nil, category: category, style: .casual,
                                    level: level.rawValue, raw: raw, pasted: text, pastedOK: !text.isEmpty)
                await MainActor.run {
                    let total = Date().timeIntervalSince(t0)
                    Log.note("keyboard dictation \(String(format: "%.1f", duration)) s → words in \(String(format: "%.2f", heard.timeIntervalSince(t0))) s, text in \(String(format: "%.2f", total)) s (\(out.cleaned ? "model" : "rules")\(out.note.map { ": " + $0 } ?? ""))\(total > 1.5 ? " — over the 1.5 s target" : "")\(polishing ? "; polishing in the background" : "")")
                    // The model is loaded and warm now, whatever loaded it.
                    if settings.engineId == "fluid" { self.warmedModel = Engines.fluidModel(settings.model) }
                    self.setEngineReady(true)
                    self.noteDictation(words: text.split(whereSeparator: { $0.isWhitespace }).count)
                    // Before the text: the keyboard reads this when it inserts, to know a polished version is coming.
                    if polishing { self.defaults?.set(id.uuidString, forKey: KeyboardBridge.Key.polishing) }
                    self.deliver(id, text: text, raw: raw)
                    if !text.isEmpty {
                        self.save(dictation: id, samples: samples, duration: duration, original: original, fixed: fixed, corrections: corrections,
                                  engine: result.engine, model: result.model, info: info, cleaned: out.cleaned)
                    } else {
                        // As on the Mac: the audio stays in Dictations as "Nothing heard", with Retry.
                        self.saveUnfinished(samples: samples, duration: duration, title: Self.nothingHeardTitle, error: Self.nothingHeardError)
                    }
                    if polishing, let polishJob { self.awaitPolish(id, inserted: text, started: t0, polishJob) }
                }
            } catch {
                Log.note("keyboard dictation: transcription failed: \(error)")
                await MainActor.run {
                    self.write(.failed, for: id, message: "Transcription failed: \(error.localizedDescription)")
                    if ribbon { self.showResult(.failed, for: id, words: 0, message: "Didn't finish writing. The audio is saved in Dictations.") }
                    // The audio is kept in Dictations as a failed dictation, with Retry, like the Mac's.
                    self.saveUnfinished(samples: samples, duration: duration, title: "Dictation", error: error.localizedDescription)
                }
            }
        }
    }

    static let nothingHeardTitle = "Nothing heard"
    static let nothingHeardError = "Nothing heard. Choose Retry to transcribe it anyway."

    /// A dictation that didn't become text (transcription failed, or nothing was heard): its audio is written to a WAV
    /// and kept in Dictations as failed, so Retry can transcribe it. Ends the background task when it's saved.
    private func saveUnfinished(samples: [Float], duration: Double, title: String, error: String) {
        guard let app, !samples.isEmpty else { endBackground(); return }
        let url = app.store.newRecordingURL()
        Task.detached(priority: .utility) {
            let wave = Self.envelope(samples)
            let ok = (try? Self.writeWAV(samples, to: url)) != nil
            await MainActor.run {
                defer { self.endBackground() }
                guard ok, let name = app.store.adoptRecording(url) else {
                    // Left in the recordings folder (if it was written), so launch recovery still finds it.
                    Log.note("keyboard dictation: couldn't save the audio of a dictation that didn't finish"); return
                }
                var t = Transcript(title: title, source: .dictation, sourceLabel: "Dictation · Keyboard", duration: duration,
                                   audioFileName: name, model: "")
                t.kind = .dictation
                t.waveform = wave
                t.status = .failed
                t.error = error
                app.store.add(t)
                Log.note("keyboard dictation: kept in Dictations as “\(title)” (\(String(format: "%.1f", duration)) s)")
            }
        }
    }

    /// The hot path: Parakeet reads the samples straight from memory, with silence trimming and Dictionary boosting
    /// (`FluidEngine.transcribeSession`). Other engines get a temporary file.
    nonisolated private static func transcribe(_ samples: [Float], engineId: String, model: String,
                                               ranked: [(text: String, aliases: [String])]) async throws -> EngineResult {
        if engineId == "fluid" {
            return try await FluidEngine.shared.transcribeSession(samples: samples, model: model, ranked: ranked,
                                                                   fallbackTrim: { SessionCapture.trimQuiet($0) })
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWAV(samples, to: url)
        return try await Engines.engine(for: engineId).transcribe(url: url, model: model, progress: { _ in })
    }

    private func deliver(_ id: UUID, text: String, raw: String) {
        if let d = defaults {
            d.set(text, forKey: KeyboardBridge.Key.text)
            d.set(raw, forKey: KeyboardBridge.Key.raw)
        }
        if !text.isEmpty {
            lastTake = (text, Date())
            if endedNotice != nil { endedNotice?.lastTake = text; endedNotice?.lastTakeAt = Date() }
        }
        // The keyboard's Recent row, and the clipboard, before the keyboard hears it's done.
        if !text.isEmpty, ribbonTakes.contains(id) {
            deliverRibbon(id, text: text)
        } else if !text.isEmpty {
            KeyboardBridge.addRecent(id: id, text: text)
            if KeyboardBridge.alwaysCopy { copyForKeyboard(id, text) }
        } else if ribbonTakes.contains(id) {
            showResult(.failed, for: id, words: 0, message: Ribbon.nothingHeardMessage)
        }
        write(text.isEmpty ? .failed : .done, for: id, message: text.isEmpty ? "No words were heard." : nil)
    }

    /// A ribbon take's words (owner decision, `Ribbon.route`): into the text field when the Verbose keyboard is on
    /// screen and showing this take, with the clipboard left alone; otherwise on the clipboard. Always in the Recent
    /// row. A clipboard write that didn't take is reported in the Live Activity and retried when Verbose opens.
    private func deliverRibbon(_ id: UUID, text: String) {
        KeyboardBridge.addRecent(id: id, text: text)
        let d = defaults
        let route = Ribbon.route(keyboardVisibleAt: d?.double(forKey: KeyboardBridge.Key.keyboardVisibleAt) ?? 0,
                                 keyboardShowsTake: KeyboardBridge.uuid(KeyboardBridge.Key.seenID) == id,
                                 now: Date().timeIntervalSince1970)
        // Before the text is marked done, so a keyboard that appears later doesn't insert it too.
        if route == .clipboard { d?.set(id.uuidString, forKey: KeyboardBridge.Key.routedAway) }
        var copied: Bool? = nil
        if Ribbon.copies(route, alwaysCopy: KeyboardBridge.alwaysCopy) {
            copied = copyRibbon(id, text)
            // The keyboard copies when the app couldn't, but only for the keyboard route; on the clipboard route
            // the failure is the result.
            if route == .keyboard { copied = nil }
        }
        let words = Ribbon.wordCount(text)
        Log.note("ribbon: take delivered to the \(route == .keyboard ? "keyboard" : "clipboard") (\(words) words)\(copied == false ? "; the clipboard write didn't take" : "")")
        showResult(Ribbon.resultPhase(route, copied: copied), for: id, words: words,
                   message: copied == false ? Ribbon.copyFailedMessage : nil)
    }

    /// Puts a ribbon take on the clipboard. False when iOS didn't take the write (it can refuse in the
    /// background); the text then waits in `pendingCopy` for Verbose to open.
    private func copyRibbon(_ id: UUID, _ text: String) -> Bool {
        // This iPhone only, for 2 minutes (KeyboardBridge.copyDictation).
        guard KeyboardBridge.copyDictation(text) else { pendingCopy = text; return false }
        copiedChangeCount = UIPasteboard.general.changeCount
        defaults?.set(id.uuidString, forKey: KeyboardBridge.copiedKey)
        pendingCopy = nil
        return true
    }

    /// Verbose came forward with a take that couldn't be copied in the background: copy it now and say so.
    private func copyPending() {
        guard let text = pendingCopy else { return }
        pendingCopy = nil
        KeyboardBridge.copyDictation(text)
        copiedChangeCount = UIPasteboard.general.changeCount
        app?.say("Copied your last take.")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if result?.phase == .failed { result = nil; updateActivity() }
    }

    /// The clipboard's change count after the app last copied a keyboard dictation, so the polished text replaces
    /// only that copy, never something you copied since.
    private var copiedChangeCount: Int?

    /// Settings › Keyboard › Also copy each dictation: the app puts the text on the clipboard and notes which
    /// dictation it copied. If the write didn't take, the keyboard copies it instead (with Full Access).
    private func copyForKeyboard(_ id: UUID, _ text: String) {
        guard KeyboardBridge.copyDictation(text) else { Log.note("keyboard dictation: couldn't copy from the app; the keyboard will"); return }
        copiedChangeCount = UIPasteboard.general.changeCount
        defaults?.set(id.uuidString, forKey: KeyboardBridge.copiedKey)
    }

    /// After the text is in: writes the audio file and adds the dictation to the library, off the hot path.
    private func save(dictation: UUID, samples: [Float], duration: Double, original: [Segment], fixed: [Segment], corrections: [Correction],
                      engine: String, model: String, info: FlowInfo, cleaned: Bool) {
        guard let app else { endBackground(); return }
        let url = app.store.newRecordingURL()
        Task.detached(priority: .utility) {
            let wave = Self.envelope(samples)
            let ok = (try? Self.writeWAV(samples, to: url)) != nil
            await MainActor.run {
                defer { self.endBackground() }
                guard ok, let name = app.store.adoptRecording(url) else { Log.note("keyboard dictation: couldn't save the audio"); return }
                var t = Transcript(title: Transcript.titleFrom(fixed) ?? "Dictation", source: .dictation, sourceLabel: "Dictation · Keyboard",
                                   duration: duration, audioFileName: name, model: model)
                // The keyboard's dictation ID, so deleting the dictation also removes it from the keyboard's Recent row.
                if app.store.transcript(dictation) == nil { t.id = dictation }
                t.kind = .dictation
                t.original = original
                t.segments = fixed
                t.corrections = corrections
                t.engine = engine
                t.flow = info
                // As on the Mac: the cleaned-up text is the dictation's document.
                if cleaned, info.pasted != info.raw { t.document = info.pasted; t.documentLevel = info.level.capitalized }
                t.waveform = wave
                t.status = .ready
                app.store.add(t)
                self.savedTranscripts[dictation] = t.id
                if let polished = self.pendingPolish.removeValue(forKey: dictation) { self.storePolished(polished, transcript: t.id) }
            }
        }
    }

    // MARK: Polish after inserting

    /// Starts the cleanup with the long `budget` and waits for it up to the keyboard's budget. In time: its result,
    /// and nothing later. Otherwise the rule-based text now, and the cleanup still running for the polished text.
    nonisolated private static func cleanThenPolish(_ r: FlowCleanup.Request, budget: Double) async -> (FlowCleanup.Result, Task<FlowCleanup.Result, Never>?) {
        let job = Task.detached(priority: .userInitiated) { await PhoneDictation.clean(r, budget: budget) }
        // Racing a wait on the job, not the job itself: when the race gives up, the job keeps running.
        if let done = await FluidEngine.race(seconds: PhoneDictation.keyboardBudget + 0.15, { await job.value }) { return (done, nil) }
        return (FlowCleanup.Result(text: FlowCleanup.rulesOnly(r), cleaned: false, note: "Inserted the rule-based text; polishing in the background"), job)
    }

    /// Waits for the background cleanup, then hands its text to the keyboard and updates the saved dictation.
    private func awaitPolish(_ id: UUID, inserted: String, started: Date, _ later: Task<FlowCleanup.Result, Never>) {
        let task = PolishBackgroundTask(name: "Keyboard polish")
        Task { @MainActor in
            let out = await later.value
            defer { task.end() }
            let polished = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
            guard let d = defaults else { return }
            guard out.cleaned, !polished.isEmpty, polished != inserted else {
                Log.note("keyboard polish: nothing to swap after \(seconds) s (\(out.cleaned ? "same text" : out.note ?? "the model's text wasn't used"))")
                if d.string(forKey: KeyboardBridge.Key.polishing) == id.uuidString { d.removeObject(forKey: KeyboardBridge.Key.polishing) }
                KeyboardBridge.post(KeyboardBridge.Note.state)
                return
            }
            Log.note("keyboard polish: polished text ready after \(seconds) s; handing it to the keyboard")
            // The text first, then the id the keyboard looks for, then the pending flag (only if it's still ours).
            d.set(inserted, forKey: KeyboardBridge.Key.polishedInserted)
            d.set(polished, forKey: KeyboardBridge.Key.polishedText)
            d.set(id.uuidString, forKey: KeyboardBridge.Key.polishedID)
            if d.string(forKey: KeyboardBridge.Key.polishing) == id.uuidString { d.removeObject(forKey: KeyboardBridge.Key.polishing) }
            KeyboardBridge.updateRecent(id: id, text: polished)
            // The copy follows the polished text, while the clipboard still holds the copy the app made.
            if KeyboardBridge.alwaysCopy || ribbonTakes.contains(id), d.string(forKey: KeyboardBridge.copiedKey) == id.uuidString,
               let count = copiedChangeCount, UIPasteboard.general.changeCount == count {
                KeyboardBridge.copyDictation(polished)
                copiedChangeCount = UIPasteboard.general.changeCount
            }
            KeyboardBridge.post(KeyboardBridge.Note.state)
            if let t = savedTranscripts[id] { storePolished(polished, transcript: t) } else { pendingPolish[id] = polished }
        }
    }

    /// The saved dictation keeps the polished text, whether or not the keyboard could swap it in.
    private func storePolished(_ text: String, transcript: UUID) {
        app?.store.update(transcript) { t in
            t.flow?.pasted = text
            t.document = text
            t.documentLevel = (t.flow?.level ?? "polished").capitalized
        }
    }

    /// What the keyboard did with the polished text, for the log.
    private func logPolishOutcome() {
        guard let d = defaults, let outcome = d.string(forKey: KeyboardBridge.Key.polishOutcome) else { return }
        d.removeObject(forKey: KeyboardBridge.Key.polishOutcome)
        Log.note("keyboard polish: keyboard " + outcome)
    }

    // MARK: Live words

    private func startLive() {
        clearLive()
        // For the keyboard (Show words as you speak) or the Dynamic Island (Show words in the Dynamic Island).
        guard KeyboardBridge.liveWords || Self.islandWordsOn else { return }
        capture.setLiveTap(live.tap)
        live.start(format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SessionCapture.sampleRate, channels: 1, interleaved: false))
    }

    private func stopLive() {
        capture.setLiveTap(nil)
        live.stop()
        clearLive()
    }

    /// Writes the live words for the keyboard when they changed. Called with the meter, so at most 10 times a second.
    private func writeLive(_ d: UserDefaults) {
        let w = live.words
        guard w != liveWritten else { return }
        liveWritten = w
        // Running only for the Dynamic Island: the keyboard doesn't show them.
        guard KeyboardBridge.liveWords else { return }
        // The end is enough: the keyboard shows two lines.
        let shown = w.tail(160)
        d.set(shown.settled, forKey: KeyboardBridge.Key.liveSettled)
        d.set(shown.volatile, forKey: KeyboardBridge.Key.liveVolatile)
    }

    private func clearLive() {
        liveWritten = LiveWords()
        defaults?.removeObject(forKey: KeyboardBridge.Key.liveSettled)
        defaults?.removeObject(forKey: KeyboardBridge.Key.liveVolatile)
    }

    // MARK: Session lifetime

    /// Resets the idle timeout (a dictation, or a new setting).
    private func touch() {
        endsAt = timeoutSeconds > 0 ? lastActivity.addingTimeInterval(TimeInterval(timeoutSeconds)) : nil
        defaults?.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: KeyboardBridge.Key.endsAt)
        updateActivity()
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tickHeartbeat() } }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    private var lastBeat = Date.distantPast

    /// Four times a second: commands (in case a Darwin notification was missed), the idle timeout, and every
    /// 2 seconds the heartbeat the keyboard watches.
    private func tickHeartbeat() {
        guard stage == .on else { return }
        if !paused { capture.checkHealth() }
        guard stage == .on else { return }
        checkCommands()
        checkMailbox()
        guard stage == .on else { return }
        switch Ribbon.endCheck(now: Date(), startedAt: sessionStartedAt, endsAt: endsAt, dictating: dictating, paused: paused) {
        case .idle:
            end(reason: "The session ended after \(Self.label(timeoutSeconds)) without dictation. Tap to start a new one.", restartable: true, screen: false)
            return
        case .cap:
            // A Live Activity lasts at most 8 hours; the microphone is never on without one.
            end(reason: "The session ended after 8 hours, the longest iOS shows it. Tap to start a new one.", restartable: true, screen: false)
            return
        case .keep:
            break
        }
        if Date().timeIntervalSince(lastBeat) >= KeyboardBridge.heartbeatInterval { writeSession() }
    }

    private func writeSession() {
        guard let d = defaults else { return }
        lastBeat = Date()
        d.set(true, forKey: KeyboardBridge.Key.sessionActive)
        d.set(Date().timeIntervalSince1970, forKey: KeyboardBridge.Key.heartbeat)
        d.set(Self.micName(), forKey: KeyboardBridge.Key.micName)
        d.set(PhoneDictation.level.title, forKey: KeyboardBridge.Key.levelLabel)
        KeyboardBridge.post(KeyboardBridge.Note.state)
    }

    /// The capture couldn't keep the microphone (a route change it couldn't recover from): keep what was being
    /// said, then end with the reason, so the keyboard says what happened instead of listening to nothing.
    private func captureFailed(_ message: String) {
        guard stage == .on else { return }
        if dictating { finishDictation() }
        end(reason: message, restartable: true, call: false)
    }

    /// The audio went for good (media services reset, a route that disconnected): keep what was being said, then end.
    private func interrupted(_ reason: String, call: Bool = true) {
        guard stage == .on else { return }
        if dictating { finishDictation() }
        end(reason: reason, restartable: true, call: call)
    }

    /// A call, FaceTime, or Siri began or ended (`Ribbon.audio` decides).
    private func audioEvent(_ event: Ribbon.AudioEvent) {
        guard stage == .on else { return }
        let (next, action) = Ribbon.audio(audioState, event, dictating: dictating)
        audioState = next
        switch action {
        case .pause(let saveTake): pauseForCall(saveTake: saveTake)
        case .reactivate: resumeAfterCall()
        case .resumed, .end, .none: break
        }
    }

    /// The call has the audio: a take in progress is saved as it is, the capture stops, and the keyboard and the
    /// Dynamic Island say "Paused for a call". The session stays on; its idle timer waits.
    private func pauseForCall(saveTake: Bool) {
        Log.note("keyboard session: paused for a call, FaceTime, or Siri\(saveTake ? "; saving the take in progress" : "")")
        if saveTake { finishDictation() }
        unseenSince = nil
        capture.stop()
        paused = true
        defaults?.set(Date().timeIntervalSince1970, forKey: KeyboardBridge.Key.pausedAt)
        KeyboardBridge.post(KeyboardBridge.Note.state)
        updateActivity()
    }

    /// The call ended (with or without `.shouldResume`): turn the audio session and the capture back on, in the
    /// background if Verbose is there (background audio allows it). The idle timer starts over. If iOS refuses,
    /// the session ends with the call message.
    private func resumeAfterCall() {
        var ok = true
        do {
            try startAudio()
        } catch {
            ok = false
            Log.note("keyboard session: couldn't turn the microphone back on after the call: \(error.localizedDescription)")
        }
        let (next, action) = Ribbon.audio(audioState, .reactivated(ok: ok), dictating: dictating)
        audioState = next
        paused = false
        defaults?.set(0.0, forKey: KeyboardBridge.Key.pausedAt)
        switch action {
        case .resumed:
            Log.note("keyboard session: back on after the call (app \(UIApplication.shared.applicationState == .active ? "in front" : "in the background"))")
            lastActivity = Date()
            touch()
            writeSession()
            updateActivity()
        case .end:
            capture.stop()
            end(reason: Ribbon.callEndedMessage, restartable: true, call: true)
        default:
            KeyboardBridge.post(KeyboardBridge.Note.state)
        }
    }

    /// Ends the session: the microphone turns off (the orange dot goes), the Live Activity ends. The speech model
    /// stays loaded until iOS reclaims it or a memory warning releases it. `restartable` (the session ended by
    /// itself: idle, the 8-hour limit, a call it couldn't come back from, a lost microphone): the Live Activity
    /// stays in the Dynamic Island and on the Lock Screen for 15 minutes as "Session ended" with Restart, and with
    /// `screen` (a call or a lost microphone, not idle or the limit) the Session ended screen shows in Verbose too.
    /// Ending it yourself (`restartable: false`) removes everything at once.
    func end(reason: String?, restartable: Bool = false, call: Bool = false, screen: Bool = true) {
        guard stage != .off else { return }
        let restarting = restartable && stage == .on
        if let id = current { capture.cancelTake(); write(.cancelled, for: id); current = nil }
        stopLive()
        unseenSince = nil
        firstTapDictation = nil
        dictating = false
        meter?.invalidate(); meter = nil
        heartbeat?.invalidate(); heartbeat = nil
        capture.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stage = .off
        paused = false
        audioState = .running
        showScreen = false
        needsManualReturn = false
        startSource = nil
        endsAt = nil
        pendingRibbonTake = false
        startedForTake = false
        takeStartedAt = nil
        sessionStartedAt = nil
        if let d = defaults {
            d.set(false, forKey: KeyboardBridge.Key.sessionActive)
            // The format chip goes back to Auto for the next session.
            d.removeObject(forKey: KeyboardBridge.formatKey)
            d.set(0.0, forKey: KeyboardBridge.Key.endsAt)
            d.set(0.0, forKey: KeyboardBridge.Key.pausedAt)
            if let reason { d.set(reason, forKey: KeyboardBridge.Key.endReason) } else { d.removeObject(forKey: KeyboardBridge.Key.endReason) }
        }
        KeyboardBridge.post(KeyboardBridge.Note.state)
        if restarting {
            let why = Ribbon.endedReason(call: call)
            if screen { endedNotice = EndedNotice(reason: why, lastTake: lastTake?.text, lastTakeAt: lastTake?.at) }
            endActivity(ended: screen ? why : (reason?.replacingOccurrences(of: " Tap to start a new one.", with: "") ?? why))
        } else {
            endActivity()
        }
        reloadControl()
    }

    // MARK: Live Activity

    private var activitiesAllowed: Bool {
        !PhoneUITest.enabled && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Returns whether a Live Activity is showing the session.
    @discardableResult
    private func startActivity() -> Bool {
        endedActivity = nil   // ended below with every other stale activity
        guard activitiesAllowed else { return false }
        endStaleActivities()
        do {
            let a = try Activity.request(attributes: VerbatimSessionAttributes(), content: ActivityContent(state: activityState(), staleDate: nil))
            activity = a
            watch(a)
            return true
        } catch {
            Log.note("Live Activity unavailable: \(error)")
            return false
        }
    }

    /// The session never outlives its Live Activity: when iOS ends it (the 8-hour limit) or you dismiss it from
    /// the Lock Screen, the session ends too, so the microphone is never on without it showing.
    private func watch(_ a: Activity<VerbatimSessionAttributes>) {
        activityWatch?.cancel()
        activityWatch = Task { [weak self] in
            for await state in a.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                guard let self, self.activity?.id == a.id, self.stage == .on else { return }
                Log.note("keyboard session: the Live Activity \(state == .ended ? "ended" : "was dismissed"); ending the session")
                self.activity = nil
                self.end(reason: "The session ended with its Live Activity. Tap to start a new one.")
                return
            }
        }
    }

    /// What the ribbon shows: listening, writing, a result for a few seconds, or ready. Counts and times only.
    private var ribbonPhase: Ribbon.Phase {
        if paused { return .paused }
        if dictating { return .listening }
        if !transcribingTakes.isEmpty { return .transcribing }
        if let r = result, r.until > Date() { return r.phase }
        return .ready
    }

    private func activityState() -> VerbatimSessionAttributes.ContentState {
        let phase = ribbonPhase
        let shownResult = phase == result?.phase ? result : nil
        return VerbatimSessionAttributes.ContentState(listening: dictating, endsAt: endsAt, phase: phase, sessionStartedAt: sessionStartedAt,
                                                      takeStartedAt: dictating ? takeStartedAt : nil,
                                                      level: dictating ? min(1, max(0, Double(capture.level))) : 0,
                                                      words: shownResult?.words ?? 0, takes: takes, message: shownResult?.message,
                                                      target: activityTarget,
                                                      liveWords: dictating && Self.islandWordsOn ? Ribbon.islandWords(live.words.text) : nil,
                                                      gettingReady: dictating && !engineReady ? true : nil)
    }

    /// Settings › Keyboard › Show words in the Dynamic Island (off unless you turn it on).
    static var islandWordsOn: Bool { KeyboardBridge.defaults?.bool(forKey: Ribbon.islandWordsKey) ?? false }

    /// The app the words go to, for "Into Messages": the app the Verbose keyboard is on screen in, or the one the
    /// session started from, when the build can read it and it's a known app. Nil (the Verbose keyboard) in App
    /// Store builds.
    private var activityTarget: String? {
        guard Distribution.current.readsHostApp else { return nil }
        let up = Ribbon.keyboardUp(visibleAt: defaults?.double(forKey: KeyboardBridge.Key.keyboardVisibleAt) ?? 0, now: Date().timeIntervalSince1970)
        let h = (up ? defaults?.string(forKey: KeyboardBridge.Key.visibleHost) : nil) ?? host
        let name = Ribbon.target(hostName: KeyboardFormat.classify(host: h)?.name, appStore: Distribution.isAppStore)
        return name == Ribbon.keyboardTarget ? nil : name
    }

    private func updateActivity() {
        guard let a = activity else { return }
        let state = activityState()
        Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Copied, Inserted, or a failure for a ribbon take. A result shows for `Ribbon.resultHold` seconds; a failed
    /// copy stays until Verbose opens or the next take starts, so it's never missed. The success haptic plays only
    /// with Verbose in front (in-app).
    private func showResult(_ phase: Ribbon.Phase, for id: UUID, words: Int, message: String? = nil) {
        transcribingTakes.remove(id)
        let sticky = phase == .failed && message == Ribbon.copyFailedMessage
        let until = sticky ? Date.distantFuture : Date().addingTimeInterval(Ribbon.resultHold)
        result = (phase, words, message, until)
        updateActivity()
        if phase == .copied || phase == .inserted, UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        guard !sticky else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Ribbon.resultHold + 0.05) { [weak self] in
            guard let self, let r = self.result, r.until <= Date() else { return }
            self.result = nil
            self.updateActivity()
        }
    }

    /// Ends the Live Activity. With `ended` (the session ended by itself), it shows "Session ended" with Restart
    /// for `Ribbon.endedHold` (15 minutes) in the Dynamic Island and on the Lock Screen.
    ///
    /// iOS takes an ended Live Activity out of the Dynamic Island at once (only the Lock Screen keeps it), so the
    /// activity stays running, updated to the ended state with a stale date 15 minutes out, and is ended when that
    /// time comes: by a timer while Verbose still runs, when Verbose next comes to the foreground or launches
    /// (`endStaleActivities`), or when a new session starts. If iOS suspends Verbose first, it stays up longer than
    /// 15 minutes, until one of those (or until you swipe it away on the Lock Screen).
    private func endActivity(ended: String? = nil) {
        activityWatch?.cancel()
        activityWatch = nil
        guard let a = activity else { return }
        activity = nil
        if let ended {
            let until = Date().addingTimeInterval(Ribbon.endedHold)
            let state = VerbatimSessionAttributes.ContentState(listening: false, endsAt: nil, phase: .ended, takes: takes, message: ended)
            Task { await a.update(ActivityContent(state: state, staleDate: until)) }
            endedActivity = (a, until)
            DispatchQueue.main.asyncAfter(deadline: .now() + Ribbon.endedHold + 1) { [weak self] in self?.endExpiredEndedActivity() }
        } else {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ends the kept Session ended activity once its 15 minutes are up.
    private func endExpiredEndedActivity() {
        guard let kept = endedActivity, Date() >= kept.until else { return }
        endedActivity = nil
        Task { await kept.activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// The Control Center switch follows the session (iOS 18).
    private func reloadControl() {
        guard !PhoneUITest.enabled else { return }
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: "co.stumpandroot.verbatim.ios.control.startSession")
        }
    }

    // MARK: Recording ribbon

    /// A command from the widget's process, read from the App Group (never from the Darwin notification itself):
    /// acted on once, only when it's fresh.
    private func checkMailbox() {
        guard let name = KeyboardBridge.takeCommand(consumed: &consumedCommands), let c = RibbonCommand(rawValue: name) else { return }
        Log.note("ribbon: \(c.rawValue) from the widget's process")
        switch c {
        case .toggle, .finish, .cancel, .endSession: _ = handleRibbon(c)
        case .startSession, .restartSession: break   // needs Verbose's process; the intent does that itself
        }
    }

    /// Starts a take, or stops the running one (the Action button, Shortcuts, the Lock Screen's Dictate). With no
    /// session it returns `.needsForeground` and touches nothing: the intent then brings Verbose forward.
    @discardableResult
    func toggleTake(source: TakeSource) -> TakeOutcome {
        let state: Ribbon.TakeState = current.map { .listening($0) } ?? .idle
        return run(Ribbon.decide(state, .toggle, sessionOn: stage == .on), source: source)
    }

    /// Starts a take with its own dictation ID (no keyboard asked for it). The keyboard picks it up when it's on
    /// screen (`KeyboardBridge.Key.ribbonID`).
    @discardableResult
    func startTake(source: TakeSource = .app) -> TakeOutcome {
        let state: Ribbon.TakeState = current.map { .listening($0) } ?? .idle
        let action = Ribbon.decide(state, .start, sessionOn: stage == .on)
        guard action == .begin else { return run(action, source: source) }
        guard !paused else { return .ignored }
        let id = UUID()
        ribbonTakes.insert(id)
        // Before the take is written as listening, so a keyboard on screen sees it's a ribbon take.
        defaults?.set(id.uuidString, forKey: KeyboardBridge.Key.ribbonID)
        Log.note("ribbon: take started (\(source.rawValue))")
        beginDictation(id)
        return .started
    }

    /// Done: stops the running take (a ribbon take or the keyboard's) and delivers the words.
    @discardableResult
    func stopTake() -> TakeOutcome {
        let state: Ribbon.TakeState = current.map { .listening($0) } ?? .idle
        return run(Ribbon.decide(state, .stop, sessionOn: stage == .on), source: .liveActivity)
    }

    /// Cancel: drops the running take. Nothing is saved.
    @discardableResult
    func cancelTake() -> TakeOutcome {
        let state: Ribbon.TakeState = current.map { .listening($0) } ?? .idle
        return run(Ribbon.decide(state, .cancel, sessionOn: stage == .on), source: .liveActivity)
    }

    private func run(_ action: Ribbon.TakeAction, source: TakeSource) -> TakeOutcome {
        switch action {
        case .needsForeground: return .needsForeground
        case .begin:
            // Paused for a call: the microphone is iOS's until the call ends.
            guard !paused else { return .ignored }
            return startTake(source: source)
        case .finish(let id):
            guard current == id else { return .ignored }
            Log.note("ribbon: take stopped (\(source.rawValue))")
            finishDictation()
            return .stopped
        case .cancel(let id):
            guard current == id else { return .ignored }
            cancelDictation()
            return .cancelled
        case .none: return .ignored
        }
    }

    /// An intent's command, in this process.
    private func handleRibbon(_ c: RibbonCommand) -> RibbonOutcome {
        func map(_ o: TakeOutcome) -> RibbonOutcome {
            switch o {
            case .started, .stopped, .cancelled: return .done
            case .ignored: return .ignored
            case .needsForeground: return .needsForeground
            }
        }
        switch c {
        case .toggle: return map(toggleTake(source: .intent))
        case .finish: return map(stopTake())
        case .cancel: return map(cancelTake())
        case .endSession:
            guard stage != .off else { return .ignored }
            end(reason: nil)
            return .done
        case .startSession:
            return stage == .off ? .needsForeground : .done
        case .restartSession:
            return restartInPlace() ? .done : .needsForeground
        }
    }

    /// Settings › Action button's choice, with Verbose in front.
    private func runAction(_ choice: Ribbon.ActionChoice) {
        guard let app else { return }
        switch choice {
        case .dictate:
            // From the Action button's audio recording intent: the Live Activity before the microphone.
            if stage == .on { toggleTake(source: .intent) } else { startFromOutside(.shortcut, take: true, recordingIntent: true) }
        case .voiceNote:
            app.requestRecord()
        case .recordOrMark:
            // While something records, a press marks a moment; otherwise it starts a voice note.
            if !app.markMoment(source: .actionButton) { app.requestRecord() }
        case .captions:
            app.requestCaptions()
        case .whatsPlaying:
            // The sheet asks iOS for its broadcast picker as soon as it shows; you tap Start Broadcast.
            app.playingSheetStartsPicker = true
            app.showPlayingSheet = true
        case .quickCapture:
            // New thought: the recorder opens on a thought (or a running one comes back).
            app.requestThought()
        }
    }

    private func endStaleActivities() {
        guard !PhoneUITest.enabled else { return }
        for a in Activity<VerbatimSessionAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: Writing

    private func write(_ phase: KeyboardBridge.Phase, for id: UUID, message: String? = nil) {
        guard let d = defaults else { return }
        d.set(id.uuidString, forKey: KeyboardBridge.Key.dictation)
        d.set(phase.rawValue, forKey: KeyboardBridge.Key.phase)
        if let message { d.set(message, forKey: KeyboardBridge.Key.message) } else { d.removeObject(forKey: KeyboardBridge.Key.message) }
        if phase != .listening { d.set(0.0, forKey: KeyboardBridge.Key.level) }
        KeyboardBridge.post(KeyboardBridge.Note.state)
    }

    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Keyboard dictation") { [weak self] in
            MainActor.assumeIsolated { self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    // MARK: Helpers

    static func label(_ seconds: Int) -> String {
        timeoutChoices.first(where: { $0.seconds == seconds })?.label ?? "\(seconds / 60) minutes"
    }

    /// "iPhone Microphone", "AirPods Pro", …
    static func micName() -> String {
        let name = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? ""
        return name.isEmpty ? "iPhone Microphone" : name
    }

    /// 16-bit, 16 kHz mono WAV, the same format as Verbatim's other recordings.
    nonisolated static func writeWAV(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SessionCapture.sampleRate, channels: 1, interleaved: false)!
        let chunk = 16_000 * 10
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            b.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                b.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            try file.write(from: b)
            i += n
        }
    }

    /// 120 RMS buckets in 0…1 for the library thumbnail (as `Waveform.envelope` makes from a file).
    nonisolated static func envelope(_ samples: [Float], buckets: Int = 120) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let per = max(1, samples.count / buckets)
        var out: [Float] = []
        var i = 0
        while i < samples.count, out.count < buckets {
            let end = min(samples.count, i + per)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            let rms = sqrt(sum / Float(end - i))
            out.append(min(1, pow(max(0, rms - 0.004) * 6, 0.5)))
            i = end
        }
        return out
    }
}


/// A UIKit background task that ends once, from `end()` or when iOS's time runs out.
@MainActor
private final class PolishBackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
