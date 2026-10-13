import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers

enum Screen: Equatable {
    case home
    case transcript(UUID)
    case dictionary
}

/// Which way the next screen slides in. Sidebar order decides up/down; opening a transcript pushes.
enum SlideDirection { case push, pop, up, down }

@MainActor
final class AppState: ObservableObject {
    @Published var screen: Screen = .home
    @Published var direction: SlideDirection = .up
    @Published var search = ""
    @Published var focusLink = false
    @Published var focusSearch = false
    @Published var showMicSheet = false
    @Published var toast: Toast?
    @Published var verbiePose: VerbiePose = .ready
    @AppStorage("showMenuBar") var showMenuBar = true
    @AppStorage("modelName") var modelName = "base"
    @AppStorage("heroDismissed") var heroDismissed = false

    let store = Store()
    let recorder = Recorder()
    let player = Player()

    private var bag = Set<AnyCancellable>()

    init() {
        Log.note("AppState init; transcripts=\(store.transcripts.count)")
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    // MARK: Navigation

    private static let order: [String: Int] = ["home": 0, "dictionary": 1]

    func go(_ next: Screen) {
        guard next != screen else { return }
        switch (screen, next) {
        case (_, .transcript): direction = .push
        case (.transcript, _): direction = .pop
        default:
            let a = Self.order[key(screen)] ?? 0, b = Self.order[key(next)] ?? 0
            direction = b > a ? .up : .down
        }
        withAnimation(Motion.settle) { screen = next }
    }

    func goHome() { go(.home) }

    private func key(_ s: Screen) -> String {
        switch s { case .home: return "home"; case .dictionary: return "dictionary"; case .transcript: return "transcript" }
    }

    // MARK: Recording

    func requestRecord() {
        goHome()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startRecording()
        case .notDetermined:
            verbiePose = .permission
            showMicSheet = true
        default:
            verbiePose = .interrupted
            toast = Toast("Microphone access is off. Turn it on in System Settings › Privacy & Security.")
        }
    }

    func allowMic() {
        showMicSheet = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                if ok { self.startRecording() } else { self.verbiePose = .ready }
            }
        }
    }

    func startRecording() {
        Log.note("startRecording")
        do {
            try recorder.start(to: store.newAudioURL(ext: "wav"))
            verbiePose = .listening
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
        guard let (url, duration) = recorder.stop() else { return }
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Microphone",
                           duration: duration, audioFileName: url.lastPathComponent, model: modelName)
        t.status = .processing
        store.add(t)
        verbiePose = .saved
        Task { try? await Task.sleep(nanoseconds: 900_000_000); if verbiePose == .saved { verbiePose = .working } }
        transcribe(t)
    }

    func importFile(_ src: URL) {
        let dest = store.newAudioURL(ext: src.pathExtension.isEmpty ? "m4a" : src.pathExtension)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            toast = Toast("Could not copy the file: \(error.localizedDescription)")
            return
        }
        let duration = Player.duration(of: dest)
        var t = Transcript(title: src.deletingPathExtension().lastPathComponent, source: .file,
                           sourceLabel: src.pathExtension.uppercased() + " file", duration: duration,
                           audioFileName: dest.lastPathComponent, model: modelName)
        t.status = .processing
        store.add(t)
        verbiePose = .working
        transcribe(t)
    }

    private func transcribe(_ t: Transcript) {
        guard let url = store.audioURL(for: t) else { return }
        let model = modelName
        Log.note("transcribe start model=\(model) file=\(url.lastPathComponent)")
        Task.detached(priority: .userInitiated) {
            do {
                let segments = try await Transcriber.shared.transcribe(url: url, model: model)
                Log.note("transcribe done segments=\(segments.count)")
                await MainActor.run {
                    self.store.update(t.id) { x in
                        x.segments = segments
                        x.status = .ready
                        x.model = Transcriber.displayName(model)
                        if x.source == .voiceMemo { x.title = Transcript.titleFrom(segments) ?? x.title }
                    }
                    self.verbiePose = .saved
                    self.toast = Toast("Transcript ready", action: "Open") { [weak self] in self?.go(.transcript(t.id)) }
                    Task { try? await Task.sleep(nanoseconds: 1_400_000_000); if self.verbiePose == .saved { self.verbiePose = .ready } }
                }
            } catch {
                Log.note("transcribe failed: \(error)")
                await MainActor.run {
                    self.store.update(t.id) { $0.status = .failed; $0.error = error.localizedDescription }
                    self.verbiePose = .interrupted
                    self.toast = Toast("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
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

    // MARK: Search

    var filtered: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.transcripts }
        return store.transcripts.filter { $0.title.lowercased().contains(q) || $0.text.lowercased().contains(q) }
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
