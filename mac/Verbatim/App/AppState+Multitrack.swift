import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The multi-track sheet's tracks: files the person picked, what Verbatim read from each, and the options.
@MainActor
final class MultitrackDraft: ObservableObject, Identifiable, Equatable {
    struct Track: Identifiable, Equatable {
        let id = UUID()
        /// nil only for the UI test's made-up tracks.
        var url: URL?
        var fileName: String
        var speaker: String
        var duration: Double? = nil
        var sampleRate: Double? = nil
        var wave: [Float] = []
        var alignEnvelope: [Float]? = nil
        /// Seconds after track 1 (negative: before), once lined up.
        var offset: Double? = nil
        var problem: String? = nil
    }

    static let maxTracks = 8
    nonisolated static func == (a: MultitrackDraft, b: MultitrackDraft) -> Bool { a === b }
    nonisolated let id = UUID()

    @Changed var tracks: [Track] = []
    @Changed var alignAutomatically = true
    @Changed var ignoreBleed = true

    var canAdd: Bool { tracks.count < Self.maxTracks }
    /// Ready to transcribe: two or more readable files.
    var canStart: Bool { tracks.count >= 2 && tracks.allSatisfy { $0.url != nil && $0.problem == nil } }

    /// Adds audio files (up to eight tracks in all), skipping ones already here, and reads each in the background.
    func add(_ urls: [URL]) {
        let have = Set(tracks.compactMap(\.url?.standardizedFileURL))
        for u in MediaImport.expand(urls) where canAdd && !have.contains(u.standardizedFileURL) && MultitrackDraft.isAudio(u) {
            let name = u.lastPathComponent
            let speaker = MultitrackMath.speakerName(fromFile: name)
            let t = Track(url: u, fileName: name, speaker: speaker.isEmpty ? "Speaker \(tracks.count + 1)" : speaker)
            tracks.append(t)
            analyze(t.id, u)
        }
    }

    func remove(_ id: UUID) {
        tracks.removeAll { $0.id == id }
        realign()
    }

    func setAlign(_ auto: Bool) {
        alignAutomatically = auto
        realign()
    }

    private func analyze(_ id: UUID, _ url: URL) {
        Task.detached(priority: .userInitiated) {
            let result = Result { try MultitrackAudio.analyze(url) }
            await MainActor.run {
                guard let i = self.tracks.firstIndex(where: { $0.id == id }) else { return }
                switch result {
                case .success(let a):
                    self.tracks[i].duration = a.duration; self.tracks[i].sampleRate = a.sampleRate
                    self.tracks[i].wave = a.wave; self.tracks[i].alignEnvelope = a.alignEnvelope
                case .failure(let e):
                    self.tracks[i].problem = e.localizedDescription
                }
                self.realign()
            }
        }
    }

    /// Offsets against track 1, by sound or all zero.
    func realign() {
        guard let first = tracks.first else { return }
        var next = tracks
        next[0].offset = first.alignEnvelope == nil && alignAutomatically && first.url != nil ? nil : 0
        for i in next.indices.dropFirst() {
            if !alignAutomatically { next[i].offset = 0; continue }
            guard let ref = first.alignEnvelope, let env = next[i].alignEnvelope else {
                if next[i].url != nil { next[i].offset = nil }
                continue
            }
            let a = MultitrackMath.estimateOffset(reference: ref, track: env)
            next[i].offset = a.confidence >= MultitrackMath.minAlignConfidence ? a.offset : 0
        }
        tracks = next
    }

    /// The title: the folder all the files share, or the first file's name.
    var title: String {
        let folders = Set(tracks.compactMap { $0.url?.deletingLastPathComponent().standardizedFileURL })
        let generic: Set<String> = ["Downloads", "Desktop", "Documents", "Music", "Movies", "tmp", "Audio", "Recordings"]
        if folders.count == 1, let f = folders.first?.lastPathComponent, !f.isEmpty, f != "/", !generic.contains(f) { return f }
        return tracks.first.map { ($0.fileName as NSString).deletingPathExtension } ?? "Multi-track recording"
    }

