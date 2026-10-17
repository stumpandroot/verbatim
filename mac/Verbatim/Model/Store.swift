import Foundation
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where things live. Transcripts, audio, stills, projects, and the Dictionary sync through Verbatim's private
/// iCloud folder when iCloud is available (same files on the Mac and the iPhone); otherwise they stay in
/// Application Support. Models, downloads, and recordings in progress are always local to the device.
enum Paths {
    /// ~/Library/Application Support/Verbatim (per device, never synced).
    static let local: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Verbatim", isDirectory: true)
    }()
    /// The synced root: iCloud when on, else `local`.
    static let root: URL = Cloud.root ?? local
    static let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
    static let audio = root.appendingPathComponent("audio", isDirectory: true)
    static let thumbs = root.appendingPathComponent("thumbs", isDirectory: true)
    static let projectsFile = root.appendingPathComponent("projects.json")
    static let dictionaryFile = root.appendingPathComponent("dictionary.json")
    static let models = local.appendingPathComponent("models", isDirectory: true)
    static let downloads = local.appendingPathComponent("downloads", isDirectory: true)
    /// Recordings are written here while they're made, then moved into `audio` when they stop, so a
    /// half-written file never syncs.
    static let recordings = local.appendingPathComponent("recordings", isDirectory: true)
}

/// Verbatim's iCloud container. `root` is nil when iCloud is off, signed out, or the build has no iCloud
/// entitlement (CI builds); everything then works locally exactly as before.
enum Cloud {
    static let containerID = "iCloud.co.stumpandroot.verbatim"
    /// Verbatim's folder in iCloud whenever this device could sync (signed in, entitled), on or off.
    static let container: URL? = {
        if ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" { return nil }
        guard FileManager.default.ubiquityIdentityToken != nil,
              let c = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        return c.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Verbatim", isDirectory: true)
    }()
    /// Settings › iCloud sync. On unless the person turned it off. Read once at launch, like `root`.
    static let syncKey = "cloud.sync"
    static var wantsSync: Bool { UserDefaults.standard.object(forKey: syncKey) as? Bool ?? true }
    /// The synced folder this launch: nil when sync is off, signed out, or unavailable.
    static let root: URL? = wantsSync ? container : nil
    static var enabled: Bool { root != nil }
    /// Sync could run on this device (it may still be switched off).
    static var available: Bool { container != nil }
    /// The switch was changed this session and takes effect the next time Verbatim opens.
    static var changePending: Bool { available && wantsSync != enabled }
    static func setWantsSync(_ on: Bool) { UserDefaults.standard.set(on, forKey: syncKey) }

    /// Turning sync off, step 1 (in the session): makes this device's local folders an exact copy of iCloud,
    /// downloading what isn't here yet. Returns how many files couldn't be read; the switch only turns off when
    /// that's 0. Step 2 (`finishTurnOffIfNeeded`, next launch) copies whatever changed in between. Off the main thread.
    static func copyToDevice() -> (copied: Int, failed: Int) {
        let r = mirrorToDevice(download: true)
        if r.failed == 0 {
            UserDefaults.standard.set(true, forKey: copyPendingKey)
            UserDefaults.standard.set(Date(), forKey: offAtKey)
            // Turning sync back on later merges this device's library up again.
            UserDefaults.standard.set(false, forKey: "cloud.migrated")
        }
        Log.note("iCloud sync turning off; copied \(r.copied) files, \(r.failed) failed")
        return r
    }

    private static let copyPendingKey = "cloud.copyPending"
    private static let offAtKey = "cloud.offAt"

    /// Turning sync off, step 2: at launch, before the library loads, copies what changed in iCloud after step 1
    /// (edits and recordings made before Verbatim quit). Only files already on this device are read, so it's quick.
    static func finishTurnOffIfNeeded() {
        guard !wantsSync, container != nil, UserDefaults.standard.bool(forKey: copyPendingKey) else { return }
        let r = mirrorToDevice(download: false)
        UserDefaults.standard.set(Date(), forKey: offAtKey)
        UserDefaults.standard.removeObject(forKey: copyPendingKey)
        Log.note("iCloud sync off; final copy \(r.copied) files, \(r.failed) not downloaded")
    }

