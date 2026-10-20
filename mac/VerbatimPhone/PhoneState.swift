import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import UIKit

/// The iPhone app's state: the same Store, recorder, player, and transcription job as the Mac, so every
/// transcript, note, bookmark, project, and Dictionary word syncs through iCloud both ways.
@MainActor
final class PhoneState: ObservableObject {
    enum Tab: Hashable {
        case home, library, moments, settings
        /// Left-to-right position in the tab bar, so a new tab's content can enter from the side you moved toward.
        var order: Int {
            switch self {
            case .home: return 0
            case .library: return 1
            case .moments: return 2
            case .settings: return 3
            }
        }
    }

    let store = Store()
    let recorder = Recorder()
    let player = Player()

    @Published var tab: Tab = .home {
        didSet { if tab != oldValue { tabFrom = oldValue; tabEpoch += 1 } }
    }
    /// The tab you came from, and a count of tab changes: each tab's content enters when the count moves on
    /// and it's the selected tab (`TabEntrance`).
    private(set) var tabFrom: Tab = .home
    @Published private(set) var tabEpoch = 0
    @Published var homePath = NavigationPath()
    @Published var libraryPath = NavigationPath()
    @Published var momentsPath = NavigationPath()
    @Published var toast: String? = nil
    @Published var showRecorder = false
    /// The Verbatim keyboard's session: microphone and speech model kept ready for dictation (KeyboardSession.swift).
    private(set) lazy var session = KeyboardSession(app: self)
    /// Why the recorder paused itself (a call, a microphone it couldn't follow); nil once you resume or stop.
    @Published var autoPauseReason: String? = nil
    /// Set to open Library on a kind's raw value, or "all" (the screenshot tour uses it); the Library screen clears it.
    @Published var libraryFilterRequest: String? = nil
    /// The one-time recording-consent notice, shown before the first recording on this iPhone.
    @Published var showConsentNotice = false
    static let consentNoticeKey = "consent.noticeShown"
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
    @Published var presetRaw: String = UserDefaults.standard.string(forKey: "preset") ?? QualityPreset.defaultPreset.rawValue { didSet { UserDefaults.standard.set(presetRaw, forKey: "preset") } }
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
        recorder.onAutoPaused = { [weak self] reason in self?.autoPauseReason = reason; self?.say(reason) }
        // Resume only this iPhone's own jobs; the Mac's show as "Transcribing on Mac".
        coordinator.resume(includeUnowned: false)
        if !queue.isEmpty { DispatchQueue.main.async { self.pump() } }
        if !PhoneUITest.enabled { DispatchQueue.main.async { self.resumeLinkFetches() } }
        if PhoneUITest.enabled { PhoneUITest.run(self) }
    }

    var preset: QualityPreset { QualityPreset(rawValue: presetRaw) ?? .defaultPreset }
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
        if !UserDefaults.standard.bool(forKey: Self.consentNoticeKey) { showConsentNotice = true; return }
        askMicAndRecord()
    }

    func dismissConsentNotice() { pendingContinue = nil }

    /// The consent notice's OK: remembered, then recording starts as asked.
    func acknowledgeConsentNotice() {
        UserDefaults.standard.set(true, forKey: Self.consentNoticeKey)
        askMicAndRecord()
    }

    private func askMicAndRecord() {
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                if ok { self.startRecording() } else { self.pendingContinue = nil; self.say("Microphone access is off. Turn it on in Settings › Verbatim.") }
            }
        }
    }

    func startRecording() {
        // The microphone can serve one of them: a voice memo ends the keyboard session.
        if session.isOn { session.end(reason: "The session ended for a voice memo. Tap to start a new one.") }
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
    func warmModel() {
        let (engineId, model) = engineChoice
        guard engineId == "fluid" else { return }
        Task.detached(priority: .utility) { await FluidEngine.shared.warm(model: model) }
    }

    private var engineChoice: (String, String) {
        preset == .advanced ? (UserDefaults.standard.string(forKey: "advEngine") ?? "fluid", UserDefaults.standard.string(forKey: "advModel") ?? "v2") : preset.config
    }

    /// Starts a recording that's added to the end of an existing transcript when you stop.
    func continueRecording(_ id: UUID) {
        guard coordinator.canContinue(id) else {
            say("This transcript can't take more recording right now."); return
        }
        requestRecord(appendTo: id)
    }

    /// Pause or Resume on the record screen. Resuming clears an automatic pause's reason.
    func togglePause() {
        recorder.togglePause()
        if !recorder.isPaused { autoPauseReason = nil }
    }

    func stopRecording() {
        showRecorder = false
        autoPauseReason = nil
        guard let (url, duration, env) = recorder.stop() else { continuing = nil; return }
        if recorder.lastJoinFailed {
            // Every part stays in the recordings folder; launch recovery joins it into one recording.
            continuing = nil
            say("Couldn't finish saving. Verbatim will recover the recording the next time it opens.")
            return
        }
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
        autoPauseReason = nil
        continuing = nil
        recorder.discard()
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

    /// Adds a link: the transcript appears in Library right away, then this iPhone resolves the link, downloads
    /// the audio, and transcribes it like any import. Sites the iPhone can't fetch go to the Mac when one syncs.
    func addLink(_ raw: String) {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: link), let host = u.host, host.contains("."), ["http", "https"].contains(u.scheme ?? "") else { say("That doesn't look like a link."); return }
        var t = Transcript(title: link, source: .link, sourceLabel: host.replacingOccurrences(of: "www.", with: ""), duration: 0, audioFileName: nil, model: "")
        t.sourceURL = link
        t.status = .processing
        t.stage = "Getting the link ready"
        t.processingDevice = Device.id; t.processingDeviceName = Device.name
        store.add(t)
        libraryFilterRequest = "all"
        startLinkFetch(t.id)
        // The "link added" card shows the fetch; its tile lands on the Library tab (PhoneLinkCard.swift).
        if let imp = linkImports[t.id] {
            if let old = linkCardImport, old.id != t.id { linkBadgeHeld.remove(old.id) }
            linkBadgeHeld.insert(t.id)
            linkCardImport = imp
        }
    }

    /// A show or feed found while fetching a link: the root's episode picker sheet (EpisodePicker.swift).
    struct EpisodeChoice: Identifiable {
        let id = UUID()
        let link: URL
        let show: PodcastShow?
    }
    @Published var episodeChoice: EpisodeChoice? = nil

    /// Links being fetched on this iPhone, by transcript. A "link added" view can observe `latestLinkImport`.
    @Published private(set) var linkImports: [UUID: LinkImport] = [:]
    @Published private(set) var latestLinkImport: LinkImport? = nil
    private var linkTasks: [UUID: Task<Void, Never>] = [:]
    /// The link whose "link added" card is showing.
    @Published var linkCardImport: LinkImport? = nil
    /// Links counted by the Library badge only once their card has landed there.
    @Published var linkBadgeHeld: Set<UUID> = []
    /// Goes up each time a card lands on the Library tab, so its badge pops.
    @Published var libraryBadgePops = 0

    /// Resolves, downloads, and prepares a link transcript's audio, then queues it for transcription.
    private func startLinkFetch(_ id: UUID) {
        guard let t = store.transcript(id), let link = t.sourceURL ?? t.link?.url, let u = URL(string: link) else { return }
        linkTasks[id]?.cancel()
        let imp = LinkImport(id: id, url: link, site: PhoneLinkFetcher.siteName(u))
        imp.thumbnailURL = LinkImport.quickThumbnail(u)   // YouTube's, from the video ID, before anything loads
        linkImports[id] = imp
        latestLinkImport = imp
        // The screenshot tour never touches the network.
        guard !PhoneUITest.enabled else { return }
        let bg = BackgroundTime("Download link")
        linkTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.linkImports[id] === imp { self.linkTasks[id] = nil }
                bg.end()
            }
            var downloaded: URL?
            // Called at most once per whole percent.
            let report: @Sendable (Double?) -> Void = { fraction in
                Task { @MainActor in
                    guard imp.phase == .downloading else { return }   // a late report after the download finished
                    imp.progress = fraction
                    if let fraction { self.store.setStage(id, "Downloading \(Int(fraction * 100))%") }
                }
            }
            do {
                var r: PhoneLinkFetcher.Resolved?
                let file: URL
                // The background download from before Verbatim last closed: it finished meanwhile or is still going.
                imp.phase = .downloading
                if let earlier = try await PhoneLinkFetcher.continueDownload(id, progress: report) {
                    file = earlier
                    if let t = self.store.transcript(id), !t.title.hasPrefix("http") { imp.title = t.title }
                } else {
                    imp.phase = .resolving
                    let resolved = try await PhoneLinkFetcher.resolve(u)
                    r = resolved
                    guard self.stillWanted(id) else { return }
                    imp.title = resolved.title; imp.site = resolved.site; imp.thumbnailURL = imp.thumbnailURL ?? resolved.thumbnail
                    self.store.update(id) { x in
                        if let title = resolved.title, !title.isEmpty, x.title == link || x.title.hasPrefix("http") { x.title = title }
                        x.link = LinkInfo(url: resolved.pageURL, site: resolved.site, channel: resolved.channel)
                        x.stage = "Downloading"
                    }
                    imp.phase = .downloading
                    file = try await PhoneLinkFetcher.download(resolved, id: id, progress: report)
                }
                downloaded = file
                // A direct link to a video file has no thumbnail of its own: use a frame from it.
                if r?.thumbnail == nil, imp.thumbnailURL == nil, self.store.transcript(id)?.link?.thumbnailFile == nil, let name = await LinkImport.saveFrameThumbnail(from: file, as: id.uuidString) {
                    self.store.update(id) { $0.link?.thumbnailFile = name }
                    imp.thumbnailURL = Paths.thumbs.appendingPathComponent(name)
                }
                imp.progress = 1
                imp.phase = .queued   // the audio is here; it's prepared and queued next
                guard self.stillWanted(id) else { try? FileManager.default.removeItem(at: file); return }
                self.store.setStage(id, "Preparing the audio")
                let prepared = try await MediaImport.prepare(file, into: self.store.newAudioURL(ext: "m4a"))
                try? FileManager.default.removeItem(at: file)
                guard self.stillWanted(id) else { try? FileManager.default.removeItem(at: prepared.url); return }
                imp.duration = prepared.duration
                self.store.update(id) { x in
                    x.audioFileName = prepared.url.lastPathComponent; x.duration = prepared.duration; x.stage = "Queued"
                    x.processingDevice = Device.id; x.processingDeviceName = Device.name
                }
                self.coordinator.enqueueExisting(id)
                if let thumb = r?.thumbnail, let name = await PhoneLinkFetcher.saveThumbnail(thumb, as: id.uuidString) {
                    self.store.update(id) { $0.link?.thumbnailFile = name }
                }
            } catch is CancellationError {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            } catch LinkFetchError.needsMac {
                self.handLinkToMac(id, imp)
            } catch LinkFetchError.chooseEpisode(let show) {
                // A whole show or feed: no transcript for it; the episode picker adds the one you choose.
                guard self.stillWanted(id) else { return }
                self.cancelLinkCard(id)
                self.closeLinkCard(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.episodeChoice = EpisodeChoice(link: u, show: show) }
            } catch {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
                guard self.stillWanted(id) else { return }
                let message = (error as? URLError).map { e -> String in
                    e.code == .notConnectedToInternet ? "You're offline. Choose Retry when you're connected." : e.localizedDescription
                } ?? error.localizedDescription
                Log.note("link fetch failed: \(error)")
                self.store.update(id) { x in
                    x.status = .failed; x.stage = nil; x.error = "Couldn't fetch that link: \(message)"
                    x.processingDevice = nil; x.processingDeviceName = nil
                }
                imp.phase = .failed(message)
                if self.linkCardImport?.id != id { self.say("Couldn't fetch that link") }
            }
        }
    }

    /// False once the transcript is deleted or cancelled while its link was being fetched.
    private func stillWanted(_ id: UUID) -> Bool {
        guard let t = store.transcript(id) else { return false }
        return t.deletedAt == nil && t.status == .processing && !Task.isCancelled
    }

    /// A site this iPhone can't fetch: the Mac fetches it when one syncs this library (its yt-dlp helper picks up
    /// `pendingLink`). With no Mac, the transcript stops with a message instead of waiting forever.
    private func handLinkToMac(_ id: UUID, _ imp: LinkImport) {
        guard stillWanted(id) else { return }
        if Cloud.enabled && macSeen {
            store.update(id) { x in
                x.pendingLink = true; x.status = .processing; x.stage = nil
                x.processingDevice = nil; x.processingDeviceName = nil
            }
            imp.phase = .waitingForMac
            say(LinkFetchError.needsMac.localizedDescription)
        } else {
            let message = "Verbatim can't fetch this link on iPhone yet."
            store.update(id) { x in
                x.status = .failed; x.stage = nil; x.error = message
                x.processingDevice = nil; x.processingDeviceName = nil
            }
            imp.phase = .failed(message)
            say(message)
        }
    }

    /// Whether a Mac has ever worked on this library (it's the only device that records app audio or names
    /// itself "your Mac"). Remembered once seen.
    var macSeen: Bool {
        let key = "sync.macSeen"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let seen = store.transcripts.contains { t in
            t.source == .app || (t.processingDevice != Device.id && (t.processingDeviceName ?? "").contains("Mac"))
                || t.link?.uploadDate != nil
        }
        if seen { UserDefaults.standard.set(true, forKey: key) }
        return seen
    }

    /// Link downloads that stopped when Verbatim closed start again.
    private func resumeLinkFetches() {
        for t in store.live where t.source == .link && t.status == .processing && t.audioFileName == nil
            && !t.pendingLink && t.processingDevice == Device.id {
            startLinkFetch(t.id)
        }
    }

    // MARK: Pipeline (same job as the Mac, in TranscriptionCoordinator)

    private func enqueue(_ t: Transcript) { coordinator.enqueue(t) }

    func retry(_ t: Transcript) {
        // A link whose audio never arrived: fetch it again.
        if t.source == .link, t.audioFileName == nil, t.sourceURL ?? t.link?.url != nil {
            store.update(t.id) { x in
                x.status = .processing; x.error = nil; x.pendingLink = false; x.stage = "Getting the link ready"
                x.processingDevice = Device.id; x.processingDeviceName = Device.name
            }
            startLinkFetch(t.id)
            return
        }
        coordinator.retry(t)
    }

    func cancel(_ id: UUID) {
        if let task = linkTasks.removeValue(forKey: id) {
            task.cancel()
            store.update(id) { x in
                x.status = .failed; x.stage = nil; x.error = "Cancelled. Choose Retry to run it again."
                x.processingDevice = nil; x.processingDeviceName = nil
            }
            linkImports[id]?.phase = .failed("Cancelled")
            return
        }
        coordinator.cancel(id)
    }

    func pump() { coordinator.pump() }

    /// Throws away a continued recording that hasn't been added; the transcript stays as it was.
    func discardPendingAppend(_ id: UUID) { coordinator.discardPendingAppend(id) }

    // MARK: Organizing and notes

    func delete(_ ids: [UUID]) {
        for id in ids { linkTasks.removeValue(forKey: id)?.cancel(); coordinator.cancelIfActive(id); store.moveToTrash(id) }
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

    // MARK: Settings › Sync and data

    /// Every finished transcript as Markdown and as JSON, plus the Dictionary and projects, in one zip for the
    /// share sheet. Text only: audio stays in iCloud and on the Mac. Nil when there's nothing to export.
    func exportEverything() async -> URL? {
        let items = store.live.filter { $0.status == .ready }
        guard !items.isEmpty else { say("Nothing to export yet."); return nil }
        let options = ExportOptions.saved
        let dictionary = (try? Store.enc.encode(store.dictionary)) ?? Data()
        let projects = (try? Store.enc.encode(store.projects)) ?? Data()
        let stamp = Formats.pattern("yyyy-MM-dd").string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Verbatim Export \(stamp).zip")
        let written: Bool = await Task.detached(priority: .userInitiated) {
            var zip = ZipWriter()
            var used = Set<String>()
            for t in items {
                var base = t.title.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                if base.isEmpty { base = "Transcript" }
                var name = base, n = 2
                while used.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
                used.insert(name.lowercased())
                zip.add("Markdown/\(name).md", Data(Exporter.render(t, as: .md, options: options).utf8))
                zip.add("JSON/\(name).json", Data(Exporter.render(t, as: .json, options: options).utf8))
            }
            zip.add("dictionary.json", dictionary)
            zip.add("projects.json", projects)
            return (try? zip.finish().write(to: url, options: .atomic)) != nil
        }.value
        if !written { say("Couldn't export.") }
        return written ? url : nil
    }

    /// Settings › Delete all data: every transcript (Recently Deleted too) with its audio and stills, every
    /// project, the Dictionary, About me, and the downloaded speech models. Uses the Store's own delete paths, so iCloud removes the files on
    /// every device, then waits until the deletes are on disk.
    func deleteAllData() {
        if recorder.isRecording { discardRecording() }
        session.end(reason: nil)
        player.stop()
        homePath = NavigationPath(); libraryPath = NavigationPath(); momentsPath = NavigationPath()
        coordinator.cancelAll()   // once, so cancelling one job doesn't start the next queued one
        for task in linkTasks.values { task.cancel() }
        linkTasks = [:]; linkImports = [:]; latestLinkImport = nil
        linkCardImport = nil; linkBadgeHeld = []
        for t in store.transcripts { store.delete(t) }
        store.projects = []
        store.dictionary = []
        UserDefaults.standard.removeObject(forKey: Profile.aboutMeKey)
        // Also files with no transcript in memory, speech models, and local-only copies (Store.removeAllFiles).
        store.removeAllFiles()
        say("Deleted everything")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

// MARK: - The "link added" card

extension PhoneState {
    /// The tile reached the Library tab: the badge counts the link now, with a pop.
    func linkCardLanded(_ id: UUID) {
        linkBadgeHeld.remove(id)
        libraryBadgePops += 1
    }

    /// The card is gone (landed, faded, or cancelled).
    func closeLinkCard(_ id: UUID) {
        if linkCardImport?.id == id { linkCardImport = nil }
        linkBadgeHeld.remove(id)
    }

    /// Cancel on the card: stops the download and removes the transcript it was filling.
    func cancelLinkCard(_ id: UUID) {
        linkTasks.removeValue(forKey: id)?.cancel()
        coordinator.cancelIfActive(id)
        if let t = store.transcript(id) { store.delete(t) }
        linkImports[id] = nil
        linkBadgeHeld.remove(id)
    }

    /// Retry on the card, after a failed download. The fetch starts over with a fresh `LinkImport`; the card
    /// follows it.
    func retryLinkCard(_ id: UUID) {
        guard let t = store.transcript(id) else { return }
        retry(t)
        if let imp = linkImports[id] { linkCardImport = imp }
    }

    /// The Library tab's badge: what's queued or transcribing on this iPhone, plus links still downloading, less
    /// links whose card hasn't landed yet.
    var libraryBadgeCount: Int {
        var ids = Set(queue)
        if let r = runningID { ids.insert(r) }
        for (id, imp) in linkImports where !imp.isFinished { ids.insert(id) }
        return ids.subtracting(linkBadgeHeld).count
    }
}

/// Extra time from iOS so a link download can finish after you leave the app. Ends when the download does,
/// or when iOS needs the time back (the download then starts again the next time Verbatim opens).
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
