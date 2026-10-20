import SwiftUI
import AppKit

/// Links fetched on this Mac and the "link added" card that shows them (Views/LinkAddedCard.swift). yt-dlp's
/// metadata line and progress lines drive a `LinkImport` (the same model the iPhone uses); the card observes it.
extension AppState {
    // MARK: The card

    func showLinkCard(_ id: UUID) {
        // A second paste replaces the card on screen; the first link still counts in Queue.
        if let old = linkCardID, old != id { linkBadgeHeld.remove(old); retireLinkImportIfDone(old) }
        linkBadgeHeld.insert(id)
        linkCardID = id
    }

    /// The tile reached Queue: the badge counts the link now, with a pop.
    func linkCardLanded(_ id: UUID) {
        linkBadgeHeld.remove(id)
        queueBadgePops += 1
    }

    /// The card is gone (landed, faded, or cancelled).
    func closeLinkCard(_ id: UUID) {
        if linkCardID == id { linkCardID = nil }
        linkBadgeHeld.remove(id)
        retireLinkImportIfDone(id)
    }

    /// Cancel on the card: stops the download and removes the transcript it was filling.
    func cancelLinkCard(_ id: UUID) {
        linkTasks.removeValue(forKey: id)?.cancel()
        coordinator.cancelIfActive(id)
        if let t = store.transcript(id) { store.delete(t) }
        linkBadgeHeld.remove(id)
        verbiePose = .ready
    }

    /// Retry on the card, after a failed download: the same transcript, fetched again.
    func retryLinkCard(_ id: UUID) {
        guard let t = store.transcript(id), let link = t.sourceURL ?? t.link?.url else { return }
        store.update(id) { x in
            x.status = .processing; x.error = nil; x.stage = "Finding the audio"
            x.processingDevice = Device.id; x.processingDeviceName = Device.name
        }
        if linkImports[id] == nil, let u = URL(string: link) {
            let imp = LinkImport(id: id, url: link, site: LinkImport.siteName(u))
            imp.thumbnailURL = LinkImport.quickThumbnail(u)
            linkImports[id] = imp
        }
        startLinkFetch(id, link: link, keepVideo: false)
    }

    /// Queue's badge: what's queued or running, plus links still downloading, less links whose card hasn't landed.
    var queueBadgeCount: Int {
        var ids = Set(queue)
        if let r = runningID { ids.insert(r) }
        for (id, imp) in linkImports where !imp.isFinished { ids.insert(id) }
        return ids.subtracting(linkBadgeHeld).count
    }

    private func retireLinkImportIfDone(_ id: UUID) {
        guard linkCardID != id else { return }
        if linkTasks[id] == nil || linkImports[id]?.isFinished == true { linkImports[id] = nil }
    }

    // MARK: Fetching