    /// Copies iCloud's library into `Paths.local` and removes local files iCloud no longer has, so the local
    /// folders match. With `download: false`, files not on this device are skipped (and kept locally if present).
    private static func mirrorToDevice(download: Bool) -> (copied: Int, failed: Int) {
        guard let cloud = container else { return (0, 0) }
        let fm = FileManager.default
        var copied = 0, failed = 0
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        func same(_ a: URL, _ b: URL) -> Bool {
            guard let va = try? a.resourceValues(forKeys: keys), let vb = try? b.resourceValues(forKeys: keys) else { return false }
            return va.fileSize == vb.fileSize && va.contentModificationDate == vb.contentModificationDate
        }
        func copy(_ src: URL, _ dst: URL) {
            if !download, !isDownloadedInCloud(src) { if !fm.fileExists(atPath: dst.path) { failed += 1 }; return }
            var err: NSError?, ok = false
            NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &err) { u in
                if fm.fileExists(atPath: dst.path) {
                    if same(u, dst) { ok = true; return }
                    try? fm.removeItem(at: dst)
                }
                if (try? fm.copyItem(at: u, to: dst)) != nil { ok = true; copied += 1 }
            }
            if !ok { failed += 1 }
        }
        for sub in ["transcripts", "audio", "thumbs"] {
            let src = cloud.appendingPathComponent(sub, isDirectory: true), dst = Paths.local.appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            var names = Set<String>()
            for f in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                // Files not downloaded yet show up as ".name.icloud" placeholders.
                var name = f.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
                if name.hasPrefix(".") { continue }
                names.insert(name)
                copy(src.appendingPathComponent(name), dst.appendingPathComponent(name))
            }
            // Deleted in iCloud (on any device): gone here too.
            for f in (try? fm.contentsOfDirectory(at: dst, includingPropertiesForKeys: nil)) ?? [] where !names.contains(f.lastPathComponent) {
                try? fm.removeItem(at: f)
            }
        }
        for name in ["projects.json", "dictionary.json"] {
            let src = cloud.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) || fm.fileExists(atPath: cloud.appendingPathComponent(".\(name).icloud").path) {
                copy(src, Paths.local.appendingPathComponent(name))
            }
        }
        return (copied, failed)
    }

    /// True when an iCloud file's bytes are on this device (`isDownloaded` only answers while sync is on).
    private static func isDownloadedInCloud(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let s = v?.ubiquitousItemDownloadingStatus { return s == .current || s == .downloaded }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// When sync was last turned off on this device (step 2's time), for `migrateIfNeeded`.
    static var turnedOffAt: Date? { UserDefaults.standard.object(forKey: offAtKey) as? Date }

    /// Writes through a file coordinator when syncing, so iCloud never reads a half-written file.
    static func write(_ data: Data, to url: URL) {
        guard enabled else { try? data.write(to: url, options: .atomic); return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in try? data.write(to: u, options: .atomic) }
    }

    static func read(_ url: URL) -> Data? {
        guard enabled else { return try? Data(contentsOf: url) }
        var out: Data?, err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in out = try? Data(contentsOf: u) }
        return out
    }

    static func remove(_ url: URL) {
        guard enabled else { try? FileManager.default.removeItem(at: url); return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in try? FileManager.default.removeItem(at: u) }
    }

    /// True when the file's bytes are on this device (always true without iCloud).
    static func isDownloaded(_ url: URL) -> Bool {
        guard enabled else { return FileManager.default.fileExists(atPath: url.path) }
        let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let s = v?.ubiquitousItemDownloadingStatus { return s == .current || s == .downloaded }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Asks iCloud for a file and waits (up to `timeout`) until it's here. Audio from the other device
    /// downloads on first play.
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 180) async -> Bool {
        if isDownloaded(url) { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if isDownloaded(url) { return true }
        }
        return false
    }

    /// First launch with iCloud on: copies what's in Application Support into iCloud (merging projects and
    /// Dictionary entries by ID), then moves the local originals into a "Before iCloud" folder rather than
    /// deleting them. Runs once per device.
    @MainActor static func migrateIfNeeded() {
        guard let root, !UserDefaults.standard.bool(forKey: "cloud.migrated") else { return }
        let fm = FileManager.default
        let old = Paths.local
        let offAt = turnedOffAt   // nil on the very first migration: everything local goes up
        var moved = 0
        for sub in ["transcripts", "audio", "thumbs"] {
            let src = old.appendingPathComponent(sub, isDirectory: true), dst = root.appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for f in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                let to = dst.appendingPathComponent(f.lastPathComponent)
                let mf = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                // Turning sync back on: only what changed here while it was off goes up. A file untouched since
                // then and missing from iCloud was deleted on the other device, so it stays deleted.
                if let off = offAt, mf <= off { continue }
                let cloudHas = fm.fileExists(atPath: to.path) || fm.fileExists(atPath: dst.appendingPathComponent(".\(f.lastPathComponent).icloud").path)
                if cloudHas {
                    let mt = (try? to.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    guard offAt != nil, mf > mt, let d = try? Data(contentsOf: f) else { continue }
                    write(d, to: to); moved += 1
                } else if (try? fm.copyItem(at: f, to: to)) != nil { moved += 1 }
            }
        }
        func merge<T: Codable & Identifiable>(_ type: T.Type, _ name: String) {
            let src = old.appendingPathComponent(name), dst = root.appendingPathComponent(name)
            guard let local = try? Store.dec.decode([T].self, from: Data(contentsOf: src)) else { return }
            var all = (try? Store.dec.decode([T].self, from: Data(contentsOf: dst))) ?? []
            if let off = offAt {
                // Back from sync being off: unchanged since then means iCloud's version stands.
                let m = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard m > off else { return }
                // Changed here: this device's entries win, and ones added here join.
                for x in local {
                    if let i = all.firstIndex(where: { $0.id == x.id }) { all[i] = x } else { all.append(x) }
                }
            } else {
                for x in local where !all.contains(where: { $0.id == x.id }) { all.append(x) }
            }
            if let d = try? Store.enc.encode(all) { write(d, to: dst) }
        }
        merge(Project.self, "projects.json")
        merge(DictionaryEntry.self, "dictionary.json")
        // A later turn-on gets its own dated folder, since "Before iCloud" already exists.
        var backup = old.appendingPathComponent("Before iCloud", isDirectory: true)
        if fm.fileExists(atPath: backup.path) {
            backup = old.appendingPathComponent("Before iCloud \(Formats.pattern("yyyy-MM-dd HH.mm").string(from: Date()))", isDirectory: true)
        }
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["transcripts", "audio", "thumbs", "projects.json", "dictionary.json"] {
            let src = old.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: backup.appendingPathComponent(name)) }
        }
        UserDefaults.standard.set(true, forKey: "cloud.migrated")
        UserDefaults.standard.removeObject(forKey: offAtKey)
        Log.note("cloud migration copied \(moved) files; local originals kept in \(backup.path)")
    }
}

