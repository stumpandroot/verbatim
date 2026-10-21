import SwiftUI
import UniformTypeIdentifiers

/// Files from the open panel or a drop, links, and links handed over from the iPhone.
extension AppState {
    // MARK: Files and links

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
    /// Returns each new transcript with the file it came from. Watched folders (FolderWatcher) pass `useLibraryProject: false`
    /// so a file never lands in whatever project the Library happens to show, and `announce: false` to stay quiet.
    @discardableResult
    func importFiles(_ urls: [URL], useLibraryProject: Bool = true, announce: Bool = true) -> [(UUID, URL)] {
        let files = MediaImport.expand(urls)
        guard !files.isEmpty else { if announce { toast = Toast("No audio or video files found there.") }; return [] }
        var pending: [(UUID, URL)] = []
        let projectId: UUID? = useLibraryProject ? projectFilter : nil
        for src in files {
            var t = Transcript(title: src.deletingPathExtension().lastPathComponent, source: .file,
                               sourceLabel: src.pathExtension.uppercased() + " file", duration: 0, audioFileName: nil, model: "")
            t.status = .processing; t.stage = "Importing"
            if let p = projectId { t.projectId = p }
            store.add(t)
            pending.append((t.id, src))
        }
        if announce && files.count > 1 { toast = Toast("Added \(files.count) files to the queue", action: "View") { [weak self] in self?.go(.queue) } }
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
                    coordinator.enqueueExisting(id)
                } catch {
                    store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                    FolderWatcher.shared.transcriptFailed(id, error: error)
                }
            }
        }
        return pending
    }

    /// Accepts files and folders dropped from Finder, any number at once. Two to eight audio files ask whether
    /// they're separate recordings or one multi-track recording (AppState+Multitrack).
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let ps = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !ps.isEmpty else { return false }
        let collector = URLCollector(expected: ps.count) { [weak self] urls in Task { @MainActor in self?.routeDroppedFiles(urls) } }
        for p in ps {
            p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                collector.add(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
            }
        }
        return true
    }

    /// Adds a link: the transcript appears right away and the "link added" card shows the fetch as it happens
    /// (AppState+LinkCard). Every place that takes a link comes through here.
    func transcribeLink(_ link: String, keepVideo: Bool? = nil) {
        let alsoKeep = keepVideo ?? keepVideoByDefault
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LinkFetcher.looksLikeLink(link), let u = URL(string: link) else { toast = Toast("That doesn't look like a link."); return }
        guard LinkFetcher.helperURL != nil else { toast = Toast("Links need the yt-dlp helper, which this build is missing."); return }
        verbiePose = .working
        var t = Transcript(title: link, source: .link, sourceLabel: u.host?.replacingOccurrences(of: "www.", with: "") ?? "Link",
                           duration: 0, audioFileName: nil, model: "")
        t.sourceURL = link
        t.status = .processing; t.stage = "Finding the audio"
        t.processingDevice = Device.id; t.processingDeviceName = Device.name
        if let p = projectFilter { t.projectId = p }
        store.add(t)
        let imp = LinkImport(id: t.id, url: link, site: LinkImport.siteName(u))
        imp.thumbnailURL = LinkImport.quickThumbnail(u)
        linkImports[t.id] = imp
        showLinkCard(t.id)
        startLinkFetch(t.id, link: link, keepVideo: alsoKeep)
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
                coordinator.enqueueExisting(id)
                if let thumb = f.thumbnail, let file = await LinkFetcher.saveThumbnail(thumb, as: id.uuidString) { store.update(id) { $0.link?.thumbnailFile = file } }
            } catch {
                store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = "Couldn't fetch that link: \(error.localizedDescription)" }
            }
        }
    }
}
