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
    @Published var showOnboarding = Onboarding.shouldShow
    /// "New project…" from a row's menu: name it, then the transcript moves into it.
    @Published var newProjectFor: UUID? = nil
    /// The transcription queue, shared with the Mac. Lazy so it can be handed the Store.
    private(set) lazy var coordinator = TranscriptionCoordinator(store: store, config: .phone)
    /// Background time and the iOS 26 continued-processing task while the queue runs.
    private(set) lazy var backgroundWork = PhoneBackgroundWork(isBusy: { [weak self] in
        guard let self else { return false }
        return self.runningID != nil || !self.queue.isEmpty
    })
    var queue: [UUID] { coordinator.queue }
    var runningID: UUID? { coordinator.runningID }
    /// Continue recording: the transcript the current recording will be added to.
    @Published var continuing: UUID? = nil
    private var pendingContinue: UUID? = nil
    /// A passage to land on when the next transcript opens (from Moments or search).
    var focusSegment: UUID? = nil

    // Preferences (same keys as the Mac app; each device keeps its own).
    @Published var presetRaw: String = UserDefaults.standard.string(forKey: "preset") ?? QualityPreset.balanced.rawValue { didSet { UserDefaults.standard.set(presetRaw, forKey: "preset") } }
    @Published var identifySpeakers: Bool = UserDefaults.standard.object(forKey: "identifySpeakers") as? Bool ?? true { didSet { UserDefaults.standard.set(identifySpeakers, forKey: "identifySpeakers") } }
    @Published var applyDictionary: Bool = UserDefaults.standard.object(forKey: "applyDictionary") as? Bool ?? true { didSet { UserDefaults.standard.set(applyDictionary, forKey: "applyDictionary") } }
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }

    private var bag = Set<AnyCancellable>()

    init() {
        for o in [store.objectWillChange.eraseToAnyPublisher(), recorder.objectWillChange.eraseToAnyPublisher(), player.objectWillChange.eraseToAnyPublisher(),
                  coordinator.objectWillChange.eraseToAnyPublisher()] {
            o.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        coordinator.host = self
        // Resume only this iPhone's own jobs; the Mac's show as "Transcribing on Mac".
        coordinator.resume(includeUnowned: false)
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
        guard coordinator.canContinue(id) else {
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
            guard coordinator.queueAppend(recording: url, to: target) else { say("Couldn't save the recording."); return }
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
                    coordinator.enqueueExisting(id)
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

    // MARK: Pipeline (same job as the Mac, in TranscriptionCoordinator)

    private func enqueue(_ t: Transcript) { coordinator.enqueue(t) }

    func retry(_ t: Transcript) { coordinator.retry(t) }

    func cancel(_ id: UUID) { coordinator.cancel(id) }

    func pump() { coordinator.pump() }

    /// Throws away a continued recording that hasn't been added; the transcript stays as it was.
    func discardPendingAppend(_ id: UUID) { coordinator.discardPendingAppend(id) }

    // MARK: Organizing and notes

    func delete(_ ids: [UUID]) {
        for id in ids { coordinator.cancelIfActive(id); store.moveToTrash(id) }
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

extension PhoneState: TranscriptionHost {
    func jobSettings() -> TranscriptionSettings {
        let (engineId, model) = engineChoice
        return TranscriptionSettings(engineId: engineId, model: model, wantSpeakers: identifySpeakers, applyDictionary: applyDictionary)
    }

    func prepareNew(_ t: inout Transcript) {}
    func didEnqueue(_ id: UUID) {}

    /// One continued-processing task covers the whole queue; it's requested before each run starts.
    func jobStarted(_ id: UUID) { backgroundWork.keepRunning() }
    func runWillBegin(_ id: UUID) { backgroundWork.begin() }
    func queueDrained() {
        store.flush()   // the last transcript is on disk before iOS may suspend the app
        backgroundWork.end()
        backgroundWork.finish()
    }
    func progress(_ id: UUID, label: String) { backgroundWork.title(label) }

    func transcriptReady(_ id: UUID, corrections: Int, queueEmpty: Bool) {
        if queueEmpty { say("Transcript ready"); UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    func jobFailed(_ id: UUID, error: Error) {
        say("Transcription failed: \(error.localizedDescription)")
    }

    func appendReady(_ id: UUID, queueEmpty: Bool) {
        if queueEmpty { say("New recording added"); UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    func appendFailed(_ id: UUID, error: Error) {
        say("Couldn't add the new recording: \(error.localizedDescription)")
    }

    func notify(_ message: String) { say(message) }
}