/// This device, for deciding who transcribes what: each device only resumes the jobs it started.
enum Device {
    static let id: String = {
        if let s = UserDefaults.standard.string(forKey: "device.id") { return s }
        let s = UUID().uuidString; UserDefaults.standard.set(s, forKey: "device.id"); return s
    }()
    /// Shown on the other device ("Transcribing on your Mac"). Deliberately generic: the computer's own name
    /// often includes the owner's name, and this goes into synced files.
    static var name: String {
        #if os(macOS)
        return "your Mac"
        #else
        return "your iPhone"
        #endif
    }
}

/// Absolute paths a transcript points at on this device (kept video and audio, an imported video's original),
/// in Application Support so they never sync. Thread-safe: transcripts decode in parallel at launch.
enum LocalMedia {
    enum Kind: String, Codable { case video, audio, original }
    private static let lock = NSLock()
    private static let file = Paths.local.appendingPathComponent("local-media.json")
    private static let writeQueue = DispatchQueue(label: "co.stumpandroot.verbatim.localmedia", qos: .utility)
    private static var cache: [UUID: [Kind: String]] = {
        guard let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([UUID: [Kind: String]].self, from: d) else { return [:] }
        return m
    }()

    static func paths(_ id: UUID) -> [Kind: String] { lock.lock(); defer { lock.unlock() }; return cache[id] ?? [:] }

