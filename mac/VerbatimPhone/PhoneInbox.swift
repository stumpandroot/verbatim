import SwiftUI
import UIKit

/// Imports what the share and broadcast extensions leave in the App Group (VerbatimShare/VerbatimInbox.swift):
/// shared videos and audio files, shared web links, and the sound from Transcribe what's playing. It runs on launch,
/// each time the app becomes active, and when the broadcast extension says a recording is saved.
///
/// Each file is moved into Verbatim's own temporary folder before its manifest is deleted, so an item is never
/// imported twice, then it goes through the same import path as a picked file (`importSources`). The first new
/// item shows the "added" card, which folds and flies into the Library tab (LinkAddedCard.swift); its landing plays
/// the success haptic. Links go to the link flow, which shows its own card.
@MainActor
private enum InboxRun {
    static var busy = false
    static var watching = false
}

extension PhoneState {
    /// Listens for Transcribe what's playing finishing while Verbatim is open. Once per process.
    func watchInbox() {
        guard !InboxRun.watching else { return }
        InboxRun.watching = true
        KeyboardBridge.observe(VerbatimInbox.broadcastFinishedNote) { [weak self] in self?.importInbox() }
    }

    func importInbox() {
        // Shared files and links join the library once it has loaded (the app becomes active before it has).
        guard store.isLoaded else { store.whenLoaded { [weak self] in self?.importInbox() }; return }
        guard !InboxRun.busy else { return }
        InboxRun.busy = true
        defer { InboxRun.busy = false }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Inbox", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var sources: [ImportSource] = []
        var cardSites: [String] = []
        var links: [String] = []
        var refusedTikTok = false

        for folder in [VerbatimInbox.inbox, VerbatimInbox.broadcasts].compactMap({ $0 }) {
            sweepOrphans(in: folder)
            for item in VerbatimInbox.pending(in: folder) {
                switch item.kind {
                case .link:
                    if let s = item.url, let u = URL(string: s) {
                        if VerbatimInbox.isTikTok(u) { refusedTikTok = true } else { links.append(s) }
                    }
                    VerbatimInbox.remove(item, in: folder)
                case .file, .broadcast:
                    guard let name = item.fileName else { VerbatimInbox.remove(item, in: folder); continue }
                    if item.kind == .broadcast, (item.duration ?? 0) < 1 { VerbatimInbox.remove(item, in: folder); continue }
                    let ext = (name as NSString).pathExtension
                    let staged = staging.appendingPathComponent(item.id.uuidString + (ext.isEmpty ? "" : "." + ext))
                    try? fm.removeItem(at: staged)
                    do {
                        try fm.moveItem(at: folder.appendingPathComponent(name), to: staged)
                    } catch {
                        Log.note("inbox: couldn't take \(name): \(error)")
                        VerbatimInbox.remove(item, in: folder)
                        continue
                    }
                    VerbatimInbox.remove(item, in: folder)
                    let cleanup: () -> Void = { try? FileManager.default.removeItem(at: staged) }
                    if item.kind == .broadcast {
                        let when = item.started ?? item.date
                        sources.append(ImportSource(url: staged, title: "Played on iPhone · " + when.formatted(date: .abbreviated, time: .shortened),
                                                    label: "Played on iPhone", source: .voiceMemo, createdAt: when, finished: cleanup))
                        cardSites.append("Played on iPhone")
                    } else {
                        let original = item.originalName ?? name
                        var title = (original as NSString).deletingPathExtension
                        if title.isEmpty { title = "Shared file" }
                        let label = ext.isEmpty ? "Shared file" : ext.uppercased() + " file"
                        sources.append(ImportSource(url: staged, title: title, label: label, createdAt: item.date, finished: cleanup))
                        cardSites.append("Shared")
                    }
                }
            }
        }

        // Links first: their card gives way to a file's card when both arrive together.
        for link in links { addLink(link) }
        if !sources.isEmpty {
            let ids = importSources(sources)
            if let first = ids.first { showAddedCard(id: first, title: sources[0].title, site: cardSites[0]) }
            if ids.count > 1 { say("Added \(ids.count) items") }
        }
        if refusedTikTok {
            say("Verbose can't download TikTok videos. Save the video in TikTok, then share it to Verbose.")
        }
    }

    /// The "added" card for an item that's already here: it says Added to Queue, then folds into the Library tab.
    private func showAddedCard(id: UUID, title: String, site: String) {
        let imp = LinkImport(id: id, url: "", site: site)
        imp.title = title
        imp.phase = .queued
        if let old = linkCardImport, old.id != id { linkBadgeHeld.remove(old.id) }
        linkBadgeHeld.insert(id)
        libraryFilterRequest = "all"
        linkCardImport = imp
    }

    /// Files left without a manifest (an extension stopped mid-copy or mid-recording) are removed after six hours.
    private func sweepOrphans(in folder: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let manifests = Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
        for f in files where f.pathExtension != "json" {
            let stem = f.deletingPathExtension().lastPathComponent
            guard !manifests.contains(stem) else { continue }
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(modified) > 6 * 3600 { try? fm.removeItem(at: f) }
        }
    }
}
