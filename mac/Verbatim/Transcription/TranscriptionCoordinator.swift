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

        static let mac = Config(speakerPass: .inline, autoTitleSources: [.voiceMemo, .app, .dictation], waitForDownload: false,
                                appendFailedStage: "Couldn't add the new recording. Choose Retry.", logsJobs: true)
        static let phone = Config(speakerPass: .afterWords, autoTitleSources: [.voiceMemo], waitForDownload: true,
                                  appendFailedStage: "Couldn't add the new recording. Tap Retry.", logsJobs: false)
    }

    let store: Store
    let config: Config
    weak var host: TranscriptionHost?

    /// Transcripts waiting to run, oldest first. One runs at a time.
    @Changed var queue: [UUID] = []
    @Changed var runningID: UUID? = nil
    /// Identifies the current run, so a cancelled run's late callbacks can't touch the next one.
    private var runToken = UUID()
    private var runningTask: Task<Void, Never>? = nil

    init(store: Store, config: Config) {
        self.store = store
        self.config = config
    }

    private var settings: TranscriptionSettings {
        host?.jobSettings() ?? TranscriptionSettings(engineId: "fluid", model: "v3", wantSpeakers: true, applyDictionary: true)
    }

    // MARK: Launch

    /// Anything still queued or mid-transcription when the app last quit. Only this device's jobs; with
    /// `includeUnowned`, also jobs that never recorded a device. Doesn't start the queue.
    func resume(includeUnowned: Bool) {
        queue = store.live.filter { ($0.status == .processing && $0.audioFileName != nil
                                     && ($0.processingDevice == Device.id || (includeUnowned && $0.processingDevice == nil)))
                                    || ($0.pendingAppend != nil && $0.processingDevice == Device.id) }
            .sorted { $0.createdAt < $1.createdAt }.map(\.id)
    }

    // MARK: Queueing

    /// Adds a new transcript to the Store and queues it.
    func enqueue(_ t: Transcript) {
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
            if runningID == id { runToken = UUID(); runningTask?.cancel(); runningTask = nil; runningID = nil; pump() }
            return
        }
        if config.speakerPass == .afterWords, store.transcript(id)?.status == .ready {
            // The words are in; only the speaker pass was running. Stop it and keep the transcript.
            store.update(id) { $0.stage = nil }
            if runningID == id { runToken = UUID(); runningTask?.cancel(); runningTask = nil; runningID = nil; labelIfNeeded(id); pump() }
            return
        }
        store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Cancelled. Choose Retry to run it again." }
        if runningID == id {
            runToken = UUID()
            runningTask?.cancel(); runningTask = nil
            runningID = nil
            pump()
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
        store.removeAfterPendingWrites([Paths.audio.appendingPathComponent(name)])
        host?.notify("New recording discarded")
    }

    /// Starts the next queued transcript if nothing is running.
    func pump() {
        guard runningID == nil else { return }
        while let next = queue.first {
            queue.removeFirst()
            guard let t = store.transcript(next), t.status == .processing || (t.pendingAppend != nil && t.processingDevice == Device.id) else { continue }
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
        labelIfNeeded(id)
        pump()
    }

    /// Once a recording is transcribed (speakers included): suggests a kind, a title, and tags on this device
    /// (AutoLabel). Runs once per transcript (while `kind` is nil) and never overwrites what the person set.
    private func labelIfNeeded(_ id: UUID) {
        guard AutoLabel.enabled, let t = store.transcript(id), t.status == .ready, t.source != .dictation,
              t.kind == nil, t.kindIsAuto, !t.segments.isEmpty else { return }
        let wantTitle = t.titleIsAuto && config.autoTitleSources.contains(t.source)
        let segs = t.segments, speakers = max(t.speakers.count, Set(t.segments.compactMap(\.speaker)).count), duration = t.duration
        Task.detached(priority: .utility) {
            let r = await AutoLabel.suggest(segments: segs, speakers: speakers, duration: duration)
            await MainActor.run {
                self.store.update(id) { x in
                    guard x.status == .ready else { return }
                    if x.kindIsAuto, x.kind == nil { x.kind = r.kind }
                    if wantTitle, x.titleIsAuto, let title = r.title { x.title = title; x.titleByModel = true }
                    if !r.tags.isEmpty { x.tags = AutoLabel.merge(x.tags, r.tags) }
                }
                Log.note("autolabel: kind \(r.kind.rawValue), title \(wantTitle && r.title != nil ? "suggested" : "kept"), \(r.tags.count) tags, model \(r.usedModel)")
            }
        }
    }

    // MARK: Running

    /// Progress can arrive many times a second while a model downloads. Publish at most ~4×/s, only when
    /// the label changed, and without touching the disk: `stage` is display-only.
    private func progressHandler(_ id: UUID) -> @Sendable (EngineProgress) -> Void {
        let labels = labelHandler(id)
        return { p in labels(p.label) }
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
            store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "The audio file is missing." }
            runningID = nil; pump(); return
        }
        host?.runWillBegin(id)
        let s = settings
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
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                if waitForDownload { _ = await Cloud.ensureDownloaded(url) }
                let out = try await TranscriptionJob.run(url: url, engineId: engineId, model: model, wantSpeakers: wantSpeakers,
                                                         dictionary: dict, project: project, needWave: needWave, progress: progress)
                let original = out.original, fixed = out.fixed, speakers = out.speakers, corrections = out.corrections, wave = out.wave
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    // Cancelled while running: keep the cancellation, drop the late result.
                    guard self.store.transcript(id)?.status == .processing else { return }
                    self.store.update(id) { x in
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
                        if !wave.isEmpty { x.waveform = wave }
                        if autoTitle.contains(x.source), x.titleIsAuto, !x.titleByModel, let auto = Transcript.titleFrom(fixed) { x.title = auto }
                    }
                    // In a batch, stay quiet until the last one.
                    self.host?.transcriptReady(id, corrections: corrections.count, queueEmpty: self.queue.isEmpty)
                }
            } catch {
                if logsJobs { Log.note("transcribe failed: \(error)") }
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.store.transcript(id)?.status == .processing else { return }
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
                    guard self.runToken == token, self.store.transcript(id)?.status == .processing else { return }
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
                    }
                    self.store.removeAfterPendingWrites([Paths.tracks(id)])
                    self.host?.transcriptReady(id, corrections: out.corrections.count, queueEmpty: self.queue.isEmpty)
                }
            } catch {
                if logsJobs { Log.note("multitrack failed: \(error)") }
                if error is CancellationError { return }
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.runToken == token, self.store.transcript(id)?.status == .processing else { return }
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
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                if waitForDownload { _ = await Cloud.ensureDownloaded(url) }
                let out = try await TranscriptionJob.run(url: url, engineId: engineId, model: model, wantSpeakers: false,
                                                         dictionary: dict, project: project, needWave: needWave, progress: progress)
                let findSpeakers = wantSpeakers && out.fixed.count > 1
                let proceed = await MainActor.run { () -> Bool in
                    guard self.store.transcript(id)?.status == .processing else { self.finished(id, token: token); return false }
                    self.store.update(id) { x in
                        x.original = out.original; x.segments = out.fixed; x.speakers = []; x.corrections = out.corrections
                        x.status = .ready; x.stage = findSpeakers ? "Finding speakers" : nil; x.engine = out.engine; x.model = out.model; x.language = out.language
                        x.processingDevice = nil; x.processingDeviceName = nil
                        if !out.wave.isEmpty { x.waveform = out.wave }
                        if autoTitle.contains(x.source), x.titleIsAuto, !x.titleByModel, let auto = Transcript.titleFrom(out.fixed) { x.title = auto }
                    }
                    self.host?.transcriptReady(id, corrections: out.corrections.count, queueEmpty: self.queue.isEmpty)
                    if !findSpeakers { self.finished(id, token: token) }
                    return true
                }
                guard proceed, findSpeakers else { return }
                guard !Task.isCancelled else { await MainActor.run { self.store.update(id) { $0.stage = nil }; self.finished(id, token: token) }; return }
                let turns = try? await FluidDiarizer.shared.diarize(url: url, progress: { _ in })
                await MainActor.run {
                    guard self.runToken == token else { return }
                    defer { self.finished(id, token: token) }
                    self.store.update(id) { x in
                        x.stage = nil
                        // Only when nobody has assigned speakers by hand in the meantime.
                        guard let turns, x.speakers.isEmpty else { return }
                        var segs = x.segments
                        let found = SpeakerAssigner.assign(turns, to: &segs)
                        guard found.count >= 2 else { return }
                        x.segments = segs; x.speakers = found
                        for i in x.original.indices where i < segs.count { x.original[i].speaker = segs[i].speaker }
                    }
                }
            } catch {
                if logsJobs { Log.note("transcribe failed: \(error)") }
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.store.transcript(id)?.status == .processing else { return }
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.host?.jobFailed(id, error: error)
                }
            }
        }
    }

    /// Transcribes a continued recording and joins it onto the transcript.
    private func runAppend(_ id: UUID, _ t: Transcript, _ url: URL) {
        guard let partName = t.pendingAppend else { finished(id); return }
        host?.runWillBegin(id)
        let part = Paths.audio.appendingPathComponent(partName)
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
                guard await Cloud.ensureDownloaded(url), await Cloud.ensureDownloaded(part) else {
                    throw NSError(domain: "Verbatim", code: 22, userInfo: [NSLocalizedDescriptionKey: "The recordings haven't finished downloading from iCloud."])
                }
                let out = try await Continuation.run(existing: t, existingAudio: url, part: part, combined: combined, engineId: engineId, model: model,
                                                     wantSpeakers: wantSpeakers, dictionary: dict, progress: progress)
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.runToken == token, !Task.isCancelled, self.store.transcript(id)?.pendingAppend == partName,
                          let name = self.store.adoptRecording(combined) else { try? FileManager.default.removeItem(at: combined); return }
                    self.store.update(id) { Continuation.apply(out, to: &$0, combinedName: name) }
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