    static func set(_ id: UUID, _ kind: Kind, _ path: String?) {
        lock.lock()
        var m = cache[id] ?? [:]
        guard m[kind] != path else { lock.unlock(); return }
        m[kind] = path
        cache[id] = m.isEmpty ? nil : m
        let snapshot = cache
        lock.unlock()
        writeQueue.async {
            try? FileManager.default.createDirectory(at: Paths.local, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
        }
    }

    static func remove(_ id: UUID) {
        lock.lock()
        guard cache.removeValue(forKey: id) != nil else { lock.unlock(); return }
        let snapshot = cache
        lock.unlock()
        writeQueue.async { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) } }
    }

    /// Transcripts whose file still had paths from an older build; the Store rewrites them once after loading.
    private static var legacy = Set<UUID>()
    static func noteLegacy(_ id: UUID) { lock.lock(); legacy.insert(id); lock.unlock() }
    static func takeLegacy() -> Set<UUID> { lock.lock(); defer { legacy = []; lock.unlock() }; return legacy }

    static func removeAll() {
        lock.lock(); cache = [:]; lock.unlock()
        writeQueue.async { try? FileManager.default.removeItem(at: file) }
    }
}

/// Transcript files: compact JSON (older builds read it fine), written and deleted in order on one background
/// queue so typing and transcription never wait on the disk, and a delete can't be undone by a save still queued.
enum TranscriptFiles {
    static let queue = DispatchQueue(label: "co.stumpandroot.verbatim.store", qos: .utility)
    static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static func url(_ id: UUID) -> URL { Paths.transcripts.appendingPathComponent("\(id.uuidString).json") }
}

/// Results of the parallel decode in `Store.load`, one slot per file so the order matches the directory listing.
private final class LoadSlots: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [(t: Transcript, mod: Date?)?]
    init(_ n: Int) { items = Array(repeating: nil, count: n) }
    func set(_ i: Int, _ v: (t: Transcript, mod: Date?)) { lock.lock(); items[i] = v; lock.unlock() }
}

