import Foundation
import Combine

/// What a run reads from the app's preferences when it starts. Both apps use the same UserDefaults keys.
struct TranscriptionSettings {
    var engineId: String
    var model: String
    var wantSpeakers: Bool
    var applyDictionary: Bool
}

/// Platform hooks for the shared queue. The Mac drives Verbie, chimes, and toasts; the iPhone keeps iOS
/// background time, shows a short message, and plays a haptic.
@MainActor
protocol TranscriptionHost: AnyObject {
    /// Engine, model, speakers, and Dictionary, read fresh for every run.
    func jobSettings() -> TranscriptionSettings
    /// A new transcript is about to be added to the Store and queued (the Mac files it into the open project).
    func prepareNew(_ t: inout Transcript)
    /// A new transcript was added to the Store, just before it joins the queue.
    func didEnqueue(_ id: UUID)
    /// The queue picked `id` to run next, just before its run starts.
    func jobStarted(_ id: UUID)
    /// A run found its audio and is about to start work.
    func runWillBegin(_ id: UUID)
    /// The queue had nothing left to start and nothing running.
    func queueDrained()
    /// A rate-limited progress label for the running job (already written to the transcript's stage).
    func progress(_ id: UUID, label: String)
    /// The words are in. `queueEmpty` is true when nothing else is waiting.
    func transcriptReady(_ id: UUID, corrections: Int, queueEmpty: Bool)
    func jobFailed(_ id: UUID, error: Error)
    /// A continued recording was joined onto its transcript.
    func appendReady(_ id: UUID, queueEmpty: Bool)
    func appendFailed(_ id: UUID, error: Error)
    /// A short message for the person (a toast on the Mac, a banner on the iPhone).
    func notify(_ message: String)
    /// The running job's share done (0…1) while it transcribes, or nil when it can't tell.
    func progressFraction(_ id: UUID, _ fraction: Double?)
    /// The recording sounds like `language` (nil: not English, but unclear which), Parakeet v3 transcribes it, and
    /// v3 isn't downloaded. Offer the download; `rerun(_:language:)` transcribes it again with v3.
    func offerParakeetV3(_ id: UUID, language: String?)
}

extension TranscriptionHost {
    func progressFraction(_ id: UUID, _ fraction: Double?) {}
    func offerParakeetV3(_ id: UUID, language: String?) {
        let what = language.map(LanguageDetection.name) ?? "another language"
        notify("This recording sounds like \(what). Download Parakeet v3 in Settings to transcribe it.")
    }
}

/// The transcription queue shared by the Mac and the iPhone: one job runs at a time, oldest first.
@MainActor
final class TranscriptionCoordinator: ObservableObject {
    struct Config {
        enum SpeakerPass { case inline, afterWords }
        /// `.inline` finds speakers inside the job; `.afterWords` opens the transcript first, then runs a separate speaker pass.
        var speakerPass: SpeakerPass
        /// Sources whose transcripts get a title from their first words.
        var autoTitleSources: Set<SourceKind>
        /// Wait for the audio to download from iCloud before transcribing it.
        var waitForDownload: Bool
        /// The stage shown when a continued recording couldn't be added.
        var appendFailedStage: String
        /// Write start and failure lines to the log.
        var logsJobs: Bool
        /// Transcribe long recordings about 5 minutes at a time, saving each finished section so a stopped job picks
        /// up where it left off (SectionedTranscription.swift). The iPhone, where iOS can stop a job in the
        /// background or for memory. The Mac hands the whole file to FluidAudio, which already streams it from disk.
        var sectioned = false

        static let mac = Config(speakerPass: .inline, autoTitleSources: [.voiceMemo, .app, .dictation], waitForDownload: false,
                                appendFailedStage: "Couldn't add the new recording. Choose Retry.", logsJobs: true)
        static let phone = Config(speakerPass: .afterWords, autoTitleSources: [.voiceMemo], waitForDownload: true,
                                  appendFailedStage: "Couldn't add the new recording. Tap Retry.", logsJobs: false, sectioned: true)
    }

    let store: Store
    let config: Config
    weak var host: TranscriptionHost?

    /// Transcripts waiting to run, oldest first. One runs at a time.
    @Changed var queue: [UUID] = []
    @Changed var runningID: UUID? = nil { didSet { updateKeepAwake() } }
    /// Identifies the current run, so a cancelled run's late callbacks can't touch the next one.
    private var runToken = UUID()
    private var runningTask: Task<Void, Never>? = nil
    /// Cancelled runs that haven't ended yet. The next job waits for them, so two never run at once.
    private var draining = 0 { didSet { updateKeepAwake() } }
    /// Launch sweeps of saved sections still running. No job starts until they end (see `resume`).
    private var sweeping = 0
    /// Held while a job runs (or a cancelled one winds down): the Mac doesn't idle-sleep in the middle of a long file.
    private var keepAwake: NSObjectProtocol?