    static func isAudio(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        if MediaImport.audioExts.contains(e) { return true }
        if MediaImport.videoExts.contains(e) { return false }
        return UTType(filenameExtension: e)?.conforms(to: .audio) ?? false
    }

    /// Made-up tracks for the UI test tour: no files, nothing transcribed.
    static func sample() -> MultitrackDraft {
        let d = MultitrackDraft()
        func wave(_ seed: Int, gaps: [Range<Int>]) -> [Float] {
            (0..<64).map { i in gaps.contains { $0.contains(i) } ? 0.04 : Float(0.25 + 0.75 * abs(sin(Double(i * 7 + seed) * 0.9))) }
        }
        d.tracks = [
            Track(url: nil, fileName: "Tim_MV7.wav", speaker: "Tim", duration: 3852, sampleRate: 48_000, wave: wave(1, gaps: [9..<18, 23..<36, 41..<52]), offset: 0),
            Track(url: nil, fileName: "Guest_SM7B.wav", speaker: "Ana", duration: 3850, sampleRate: 48_000, wave: wave(4, gaps: [0..<9, 18..<23, 36..<41, 52..<58]), offset: 0.4),
            Track(url: nil, fileName: "Room_Zoom_H6.wav", speaker: "Room", duration: 3861, sampleRate: 44_100, wave: wave(9, gaps: [30..<34]), offset: -1.2),
        ]
        return d
    }
}

extension AppState {
    // MARK: Multi-track recordings

    /// Import › Multi-track recording…: pick the files (one per mic), then the sheet.
    func chooseMultitrack() {
        guard let urls = Self.pickAudioFiles(prompt: "Choose", message: "Choose one audio file per mic, recorded at the same time (2 to 8 files).") else { return }
        openMultitrack(urls)
    }

    static func pickAudioFiles(prompt: String, message: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, UTType("public.mpeg-4-audio") ?? .audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }

    func openMultitrack(_ urls: [URL]) {
        let d = MultitrackDraft()
        d.add(urls)
        multitrackDraft = d
    }