    /// Fetches a link's audio into transcript `id`, reporting to its `LinkImport`, then queues it.
    func startLinkFetch(_ id: UUID, link: String, keepVideo: Bool) {
        guard let imp = linkImports[id] else { return }
        linkTasks[id]?.cancel()
        imp.phase = .resolving
        imp.progress = nil
        let gate = PercentStep()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let f = try await LinkFetcher.fetch(link, progress: { _ in }) { event in
                    Task { @MainActor in self.linkEvent(id, imp: imp, link: link, event, gate: gate) }
                }
                guard linkStillWanted(id) else { try? FileManager.default.removeItem(at: f.url); finishLinkTask(id); return }
                let dest = store.newAudioURL(ext: f.url.pathExtension.isEmpty ? "m4a" : f.url.pathExtension)
                try FileManager.default.moveItem(at: f.url, to: dest)
                let duration = Player.duration(of: dest)
                store.update(id) { x in
                    x.audioFileName = dest.lastPathComponent; x.duration = duration
                    if x.title.isEmpty || x.title == link || x.title.hasPrefix("http") { x.title = f.title }
                    x.sourceURL = f.pageURL ?? link
                    x.link = LinkInfo(url: f.pageURL ?? link, site: f.site, channel: f.uploader, uploadDate: f.uploadDate)
                    x.stage = "Queued"
                    x.processingDevice = Device.id; x.processingDeviceName = Device.name
                }
                if imp.title == nil { imp.title = f.title }
                if duration > 0 { imp.duration = duration }
                imp.progress = 1
                imp.phase = .queued
                coordinator.enqueueExisting(id)
                verbiePose = .ready
                if keepVideo { self.keepVideo(id) }
                finishLinkTask(id)
                // The thumbnail goes with the transcript, so Library and Links rows show it.
                if let thumb = f.thumbnail, let file = await LinkFetcher.saveThumbnail(thumb, as: id.uuidString) {
                    store.update(id) { $0.link?.thumbnailFile = file }
                } else if let file = await LinkImport.saveFrameThumbnail(from: dest, as: id.uuidString) {
                    store.update(id) { $0.link?.thumbnailFile = file }
                    if imp.thumbnailURL == nil { imp.thumbnailURL = Paths.thumbs.appendingPathComponent(file) }
                }
            } catch is CancellationError {
                finishLinkTask(id)
            } catch {
                finishLinkTask(id)
                guard linkStillWanted(id) else { return }
                Log.note("link fetch failed: \(error)")
                let message = error.localizedDescription
                store.update(id) { x in
                    x.status = .failed; x.stage = nil; x.error = "Couldn't fetch that link: \(message)"
                    x.processingDevice = nil; x.processingDeviceName = nil
                }
                imp.phase = .failed(message)
                verbiePose = .interrupted
                if linkCardID != id { toast = Toast("Couldn't fetch that link: \(message)") }
            }
        }
        linkTasks[id] = task
    }

    private func linkEvent(_ id: UUID, imp: LinkImport, link: String, _ event: LinkFetcher.Event, gate: PercentStep) {
        guard !imp.isFinished, linkTasks[id] != nil else { return }   // a late report after the fetch ended
        switch event {
        case let .meta(title, uploader, site, thumbnail, duration):
            if let title, !title.isEmpty {
                imp.title = title
                store.update(id) { x in if x.title == link || x.title.hasPrefix("http") { x.title = title } }
            }
            if let site { imp.site = site }
            // A YouTube thumbnail derived from the link is already showing; keep it rather than reload.
            if imp.thumbnailURL == nil, let thumbnail, let u = URL(string: thumbnail) { imp.thumbnailURL = u }
            if let duration, duration > 0 { imp.duration = duration }
            store.update(id) { x in
                if x.link == nil { x.link = LinkInfo(url: link, site: site, channel: uploader) }
            }
            if imp.phase == .resolving { imp.phase = .downloading; store.setStage(id, "Downloading") }
        case .progress(let fraction):
            if imp.phase == .resolving { imp.phase = .downloading }
            guard gate.changed(fraction) else { return }
            imp.progress = fraction
            store.setStage(id, "Downloading \(Int(fraction * 100))%")
        }
    }

    private func finishLinkTask(_ id: UUID) {
        linkTasks[id] = nil
        if linkCardID != id, linkImports[id]?.isFinished ?? true { linkImports[id] = nil }
    }

    /// False once the transcript is deleted or cancelled while its link was being fetched.
    private func linkStillWanted(_ id: UUID) -> Bool {
        guard let t = store.transcript(id) else { return false }
        return t.deletedAt == nil && t.status == .processing && !Task.isCancelled
    }

    /// Link downloads that stopped when Verbatim quit start again (no card; they show in Library and Queue).
    func resumeLinkFetches() {
        for t in store.live where t.source == .link && t.status == .processing && t.audioFileName == nil
            && !t.pendingLink && t.processingDevice == Device.id && !claiming.contains(t.id) && linkTasks[t.id] == nil {
            guard let link = t.sourceURL ?? t.link?.url, let u = URL(string: link) else { continue }
            let imp = LinkImport(id: t.id, url: link, site: LinkImport.siteName(u))
            linkImports[t.id] = imp
            startLinkFetch(t.id, link: link, keepVideo: false)
        }
    }

    // MARK: ⌘V

    /// ⌘V on Home, Library, or Links with a link on the clipboard adds it, unless you're typing in a field.
    func installLinkPasteMonitor() {
        guard linkPasteMonitor == nil else { return }
        linkPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers?.lowercased() == "v",
                  let window = e.window, window === self.mainWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  [Screen.home, .library, .links].contains(self.screen),
                  let link = AppState.clipboardLink else { return e }
            self.transcribeLink(link)
            return nil
        }
    }

    /// The clipboard's text when it's a single web link.
    static var clipboardLink: String? {
        let pb = NSPasteboard.general
        guard let s = (pb.string(forType: .URL) ?? pb.string(forType: .string))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.contains(where: \.isWhitespace), LinkFetcher.looksLikeLink(s) else { return nil }
        return s
    }
}

/// Lets progress through only when the whole percent changes (yt-dlp reports many times a second).
final class PercentStep {
    private var last = -1
    func changed(_ fraction: Double) -> Bool {
        let p = Int(fraction * 100)
        guard p != last else { return false }
        last = p
        return true
    }
}

/// Hands the hosting NSWindow to a closure once the view is in a window.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let w = v.window { DispatchQueue.main.async { onWindow(w) } }
    }
}