    private func updateKeepAwake() {
        #if os(macOS)
        let busy = runningID != nil || draining > 0
        if busy, keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transcribing")
        } else if !busy, let a = keepAwake {
            ProcessInfo.processInfo.endActivity(a)
            keepAwake = nil
        }
        #endif
    }

    /// Stops the running job. The next one starts only once the old task has actually ended, so an engine still
    /// finishing the old file never runs alongside the new one.
    private func stopRunning() {
        runToken = UUID()
        let old = runningTask
        runningTask = nil
        runningID = nil
        guard let old else { return }
        old.cancel()
        draining += 1
        Task { [weak self] in
            await old.value
            guard let self else { return }
            self.draining -= 1
            self.pump()
        }
    }

    init(store: Store, config: Config) {
        self.store = store
        self.config = config
        SummaryCenter.shared.retitleSources = config.autoTitleSources
        // Run automatically's templates wait while a transcription runs, so they never slow one (TemplateRunner.swift).
        TemplateCenter.shared.transcribing = { [weak self] in self.map { $0.runningID != nil || !$0.queue.isEmpty } ?? false }
    }

    private var settings: TranscriptionSettings {
        host?.jobSettings() ?? TranscriptionSettings(engineId: "fluid", model: QualityPreset.defaultPreset.config.1, wantSpeakers: true, applyDictionary: true)
    }

    // MARK: Launch

    /// Anything still queued or mid-transcription when the app last quit. Only this device's jobs; with
    /// `includeUnowned`, also jobs that never recorded a device. Doesn't start the queue.
    func resume(includeUnowned: Bool) {
        queue = store.live.filter { ($0.status == .processing && $0.audioFileName != nil
                                     && ($0.processingDevice == Device.id || (includeUnowned && $0.processingDevice == nil)))
                                    || ($0.pendingAppend != nil && $0.processingDevice == Device.id) }
            .sorted { $0.createdAt < $1.createdAt }.map(\.id)
        // Saved sections only for jobs that will pick up again; the rest finished, were deleted, or were cancelled.
        let resuming = Set((queue + [runningID].compactMap { $0 }).compactMap { store.transcript($0)?.audioFileName })
        // Jobs wait for the sweep: one queued in between (a recovered recording, a dropped file) could otherwise write
        // its first section and have it swept, so a crash during that job would start it from the beginning.
        sweeping += 1
        Task { [weak self] in
            await Task.detached(priority: .utility) { SectionCheckpoint.sweep(keeping: resuming) }.value
            guard let self else { return }
            self.sweeping -= 1
            self.pump()
        }
    }

    // MARK: Queueing

    /// Adds a new transcript to the Store and queues it. An Audio only recording is kept instead (`keepAudioOnly`).
    func enqueue(_ t: Transcript) {
        if t.isAudioOnly { keepAudioOnly(t); return }
        var t = t
        t.status = .processing
        t.stage = "Queued"
        t.processingDevice = Device.id; t.processingDeviceName = Device.name
        host?.prepareNew(&t)
        store.add(t)
        store.waitForWrites()   // its audio was just moved in; the transcript pointing at it lands first (as before)
        host?.didEnqueue(t.id)
        queue.append(t.id)
        pump()
    }

    /// Audio only (AudioOnly.swift): saved as sound, ready at once, and never queued until you ask for its words.
    func keepAudioOnly(_ t: Transcript) {
        var t = t
        t.status = .ready
        t.stage = nil
        t.processingDevice = nil; t.processingDeviceName = nil
        host?.prepareNew(&t)
        store.add(t)
        store.waitForWrites()
    }

    /// The kind each Transcribe on an Audio only recording files it as when the words are in (`nil`: a voice note).
    /// Kept on this device while the job runs; a job a quit interrupted becomes a voice note.
    private var laterKinds: [UUID: RecordingKind?] = [:]

    /// Transcribe on an Audio only recording (Transcribe later): the normal transcription queue, the same path as
    /// Transcribe again. It stays Audio only, with its progress where Transcribe was, until the words are in; then it's
    /// a voice note, or the kind you picked with Transcribe as. The title, notes, moments, and audio stay.
    func transcribeLater(_ id: UUID, as kind: RecordingKind? = nil) {
        guard let t = store.transcript(id), AudioOnlyRules.canTranscribe(t) else { return }
        laterKinds[id] = .some(kind)
        if let name = t.audioFileName { SectionCheckpoint.remove(audio: name) }
        store.update(id) { x in
            x.beginTranscribeLater()
            x.processingDevice = Device.id; x.processingDeviceName = Device.name
        }
        if !queue.contains(id) && runningID != id { queue.append(id) }
        pump()
    }

    /// Words just landed on a transcript: an Audio only one stops being Audio only (`finishTranscribeLater`).
    private func promoteAudioOnly(_ x: inout Transcript, _ id: UUID) {
        guard x.isAudioOnly else { return }
        let picked = laterKinds.removeValue(forKey: id) ?? nil
        x.finishTranscribeLater(as: picked)
    }

    /// Queues a transcript that's already in the Store (an import or a fetched link that's ready).
    func enqueueExisting(_ id: UUID) {
        queue.append(id)
        pump()
    }

    /// Adopts a continued recording and queues it to be joined onto the end of `id`. False when it couldn't be saved.
    func queueAppend(recording url: URL, to id: UUID) -> Bool {
        guard store.transcript(id) != nil, let name = store.adoptRecording(url) else { return false }
        store.update(id) { $0.pendingAppend = name; $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
        store.waitForWrites()
        queue.append(id)
        pump()
        return true
    }

    /// Whether a transcript can take a continued recording right now.
    func canContinue(_ id: UUID) -> Bool {
        guard let t = store.transcript(id), t.status == .ready, t.audioFileName != nil, t.pendingAppend == nil else { return false }
        return true
    }

    /// Transcribes a finished transcript again, in `language` (nil: Verbatim checks the language). Its words,
    /// speakers, and Dictionary fixes are replaced; title, notes, and tags stay. `checkWithV3` downloads Parakeet v3
    /// if needed and checks the language with it (the language was unclear to the English-only model).
    func rerun(_ id: UUID, language: String?, checkWithV3: Bool = false) {
        guard let t = store.transcript(id), t.audioFileName != nil, t.pendingAppend == nil else { return }
        // Still running with the old settings (the v3 offer comes mid-run): that run stops; its late result is dropped.
        queue.removeAll { $0 == id }
        if runningID == id { stopRunning() }
        if let name = t.audioFileName { SectionCheckpoint.remove(audio: name) }
        if checkWithV3 { checkWithV3IDs.insert(id) }
        // A Whisper Turbo request still waiting gives way: this run uses your engine, in the language you picked.
        store.update(id) { $0.languageChoice = language; $0.rerunRequest = nil }
        if let fresh = store.transcript(id) { retry(fresh) }
    }

    /// Transcribes a finished transcript again with another engine (Transcribe again with Whisper Turbo), keeping the
    /// words it replaces as `previousVersion` to switch back to. The request rides on the transcript (`rerunRequest`),
    /// so a job a quit interrupted picks up the same way. Speakers, notes, and moments carry over
    /// (TranscriptVersions.swift); a failure or Cancel leaves the transcript as it was.
    func rerun(_ id: UUID, engine: String, model: String) {
        guard let t = store.transcript(id), t.audioFileName != nil, t.pendingAppend == nil else { return }
        queue.removeAll { $0 == id }
        if runningID == id { stopRunning() }
        if let name = t.audioFileName { SectionCheckpoint.remove(audio: name) }
        store.update(id) { x in
            var req = x.rerunRequest ?? RerunRequest(engine: engine, model: model, device: Device.id, deviceName: Device.name)
            req.engine = engine; req.model = model
            x.rerunRequest = req
        }
        if let fresh = store.transcript(id) { retry(fresh) }
    }

    /// A rerun stopped (failed or cancelled): the transcript goes back to its words as they were.
    private func restoreAfterRerun(_ id: UUID, error: Error?) {
        store.update(id) { x in
            x.status = .ready; x.stage = nil; x.error = nil; x.rerunRequest = nil
            x.processingDevice = nil; x.processingDeviceName = nil
        }
        if let error { host?.notify("Couldn't transcribe again: \(error.localizedDescription) Your transcript is as it was.") }
    }

    func retry(_ t: Transcript) {
        guard t.audioFileName != nil else { host?.notify("That recording's audio is missing."); return }
        if t.pendingAppend != nil {
            store.update(t.id) { $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
            if !queue.contains(t.id) && runningID != t.id { queue.append(t.id) }
            pump(); return
        }
        store.update(t.id) { $0.status = .processing; $0.error = nil; $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
        if !queue.contains(t.id) && runningID != t.id { queue.append(t.id) }
        pump()
    }

    /// Stops a queued or running transcript. It stays in Library as "Cancelled" with Retry.
    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if store.transcript(id)?.pendingAppend != nil {
            // The transcript stays as it was; the new recording is kept, ready to add with Retry.
            store.update(id) { $0.stage = "New recording not added yet"; $0.processingDevice = nil; $0.processingDeviceName = nil }
            if runningID == id { stopRunning(); pump() }
            return
        }
        if let t = store.transcript(id), t.rerunRequest != nil, t.status == .processing {
            // Transcribe again with another engine: the words it would replace are still here.
            restoreAfterRerun(id, error: nil)
            if let name = t.audioFileName { SectionCheckpoint.remove(audio: name) }
            if runningID == id { stopRunning(); pump() }
            return
        }
        if config.speakerPass == .afterWords, store.transcript(id)?.status == .ready {
            // The words are in; only the speaker pass was running. Stop it and keep the transcript.
            store.update(id) { $0.stage = nil }
            if runningID == id { stopRunning(); labelIfNeeded(id); SpeakerNameSuggester.runIfNeeded(id, store: store); SummaryCenter.shared.summarizeIfNeeded(id, store: store); pump() }
            return
        }
        store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Cancelled. Choose Retry to run it again." }
        if let name = store.transcript(id)?.audioFileName { SectionCheckpoint.remove(audio: name) }
        if runningID == id {
            stopRunning()
            pump()   // waits until the cancelled job has ended (`draining`)
        }
    }

    /// Cancels `id` if it's waiting or running.
    func cancelIfActive(_ id: UUID) {
        if runningID == id || queue.contains(id) { cancel(id) }
    }

    func cancelAll() {
        for id in queue { cancel(id) }
        queue = []
        if let r = runningID { cancel(r) }
    }

    /// Throws away a continued recording that hasn't been added; the transcript stays as it was.
    func discardPendingAppend(_ id: UUID) {
        cancelIfActive(id)
        guard let name = store.transcript(id)?.pendingAppend else { return }
        store.update(id) { $0.pendingAppend = nil; $0.stage = nil; $0.processingDevice = nil; $0.processingDeviceName = nil }
        if let file = LibraryFile.url(name, in: Paths.audio, field: "continued recording") { store.removeAfterPendingWrites([file]) }
        host?.notify("New recording discarded")
    }

    /// Starts the next queued transcript if nothing is running.
    func pump() {
        guard runningID == nil, draining == 0, sweeping == 0 else { return }
        while let next = queue.first {
            queue.removeFirst()
            // A job another device has taken over since it was queued (Retry or a claimed link there) is theirs now.
            guard let t = store.transcript(next), (t.status == .processing && t.jobIsMine()) || (t.pendingAppend != nil && t.processingDevice == Device.id) else { continue }
            // Audio only waits until you ask for its words (Transcribe sets it to processing).
            guard !AudioOnlyRules.skipsQueue(t) else { continue }
            runningID = next
            host?.jobStarted(next)
            run(next)
            return
        }
        host?.queueDrained()
    }

    /// Called when a run ends for any reason.
    private func finished(_ id: UUID, token: UUID? = nil) {
        guard runningID == id, token == nil || token == runToken else { return }
        runningID = nil; runningTask = nil
        snapMarks(id)
        detectSponsors(id)
        labelIfNeeded(id)
        // Names for two or more speakers, as suggestions (after the speaker pass, where it runs on its own).
        SpeakerNameSuggester.runIfNeeded(id, store: store)
        SummaryCenter.shared.summarizeIfNeeded(id, store: store)
        // Run automatically: once its kind and summary are in, the kind's template runs, once (Templates.swift).
        TemplateCenter.shared.recordingFinished(id, store: store)
        pump()
    }

    /// Moments marked while recording (Marks.swift) move onto the line that was being said, once the words are in:
    /// the line's time, and its first sentence unless the moment was named. Marks already on a line stay put.
    private func snapMarks(_ id: UUID) {
        guard let t = store.transcript(id), t.status == .ready, !t.segments.isEmpty,
              t.notes.contains(where: { $0.isMark && $0.segmentId == nil && $0.at != nil }) else { return }
        let snapped = Marks.snap(t.notes, to: t.segments)
        guard snapped != t.notes else { return }
        store.update(id) { $0.notes = Marks.snap($0.notes, to: $0.segments) }
        Log.note("marks: \(t.notes.filter(\.isMark).count) moment(s) on their lines")
    }

    /// Once a recording is transcribed (speakers included): suggests a kind, a title, and tags on this device
    /// (AutoLabel). Runs once per transcript (while `kind` is nil) and never overwrites what the person set.
    private func labelIfNeeded(_ id: UUID) {
        guard AutoLabel.enabled, let t = store.transcript(id), t.status == .ready, t.source != .dictation,
              AudioOnlyRules.labels(t), t.wantsSuggestedKind, !t.segments.isEmpty else { return }
        let wantTitle = t.titleIsAuto && config.autoTitleSources.contains(t.source)
        // Sponsor reads (detectSponsors, just before) never name or tag the recording.
        let segs = t.segmentsWithoutSponsors, speakers = max(t.speakers.count, Set(t.segments.compactMap(\.speaker)).count), duration = t.duration
        let origin = KindRule.origin(of: t)
        Task.detached(priority: .utility) {
            let r = await AutoLabel.suggest(segments: segs, speakers: speakers, duration: duration, origin: origin)
            await MainActor.run {
                self.store.update(id) { x in
                    guard x.status == .ready else { return }
                    // A kind you picked (Record a meeting, or the kind chip) is never replaced (Templates.swift).
                    x.applySuggestedKind(r.kind)
                    // A title written from the summary covers the whole recording; it wins over this excerpt-based one.
                    if wantTitle, x.titleIsAuto, !SummaryCenter.shared.retitled.contains(id), let title = r.title { x.title = title; x.titleByModel = true }
                    if !r.tags.isEmpty { x.tags = AutoLabel.merge(x.tags, r.tags) }
                }
                Log.note("autolabel: kind \(r.kind.rawValue), title \(wantTitle && r.title != nil ? "suggested" : "kept"), \(r.tags.count) tags, model \(r.usedModel)")
            }
        }
    }

    /// Once a podcast, video, talk, or interview from a link or an imported file is transcribed (and again after
    /// Transcribe again): finds its sponsor reads by rule (SponsorDetect) before the labels and the summary run, so
    /// neither reads them. Spans someone marked or dismissed stay. Then Apple Intelligence, where it can run,
    /// confirms and names each read the rules found.
    private func detectSponsors(_ id: UUID) {
        guard let t = store.transcript(id), t.status == .ready, t.source != .dictation, !t.segments.isEmpty else { return }
        let origin = KindRule.origin(of: t)
        guard case .media(_) = origin else { return }
        let speakers = max(t.speakers.count, Set(t.segments.compactMap(\.speaker)).count)
        let kind = t.kind ?? KindRule.kind(origin: origin, speakers: speakers, duration: t.duration)
        guard Transcript.detectsSponsors(isMedia: true, kind: kind) else { return }
        let found = SponsorDetect.detect(t.sponsorLines)
        store.update(id) { $0.applySponsors(found) }
        Log.note("sponsors: \(found.count) found by rule")
        refineSponsors(id)
    }

    /// Apple Intelligence's pass over the reads the rules found: a read it calls a sponsor read takes its name (when
    /// it spells the same brand); one it says isn't goes away. A decline or failure leaves the rules' span.
    private func refineSponsors(_ id: UUID) {
        guard SponsorRefine.available, let t = store.transcript(id) else { return }
        let spans = (t.sponsors ?? []).filter { $0.source == .rules && !$0.dismissed }
        guard !spans.isEmpty else { return }
        let passages = spans.map { sp in (sp.id, t.segments.filter { t.sponsorSpan(for: $0, in: [sp]) != nil }.map(\.text).joined(separator: " ")) }
        Task.detached(priority: .utility) {
            var answers: [UUID: SponsorDetect.Verdict] = [:]
            for (sid, text) in passages {
                if Task.isCancelled { return }
                answers[sid] = await SponsorRefine.check(text)
            }
            let verdicts = answers
            await MainActor.run {
                self.store.update(id) { x in
                    guard var list = x.sponsors else { return }
                    list.removeAll { verdicts[$0.id] == .notSponsor && $0.source == .rules }
                    for i in list.indices where list[i].source == .rules {
                        guard case .sponsor(let name)? = verdicts[list[i].id] else { continue }
                        list[i].source = .model
                        list[i].name = SponsorDetect.pickName(rule: list[i].name, model: name)
                    }
                    x.sponsors = list
                }
                let kept = verdicts.values.filter { if case .sponsor(_) = $0 { return true }; return false }.count
                Log.note("sponsors: Apple Intelligence confirmed \(kept) of \(verdicts.count)")
            }
        }
    }

    // MARK: Running

    /// Progress can arrive many times a second while a model downloads. Publish at most ~4×/s, only when
    /// the label changed, and without touching the disk: `stage` is display-only.
    private func progressHandler(_ id: UUID) -> @Sendable (EngineProgress) -> Void {
        let labels = labelHandler(id)
        return { p in
            if case .transcribing(let f) = p { Task { @MainActor in self.host?.progressFraction(id, f) } }
            labels(p.label)
        }
    }

    /// Transcripts whose next run checks the language with Parakeet v3, downloading it first (`rerun`).
    private var checkWithV3IDs: Set<UUID> = []

    /// Language and long-recording handling for a run of `t`.
    private func jobOptions(_ id: UUID, _ t: Transcript) -> JobOptions {
        let withV3 = checkWithV3IDs.remove(id) != nil
        return JobOptions(sectioned: config.sectioned, audioName: t.audioFileName, languageChoice: t.languageChoice,
                   detectLanguage: LanguageDetection.isEnabled || withV3, checkWithV3: withV3,
                   offerV3: { language in Task { @MainActor in self.host?.offerParakeetV3(id, language: language) } })
    }

    /// The job's words are saved in the Store: its saved sections can go.
    private func dropSections(_ t: Transcript) {
        if let name = t.audioFileName { SectionCheckpoint.remove(audio: name) }
    }

    /// The same, for runs that write their own labels ("Track 2 of 3 · 41%").
    private func labelHandler(_ id: UUID) -> @Sendable (String) -> Void {
        let gate = ProgressGate()
        return { label in
            guard gate.shouldPublish(label) else { return }
            Task { @MainActor in self.store.setStage(id, label); self.host?.progress(id, label: label) }
        }
    }

    private func run(_ id: UUID) {
        if let t = store.transcript(id), t.pendingAppend != nil, let url = store.audioURL(for: t) { runAppend(id, t, url); return }
        guard let t = store.transcript(id), let url = store.audioURL(for: t) else {
            if store.transcript(id)?.rerunRequest != nil {
                // Transcribe again with another engine: the words it would replace stay.
                restoreAfterRerun(id, error: NSError(domain: "Verbatim", code: 23, userInfo: [NSLocalizedDescriptionKey: "The audio file is missing."]))
            } else {
                store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "The audio file is missing." }
            }
            runningID = nil; pump(); return
        }
        host?.runWillBegin(id)
        var s = settings
        // Transcribe again with another engine: its engine and model, and speakers carried over by time when the
        // words had them (TranscriptVersions.swift) instead of found again.
        if let req = t.rerunRequest {
            s.engineId = req.engine; s.model = req.model
            if t.speakers.count >= 1, t.segments.contains(where: { $0.speaker != nil }) { s.wantSpeakers = false }
        }
        let dict = s.applyDictionary ? store.dictionary : []
        let token = UUID(); runToken = token
        if config.logsJobs { Log.note("transcribe start engine=\(s.engineId) model=\(s.model) file=\(url.lastPathComponent)") }
        // A multi-track recording whose tracks are still here: each track on its own, then woven together.
        if let mt = t.multitrack, MultitrackJob.canRun(t) { runMultitrack(id, t, mt, s, dict, token); return }
        switch config.speakerPass {
        case .inline: runInline(id, t, url, s, dict, token)
        case .afterWords: runAfterWords(id, t, url, s, dict, token)
        }
    }

    /// One job finds words and speakers together, then the transcript is ready.
    private func runInline(_ id: UUID, _ t: Transcript, _ url: URL, _ s: TranscriptionSettings, _ dict: [DictionaryEntry], _ token: UUID) {
        let engineId = s.engineId, model = s.model, wantSpeakers = s.wantSpeakers
        let project = t.projectId
        let needWave = t.waveform.isEmpty
        let waitForDownload = config.waitForDownload
        let autoTitle = config.autoTitleSources
        let logsJobs = config.logsJobs
        let progress = progressHandler(id)
        let options = jobOptions(id, t)
        let keepsVersion = t.rerunRequest != nil
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                // A recording just handed to iCloud is moved into the audio folder in the background first.
                await self.store.waitForAdoption(of: url)
                // A rerun asked for on the iPhone: its audio may still be in iCloud on this Mac. Without it, nothing
                // downloads or runs (Whisper Turbo is 1.6 GB), and the transcript stays as it was.
                let missing = NSError(domain: "Verbatim", code: 23, userInfo: [NSLocalizedDescriptionKey: "The audio file is missing."])
                if keepsVersion {
                    let inCloud = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus != nil
                    guard inCloud || FileManager.default.fileExists(atPath: url.path) else { throw missing }
                }
                if waitForDownload || keepsVersion { _ = await Cloud.ensureDownloaded(url) }
                if keepsVersion, !FileManager.default.fileExists(atPath: url.path) { throw missing }
                let out = try await TranscriptionJob.run(url: url, engineId: engineId, model: model, wantSpeakers: wantSpeakers,
                                                         dictionary: dict, project: project, needWave: needWave, options: options, progress: progress)
                let original = out.original, fixed = out.fixed, speakers = out.speakers, corrections = out.corrections, wave = out.wave
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    // Cancelled while running (or started again): keep the cancellation, drop the late result.
                    guard self.runToken == token, self.store.transcript(id).map({ $0.status == .processing && $0.jobIsMine() }) == true else { return }
                    self.store.update(id) { x in
                        // Transcribe again with another engine: the words it replaces stay, to switch back to.
                        let old: TranscriptVersion? = keepsVersion ? x.currentVersion : nil
                        x.unclear = out.unclear
                        x.original = original
                        x.segments = fixed
                        x.speakers = speakers
                        x.corrections = corrections
                        x.status = .ready
                        x.stage = nil
                        x.engine = out.engine
                        x.model = out.model
                        x.language = out.language
                        x.processingDevice = nil; x.processingDeviceName = nil
                        self.promoteAudioOnly(&x, id)
                        if !wave.isEmpty { x.waveform = wave }
                        if autoTitle.contains(x.source), x.titleIsAuto, !x.titleByModel, let auto = Transcript.titleFrom(fixed) { x.title = auto }
                        // New words: a summary Apple Intelligence wrote for the old ones goes (an edited one stays).
                        if x.summaryByModel { x.summary = nil; x.summaryByModel = false }
                        if let old {
                            x.previousVersion = old
                            x.carryOver(from: old)
                            x.rerunRequest = nil
                        }
                    }
                    if !keepsVersion || !out.voices.isEmpty { SpeakerVoices.keep(id, voices: out.voices) }
                    self.dropSections(t)
                    // In a batch, stay quiet until the last one.
                    self.host?.transcriptReady(id, corrections: corrections.count, queueEmpty: self.queue.isEmpty)
                }
            } catch {
                if logsJobs { Log.note("transcribe failed: \(error)") }
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.runToken == token, self.store.transcript(id).map({ $0.status == .processing && $0.jobIsMine() }) == true else { return }
                    if keepsVersion { self.restoreAfterRerun(id, error: error); return }
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.host?.jobFailed(id, error: error)
                }
            }
        }
    }

    /// Multi-track: transcribes every track (one speaker each), drops mic bleed, and merges them by time. The
    /// working copies go once the transcript is ready.
    private func runMultitrack(_ id: UUID, _ t: Transcript, _ info: MultitrackInfo, _ s: TranscriptionSettings, _ dict: [DictionaryEntry], _ token: UUID) {
        let engineId = s.engineId, model = s.model
        let project = t.projectId
        let logsJobs = config.logsJobs
        let progress = labelHandler(id)
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                let out = try await MultitrackJob.run(id: id, info: info, engineId: engineId, model: model, dictionary: dict,
                                                      project: project, progress: progress)
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.runToken == token, self.store.transcript(id).map({ $0.status == .processing && $0.jobIsMine() }) == true else { return }
                    self.store.update(id) { x in
                        x.original = out.original
                        x.segments = out.fixed
                        x.speakers = out.speakers
                        x.corrections = out.corrections
                        x.status = .ready
                        x.stage = nil
                        x.engine = out.engine
                        x.model = out.model
                        x.language = out.language
                        x.processingDevice = nil; x.processingDeviceName = nil
                        self.promoteAudioOnly(&x, id)
                    }
                    self.store.removeAfterPendingWrites([Paths.tracks(id)])
                    self.host?.transcriptReady(id, corrections: out.corrections.count, queueEmpty: self.queue.isEmpty)
                }
            } catch {
                if logsJobs { Log.note("multitrack failed: \(error)") }
                if error is CancellationError { return }
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.runToken == token, self.store.transcript(id).map({ $0.status == .processing && $0.jobIsMine() }) == true else { return }
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.host?.jobFailed(id, error: error)
                }
            }
        }
    }

    /// Words first: the transcript opens as soon as they're ready, and speakers are added after.
    private func runAfterWords(_ id: UUID, _ t: Transcript, _ url: URL, _ s: TranscriptionSettings, _ dict: [DictionaryEntry], _ token: UUID) {
        let engineId = s.engineId, model = s.model, wantSpeakers = s.wantSpeakers
        let project = t.projectId
        let needWave = t.waveform.isEmpty
        let waitForDownload = config.waitForDownload
        let autoTitle = config.autoTitleSources
        let logsJobs = config.logsJobs
        let progress = progressHandler(id)
        let options = jobOptions(id, t)
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                // A recording just handed to iCloud is moved into the audio folder in the background first.
                await self.store.waitForAdoption(of: url)
                if waitForDownload { _ = await Cloud.ensureDownloaded(url) }
                let out = try await TranscriptionJob.run(url: url, engineId: engineId, model: model, wantSpeakers: false,
                                                         dictionary: dict, project: project, needWave: needWave, options: options, progress: progress)
                let findSpeakers = wantSpeakers && out.fixed.count > 1
                let proceed = await MainActor.run { () -> Bool in
                    guard self.runToken == token, self.store.transcript(id).map({ $0.status == .processing && $0.jobIsMine() }) == true else { self.finished(id, token: token); return false }
                    self.store.update(id) { x in
                        x.original = out.original; x.segments = out.fixed; x.speakers = []; x.corrections = out.corrections; x.unclear = out.unclear
                        x.status = .ready; x.stage = findSpeakers ? "Finding speakers" : nil; x.engine = out.engine; x.model = out.model; x.language = out.language
                        x.processingDevice = nil; x.processingDeviceName = nil
                        self.promoteAudioOnly(&x, id)
                        if !out.wave.isEmpty { x.waveform = out.wave }
                        if autoTitle.contains(x.source), x.titleIsAuto, !x.titleByModel, let auto = Transcript.titleFrom(out.fixed) { x.title = auto }
                        if x.summaryByModel { x.summary = nil; x.summaryByModel = false }
                    }
                    self.dropSections(t)
                    self.host?.transcriptReady(id, corrections: out.corrections.count, queueEmpty: self.queue.isEmpty)
                    if !findSpeakers { self.finished(id, token: token) }
                    return true
                }
                guard proceed, findSpeakers else { return }
                guard !Task.isCancelled else { await MainActor.run { self.store.update(id) { $0.stage = nil }; self.finished(id, token: token) }; return }
                let found = try? await FluidDiarizer.shared.diarizeDetailed(url: url, progress: { _ in })
                await MainActor.run {
                    guard self.runToken == token else { return }
                    defer { self.finished(id, token: token) }
                    // Another device transcribing it again since (Retry there) owns its words and stage now.
                    guard let now = self.store.transcript(id), now.status == .ready, now.jobIsMine() else { return }
                    self.store.update(id) { x in
                        x.stage = nil
                        // Only when nobody has assigned speakers by hand in the meantime.
                        guard let found, x.speakers.isEmpty else { return }
                        var segs = x.segments
                        // The original lines are cut alongside (matched by index); lines with corrections stay whole.
                        var original: [Segment]? = x.original
                        let paired = x.original.count == segs.count
                        let speakers = SpeakerAssigner.assign(found, to: &segs, parallel: &original, keepWhole: Set(x.corrections.map(\.segmentId)))
                        guard speakers.count >= 2 else { return }
                        x.segments = segs; x.speakers = speakers
                        if paired, let original { x.original = original }
                        else { for i in x.original.indices where i < segs.count { x.original[i].speaker = segs[i].speaker } }
                        SpeakerVoices.keep(id, voices: SpeakerNames.voices(turns: found.turns, embeddings: found.embeddings, segments: segs))
                    }
                }
            } catch {
                if logsJobs { Log.note("transcribe failed: \(error)") }
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.runToken == token, self.store.transcript(id).map({ $0.status == .processing && $0.jobIsMine() }) == true else { return }
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.host?.jobFailed(id, error: error)
                }
            }
        }
    }

    /// Transcribes a continued recording and joins it onto the transcript.
    private func runAppend(_ id: UUID, _ t: Transcript, _ url: URL) {
        guard let partName = t.pendingAppend, let part = LibraryFile.url(partName, in: Paths.audio, field: "continued recording") else { finished(id); return }
        host?.runWillBegin(id)
        let combined = Continuation.scratchURL()
        let token = UUID(); runToken = token
        let s = settings
        let engineId = s.engineId, model = s.model, wantSpeakers = s.wantSpeakers
        let dict = s.applyDictionary ? store.dictionary : []
        let failedStage = config.appendFailedStage
        let logsJobs = config.logsJobs
        let progress = progressHandler(id)
        store.setStage(id, "Adding the new recording")
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                await self.store.waitForAdoption(of: url)
                await self.store.waitForAdoption(of: part)
                guard await Cloud.ensureDownloaded(url), await Cloud.ensureDownloaded(part) else {
                    throw NSError(domain: "Verbatim", code: 22, userInfo: [NSLocalizedDescriptionKey: "The recordings haven't finished downloading from iCloud."])
                }
                let out = try await Continuation.run(existing: t, existingAudio: url, part: part, combined: combined, engineId: engineId, model: model,
                                                     wantSpeakers: wantSpeakers, dictionary: dict, progress: progress)
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.runToken == token, !Task.isCancelled, self.store.transcript(id)?.pendingAppend == partName,
                          let name = self.store.adoptRecording(combined) else { try? FileManager.default.removeItem(at: combined); return }
                    self.store.update(id) { x in
                        Continuation.apply(out, to: &x, combinedName: name)
                        SpeakerVoices.forget(id)
                        // The recording grew: Apple Intelligence's summary is rewritten for the whole of it.
                        if x.summaryByModel { x.summary = nil; x.summaryByModel = false }
                    }
                    // The two halves go only after the transcript pointing at the joined file is on disk.
                    self.store.removeAfterPendingWrites([url, part])
                    self.host?.appendReady(id, queueEmpty: self.queue.isEmpty)
                }
            } catch {
                if logsJobs { Log.note("continue failed: \(error)") }
                try? FileManager.default.removeItem(at: combined)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.runToken == token else { return }
                    defer { self.finished(id, token: token) }
                    self.store.update(id) { $0.stage = failedStage; $0.processingDevice = nil; $0.processingDeviceName = nil }
                    self.host?.appendFailed(id, error: error)
                }
            }
        }
    }
}