/// Transcripts live as one JSON file each in /transcripts, with audio beside them in /audio.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var transcripts: [Transcript] = []
    @Published var projects: [Project] = [] { didSet { saveProjects() } }
    @Published var dictionary: [DictionaryEntry] = [] { didSet { saveDictionary() } }

    static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private var loading = true
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    /// Writes and deletes queued on `TranscriptFiles.queue` and not finished yet. The disk is behind memory for
    /// these, so a file change seen meanwhile isn't read back over newer edits.
    private var inFlight: [UUID: Int] = [:]
    /// Changed files skipped while this device's own edit was waiting to be written. Read once the write lands,
    /// so a remote edit that arrived in that window isn't missed (a re-read that matches memory changes nothing).
    private var deferredIngest: [UUID: URL] = [:]
    /// Lowercased transcript text for search, by ID. Dropped whenever that transcript's content may change.
    private var searchCache: [UUID: String] = [:]
    /// Modification dates of files read unchanged at launch, handed to CloudSync so its first pass skips them.
    private var loadedDates: [UUID: Date] = [:]
    /// Called after a transcript arrives or changes from the other device (Mac: claim pending links).
    var onRemoteChange: ((Transcript) -> Void)?
    private var sync: CloudSync?

    init() {
        Cloud.finishTurnOffIfNeeded()
        Cloud.migrateIfNeeded()
        for d in [Paths.transcripts, Paths.audio, Paths.models, Paths.downloads, Paths.thumbs, Paths.recordings] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        load()
        loading = false
        if Cloud.enabled { let s = CloudSync(store: self); sync = s; s.seed(loadedDates); s.start() }
        loadedDates = [:]
        // Deferred edits are written before the app quits or is suspended, and queued writes finish first.
        let nc = NotificationCenter.default
        #if os(macOS)
        let names = [NSApplication.willTerminateNotification]
        #else
        let names = [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        #endif
        for name in names {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
        }
    }

    func load() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Paths.transcripts, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        // Decoded in parallel: launch waits for this, and a big library is hundreds of files.
        let slots = LoadSlots(files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let u = files[i]
            guard let data = Cloud.read(u), let t = try? TranscriptFiles.dec.decode(Transcript.self, from: data) else { return }
            let mod = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            slots.set(i, (t, mod))
        }
        var list: [Transcript] = [], dates: [UUID: Date] = [:]
        for case let slot? in slots.items {
            var t = slot.t
            if t.status == .processing { t.stage = "Queued" }   // AppState resumes these
            if t.status == .ready, t.pendingAppend == nil, t.stage != nil { t.stage = nil }   // a speaker pass that didn't finish
            // Only files that match memory exactly may be skipped by CloudSync's first pass; the rest are read again.
            if t == slot.t, let mod = slot.mod { dates[t.id] = mod }
            list.append(t)
        }
        searchCache = [:]
        transcripts = list.sorted { $0.createdAt > $1.createdAt }
        loadedDates = dates
        // Files from older builds that still hold absolute paths: rewritten once without them.
        for id in LocalMedia.takeLegacy() { if let t = transcript(id) { loadedDates[id] = nil; save(t) } }
        sync?.seed(dates)
        projects = Cloud.read(Paths.projectsFile).flatMap { try? Self.dec.decode([Project].self, from: $0) } ?? []
        dictionary = Cloud.read(Paths.dictionaryFile).flatMap { try? Self.dec.decode([DictionaryEntry].self, from: $0) } ?? []
        recoverOrphans()
        purgeExpired()
    }

    /// Transcripts that aren't in Recently Deleted.
    var live: [Transcript] { transcripts.filter { $0.deletedAt == nil } }
    /// Recently Deleted, newest first.
    var trash: [Transcript] { transcripts.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) } }

    func moveToTrash(_ id: UUID) { update(id) { $0.deletedAt = Date(); $0.pinned = false } }
    func restore(_ id: UUID) { update(id) { $0.deletedAt = nil } }

    /// Recently Deleted keeps things for `trashDays` (30) days.
    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Double(Self.trashDays) * 86_400)
        for t in transcripts where (t.deletedAt ?? .distantFuture) < cutoff { delete(t) }
    }

    /// A recording whose app died before it stopped is still in the local recordings folder. Surface it.
    /// (Only local recordings: with iCloud, audio from the other device can arrive before its transcript.)
    private func recoverOrphans() {
        let fm = FileManager.default
        // A long recording interrupted mid-way left segment files: one recording again first.
        RecordingSegments.joinLeftovers(in: Paths.recordings)
        let known = Set(transcripts.compactMap(\.audioFileName))
        let files = (try? fm.contentsOfDirectory(at: Paths.recordings, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where !known.contains(f.lastPathComponent) && !f.lastPathComponent.hasPrefix(".") && RecordingSegments.parse(f) == nil
            && ["wav", "m4a", "mp3", "mp4", "mov", "aiff"].contains(f.pathExtension.lowercased()) {
            WavRepair.fixHeader(f)   // the app quit before the recording was closed
            let dur = Player.duration(of: f)
            guard dur > 1 else { continue }
            let when = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            guard let name = adoptRecording(f) else { continue }
            var t = Transcript(title: "Recovered recording", source: .voiceMemo, sourceLabel: "Recovered", duration: dur, audioFileName: name, model: "")
            t.createdAt = when
            t.status = .failed
            t.error = "This recording was saved but never transcribed. Right-click to retry."
            searchCache[t.id] = nil
            transcripts.append(t)
            save(t)
        }
        transcripts.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: Transcripts

    func add(_ t: Transcript) { searchCache[t.id] = nil; transcripts.insert(t, at: 0); save(t) }

    // MARK: Sync (iCloud)

    /// A transcript file changed on disk (usually written by the other device). Takes it unless this device
    /// has unsaved edits to the same transcript.
    func ingest(_ url: URL) { ingest([url]) }

    /// Several changed files at once: new arrivals are sorted in once, not after each one.
    func ingest(_ urls: [URL]) {
        var changed: [Transcript] = [], appended = false
        for url in urls {
            guard let r = take(url) else { continue }
            changed.append(r.t)
            if r.appended { appended = true }
        }
        if appended { transcripts.sort { $0.createdAt > $1.createdAt } }
        for t in changed { onRemoteChange?(t) }
    }

    /// Reads one changed file into `transcripts`. Nil when nothing changed or this device's edits win.
    private func take(_ url: URL) -> (t: Transcript, appended: Bool)? {
        guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
        if pendingSaves[id] != nil || inFlight[id] != nil { deferredIngest[id] = url; return nil }
        CloudSync.resolveConflicts(url)
        guard let data = Cloud.read(url), var t = try? TranscriptFiles.dec.decode(Transcript.self, from: data) else { return nil }
        if let i = transcripts.firstIndex(where: { $0.id == id }) {
            // Keep this device's live progress label for jobs it's running.
            if t.status == .processing, t.processingDevice == Device.id { t.stage = transcripts[i].stage }
            guard transcripts[i] != t else { return nil }
            searchCache[id] = nil
            transcripts[i] = t
            return (t, false)
        }
        searchCache[t.id] = nil
        transcripts.append(t)
        return (t, true)
    }

    /// A transcript file this device wrote (or loaded) came back unchanged: nothing to decode, but conflicts are
    /// still resolved as `ingest` would.
    func ingestUnchanged(_ url: URL) {
        guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
        if pendingSaves[id] != nil || inFlight[id] != nil { deferredIngest[id] = url; return }
        CloudSync.resolveConflicts(url)
    }

    /// A transcript file disappeared (deleted for good on the other device).
    func ingestRemoval(_ url: URL) {
        guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
        searchCache[id] = nil
        transcripts.removeAll { $0.id == id }
    }

    func ingestProjects() {
        guard let d = Cloud.read(Paths.projectsFile), let p = try? Self.dec.decode([Project].self, from: d), p != projects else { return }
        loading = true; projects = p; loading = false
    }

    func ingestDictionary() {
        guard let d = Cloud.read(Paths.dictionaryFile), let x = try? Self.dec.decode([DictionaryEntry].self, from: d), x != dictionary else { return }
        loading = true; dictionary = x; loading = false
    }

    /// Moves a finished recording from the local recordings folder into the synced audio folder.
    /// Returns its file name there.
    @discardableResult
    func adoptRecording(_ url: URL) -> String? {
        let dest = Paths.audio.appendingPathComponent(url.lastPathComponent)
        guard url.standardizedFileURL != dest.standardizedFileURL else { return url.lastPathComponent }
        do {
            if Cloud.enabled { try FileManager.default.setUbiquitous(true, itemAt: url, destinationURL: dest) }
            else { try FileManager.default.moveItem(at: url, to: dest) }
            return dest.lastPathComponent
        } catch {
            Log.note("adoptRecording failed: \(error)")
            return FileManager.default.fileExists(atPath: dest.path) ? dest.lastPathComponent : nil
        }
    }

    /// Where a new recording is written while it's being made.
    func newRecordingURL(ext: String = "wav") -> URL {
        Paths.recordings.appendingPathComponent("\(Formats.fileStamp.string(from: Date())).\(ext)")
    }

    func update(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }) else { return }
        searchCache[id] = nil
        change(&transcripts[i])
        save(transcripts[i])
    }

    /// Like `update`, but writes to disk a second after the last change: for typing.
    func updateDeferred(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }) else { return }
        searchCache[id] = nil
        change(&transcripts[i])
        pendingSaves[id]?.cancel()
        let w = DispatchWorkItem { [weak self] in if let t = self?.transcript(id) { self?.save(t) } }
        pendingSaves[id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    /// Permanent: removes the transcript, its audio, and its thumbnail.
    func delete(_ t: Transcript) {
        transcripts.removeAll { $0.id == t.id }
        searchCache[t.id] = nil
        var files = [TranscriptFiles.url(t.id)]
        if let a = audioURL(for: t) { files.append(a) }
        if let p = t.pendingAppend { files.append(Paths.audio.appendingPathComponent(p)) }
        if let th = t.link?.thumbnailFile { files.append(Paths.thumbs.appendingPathComponent(th)) }
        LocalMedia.remove(t.id)
        // Note stills go too. Kept MP4/M4A files in the Keep folder are yours and stay.
        for f in t.notes.compactMap(\.frameFile) { files.append(Paths.thumbs.appendingPathComponent(f)) }
        // Same queue as saves, so a write still queued for this transcript lands before the delete, never after.
        let id = t.id, gone = files
        inFlight[id, default: 0] += 1
        TranscriptFiles.queue.async { [weak self] in
            for f in gone { Cloud.remove(f) }
            let store = self
            DispatchQueue.main.async { MainActor.assumeIsolated { store?.finished(id, modified: nil) } }
        }
    }

    /// Encodes and writes on `TranscriptFiles.queue` from a copy, so the caller never waits on the disk.
    func save(_ t: Transcript) {
        pendingSaves[t.id] = nil
        let id = t.id
        inFlight[id, default: 0] += 1
        TranscriptFiles.queue.async { [weak self] in
            let url = TranscriptFiles.url(id)
            let data = try? TranscriptFiles.enc.encode(t)
            if let data { Cloud.write(data, to: url) }
            let mod: Date? = data == nil ? nil : (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let size = data?.count
            let store = self
            DispatchQueue.main.async { MainActor.assumeIsolated { store?.finished(id, modified: mod, size: size) } }
        }
    }

    /// A queued write or delete is done. A write's date tells CloudSync the matching update is this device's own.
    private func finished(_ id: UUID, modified: Date?, size: Int? = nil) {
        if let n = inFlight[id], n > 1 { inFlight[id] = n - 1 } else { inFlight[id] = nil }
        if let modified { sync?.wrote(id, at: modified, size: size) }
        // Caught up: read anything that changed remotely while this device's write was queued.
        if inFlight[id] == nil, pendingSaves[id] == nil, let u = deferredIngest.removeValue(forKey: id) { ingest(u) }
    }

    /// Waits until every queued transcript write and delete is on disk. For the moments a crash right after
    /// would otherwise leave a file without the transcript that points at it.
    func waitForWrites() { TranscriptFiles.queue.sync {} }

    /// Delete All Data, after every transcript went through `delete`: removes whatever files are left in the
    /// library (iCloud placeholders not downloaded yet, audio that arrived before its transcript, stills, leftover
    /// recordings), plus the local-only folders: the "Before iCloud" backup, downloads, speech models, the copy
    /// kept on this device while sync is on, and the local paths record. Queued behind pending writes; never blocks.
    func removeAllFiles() {
        let fm = FileManager.default
        let synced = [Paths.transcripts, Paths.audio, Paths.thumbs, Paths.recordings].flatMap {
            (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [])) ?? []
        }
        removeAfterPendingWrites(synced)
        let backups = ((try? fm.contentsOfDirectory(at: Paths.local, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Before iCloud") }
        var local = backups + [Paths.downloads, Paths.models]
        if Cloud.enabled {
            local += ["transcripts", "audio", "thumbs", "projects.json", "dictionary.json"].map { Paths.local.appendingPathComponent($0) }
        }
        LocalMedia.removeAll()
        TranscriptFiles.queue.async {
            local.forEach { try? fm.removeItem(at: $0) }
            for d in [Paths.downloads, Paths.models] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        }
    }

    /// Removes files only after every transcript write queued so far has landed (the transcript stops pointing at
    /// them first), so a crash in between can't leave a transcript pointing at deleted audio.
    func removeAfterPendingWrites(_ urls: [URL]) { TranscriptFiles.queue.async { urls.forEach(Cloud.remove) } }

    /// Writes every deferred edit now and waits until all queued writes and deletes are on disk.
    func flush() {
        for (id, w) in pendingSaves {
            w.cancel()
            if let t = transcript(id) { save(t) }
        }
        pendingSaves = [:]
        TranscriptFiles.queue.sync {}
    }

    /// Lowercased text for search, cached by ID until the transcript changes. Pass a transcript from `transcripts`.
    func searchText(_ t: Transcript) -> String {
        if let s = searchCache[t.id] { return s }
        let s = t.text.lowercased()
        searchCache[t.id] = s
        return s
    }

    func transcript(_ id: UUID) -> Transcript? { transcripts.first { $0.id == id } }

    /// Display-only progress text; not written to disk.
    func setStage(_ id: UUID, _ stage: String) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }), transcripts[i].stage != stage else { return }
        transcripts[i].stage = stage
    }

    func audioURL(for t: Transcript) -> URL? {
        guard let name = t.audioFileName else { return nil }
        return Paths.audio.appendingPathComponent(name)
    }

    func newAudioURL(ext: String) -> URL {
        Paths.audio.appendingPathComponent("\(Formats.fileStamp.string(from: Date())).\(ext)")
    }

    /// A new audio file name that's not in use and isn't any of `avoiding`.
    func newAudioURL(ext: String, avoiding: [URL]) -> URL {
        let base = newAudioURL(ext: ext)
        var u = base, n = 2
        let taken = Set(avoiding.map(\.standardizedFileURL))
        while taken.contains(u.standardizedFileURL) || FileManager.default.fileExists(atPath: u.path) {
            u = Paths.audio.appendingPathComponent("\(base.deletingPathExtension().lastPathComponent) \(n).\(ext)"); n += 1
        }
        return u
    }

    // MARK: Projects and dictionary

    private func saveProjects() {
        guard !loading, let d = try? Self.enc.encode(projects) else { return }
        Cloud.write(d, to: Paths.projectsFile)
    }

    private func saveDictionary() {
        guard !loading, let d = try? Self.enc.encode(dictionary) else { return }
        Cloud.write(d, to: Paths.dictionaryFile)
    }

    func addProject(_ name: String) -> Project {
        let p = Project(name: name, colorIndex: projects.count % 3); projects.append(p); return p
    }

    func addNote(_ note: Note, to id: UUID) {
        update(id) { $0.notes.insert(note, at: 0) }
    }

    /// Adds a dictionary entry or extends an existing one with a new "heard as" form.
    func remember(preferred: String, heardAs: String, from source: String, project: UUID? = nil) {
        if let i = dictionary.firstIndex(where: { $0.preferred.caseInsensitiveCompare(preferred) == .orderedSame && $0.projectId == project }) {
            if !dictionary[i].heardAs.contains(where: { $0.caseInsensitiveCompare(heardAs) == .orderedSame }) {
                dictionary[i].heardAs.append(heardAs)
            }
        } else {
            dictionary.append(DictionaryEntry(preferred: preferred, heardAs: [heardAs], learnedFrom: source, projectId: project))
        }
    }

    // MARK: Grouping

    static func group(_ list: [Transcript]) -> [(label: String, items: [Transcript])] {
        let list = list.filter { $0.deletedAt == nil }
        let cal = Calendar.current
        let f = Formats.style(date: .medium, time: .none)
        var out: [(String, [Transcript])] = []
        let pinned = list.filter(\.pinned)
        if !pinned.isEmpty { out.append(("Pinned", pinned)) }
        for t in list where !t.pinned {
            let label = cal.isDateInToday(t.createdAt) ? "Today" : cal.isDateInYesterday(t.createdAt) ? "Yesterday" : f.string(from: t.createdAt)
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(t) } else { out.append((label, [t])) }
        }
        return out.map { (label: $0.0, items: $0.1) }
    }
}
