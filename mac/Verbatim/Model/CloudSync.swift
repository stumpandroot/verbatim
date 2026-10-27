import Foundation

/// Watches Verbatim's iCloud folder and feeds changes from the other device into the Store.
/// Transcript files and stills download as soon as they appear; audio downloads when it's first played.
/// Conflicts (both devices edited one transcript while offline) resolve to the most recent version.
@MainActor
final class CloudSync: NSObject {
    private weak var store: Store?
    private let query = NSMetadataQuery()
    private var seen: [String: Date] = [:]
    /// When this device last wrote (or loaded unchanged) each transcript file. An update carrying the same date is
    /// this device's own write coming back, so the file isn't decoded again.
    private var lastWritten: [UUID: (date: Date, size: Int?)] = [:]

    init(store: Store) { self.store = store }

    /// Dates of the files the Store read at launch, so the first gather doesn't decode every transcript twice.
    func seed(_ dates: [UUID: Date]) { for (id, d) in dates { lastWritten[id] = (d, nil) } }

    /// The Store finished writing a transcript file; `date` is its modification date on disk.
    func wrote(_ id: UUID, at date: Date, size: Int? = nil) { lastWritten[id] = (date, size) }

    func start() {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        nc.addObserver(self, selector: #selector(changed(_:)), name: .NSMetadataQueryDidUpdate, object: query)
        query.start()
        Log.note("cloud sync started at \(Paths.root.path)")
    }

    @objc private func changed(_ n: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        guard let store else { return }
        var transcriptsChanged: [URL] = [], unchanged: [URL] = []
        var projects = false, dictionary = false, snippets = false, templates = false, recipes = false, plans = false, profile = false
        // Every item once when gathering finishes; after that only what each update says was added or changed.
        let items: [Any]
        if n.name == .NSMetadataQueryDidUpdate {
            items = (n.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? [])
                + (n.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? [])
        } else {
            items = query.results
        }
        for case let item as NSMetadataItem in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let dir = url.deletingLastPathComponent().lastPathComponent
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let current = status == NSMetadataUbiquitousItemDownloadingStatusCurrent
            if !current {
                // Small files come down right away; audio waits until it's played.
                if dir != "audio" { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                continue
            }
            let mod = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date ?? .distantPast
            if seen[url.path] == mod { continue }
            seen[url.path] = mod
            switch (dir, url.lastPathComponent) {
            case ("transcripts", _):
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), let w = lastWritten[id], abs(w.date.timeIntervalSince(mod)) < 1,
                   w.size == nil || (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue == w.size {
                    // Same date and size as this device's own write: it's ours coming back.
                    unchanged.append(url)
                } else {
                    transcriptsChanged.append(url)
                }
            case (_, "projects.json"), (_, "projects-deleted.json"): projects = true
            case (_, "dictionary.json"), (_, "dictionary-deleted.json"): dictionary = true
            case (_, "snippets.json"), (_, "snippets-deleted.json"): snippets = true
            case (_, "templates.json"), (_, "templates-deleted.json"): templates = true
            case (_, "recipes.json"), (_, "recipes-deleted.json"): recipes = true
            case (_, "plans.json"), (_, "plans-deleted.json"): plans = true
            case (_, "profile.json"): profile = true
            default: break
            }
        }
        if let removed = n.userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [NSMetadataItem] {
            for item in removed {
                guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
                seen[url.path] = nil
                if url.deletingLastPathComponent().lastPathComponent == "transcripts", !FileManager.default.fileExists(atPath: url.path) {
                    store.ingestRemoval(url)
                }
            }
        }
        for u in unchanged { store.ingestUnchanged(u) }
        store.ingest(transcriptsChanged)
        if projects { store.ingestProjects() }
        if dictionary { store.ingestDictionary() }
        if snippets { store.ingestSnippets() }
        if templates { store.ingestTemplates() }
        if recipes { store.ingestRecipes() }
        if plans { store.ingestPlans() }
        if profile { store.ingestProfile() }
    }

    /// Keeps the current version and drops the rest: for the synced lists, whose conflict versions were merged in
    /// entry by entry first (Store.ingestList). Transcripts use `resolveTranscriptConflicts`.
    nonisolated static func resolveConflicts(_ url: URL) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return }
        for v in versions { v.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    /// A transcript file's conflict: the most recently modified version wins on every device (`SyncMerge.conflictWinner`),
    /// then the rest are dropped. True when another device's version replaced this file, so the caller reads it again.
    @discardableResult
    nonisolated static func resolveTranscriptConflicts(_ url: URL) -> Bool {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return false }
        var replaced = false
        let current = NSFileVersion.currentVersionOfItem(at: url)?.modificationDate
        if let i = SyncMerge.conflictWinner(current: current, others: versions.map(\.modificationDate)) {
            var err: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
                do { _ = try versions[i].replaceItem(at: u, options: []); replaced = true }
                catch { Log.note("sync: kept this device's copy of \(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        for v in versions { v.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return replaced
    }
}
