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
    @Changed var focusLink = false
    @Changed var focusSearch = false
    @Changed var showMicSheet = false
    @Changed var showAppPicker = false
    @Changed var toast: Toast? = nil
    @Changed var verbiePose: VerbiePose = .ready
    @Changed var fetching: String? = nil     // link fetch status line on Home

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

    /// Transcripts waiting to run, oldest first. One runs at a time.
    @Changed var queue: [UUID] = []
    @Changed var runningID: UUID? = nil
    /// A passage to scroll to and select when the next transcript opens (from search, a note, a link).
    var focusSegment: UUID? = nil
    private var runningTask: Task<Void, Never>? = nil
    private var claiming: Set<UUID> = []

    private var bag = Set<AnyCancellable>()

    init() {
        Sounds.enabled = sounds
        Log.note("AppState init; transcripts=\(store.transcripts.count)")
        for o in [store.objectWillChange.eraseToAnyPublisher(), recorder.objectWillChange.eraseToAnyPublisher(),
                  player.objectWillChange.eraseToAnyPublisher(), capture.objectWillChange.eraseToAnyPublisher(),
                  dictation.objectWillChange.eraseToAnyPublisher()] {
            o.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        dictation.attach(self)
        applyAppearance()
        // Anything still queued or mid-transcription when Verbatim last quit picks up where it left off.
        // Only jobs this Mac started: the iPhone's jobs show as "Transcribing on iPhone" and stay its own.
        queue = store.live.filter { $0.status == .processing && $0.audioFileName != nil && ($0.processingDevice == nil || $0.processingDevice == Device.id) }
            .sorted { $0.createdAt < $1.createdAt }.map(\.id)
        // Links added on the iPhone wait for a Mac: claim them now and whenever more arrive.
        store.onRemoteChange = { [weak self] t in self?.claimIfPendingLink(t) }
        DispatchQueue.main.async { for t in self.store.live where t.pendingLink { self.claimIfPendingLink(t) } }
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

    // MARK: Recording (microphone)

    func requestRecord() {
        goHome()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startRecording()
        case .notDetermined:
            verbiePose = .permission
            showMicSheet = true
        default:
            verbiePose = .interrupted
            toast = Toast("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
        }
    }

    func allowMic() {
        showMicSheet = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in if ok { self.startRecording() } else { self.verbiePose = .ready } }
        }
    }

    func startRecording() {
        Log.note("startRecording")
        do {
            try recorder.start(to: store.newRecordingURL())
            verbiePose = .listening
            Sounds.start()
        } catch {
            verbiePose = .interrupted
            toast = Toast("Could not start recording: \(error.localizedDescription)")
        }
    }

    func togglePause() {
        recorder.togglePause()
        verbiePose = recorder.isPaused ? .paused : .listening
    }

    func stopRecording() {
        guard let stopped = recorder.stop() else { return }
        let (url, duration, env) = stopped
        guard duration >= 0.5 else { try? FileManager.default.removeItem(at: url); verbiePose = .ready; return }
        guard let name = store.adoptRecording(url) else { toast = Toast("Couldn't save the recording."); return }
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo",
                           duration: duration, audioFileName: name, model: "")
        t.waveform = env
        enqueue(t)
    }

    // MARK: App audio

    func pickApp() { goHome(); showAppPicker = true }

    func startCapture(_ app: AppAudioCapture.RunningApp) {
        showAppPicker = false
        Task {
            do {
                try await capture.start(app: app, to: store.newRecordingURL())
                verbiePose = .listening
            } catch {
                verbiePose = .interrupted
                toast = Toast("Could not capture \(app.name): \(error.localizedDescription). Allow Verbatim under System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
        }
    }

    func stopCapture() {
        Task {
            guard let (url, duration) = await capture.stop() else { return }
            guard let name = store.adoptRecording(url) else { toast = Toast("Couldn't save the capture."); return }
            let t = Transcript(title: capture.appName.isEmpty ? "App audio" : capture.appName, source: .app, sourceLabel: capture.appName,
                               duration: duration, audioFileName: name, model: "")
            enqueue(t)
        }
    }

    // MARK: Files and links

    func importFile(_ src: URL) { importFiles([src]) }

    /// The open panel: any number of audio or video files, or whole folders.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent, .mpeg4Movie, .mp3, .wav, .aiff, .quickTimeMovie, UTType("public.mpeg-4-audio") ?? .audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Transcribe"
        panel.message = "Choose audio or video files, or folders. They're transcribed one at a time, in order."
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    /// Imports any number of files or folders. Each gets a Library entry right away; files are copied (and video
    /// reduced to its audio) one after another in the background, and each joins the queue as soon as it's ready.
    func importFiles(_ urls: [URL]) {
        let files = MediaImport.expand(urls)
        guard !files.isEmpty else { toast = Toast("No audio or video files found there."); return }
        var pending: [(UUID, URL)] = []
        for src in files {
            var t = Transcript(title: src.deletingPathExtension().lastPathComponent, source: .file,
                               sourceLabel: src.pathExtension.uppercased() + " file", duration: 0, audioFileName: nil, model: "")
            t.status = .processing; t.stage = "Importing"
            if let p = projectFilter { t.projectId = p }
            store.add(t)
            pending.append((t.id, src))
        }
        if files.count > 1 { toast = Toast("Added \(files.count) files to the queue", action: "View") { [weak self] in self?.go(.queue) } }
        verbiePose = .receiving
        Task {
            for (id, src) in pending {
                guard store.transcript(id)?.status == .processing else { continue }   // cancelled while waiting
                do {
                    let dest = store.newAudioURL(ext: "m4a")
                    let prepared = try await MediaImport.prepare(src, into: dest)
                    let isVideo = MediaImport.videoExts.contains(src.pathExtension.lowercased())
                    store.update(id) {
                        $0.audioFileName = prepared.url.lastPathComponent; $0.duration = prepared.duration; $0.stage = "Queued"
                        if isVideo { $0.originalMedia = src.path }
                    }
                    queue.append(id)
                    pump()
                } catch {
                    store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                }
            }
        }
    }

    /// Accepts files and folders dropped from Finder, any number at once.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let ps = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !ps.isEmpty else { return false }
        let collector = URLCollector(expected: ps.count) { [weak self] urls in Task { @MainActor in self?.importFiles(urls) } }
        for p in ps {
            p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                collector.add(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
            }
        }
        return true
    }

    func transcribeLink(_ link: String, keepVideo: Bool? = nil) {
        let alsoKeep = keepVideo ?? keepVideoByDefault
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LinkFetcher.looksLikeLink(link) else { toast = Toast("That doesn't look like a link."); return }
        guard LinkFetcher.helperURL != nil else { toast = Toast("Links need the yt-dlp helper, which this build is missing."); return }
        fetching = "Fetching audio…"
        verbiePose = .working
        Task {
            do {
                let f = try await LinkFetcher.fetch(link) { s in Task { @MainActor in self.fetching = s } }
                let dest = store.newAudioURL(ext: f.url.pathExtension.isEmpty ? "m4a" : f.url.pathExtension)
                try FileManager.default.moveItem(at: f.url, to: dest)
                let duration = Player.duration(of: dest)
                var t = Transcript(title: f.title, source: .link, sourceLabel: URL(string: link)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link",
                                   duration: duration, audioFileName: dest.lastPathComponent, model: "")
                t.sourceURL = f.pageURL ?? link
                t.link = LinkInfo(url: f.pageURL ?? link, site: f.site, channel: f.uploader, uploadDate: f.uploadDate)
                fetching = nil
                enqueue(t)
                if alsoKeep { self.keepVideo(t.id) }
                if let thumb = f.thumbnail {
                    let id = t.id
                    Task { if let file = await LinkFetcher.saveThumbnail(thumb, as: id.uuidString) { self.store.update(id) { $0.link?.thumbnailFile = file } } }
                }
            } catch {
                fetching = nil
                verbiePose = .interrupted
                toast = Toast("Couldn't fetch that link: \(error.localizedDescription)")
            }
        }
    }

    /// A link added on the iPhone: this Mac fetches its audio into the same transcript and transcribes it.
    func claimIfPendingLink(_ t: Transcript) {
        guard t.pendingLink, t.deletedAt == nil, t.audioFileName == nil, LinkFetcher.helperURL != nil,
              let link = t.sourceURL ?? t.link?.url, !claiming.contains(t.id) else { return }
        claiming.insert(t.id)
        let id = t.id
        store.update(id) { $0.pendingLink = false; $0.stage = "Fetching audio"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
        Log.note("claiming iPhone link \(link)")
        Task {
            defer { claiming.remove(id) }
            do {
                let f = try await LinkFetcher.fetch(link) { s in Task { @MainActor in self.store.setStage(id, s) } }
                let dest = store.newAudioURL(ext: f.url.pathExtension.isEmpty ? "m4a" : f.url.pathExtension)
                try FileManager.default.moveItem(at: f.url, to: dest)
                let duration = Player.duration(of: dest)
                store.update(id) { x in
                    x.audioFileName = dest.lastPathComponent; x.duration = duration
                    if x.title.isEmpty || x.title == "Link" || x.title.hasPrefix("http") { x.title = f.title }
                    x.sourceURL = f.pageURL ?? link
                    x.link = LinkInfo(url: f.pageURL ?? link, site: f.site, channel: f.uploader, uploadDate: f.uploadDate)
                    x.stage = "Queued"
                }
                queue.append(id); pump()
                if let thumb = f.thumbnail, let file = await LinkFetcher.saveThumbnail(thumb, as: id.uuidString) { store.update(id) { $0.link?.thumbnailFile = file } }
            } catch {
                store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Couldn't fetch that link: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: Pipeline

    func retry(_ t: Transcript) {
        guard t.audioFileName != nil else { toast = Toast("That recording's audio is missing."); return }
        store.update(t.id) { $0.status = .processing; $0.error = nil; $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
        if !queue.contains(t.id) && runningID != t.id { queue.append(t.id) }
        pump()
    }

    private func enqueue(_ t: Transcript) {
        var t = t
        t.status = .processing
        t.stage = "Queued"
        t.processingDevice = Device.id; t.processingDeviceName = Device.name
        if let p = projectFilter { t.projectId = p }
        store.add(t)
        verbiePose = .saved
        Task { try? await Task.sleep(nanoseconds: 700_000_000); if verbiePose == .saved { verbiePose = .working } }
        queue.append(t.id)
        pump()
    }

    /// Starts the next queued transcript if nothing is running.
    func pump() {
        guard runningID == nil else { return }
        while let next = queue.first {
            queue.removeFirst()
            guard store.transcript(next)?.status == .processing else { continue }
            runningID = next
            run(next)
            return
        }
    }

    /// Stops a queued or running transcript. It stays in Library as "Cancelled" with Retry.
    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Cancelled. Choose Retry to run it again." }
        if runningID == id {
            runningTask?.cancel(); runningTask = nil
            runningID = nil
            pump()
        }
    }

    func cancelAll() {
        for id in queue { store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Cancelled. Choose Retry to run it again." } }
        queue = []
        if let r = runningID { cancel(r) }
    }

    /// Called when a run ends for any reason.
    private func finished(_ id: UUID) {
        guard runningID == id else { return }
        runningID = nil; runningTask = nil
        pump()
    }

    private func run(_ id: UUID) {
        guard let t = store.transcript(id), let url = store.audioURL(for: t) else {
            store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "The audio file is missing." }
            runningID = nil; pump(); return
        }
        let (engineId, model) = engineChoice
        let wantSpeakers = identifySpeakers
        let dict = applyDictionary ? store.dictionary : []
        let project = t.projectId
        let needWave = t.waveform.isEmpty
        Log.note("transcribe start engine=\(engineId) model=\(model) file=\(url.lastPathComponent)")
        // Progress can arrive many times a second while a model downloads. Publish at most ~4×/s, only when
        // the label changed, and without touching the disk: `stage` is display-only.
        let gate = ProgressGate()
        let progress: @Sendable (EngineProgress) -> Void = { p in
            let label = p.label
            guard gate.shouldPublish(label) else { return }
            Task { @MainActor in self.store.setStage(id, label) }
        }
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                let out = try await TranscriptionJob.run(url: url, engineId: engineId, model: model, wantSpeakers: wantSpeakers,
                                                         dictionary: dict, project: project, needWave: needWave, progress: progress)
                let original = out.original, fixed = out.fixed, speakers = out.speakers, corrections = out.corrections, wave = out.wave
                await MainActor.run {
                    defer { self.finished(id) }
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
                        if x.source == .voiceMemo || x.source == .app || x.source == .dictation, let auto = Transcript.titleFrom(fixed) { x.title = auto }
                    }
                    self.verbiePose = .saved
                    // In a batch, stay quiet until the last one; then one chime and one toast.
                    if self.queue.isEmpty {
                        Sounds.done()
                        let n = corrections.count
                        self.toast = Toast(n > 0 ? "Transcript ready · Dictionary fixed \(n) word\(n == 1 ? "" : "s")" : "Transcript ready", action: "Open") { [weak self] in self?.go(.transcript(id)) }
                    }
                    Task { try? await Task.sleep(nanoseconds: 1_400_000_000); if self.verbiePose == .saved { self.verbiePose = .ready } }
                }
            } catch {
                Log.note("transcribe failed: \(error)")
                await MainActor.run {
                    defer { self.finished(id) }
                    guard self.store.transcript(id)?.status == .processing else { return }
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.verbiePose = .interrupted
                    self.toast = Toast("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    // MARK: Organizing

    func move(_ ids: [UUID], to project: UUID?) {
        for id in ids { store.update(id) { $0.projectId = project } }
        let name = project.flatMap { p in store.projects.first { $0.id == p }?.name }
        toast = Toast(name.map { "Moved \(ids.count == 1 ? "1 transcript" : "\(ids.count) transcripts") to \($0)" } ?? "Removed from project")
        Sounds.play("Tink")
    }

    func delete(_ ids: [UUID]) {
        // Moves to Recently Deleted (kept 30 days). Undo puts them straight back.
        for id in ids { if runningID == id || queue.contains(id) { cancel(id) }; store.moveToTrash(id) }
        if case .transcript(let open) = screen, ids.contains(open) { go(.library) }
        toast = Toast(ids.count == 1 ? "Moved to Recently Deleted" : "Moved \(ids.count) to Recently Deleted", action: "Undo") { [weak self] in
            ids.forEach { self?.store.restore($0) }
        }
    }

    func restore(_ ids: [UUID]) {
        ids.forEach { store.restore($0) }
        toast = Toast(ids.count == 1 ? "Restored" : "Restored \(ids.count) transcripts")
    }

    /// Permanent. Only offered from Recently Deleted.
    func purge(_ ids: [UUID]) {
        for id in ids { if let t = store.transcript(id) { store.delete(t) } }
    }

    // MARK: Editing

    /// Replaces a word in one segment; with `remember`, teaches the Dictionary so future transcripts get it right.
    func correct(transcript id: UUID, segment sid: UUID, from: String, to: String, remember: Bool) {
        store.update(id) { t in
            guard let i = t.segments.firstIndex(where: { $0.id == sid }) else { return }
            t.segments[i].text = t.segments[i].text.replacingOccurrences(of: from, with: to)
            t.corrections.append(Correction(segmentId: sid, from: from, to: to, byDictionary: false))
        }
        if remember, let t = store.transcript(id) {
            store.remember(preferred: to, heardAs: from, from: t.title, project: projectScopedVocabulary ? t.projectId : nil)
            toast = Toast("\(to) added to Dictionary" + (projectScopedVocabulary && t.projectId != nil ? " for this project" : ""))
        }
    }

    func addNote(transcript id: UUID, text: String, at: Double?, segment: UUID?, bookmark: Bool = false) {
        let note = Note(text: text, at: at, segmentId: segment, isBookmark: bookmark)
        store.addNote(note, to: id)
        toast = Toast(bookmark ? "Bookmarked \((at ?? 0).timecode)" : "Note added")
        if at != nil, let video = store.transcript(id)?.videoFile { grabFrames(id, video: video, only: [note.id]) }
    }

    // MARK: Keep

    /// Saves the link's video as an MP4 in the Keep folder. Notes with a moment get a still once it lands.
    func keepVideo(_ id: UUID) {
        guard let t = store.transcript(id), keeping[id] == nil else { return }
        guard let url = t.linkInfo?.url ?? t.sourceURL else { toast = Toast("Only link transcripts have a video to keep."); return }
        guard LinkFetcher.helperURL != nil else { toast = Toast("Keeping video needs the yt-dlp helper, which this build is missing."); return }
        keeping[id] = "Keeping video"
        let gate = ProgressGate()
        let title = t.title
        Task {
            do {
                let out = try await Keep.video(link: url, title: title) { s in
                    if gate.shouldPublish(s) { Task { @MainActor in if self.keeping[id] != nil { self.keeping[id] = s } } }
                }
                keeping[id] = nil
                store.update(id) { $0.keptVideo = out.path }
                toast = Toast("Kept “\(out.lastPathComponent)”", action: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                grabFrames(id, video: out)
            } catch {
                keeping[id] = nil
                toast = Toast("Couldn't keep the video: \(error.localizedDescription)")
            }
        }
    }

    /// Copies the transcript's audio to the Keep folder (M4A for links, recordings, and imports).
    func keepAudio(_ id: UUID) {
        guard let t = store.transcript(id), let name = t.audioFileName else { toast = Toast("That transcript's audio is missing."); return }
        let src = Paths.audio.appendingPathComponent(name)
        do {
            let out = try Keep.destination(title: t.title, ext: src.pathExtension.isEmpty ? "m4a" : src.pathExtension)
            try FileManager.default.copyItem(at: src, to: out)
            store.update(id) { $0.keptAudio = out.path }
            toast = Toast("Kept “\(out.lastPathComponent)”", action: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
        } catch {
            toast = Toast("Couldn't keep the audio: \(error.localizedDescription)")
        }
    }

    func showKept(_ path: String?) {
        guard let path, FileManager.default.fileExists(atPath: path) else { toast = Toast("That file has moved or been deleted."); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Stills for notes pinned to a moment that don't have one yet (or just `only`).
    func grabFrames(_ id: UUID, video: URL, only: Set<UUID>? = nil) {
        guard let t = store.transcript(id) else { return }
        let wanted = t.notes.filter { n in n.at != nil && (only.map { $0.contains(n.id) } ?? (n.frameFile == nil)) }
        guard !wanted.isEmpty else { return }
        Task {
            for n in wanted {
                guard let at = n.at, let file = await Keep.frame(from: video, at: at, name: n.id.uuidString) else { continue }
                store.update(id) { t in if let i = t.notes.firstIndex(where: { $0.id == n.id }) { t.notes[i].frameFile = file } }
            }
        }
    }

    /// Fills in missing stills for every transcript with a video on this Mac. Runs once at launch.
    func backfillFrames() {
        for t in store.live where t.notes.contains(where: { $0.at != nil && $0.frameFile == nil }) {
            if let v = t.videoFile { grabFrames(t.id, video: v) }
        }
    }

    func deleteNote(transcript id: UUID, note nid: UUID) {
        store.update(id) { $0.notes.removeAll { $0.id == nid } }
    }

    func renameSpeaker(transcript id: UUID, speaker sid: String, to name: String) {
        store.update(id) { t in
            // Any name works: first and last, initials, underscores. Only surrounding spaces are trimmed.
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = t.speakers.firstIndex(where: { $0.id == sid }), !clean.isEmpty { t.speakers[i].name = clean }
        }
    }

    func assign(transcript id: UUID, segment seg: UUID, to speaker: String?) {
        store.update(id) { t in
            if let i = t.segments.firstIndex(where: { $0.id == seg }) { t.segments[i].speaker = speaker }
        }
    }

    // MARK: Search

    var filtered: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.live.filter { t in
            (projectFilter == nil || t.projectId == projectFilter) &&
            (q.isEmpty || t.title.lowercased().contains(q) || t.text.lowercased().contains(q))
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    init(_ message: String, action: String? = nil, onAction: (() -> Void)? = nil) {
        self.message = message; self.action = action; self.onAction = onAction
    }
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// Rate-limits progress labels from engine threads.
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
