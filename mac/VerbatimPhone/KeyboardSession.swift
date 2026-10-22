import SwiftUI
import AVFoundation
import ActivityKit
import UIKit

/// The app's half of keyboard dictation (see `KeyboardBridge` for the whole flow).
///
/// A *session* keeps the microphone open and the speech model loaded so the keyboard can dictate without
/// switching apps. It starts when the keyboard opens `verbatim://session?start=1…` (the app comes forward for
/// under a second, then switches back to the app you came from). With Start dictating when you come back on, the
/// link names a dictation too, and the app begins it as soon as the microphone is on. The session ends after an
/// idle timeout, from the Live Activity or Settings › Keyboard, or for a call. Each dictation is marked in the
/// running capture, transcribed straight away with the warm model (not through the transcription queue), handed
/// to the keyboard, and then saved as a dictation in Library › Dictations.
@MainActor
final class KeyboardSession: ObservableObject {
    enum Stage: Equatable {
        case off
        /// Asking for the microphone and starting the capture (the app is in front).
        case starting
        case on
    }

    /// Settings › Keyboard › End the session after. 0 = until you end it.
    static let timeoutKey = "keyboard.sessionTimeout"
    static let timeoutChoices: [(seconds: Int, label: String)] = [(60, "1 minute"), (300, "5 minutes"), (900, "15 minutes"), (0, "Until I end it")]

    @Published private(set) var stage: Stage = .off
    /// The start screen over the app: shown while starting, and when switching back to your app didn't work.
    @Published var showScreen = false
    /// True when Verbatim couldn't switch back by itself, so the screen asks you to swipe back.
    @Published private(set) var needsManualReturn = false
    @Published private(set) var dictating = false {
        didSet { if dictating != oldValue { PhoneDucker.set(dictating) } }   // Lower other audio while listening.
    }
    @Published private(set) var endsAt: Date? = nil
    @Published var timeoutSeconds: Int = UserDefaults.standard.object(forKey: KeyboardSession.timeoutKey) as? Int ?? 300 {
        didSet {
            UserDefaults.standard.set(timeoutSeconds, forKey: Self.timeoutKey)
            if stage == .on { touch() }
        }
    }

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
    /// Live words for the keyboard while you talk (Settings › Keyboard › Show words as you speak).
    private let live = LiveTranscriber()
    private var liveWritten = LiveWords()
    /// Polish after inserting: the saved dictation for each keyboard dictation, and polished text that arrived
    /// before its dictation was saved.
    private var savedTranscripts: [UUID: UUID] = [:]
    private var pendingPolish: [UUID: String] = [:]

    init(app: PhoneState) {
        self.app = app
        // A session never outlives the app: a Live Activity left by a crash or a force quit goes now.
        endStaleActivities()
        if let d = defaults, d.bool(forKey: KeyboardBridge.Key.sessionActive) {
            d.set(false, forKey: KeyboardBridge.Key.sessionActive)
            KeyboardBridge.post(KeyboardBridge.Note.state)
        }
    }

    private var defaults: UserDefaults? { KeyboardBridge.defaults }
    var isOn: Bool { stage == .on }

    // MARK: Start

