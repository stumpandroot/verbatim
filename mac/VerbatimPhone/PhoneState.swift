import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import UIKit

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
    @Published var queue: [UUID] = []
    @Published var runningID: UUID? = nil
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
        queue = store.live.filter { $0.status == .processing && $0.audioFileName != nil && $0.processingDevice == Device.id }
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

    func requestRecord() {
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                if ok { self.startRecording() } else { self.say("Microphone access is off. Turn it on in Settings › Verbatim.") }
            }
        }
    }

    func startRecording() {
        do {
            try recorder.start(to: store.newRecordingURL())
            showRecorder = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            say("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        showRecorder = false
        guard let (url, duration, env) = recorder.stop() else { return }
        guard duration >= 0.5 else { try? FileManager.default.removeItem(at: url); return }
        guard let name = store.adoptRecording(url) else { say("Couldn't save the recording."); return }
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo", duration: duration, audioFileName: name, model: "")
        t.waveform = env
        enqueue(t)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func discardRecording() {
        showRecorder = false
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
        store.update(t.id) { $0.status = .processing; $0.error = nil; $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
        if !queue.contains(t.id) && runningID != t.id { queue.append(t.id) }
        pump()
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Cancelled. Choose Retry to run it again." }
        if runningID == id { runningTask?.cancel(); runningTask = nil; runningID = nil; pump() }
    }

    func pump() {
        guard runningID == nil else { return }
        while let next = queue.first {
            queue.removeFirst()
            guard store.transcript(next)?.status == .processing else { continue }
            runningID = next
            run(next)
            return
        }
        endBackground()
    }

    private func run(_ id: UUID) {
        guard let t = store.transcript(id), let url = store.audioURL(for: t) else {
            store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "The audio file is missing." }
            runningID = nil; pump(); return
        }
        beginBackground()
        let (engineId, model) = preset == .advanced ? (UserDefaults.standard.string(forKey: "advEngine") ?? "fluid", UserDefaults.standard.string(forKey: "advModel") ?? "v3") : preset.config
        let wantSpeakers = identifySpeakers
        let dict = applyDictionary ? store.dictionary : []
        let project = t.projectId
        let needWave = t.waveform.isEmpty
        let gate = ProgressGate()
        let progress: @Sendable (EngineProgress) -> Void = { p in
            let label = p.label
            guard gate.shouldPublish(label) else { return }
            Task { @MainActor in self.store.setStage(id, label) }
        }
        runningTask = Task.detached(priority: .userInitiated) {
            do {
                _ = await Cloud.ensureDownloaded(url)
                let out = try await TranscriptionJob.run(url: url, engineId: engineId, model: model, wantSpeakers: wantSpeakers,
                                                         dictionary: dict, project: project, needWave: needWave, progress: progress)
                await MainActor.run {
                    defer { self.finished(id) }
                    guard self.store.transcript(id)?.status == .processing else { return }
                    self.store.update(id) { x in
                        x.original = out.original; x.segments = out.fixed; x.speakers = out.speakers; x.corrections = out.corrections
                        x.status = .ready; x.stage = nil; x.engine = out.engine; x.model = out.model; x.language = out.language
                        x.processingDevice = nil; x.processingDeviceName = nil
                        if !out.wave.isEmpty { x.waveform = out.wave }
                        if x.source == .voiceMemo, let auto = Transcript.titleFrom(out.fixed) { x.title = auto }
                    }
                    if self.queue.isEmpty { self.say("Transcript ready"); UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            } catch {
                await MainActor.run {
                    defer { self.finished(id) }
                    guard self.store.transcript(id)?.status == .processing else { return }
                    self.store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self.say("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finished(_ id: UUID) {
        guard runningID == id else { return }
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