    /// Files dropped on the window: two to eight audio files could be one recording per mic, so ask.
    func routeDroppedFiles(_ urls: [URL]) {
        let audioOnly = urls.allSatisfy { u in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && !dir.boolValue && MultitrackDraft.isAudio(u)
        }
        guard audioOnly, (2...MultitrackDraft.maxTracks).contains(urls.count) else { importFiles(urls); return }
        let alert = NSAlert()
        alert.messageText = "Transcribe as separate files or as one multi-track recording?"
        alert.informativeText = "A multi-track recording has one file per mic, all recorded at the same time. Verbose weaves them into one transcript with a speaker for each file."
        alert.addButton(withTitle: "Separate Files")
        alert.addButton(withTitle: "Multi-track Recording")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            switch r {
            case .alertFirstButtonReturn: self?.importFiles(urls)
            case .alertSecondButtonReturn: self?.openMultitrack(urls)
            default: break
            }
        }
        if let w = mainWindow { alert.beginSheetModal(for: w, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// The sheet's Transcribe button: the transcript appears in the queue right away; working copies, the
    /// line-up, and the mix happen in the background, then it joins the queue.
    func startMultitrack(_ draft: MultitrackDraft) {
        let picked = draft.tracks.filter { $0.url != nil }
        guard picked.count >= 2 else { return }
        let auto = draft.alignAutomatically
        startMultitrack(sources: picked.compactMap(\.url), sourceNames: picked.map(\.fileName),
                        speakers: picked.map(\.speaker), offsets: picked.map { auto ? $0.offset : 0 },
                        durations: picked.map { $0.duration ?? 0 }, title: draft.title, align: auto, ignoreBleed: draft.ignoreBleed)
        multitrackDraft = nil
    }

    /// Makes a multi-track transcript from files recorded at the same time, one speaker each: the sheet's tracks,
    /// or a meeting capture's mic and system tracks (App/MeetingSession.swift), which pass offsets from host time
    /// with `align` off. `onPrepared` runs on the main actor once the working copies and the mix are made (true) or
    /// that failed (false); the sources can go after true. Returns the transcript's ID.
    @discardableResult
    func startMultitrack(sources: [URL], sourceNames: [String], speakers: [String], offsets known: [Double?], durations: [Double],
                         title: String, align auto: Bool, ignoreBleed: Bool, source: SourceKind = .file, sourceLabel: String? = nil,
                         recordedAt: Date? = nil, onPrepared: ((Bool) -> Void)? = nil) -> UUID? {
        guard sources.count >= 2, sources.count == speakers.count else { return nil }
        let fileNames = sources.indices.map { "track-\($0 + 1).wav" }
        var t = Transcript(title: title, source: source, sourceLabel: sourceLabel ?? "\(sources.count) tracks",
                           duration: durations.max() ?? 0, audioFileName: nil, model: "")
        if let recordedAt { t.createdAt = recordedAt }
        t.status = .processing; t.stage = "Preparing tracks"
        t.kind = .meeting
        t.titleIsAuto = false
        t.multitrack = MultitrackInfo(tracks: sources.indices.map { i in
            let speaker = speakers[i].trimmingCharacters(in: .whitespaces)
            return AudioTrack(fileName: fileNames[i], sourceName: i < sourceNames.count ? sourceNames[i] : sources[i].lastPathComponent,
                              speaker: speaker.isEmpty ? "Speaker \(i + 1)" : speaker,
                              offset: (i < known.count ? known[i] : nil) ?? 0, duration: i < durations.count ? durations[i] : 0)
        }, ignoreBleed: ignoreBleed, alignAutomatically: auto)
        t.processingDevice = Device.id; t.processingDeviceName = Device.name
        if let p = projectFilter { t.projectId = p }
        store.add(t)
        verbiePose = .receiving
        toast = Toast("Preparing \(sources.count) tracks", action: "View") { [weak self] in self?.go(.queue) }

        let id = t.id, folder = Paths.tracks(id), mixDest = store.newAudioURL(ext: "m4a")
        let store = self.store
        multitrackTasks[id] = Task.detached(priority: .userInitiated) { [weak self] in
            let stage: (String) -> Void = { s in Task { @MainActor in store.setStage(id, s) } }
            do {
                let r = try MultitrackAudio.prepare(sources: sources, fileNames: fileNames, folder: folder, align: auto,
                                                    knownOffsets: known, mixDest: mixDest, stage: stage)
                await MainActor.run {
                    guard let self else { return }
                    self.multitrackTasks[id] = nil
                    guard store.transcript(id)?.status == .processing else {
                        try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: mixDest); return
                    }
                    store.update(id) { x in
                        x.audioFileName = mixDest.lastPathComponent
                        x.duration = r.mixDuration
                        x.waveform = r.wave
                        x.stage = "Queued"
                        let n = min(x.multitrack?.tracks.count ?? 0, r.offsets.count)
                        for i in 0..<n {
                            x.multitrack?.tracks[i].offset = r.offsets[i]
                            x.multitrack?.tracks[i].duration = r.durations[i]
                        }
                    }
                    Log.note("multitrack: prepared \(sources.count) tracks, offsets \(r.offsets.map { String(format: "%.2f", $0) })")
                    self.coordinator.enqueueExisting(id)
                    onPrepared?(true)
                }
            } catch {
                try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: mixDest)
                Log.note("multitrack: prepare failed: \(error)")
                await MainActor.run {
                    self?.multitrackTasks[id] = nil
                    onPrepared?(false)
                    guard !(error is CancellationError), store.transcript(id)?.status == .processing else { return }
                    store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    self?.jobFailed(id, error: error)
                }
            }
        }
        return id
    }
}