    /// Handles a link the app was opened with. True when it was a keyboard session link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = KeyboardBridge.sessionLink(in: url) else { return false }
        start(request: link.request, host: link.host, dictation: link.dictation)
        return true
    }

    func start(request r: UUID?, host h: String?, dictation d: UUID? = nil) {
        guard let app else { return }
        request = r
        host = h
        firstTapDictation = d
        let hostNote = h.map { "names the host app " + $0 } ?? "names no host app (the keyboard couldn't read it)"
        let dictationNote = d == nil ? "" : ", starts a dictation"
        Log.note("keyboard session: link " + hostNote + dictationNote)
        observe()
        if stage == .on {
            // Already on (a second tap, or a keyboard that missed the heartbeat): start the dictation, then go back.
            beginFirstTapDictation()
            answer(ok: true)
            goBack()
            return
        }
        guard stage == .off else { return }
        guard !app.recorder.isRecording else {
            answer(ok: false, "Verbatim is recording a voice memo. Stop it first.")
            app.say("Stop the recording first to use the keyboard.")
            return
        }
        stage = .starting
        needsManualReturn = false
        app.showOnboarding = false
        showScreen = true
        defaults?.removeObject(forKey: KeyboardBridge.Key.endReason)
        defaults?.set(PhoneDictation.level.title, forKey: KeyboardBridge.Key.levelLabel)
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                guard self.stage == .starting else { return }
                if ok { self.beginCapture() } else {
                    self.stage = .off
                    self.showScreen = false
                    self.answer(ok: false, "Microphone access is off. Turn it on in Settings › Verbatim.")
                    app.say("Microphone access is off. Turn it on in Settings › Verbatim.")
                }
            }
        }
    }

    private func beginCapture() {
        do {
            let s = AVAudioSession.sharedInstance()
            // Mixes with other audio, so a session doesn't stop your music or podcast.
            try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            // No pinned input from an earlier recording: the system's current microphone (AirPods when they're in,
            // the iPhone's otherwise), and the capture follows it when that changes.
            try? s.setPreferredInput(nil)
            try s.setActive(true)
            capture.onFailure = { [weak self] message in
                MainActor.assumeIsolated { self?.captureFailed(message) }
            }
            try capture.start()
        } catch {
            capture.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            stage = .off
            showScreen = false
            answer(ok: false, "Couldn't turn on the microphone: \(error.localizedDescription)")
            app?.say("Couldn't turn on the microphone.")
            return
        }
        stage = .on
        lastActivity = Date()
        // A start command left from before this launch isn't for this session.
        if let old = KeyboardBridge.uuid(KeyboardBridge.Key.startID), old != firstTapDictation { handled.insert(old) }
        touch()
        writeSession()
        // Listening before the keyboard hears the session is on, so it shows the dictation the moment you're back.
        beginFirstTapDictation()
        answer(ok: true)
        startHeartbeat()
        startActivity()
        warmModel()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Back to your app as soon as the capture is running. A short beat lets the screen draw first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.goBack() }
    }

    /// Loads the speech model and runs one warm-up inference, so the first dictation pays nothing for it. Also
    /// starts loading the speech detector (silence trimming), the vocabulary booster for your Dictionary words,
    /// and Apple's language model for cleanup, none of which a dictation ever waits for.
    private func warmModel() {
        FlowCleanup.prewarm(level: PhoneDictation.level)
        // Live words: asks for Apple's on-device speech model to be installed. Never prompts for permission here.
        if KeyboardBridge.liveWords { live.prepare() }
        guard let app else { return }
        let s = app.jobSettings()
        guard s.engineId == "fluid" else { return }
        let model = s.model
        let terms = boostTerms()
        Task.detached(priority: .utility) { await FluidEngine.shared.prewarm(model: model, boostTerms: terms, dictation: true) }
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
    static func returnToHostApp(linkHost: String?) -> ReturnResult {
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
    }

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

    // MARK: Dictation (no app switch)

    private func observe() {
        guard !observing else { return }
        observing = true
        KeyboardBridge.observe(KeyboardBridge.Note.command) { [weak self] in self?.checkCommands() }
        SessionEndSignal.handler = { [weak self] in self?.end(reason: nil) }
        let endNote = SessionEndSignal.note
        KeyboardBridge.observe(endNote) { [weak self] in self?.end(reason: nil) }
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self.interrupted("The session ended for a call or another app's audio. Tap to start a new one.")
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted("The session ended. Tap to start a new one.") }
        })
        observers.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(reason: "Verbatim was closed. Tap to start a new session.") }
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
        guard stage == .on else { return }
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
        checkCommands()
        if dictating, seconds >= KeyboardBridge.maxSeconds { finishDictation() }
        // A first-tap dictation nobody came back to: stop listening after a minute.
        if dictating, let since = unseenSince, let id = current {
            if KeyboardBridge.uuid(KeyboardBridge.Key.seenID) == id {
                unseenSince = nil
            } else if KeyboardBridge.shouldStopUnseenTake(startedAt: since, seen: false, now: Date()) {
                Log.note("keyboard session: no keyboard showed the first-tap dictation within \(Int(KeyboardBridge.unseenTakeLimit)) s; stopping it")
                cancelDictation(message: "Verbatim stopped listening because you didn't come back within a minute. Tap the record button to dictate.")
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
        touch()
        updateActivity()
        let duration = Double(samples.count) / SessionCapture.sampleRate
        guard duration >= 0.4 else { write(.failed, for: id, message: "No words were heard."); return }
        write(.transcribing, for: id)
        beginBackground()
        let settings = app.jobSettings()
        let dictionary = settings.applyDictionary ? app.store.dictionary : []
        let ranked = rankedBoostTerms()
        let vocabulary = dictionary.filter { $0.enabled && $0.projectId == nil }.map(\.preferred)
        let snippets = app.store.snippets
        let level = PhoneDictation.level
        let category = PhoneDictation.category(host: host)
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
                    // Before the text: the keyboard reads this when it inserts, to know a polished version is coming.
                    if polishing { self.defaults?.set(id.uuidString, forKey: KeyboardBridge.Key.polishing) }
                    self.deliver(id, text: text, raw: raw)
                    if !text.isEmpty {
                        self.save(dictation: id, samples: samples, duration: duration, original: original, fixed: fixed, corrections: corrections,
                                  engine: result.engine, model: result.model, info: info, cleaned: out.cleaned)
                    } else {
                        self.endBackground()
                    }
                    if polishing, let polishJob { self.awaitPolish(id, inserted: text, started: t0, polishJob) }
                }
            } catch {
                await MainActor.run {
                    self.write(.failed, for: id, message: "Transcription failed: \(error.localizedDescription)")
                    self.endBackground()
                }
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
        // The keyboard's Recent row, and Also copy each dictation, before the keyboard hears it's done.
        if !text.isEmpty {
            KeyboardBridge.addRecent(id: id, text: text)
            if KeyboardBridge.alwaysCopy { copyForKeyboard(id, text) }
        }
        write(text.isEmpty ? .failed : .done, for: id, message: text.isEmpty ? "No words were heard." : nil)
    }

    /// The clipboard's change count after the app last copied a keyboard dictation, so the polished text replaces
    /// only that copy, never something you copied since.
    private var copiedChangeCount: Int?

    /// Settings › Keyboard › Also copy each dictation: the app puts the text on the clipboard and notes which
    /// dictation it copied. If the write didn't take, the keyboard copies it instead (with Full Access).
    private func copyForKeyboard(_ id: UUID, _ text: String) {
        let pb = UIPasteboard.general
        let before = pb.changeCount
        pb.string = text
        guard pb.changeCount != before else { Log.note("keyboard dictation: couldn't copy from the app; the keyboard will"); return }
        copiedChangeCount = pb.changeCount
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
            if KeyboardBridge.alwaysCopy, d.string(forKey: KeyboardBridge.copiedKey) == id.uuidString,
               let count = copiedChangeCount, UIPasteboard.general.changeCount == count {
                UIPasteboard.general.string = polished
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
        guard KeyboardBridge.liveWords else { return }
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
        capture.checkHealth()
        guard stage == .on else { return }
        checkCommands()
        if !dictating, let e = endsAt, Date() >= e {
            end(reason: "The session ended after \(Self.label(timeoutSeconds)) without dictation. Tap to start a new one.")
            return
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
        end(reason: message)
    }

    /// A call or another app took the audio: keep what was being said, then end.
    private func interrupted(_ reason: String) {
        guard stage == .on else { return }
        if dictating { finishDictation() }
        end(reason: reason)
    }

    /// Ends the session: the microphone turns off (the orange dot goes), the Live Activity ends. The speech model
    /// stays loaded until iOS reclaims it.
    func end(reason: String?) {
        guard stage != .off else { return }
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
        showScreen = false
        needsManualReturn = false
        endsAt = nil
        if let d = defaults {
            d.set(false, forKey: KeyboardBridge.Key.sessionActive)
            d.set(0.0, forKey: KeyboardBridge.Key.endsAt)
            if let reason { d.set(reason, forKey: KeyboardBridge.Key.endReason) } else { d.removeObject(forKey: KeyboardBridge.Key.endReason) }
        }
        KeyboardBridge.post(KeyboardBridge.Note.state)
        endActivity()
    }

    // MARK: Live Activity

    private var activitiesAllowed: Bool {
        !PhoneUITest.enabled && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private func startActivity() {
        guard activitiesAllowed else { return }
        endStaleActivities()
        let state = VerbatimSessionAttributes.ContentState(listening: false, endsAt: endsAt)
        do {
            activity = try Activity.request(attributes: VerbatimSessionAttributes(), content: ActivityContent(state: state, staleDate: nil))
        } catch {
            Log.note("Live Activity unavailable: \(error)")
        }
    }

    private func updateActivity() {
        guard let a = activity else { return }
        let state = VerbatimSessionAttributes.ContentState(listening: dictating, endsAt: endsAt)
        Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
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
