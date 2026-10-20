import SwiftUI
import AVFoundation
import ActivityKit
import UIKit

/// The app's half of keyboard dictation (see `KeyboardBridge` for the whole flow).
///
/// A *session* keeps the microphone open and the speech model loaded so the keyboard can dictate without
/// switching apps. It starts when the keyboard opens `verbatim://session?start=1…` (the app comes forward for
/// under a second, then switches back to the app you came from), and ends after an idle timeout, from the Live
/// Activity or Settings › Keyboard, or for a call. Each dictation is marked in the running capture, transcribed
/// straight away with the warm model (not through the transcription queue), handed to the keyboard, and then
/// saved as a dictation in Library › Dictations.
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
    @Published private(set) var dictating = false
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
    private var observing = false
    private var observers: [NSObjectProtocol] = []
    private var activity: Activity<VerbatimSessionAttributes>?
    private var background: UIBackgroundTaskIdentifier = .invalid

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
        start(request: link.request, host: link.host)
        return true
    }

    func start(request r: UUID?, host h: String?) {
        guard let app else { return }
        request = r
        host = h
        observe()
        if stage == .on {
            // Already on (a second tap, or a keyboard that missed the heartbeat): just go back.
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
            try s.setActive(true)
            capture.onFailure = { [weak self] in
                MainActor.assumeIsolated { self?.end(reason: "The microphone stopped. Tap to start a new session.") }
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
        touch()
        writeSession()
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
        guard let app else { return }
        let s = app.jobSettings()
        guard s.engineId == "fluid" else { return }
        let model = s.model
        let terms = boostTerms()
        Task.detached(priority: .utility) { await FluidEngine.shared.prewarm(model: model, boostTerms: terms, dictation: true) }
    }

    /// Dictionary words for vocabulary boosting, ranked as on the Mac (newest first, up to 100). Only words for
    /// every transcript: the iPhone has no active project. Empty when Apply Dictionary is off, or when boosting is
    /// turned off (`flow.boost`, the Mac's key; on unless set).
    private func rankedBoostTerms() -> [(text: String, aliases: [String])] {
        guard let app, app.applyDictionary, UserDefaults.standard.object(forKey: "flow.boost") as? Bool ?? true else { return [] }
        return BoostVocabulary.rank(app.store.dictionary, project: nil)
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

    /// Switches back to the app the keyboard was in. If that isn't possible (no bundle ID, or iOS refused), the
    /// screen tells you to swipe back. Never blocks.
    private func goBack() {
        guard let h = host, Self.returnToHostApp(bundleID: h) else { showManualReturn(); return }
        // iOS said yes but Verbatim is still in front a moment later: fall back to the swipe.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.stage == .on, UIApplication.shared.applicationState == .active, self.showScreen else { return }
            self.showManualReturn()
        }
    }

    private func showManualReturn() {
        needsManualReturn = true
        showScreen = true
    }

    /// Opens the app with `bundleID` (the app you were typing in).
    ///
    /// App Review risk: this calls the private `LSApplicationWorkspace.openApplicationWithBundleID:` through the
    /// Objective-C runtime. There is no public API that opens another app by bundle ID. Apple can reject a build
    /// that uses it under guideline 2.5.1 (public APIs only), and an iOS release can make it fail or return false.
    /// Everything that depends on it goes through this one function; returning false shows the "swipe right along
    /// the bottom edge" screen instead, so deleting the body (`return false`) is a safe App Store fallback.
    static func returnToHostApp(bundleID: String) -> Bool {
        guard !PhoneUITest.enabled,
              let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return false }
        let workspaceSel = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: workspaceSel),
              let workspace = cls.perform(workspaceSel)?.takeUnretainedValue() as? NSObject else { return false }
        let openSel = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSel) else { return false }
        typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let open = unsafeBitCast(workspace.method(for: openSel), to: Open.self)
        return open(workspace, openSel, bundleID as NSString)
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

    private func beginDictation(_ id: UUID) {
        if current != nil { cancelDictation() }
        handled.insert(id)
        current = id
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
        KeyboardBridge.post(KeyboardBridge.Note.state)
        checkCommands()
        if dictating, seconds >= KeyboardBridge.maxSeconds { finishDictation() }
    }

    private func cancelDictation() {
        guard let id = current else { return }
        capture.cancelTake()
        current = nil
        dictating = false
        meter?.invalidate(); meter = nil
        lastActivity = Date()
        touch()
        write(.cancelled, for: id)
        updateActivity()
    }

    /// Done: stops the mark, transcribes right away on a high-priority task with the warm model (not through the
    /// transcription queue), writes the text for the keyboard, then saves the dictation.
    private func finishDictation() {
        guard let id = current, let app else { return }
        let samples = capture.endTake()
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
        let t0 = Date()
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await Self.transcribe(samples, engineId: settings.engineId, model: settings.model, ranked: ranked)
                let heard = Date()
                let original = result.segments
                var fixed = original
                let corrections = dictionary.isEmpty ? [] : DictionaryApplier.apply(dictionary, to: &fixed)
                let raw = fixed.filter { !$0.isFillerOnly }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                // The Mac's cleanup at your level: Apple's model on iOS 26 when it's available and answers within the
                // keyboard's budget, otherwise the rules (prepass, then lists and paragraphs). Plain bullets.
                let request = PhoneDictation.request(raw: raw, level: level, category: category, vocabulary: vocabulary,
                                                     snippets: snippets, budget: PhoneDictation.keyboardBudget)
                let out = await PhoneDictation.clean(request, budget: PhoneDictation.keyboardBudget)
                let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let info = FlowInfo(app: category == .other ? "Verbatim" : "Keyboard", bundleID: nil, category: category, style: .casual,
                                    level: level.rawValue, raw: raw, pasted: text, pastedOK: !text.isEmpty)
                await MainActor.run {
                    let total = Date().timeIntervalSince(t0)
                    Log.note("keyboard dictation \(String(format: "%.1f", duration)) s → words in \(String(format: "%.2f", heard.timeIntervalSince(t0))) s, text in \(String(format: "%.2f", total)) s (\(out.cleaned ? "model" : "rules")\(out.note.map { ": " + $0 } ?? ""))\(total > 1.5 ? " — over the 1.5 s target" : "")")
                    self.deliver(id, text: text, raw: raw)
                    if !text.isEmpty {
                        self.save(samples: samples, duration: duration, original: original, fixed: fixed, corrections: corrections,
                                  engine: result.engine, model: result.model, info: info)
                    } else {
                        self.endBackground()
                    }
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
        write(text.isEmpty ? .failed : .done, for: id, message: text.isEmpty ? "No words were heard." : nil)
    }

    /// After the text is in: writes the audio file and adds the dictation to the library, off the hot path.
    private func save(samples: [Float], duration: Double, original: [Segment], fixed: [Segment], corrections: [Correction], engine: String, model: String, info: FlowInfo) {
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
                t.waveform = wave
                t.status = .ready
                app.store.add(t)
            }
        }
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
