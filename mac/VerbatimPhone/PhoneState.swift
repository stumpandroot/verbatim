import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import UIKit
import BackgroundTasks

/// The iPhone app's state: the same Store, recorder, player, and transcription job as the Mac, so every
/// transcript, note, bookmark, project, and Dictionary word syncs through iCloud both ways.
@MainActor
final class PhoneState: ObservableObject {
    enum Tab: Hashable { case home, library, moments, settings }

    let store = Store()
    let recorder = Recorder()
    let player = Player()

    @Published var tab: Tab = .home
    @Published var homePath = NavigationPath()
    @Published var libraryPath = NavigationPath()
    @Published var momentsPath = NavigationPath()
    @Published var toast: String? = nil
    @Published var showRecorder = false
    @Published var showLinkSheet = false
    @Published var showImporter = false
    @Published var showOnboarding = Onboarding.shouldShow
    @Published var queue: [UUID] = []
    @Published var runningID: UUID? = nil
    /// Continue recording: the transcript the current recording will be added to.
    @Published var continuing: UUID? = nil
    private var pendingContinue: UUID? = nil
    private var runToken = UUID()
    /// A passage to land on when the next transcript opens (from Moments or search).
    var focusSegment: UUID? = nil

    // Preferences (same keys as the Mac app; each device keeps its own).
    @Published var presetRaw: String = UserDefaults.standard.string(forKey: "preset") ?? QualityPreset.balanced.rawValue { didSet { UserDefaults.standard.set(presetRaw, forKey: "preset") } }
    @Published var identifySpeakers: Bool = UserDefaults.standard.object(forKey: "identifySpeakers") as? Bool ?? true { didSet { UserDefaults.standard.set(identifySpeakers, forKey: "identifySpeakers") } }
    @Published var applyDictionary: Bool = UserDefaults.standard.object(forKey: "applyDictionary") as? Bool ?? true { didSet { UserDefaults.standard.set(applyDictionary, forKey: "applyDictionary") } }
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }

    private var runningTask: Task<Void, Never>? = nil
    private var bag = Set<AnyCancellable>()
    private var background: UIBackgroundTaskIdentifier = .invalid

    init() {
        for o in [store.objectWillChange.eraseToAnyPublisher(), recorder.objectWillChange.eraseToAnyPublisher(), player.objectWillChange.eraseToAnyPublisher()] {
            o.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        // Resume only this iPhone's own jobs; the Mac's show as "Transcribing on Mac".
        queue = store.live.filter { ($0.status == .processing && $0.audioFileName != nil && $0.processingDevice == Device.id)
                                    || ($0.pendingAppend != nil && $0.processingDevice == Device.id) }
            .sorted { $0.createdAt < $1.createdAt }.map(\.id)
        if !queue.isEmpty { DispatchQueue.main.async { self.pump() } }
        if PhoneUITest.enabled { PhoneUITest.run(self) }
    }

    var preset: QualityPreset { QualityPreset(rawValue: presetRaw) ?? .balanced }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    func say(_ s: String) {
        toast = s
        let current = s
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if self.toast == current { self.toast = nil } }
    }

    func open(_ id: UUID, segment: UUID? = nil) {
        focusSegment = segment
        switch tab {
        case .home: homePath.append(id)
        case .library: libraryPath.append(id)
        case .moments: momentsPath.append(id)
        case .settings: tab = .library; libraryPath.append(id)
        }
    }

    // MARK: Recording

    func requestRecord(appendTo target: UUID? = nil) {
        pendingContinue = target
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                if ok { self.startRecording() } else { self.pendingContinue = nil; self.say("Microphone access is off. Turn it on in Settings › Verbatim.") }
            }
        }
    }

    func startRecording() {
        do {
            try recorder.start(to: store.newRecordingURL())
            continuing = pendingContinue
            pendingContinue = nil
            showRecorder = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            warmModel()
        } catch {
            say("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    /// Loads the speech model while you talk, so transcription starts the moment you stop. iOS clears it from
    /// memory when Verbatim is closed, so without this every recording would wait for it to load first.
    private func warmModel() {
        let (engineId, model) = engineChoice
        guard engineId == "fluid" else { return }
        Task.detached(priority: .utility) { await FluidEngine.shared.warm(model: model) }
    }

    private var engineChoice: (String, String) {
        preset == .advanced ? (UserDefaults.standard.string(forKey: "advEngine") ?? "fluid", UserDefaults.standard.string(forKey: "advModel") ?? "v3") : preset.config
    }

    /// Starts a recording that's added to the end of an existing transcript when you stop.
    func continueRecording(_ id: UUID) {
        guard let t = store.transcript(id), t.status == .ready, t.audioFileName != nil, t.pendingAppend == nil else {
            say("This transcript can't take more recording right now."); return
        }
        requestRecord(appendTo: id)
    }

    func stopRecording() {
        showRecorder = false
        guard let (url, duration, env) = recorder.stop() else { continuing = nil; return }
        if let target = continuing {
            continuing = nil
            guard duration >= 0.5 else { try? FileManager.default.removeItem(at: url); return }
            guard store.transcript(target) != nil, let name = store.adoptRecording(url) else { say("Couldn't save the recording."); return }
            store.update(target) { $0.pendingAppend = name; $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
            queue.append(target); pump()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        guard duration >= 0.5 else { try? FileManager.default.removeItem(at: url); return }
        guard let name = store.adoptRecording(url) else { say("Couldn't save the recording."); return }
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo", duration: duration, audioFileName: name, model: "")
        t.waveform = env
        enqueue(t)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func discardRecording() {
        showRecorder = false
        continuing = nil
        if let (url, _, _) = recorder.stop() { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        let files = MediaImport.expand(urls)
        guard !files.isEmpty else { say("No audio or video found."); return }
        var pending: [(UUID, URL)] = []
        for src in files {
            var t = Transcript(title: src.deletingPathExtension().lastPathComponent, source: .file, sourceLabel: src.pathExtension.uppercased() + " file", duration: 0, audioFileName: nil, model: "")
            t.status = .processing; t.stage = "Importing"; t.processingDevice = Device.id; t.processingDeviceName = Device.name
            store.add(t)
            pending.append((t.id, src))
        }
        if files.count > 1 { say("Added \(files.count) files") }
        Task {
            for (id, src) in pending {
                let access = src.startAccessingSecurityScopedResource()
                defer { if access { src.stopAccessingSecurityScopedResource() } }
                do {
                    let prepared = try await MediaImport.prepare(src, into: store.newAudioURL(ext: "m4a"))
                    store.update(id) { $0.audioFileName = prepared.url.lastPathComponent; $0.duration = prepared.duration; $0.stage = "Queued" }
                    queue.append(id); pump()
                } catch {
                    store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                }
            }
        }
    }

    /// iPhone can't fetch link audio itself; it hands the link to your Mac, which fetches and transcribes it.
    func addLink(_ raw: String) {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: link), let host = u.host, ["http", "https"].contains(u.scheme ?? "") else { say("That doesn't look like a link."); return }
        var t = Transcript(title: link, source: .link, sourceLabel: host.replacingOccurrences(of: "www.", with: ""), duration: 0, audioFileName: nil, model: "")
        t.sourceURL = link
        t.status = .processing
        t.pendingLink = true
        store.add(t)
        say(Cloud.enabled ? "Sent to your Mac to fetch" : "Saved. Turn on iCloud so your Mac can fetch it.")
    }

    // MARK: Pipeline (same job as the Mac)

    private func enqueue(_ t: Transcript) {
        var t = t
        t.status = .processing; t.stage = "Queued"; t.processingDevice = Device.id; t.processingDeviceName = Device.name
        store.add(t)
        queue.append(t.id)
        pump()
    }

    func retry(_ t: Transcript) {
        guard t.audioFileName != nil else { say("That recording's audio is missing."); return }
        if t.pendingAppend != nil {
            store.update(t.id) { $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
            if !queue.contains(t.id) && runningID != t.id { queue.append(t.id) }
            pump(); return
        }
        store.update(t.id) { $0.status = .processing; $0.error = nil; $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
        if !queue.contains(t.id) && runningID != t.id { queue.append(t.id) }
        pump()
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if store.transcript(id)?.pendingAppend != nil {
            // The transcript stays as it was; the new recording is kept, ready to add with Retry.
            store.update(id) { $0.stage = "New recording not added yet"; $0.processingDevice = nil; $0.processingDeviceName = nil }
            if runningID == id { runToken = UUID(); runningTask?.cancel(); runningTask = nil; runningID = nil; pump() }
            return
        }
        if store.transcript(id)?.status == .ready {
            // The words are in; only the speaker pass was running. Stop it and keep the transcript.
            store.update(id) { $0.stage = nil }
            if runningID == id { runToken = UUID(); runningTask?.cancel(); runningTask = nil; runningID = nil; pump() }
            return
        }
        store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Cancelled. Choose Retry to run it again." }
        if runningID == id { runToken = UUID(); runningTask?.cancel(); runningTask = nil; runningID = nil; pump() }
    }

    func pump() {
        guard runningID == nil else { return }
        while let next = queue.first {
            queue.removeFirst()
            guard let t = store.transcript(next), t.status == .processing || (t.pendingAppend != nil && t.processingDevice == Device.id) else { continue }
            runningID = next
            keepRunningInBackground()
            run(next)
            return
        }
        endBackground()
        finishBackgroundWork()
    }

    private func run(_ id: UUID) {
        if let t = store.transcript(id), t.pendingAppend != nil, let url = store.audioURL(for: t) { runAppend(id, t, url); return }
        guard let t = store.transcript(id), let url = store.audioURL(for: t) else {
            store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "The audio file is missing." }
            runningID = nil; pump(); return
        }
        beginBackground()
        let (engineId, model) = engineChoice
        let wantSpeakers = identifySpeakers
        let dict = applyDictionary ? store.dictionary : []
        let project = t.projectId
        let needWave = t.waveform.isEmpty
        let progress = progressHandler(id)
        let token = UUID(); runToken = token
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                _ = await Cloud.ensureDownloaded(url)
                // Words first: the transcript opens as soon as they're ready, and speakers are added after.
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
                        if x.source == .voiceMemo, let auto = Transcript.titleFrom(out.fixed) { x.title = auto }
                    }
                    if self.queue.isEmpty { self.say("Transcript ready"); UINotificationFeedbackGenerator().notificationOccurred(.success) }
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
                await MainActor.run {
                    defer { self.finished(id, token: token) }
                    guard self.store.transcript(id)?.status == .processing else { return }
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.say("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func progressHandler(_ id: UUID) -> @Sendable (EngineProgress) -> Void {
        let gate = ProgressGate()
        return { p in
            let label = p.label
            guard gate.shouldPublish(label) else { return }
            Task { @MainActor in self.store.setStage(id, label); self.backgroundTitle(label) }
        }
    }

    /// Transcribes a continued recording and joins it onto the transcript.
    private func runAppend(_ id: UUID, _ t: Transcript, _ url: URL) {
        guard let partName = t.pendingAppend else { finished(id); return }
        beginBackground()
        let part = Paths.audio.appendingPathComponent(partName)
        let combined = Continuation.scratchURL()
        let token = UUID(); runToken = token
        let (engineId, model) = engineChoice
        let wantSpeakers = identifySpeakers
        let dict = applyDictionary ? store.dictionary : []
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
                    Cloud.remove(url)
                    Cloud.remove(part)
                    if self.queue.isEmpty { self.say("New recording added"); UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            } catch {
                try? FileManager.default.removeItem(at: combined)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.runToken == token else { return }
                    defer { self.finished(id, token: token) }
                    self.store.update(id) { $0.stage = "Couldn't add the new recording. Tap Retry."; $0.processingDevice = nil; $0.processingDeviceName = nil }
                    self.say("Couldn't add the new recording: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Throws away a continued recording that hasn't been added; the transcript stays as it was.
    func discardPendingAppend(_ id: UUID) {
        if runningID == id || queue.contains(id) { cancel(id) }
        guard let name = store.transcript(id)?.pendingAppend else { return }
        Cloud.remove(Paths.audio.appendingPathComponent(name))
        store.update(id) { $0.pendingAppend = nil; $0.stage = nil; $0.processingDevice = nil; $0.processingDeviceName = nil }
        say("New recording discarded")
    }

    private func finished(_ id: UUID, token: UUID? = nil) {
        guard runningID == id, token == nil || token == runToken else { return }
        runningID = nil; runningTask = nil
        pump()
    }

    /// Asks iOS for extra time so a transcript can finish after you leave the app. Long jobs pause when
    /// iOS suspends Verbatim and pick up again the next time it opens.
    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Transcribe") { [weak self] in self?.endBackground() }
    }
    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background); background = .invalid
    }

    // MARK: Keep transcribing after you leave the app (iOS 26)

    /// iOS 26 lets work you started keep going after you lock the phone or switch apps, with a progress
    /// banner from the system. One task covers the whole queue and ends when the queue is empty.
    private static let bgIdentifier = "co.stumpandroot.verbatim.ios.transcribe"
    private var bgRegistered = false
    private var bgTask: AnyObject? = nil
    private var bgSubmitted = false
    private var bgTicker: Timer? = nil

    private func keepRunningInBackground() {
        guard #available(iOS 26, *), !bgSubmitted else { return }
        if !bgRegistered {
            bgRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgIdentifier, using: nil) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in self?.adopt(task) }
            }
        }
        guard bgRegistered else { return }
        let req = BGContinuedProcessingTaskRequest(identifier: Self.bgIdentifier, title: "Transcribing", subtitle: "Verbatim keeps going while you're away")
        req.strategy = .fail
        do { try BGTaskScheduler.shared.submit(req); bgSubmitted = true }
        catch { Log.note("continued processing not available: \(error)") }
    }

    @available(iOS 26, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        guard runningID != nil || !queue.isEmpty else { task.setTaskCompleted(success: true); bgSubmitted = false; return }
        bgTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 5
        task.expirationHandler = { [weak self, weak task] in
            // iOS needs the time back. The job stops where it is and starts again the next time Verbatim opens.
            task?.setTaskCompleted(success: false)
            Task { @MainActor in self?.bgTask = nil; self?.bgSubmitted = false; self?.bgTicker?.invalidate() }
        }
        // The system banner expects steady progress; the engine doesn't report a fraction while transcribing.
        bgTicker?.invalidate()
        bgTicker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let task = self?.bgTask as? BGContinuedProcessingTask else { return }
                let p = task.progress
                p.completedUnitCount = min(95, p.completedUnitCount + max(1, (95 - p.completedUnitCount) / 12))
            }
        }
    }

    /// Moves the system's progress banner along with the job's stage.
    private func backgroundTitle(_ label: String) {
        guard #available(iOS 26, *), let task = bgTask as? BGContinuedProcessingTask else { return }
        task.updateTitle("Transcribing", subtitle: label)
    }

    private func finishBackgroundWork() {
        guard #available(iOS 26, *) else { return }
        if let task = bgTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        }
        bgTask = nil; bgSubmitted = false
        bgTicker?.invalidate(); bgTicker = nil
    }

    // MARK: Organizing and notes

    func delete(_ ids: [UUID]) {
        for id in ids { if runningID == id || queue.contains(id) { cancel(id) }; store.moveToTrash(id) }
        say(ids.count == 1 ? "Moved to Recently Deleted" : "Moved \(ids.count) to Recently Deleted")
    }
    func restore(_ id: UUID) { store.restore(id); say("Restored") }
    func purge(_ id: UUID) { if let t = store.transcript(id) { store.delete(t) } }
    func move(_ id: UUID, to project: UUID?) { store.update(id) { $0.projectId = project } }
    func togglePin(_ id: UUID) { store.update(id) { $0.pinned.toggle() } }
    /// Renames a speaker everywhere in the transcript. Any name works (first and last, underscores); blank keeps the old one.
    func renameSpeaker(_ id: UUID, speaker sid: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        store.update(id) { t in if let i = t.speakers.firstIndex(where: { $0.id == sid }) { t.speakers[i].name = clean } }
    }
    /// Moves one line to another speaker, or to no speaker.
    func assign(_ id: UUID, segment: UUID, to speaker: String?) {
        store.update(id) { t in if let i = t.segments.firstIndex(where: { $0.id == segment }) { t.segments[i].speaker = speaker } }
    }

    func addNote(_ id: UUID, text: String, at: Double?, segment: UUID?, bookmark: Bool = false) {
        store.addNote(Note(text: text, at: at, segmentId: segment, isBookmark: bookmark), to: id)
        say(bookmark ? "Bookmarked \((at ?? 0).timecode)" : "Note added")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    func deleteNote(_ id: UUID, note: UUID) { store.update(id) { $0.notes.removeAll { $0.id == note } } }

    func copyText(_ t: Transcript) {
        UIPasteboard.general.string = Exporter.text(t, ExportOptions.saved)
        say("Copied")
    }

    /// Writes an export to a temporary file for the share sheet.
    func exportFile(_ t: Transcript, as f: ExportFormat) -> URL? {
        var base = t.title.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Transcript" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(base + "." + f.ext)
        do {
            if f == .docx { try Exporter.writeDocx(t, options: .saved, to: url) }
            else { try Exporter.render(t, as: f, options: .saved).write(to: url, atomically: true, encoding: .utf8) }
            return url
        } catch { say("Couldn't export: \(error.localizedDescription)"); return nil }
    }
}

/// Rate-limits progress labels from engine threads (same as the Mac's).
final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    private var at = Date.distantPast
    func shouldPublish(_ label: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard label != last, now.timeIntervalSince(at) > 0.25 || !label.hasPrefix(last.prefix(12)) else { return false }
        last = label; at = now
        return true
    }
}
