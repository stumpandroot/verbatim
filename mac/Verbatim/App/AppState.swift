import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers

enum Screen: Equatable {
    case home
    case library
    case transcript(UUID)
    case dictionary
}

/// Which way the next screen slides in. Sidebar order decides up/down; opening a transcript pushes.
enum SlideDirection: Equatable { case push, pop, up, down }

@MainActor
final class AppState: ObservableObject {
    @Changed var screen: Screen = .home
    @Changed var direction: SlideDirection = .up
    @Changed var search = ""
    @Changed var projectFilter: UUID? = nil
    @Changed var focusLink = false
    @Changed var focusSearch = false
    @Changed var showMicSheet = false
    /// Counts navigations so the newest screen always stacks on top of one that is still leaving.
    @Changed var navCount = 0
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
    @Changed("captureMode") var captureMode = "voice"      // "voice" | "dictate"
    @Changed("sounds") var sounds = true { didSet { Sounds.enabled = sounds } }

    let store = Store()
    let recorder = Recorder()
    let player = Player()
    let capture = AppAudioCapture()
    let dictation = DictationController()

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
    }

    var preset: QualityPreset { QualityPreset(rawValue: presetRaw) ?? .balanced }
    var engineChoice: (engine: String, model: String) {
        preset == .advanced ? (advEngine, advModel) : (preset.config.0, preset.config.1)
    }

    // MARK: Navigation

    private static let order: [String: Int] = ["home": 0, "library": 1, "dictionary": 2]

    func go(_ next: Screen) {
        guard next != screen else { return }
        switch (screen, next) {
        case (_, .transcript): direction = .push
        case (.transcript, _): direction = .pop
        default:
            let a = Self.order[key(screen)] ?? 0, b = Self.order[key(next)] ?? 0
            direction = b > a ? .up : .down
        }
        navCount += 1
        if UITest.enabled { Log.note("UITEST go \(key(next)) nav=\(navCount)") }
        withAnimation(Motion.settle) { screen = next }
    }

    func goHome() { go(.home) }

    private func key(_ s: Screen) -> String {
        switch s { case .home: return "home"; case .library: return "library"; case .dictionary: return "dictionary"; case .transcript: return "transcript" }
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
            try recorder.start(to: store.newAudioURL(ext: "wav"))
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
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo",
                           duration: duration, audioFileName: url.lastPathComponent, model: "")
        t.waveform = env
        enqueue(t)
    }

    // MARK: App audio

    func pickApp() { goHome(); showAppPicker = true }

    func startCapture(_ app: AppAudioCapture.RunningApp) {
        showAppPicker = false
        Task {
            do {
                try await capture.start(app: app, to: store.newAudioURL(ext: "wav"))
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
            let t = Transcript(title: capture.appName.isEmpty ? "App audio" : capture.appName, source: .app, sourceLabel: capture.appName,
                               duration: duration, audioFileName: url.lastPathComponent, model: "")
            enqueue(t)
        }
    }

    // MARK: Files and links

    func importFile(_ src: URL) {
        let ext = src.pathExtension.isEmpty ? "m4a" : src.pathExtension
        let dest = store.newAudioURL(ext: ext)
        do { try FileManager.default.copyItem(at: src, to: dest) } catch {
            toast = Toast("Could not copy the file: \(error.localizedDescription)"); return
        }
        let duration = Player.duration(of: dest)
        guard duration > 0 else {
            try? FileManager.default.removeItem(at: dest)
            toast = Toast("That file has no audio Verbatim can read (\(ext.uppercased()))."); return
        }
        let t = Transcript(title: src.deletingPathExtension().lastPathComponent, source: .file,
                           sourceLabel: ext.uppercased() + " file", duration: duration, audioFileName: dest.lastPathComponent, model: "")
        enqueue(t)
    }

    /// Accepts a dropped file from Finder.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in self.importFile(url) }
        }
        return true
    }

    func transcribeLink(_ link: String) {
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
                t.sourceURL = link
                fetching = nil
                enqueue(t)
            } catch {
                fetching = nil
                verbiePose = .interrupted
                toast = Toast("Couldn't fetch that link: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Pipeline

    func retry(_ t: Transcript) {
        store.update(t.id) { $0.status = .processing; $0.error = nil; $0.stage = "Queued" }
        run(t.id)
    }

    private func enqueue(_ t: Transcript) {
        var t = t
        t.status = .processing
        t.stage = "Queued"
        if let p = projectFilter { t.projectId = p }
        store.add(t)
        verbiePose = .saved
        Task { try? await Task.sleep(nanoseconds: 700_000_000); if verbiePose == .saved { verbiePose = .working } }
        run(t.id)
    }

    private func run(_ id: UUID) {
        guard let t = store.transcript(id), let url = store.audioURL(for: t) else { return }
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
        Task.detached(priority: .userInitiated) {
            do {
                let engine = Engines.engine(for: engineId)
                var result = try await engine.transcribe(url: url, model: model, progress: progress)
                Log.note("transcribe done segments=\(result.segments.count)")
                var speakers: [Speaker] = []
                if wantSpeakers, result.segments.count > 1 {
                    do {
                        let turns = try await FluidDiarizer.shared.diarize(url: url, progress: progress)
                        speakers = SpeakerAssigner.assign(turns, to: &result.segments)
                        Log.note("diarize done speakers=\(speakers.count)")
                    } catch {
                        Log.note("diarize failed (kept transcript): \(error)")
                    }
                }
                let original = result.segments
                var fixed = result.segments
                var corrections: [Correction] = []
                if !dict.isEmpty {
                    progress(.applyingDictionary)
                    corrections = DictionaryApplier.apply(dict, to: &fixed, project: project)
                }
                let wave = needWave ? Waveform.envelope(of: url) : []
                let r = result
                await MainActor.run {
                    self.store.update(id) { x in
                        x.original = original
                        x.segments = fixed
                        x.speakers = speakers
                        x.corrections = corrections
                        x.status = .ready
                        x.stage = nil
                        x.engine = r.engine
                        x.model = r.model
                        x.language = r.language
                        if !wave.isEmpty { x.waveform = wave }
                        if x.source == .voiceMemo || x.source == .app, let auto = Transcript.titleFrom(fixed) { x.title = auto }
                    }
                    self.verbiePose = .saved
                    Sounds.done()
                    let n = corrections.count
                    self.toast = Toast(n > 0 ? "Transcript ready · Dictionary fixed \(n) word\(n == 1 ? "" : "s")" : "Transcript ready", action: "Open") { [weak self] in self?.go(.transcript(id)) }
                    Task { try? await Task.sleep(nanoseconds: 1_400_000_000); if self.verbiePose == .saved { self.verbiePose = .ready } }
                }
            } catch {
                Log.note("transcribe failed: \(error)")
                await MainActor.run {
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.verbiePose = .interrupted
                    self.toast = Toast("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
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
        store.addNote(Note(text: text, at: at, segmentId: segment, isBookmark: bookmark), to: id)
        toast = Toast(bookmark ? "Bookmarked \((at ?? 0).timecode)" : "Note added")
    }

    func deleteNote(transcript id: UUID, note nid: UUID) {
        store.update(id) { $0.notes.removeAll { $0.id == nid } }
    }

    func renameSpeaker(transcript id: UUID, speaker sid: String, to name: String) {
        store.update(id) { t in
            if let i = t.speakers.firstIndex(where: { $0.id == sid }) { t.speakers[i].name = name }
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
        return store.transcripts.filter { t in
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
