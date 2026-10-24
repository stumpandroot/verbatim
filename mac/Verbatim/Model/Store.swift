import Foundation
import Combine
import os
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
    /// Dictation snippets (say the trigger, get the text), shared by the Mac and the iPhone.
    static let snippetsFile = root.appendingPathComponent("snippets.json")
    /// Your name and About me, shared by the Mac and the iPhone (Home greeting, titles, summaries).
    static let profileFile = root.appendingPathComponent("profile.json")
    static let models = local.appendingPathComponent("models", isDirectory: true)
    static let downloads = local.appendingPathComponent("downloads", isDirectory: true)
    /// Recordings are written here while they're made, then moved into `audio` when they stop, so a
    /// half-written file never syncs.
    static let recordings = local.appendingPathComponent("recordings", isDirectory: true)
    /// FluidAudio's own model folder (voice activity, CTC), where it downloads when no folder is passed.
    static let fluidAudioModels: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio", isDirectory: true).appendingPathComponent("Models", isDirectory: true)

    /// Speech models are large and download again on demand, so they're kept out of iCloud and device backups
    /// (and Time Machine). Setting it on the folder covers everything downloaded into it later.
    static func excludeModelsFromBackup() {
        for d in [models, fluidAudioModels] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var u = d
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            do { try u.setResourceValues(v) } catch { Log.note("backup: couldn't exclude \(d.lastPathComponent): \(error.localizedDescription)") }
        }
    }
}

/// Verbatim's iCloud container. `root` is nil when iCloud is off, signed out, or the build has no iCloud
/// entitlement (CI builds); everything then works locally exactly as before.
enum Cloud {
    static let containerID = "iCloud.co.stumpandroot.verbatim"
    /// Verbatim's folder in iCloud whenever this device could sync (signed in, entitled), on or off. The same
    /// value for the whole launch. `url(forUbiquityContainerIdentifier:)` can take seconds, so it's looked up on a
    /// background thread (`prefetchContainer`, first thing at launch); the path it found last time is used meanwhile
    /// so launch never waits on it, except the very first time.
    static var container: URL? { ContainerLookup.shared.value }

    /// Starts the iCloud container lookup on a background thread. Call first thing at launch.
    static func prefetchContainer() { ContainerLookup.shared.start() }

    /// The lookup behind `container`. Thread-safe.
    final class ContainerLookup: @unchecked Sendable {
        static let shared = ContainerLookup()
        private let lock = NSCondition()
        private var started = false
        private var looked: URL?? = nil       // the background lookup's answer, once it has one
        private var pinned: URL?? = nil       // what `value` answered first: every later call gets the same
        private static let cacheKey = "cloud.containerPath"

        func start() {
            lock.lock(); defer { lock.unlock() }
            guard !started else { return }
            started = true
            if ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" { looked = .some(nil); return }
            Thread.detachNewThread { [self] in
                let found = Self.lookUp()
                lock.lock()
                looked = .some(found)
                let usedCache = pinned.map { $0 != found } ?? false
                lock.broadcast()
                lock.unlock()
                if let found { UserDefaults.standard.set(found.path, forKey: Self.cacheKey) }
                else { UserDefaults.standard.removeObject(forKey: Self.cacheKey) }
                if usedCache { Log.note("iCloud container differs from the one used at launch; the next launch uses \(found?.path ?? "none")") }
            }
        }

        var value: URL? {
            start()
            lock.lock(); defer { lock.unlock() }
            if let p = pinned { return p }
            if let l = looked { pinned = l; return l }
            // Signed in, and the lookup found the folder before: use it now, without waiting.
            if FileManager.default.ubiquityIdentityToken != nil, let path = UserDefaults.standard.string(forKey: Self.cacheKey),
               FileManager.default.fileExists(atPath: path) {
                let u = URL(fileURLWithPath: path, isDirectory: true)
                pinned = .some(u)
                return u
            }
            // First launch with iCloud (nothing cached): wait for the background lookup.
            if Thread.isMainThread { Log.note("iCloud container: first lookup, waiting for it") }
            while looked == nil { lock.wait() }
            pinned = looked
            return looked ?? nil
        }

        private static func lookUp() -> URL? {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let c = FileManager.default.url(forUbiquityContainerIdentifier: Cloud.containerID) else { return nil }
            return c.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Verbatim", isDirectory: true)
        }
    }
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
        for name in Store.syncedListFiles {
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
        merge(Snippet.self, "snippets.json")
        // A later turn-on gets its own dated folder, since "Before iCloud" already exists.
        var backup = old.appendingPathComponent("Before iCloud", isDirectory: true)
        if fm.fileExists(atPath: backup.path) {
            backup = old.appendingPathComponent("Before iCloud \(Formats.pattern("yyyy-MM-dd HH.mm").string(from: Date()))", isDirectory: true)
        }
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["transcripts", "audio", "thumbs"] + Store.syncedListFiles {
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
    @Published private(set) var transcripts: [Transcript] = [] { didSet { transcriptsGeneration &+= 1 } }
    @Published var projects: [Project] = [] {
        didSet {
            projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            listEdited(old: oldValue, list: \.projects, sync: \.projectSync)
        }
    }
    /// `projects` by ID, for rows that show their project's name (kept in step by `projects`' didSet).
    private(set) var projectsByID: [UUID: Project] = [:]
    @Published var dictionary: [DictionaryEntry] = [] { didSet { listEdited(old: oldValue, list: \.dictionary, sync: \.dictionarySync) } }
    /// Snippets for dictation. Synced like the Dictionary; the Mac mirrors them into `FlowSettings.snippets`.
    @Published var snippets: [Snippet] = [] { didSet { listEdited(old: oldValue, list: \.snippets, sync: \.snippetSync) } }

    /// A synced list's file, its deletes, and whether this device may write it (SyncMerge).
    struct ListSync {
        let file: URL
        /// "<name>-deleted.json" beside the list: its tombstones.
        var tombFile: URL { file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-deleted.json") }
        var tombstones: [Tombstone] = []
        /// The file read cleanly, or there is none: writes are allowed. False while it isn't downloaded or can't be
        /// decoded, so a device that hasn't seen the list never replaces it.
        var writable = false
        /// Edited while not writable: merged and written once the file reads cleanly.
        var dirty = false
        init(file: URL) { self.file = file }
    }
    private var projectSync = ListSync(file: Paths.projectsFile)
    private var dictionarySync = ListSync(file: Paths.dictionaryFile)
    private var snippetSync = ListSync(file: Paths.snippetsFile)
    /// The synced list files and their tombstone files, at the root of the library.
    nonisolated static let syncedListFiles = ["projects.json", "dictionary.json", "snippets.json",
                                              "projects-deleted.json", "dictionary-deleted.json", "snippets-deleted.json"]
    /// Snippets read cleanly from the synced file (or there is none yet), so they can be mirrored over local ones.
    var snippetsReadable: Bool { snippetSync.writable }

    static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private var loading = true
    /// How long the launch `load()` took, in milliseconds (the Mac self-test logs it as UITEST TIMING).
    private(set) var loadMs = 0.0
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
    /// Recordings recovered after launch (queued to transcribe, or added to the transcript they continued): the
    /// app queues these IDs, and says so when `announce` is true (recovery after joining leftover segments).
    var onRecovered: ((_ ids: [UUID], _ announce: Bool) -> Void)?
    private var sync: CloudSync?

    init() {
        Cloud.finishTurnOffIfNeeded()
        Cloud.migrateIfNeeded()
        for d in [Paths.transcripts, Paths.audio, Paths.models, Paths.downloads, Paths.thumbs, Paths.recordings] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        Paths.excludeModelsFromBackup()
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
        let started = Date()
        let interval = Perf.signposter.beginInterval("Store.load")
        defer {
            Perf.signposter.endInterval("Store.load", interval)
            loadMs = Date().timeIntervalSince(started) * 1000
        }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Paths.transcripts, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        // Decoded in parallel: launch waits for this, and a big library is hundreds of files.
        let slots = LoadSlots(files.count)
        let decode = Perf.signposter.beginInterval("Store.decode", "\(files.count) files")
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let u = files[i]
            guard let data = Cloud.read(u) else { return }
            let t: Transcript
            do { t = try TranscriptFiles.dec.decode(Transcript.self, from: data) } catch {
                // Left on disk untouched (never rewritten), so a newer build still has it.
                Log.note("load: couldn't read \(u.lastPathComponent): \(error)")
                return
            }
            let mod = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            slots.set(i, (t, mod))
        }
        Perf.signposter.endInterval("Store.decode", decode)
        var list: [Transcript] = [], dates: [UUID: Date] = [:]
        var stuck: [UUID] = []
        for case let slot? in slots.items {
            var t = slot.t
            if Self.isStuckImport(t) { stuck.append(t.id) }
            else if t.status == .processing { t.stage = "Queued" }   // AppState resumes these
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
        loadList(list: \.projects, sync: \.projectSync)
        loadList(list: \.dictionary, sync: \.dictionarySync)
        loadList(list: \.snippets, sync: \.snippetSync)
        cleanUpStuckImports(stuck)
        startProfileSync()
        // Housekeeping the first frame doesn't wait for: old downloads are removed on a background queue, the
        // recordings folder is checked for orphans on one (they're adopted here afterward), and expired items
        // leave Recently Deleted a run-loop turn later, once the window has drawn.
        DispatchQueue.global(qos: .utility).async { Self.cleanDownloads() }
        recoverOrphans()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.purgeExpired() } }
    }

    // MARK: Launch cleanup

    /// An import placeholder this device left when the app quit before the file's audio was ready: no audio, still
    /// "Importing". (Links and multi-track recordings have their own resume paths.)
    nonisolated static func isStuckImport(_ t: Transcript) -> Bool {
        t.status == .processing && t.audioFileName == nil && t.stage == PendingImports.stage && t.source != .link
            && t.multitrack == nil && t.pendingAppend == nil
            // This device's own: another device's import may still be running there.
            && (t.processingDevice == Device.id || (t.processingDevice == nil && PendingImports.entry(t.id) != nil))
    }

    /// Stuck imports whose file is still here, for the app to import again (`takeResumableImports`).
    private var resumableImports: [(UUID, URL)] = []

    /// The app (Mac: AppState, iPhone: PhoneState) takes these once at launch and imports each file again into its
    /// placeholder.
    func takeResumableImports() -> [(UUID, URL)] {
        defer { resumableImports = [] }
        return resumableImports
    }

    /// At launch: each stuck import's half-written audio (and track copies) is removed. Its placeholder is imported
    /// again when its file is still here, and removed otherwise.
    private func cleanUpStuckImports(_ ids: [UUID]) {
        let fm = FileManager.default
        for id in ids {
            guard let t = transcript(id) else { continue }
            let entry = PendingImports.entry(id)
            if let dest = entry?.dest, let file = LibraryFile.url(dest, in: Paths.audio, field: "import") {
                let base = file.deletingPathExtension()
                for ext in Set([URL(fileURLWithPath: dest).pathExtension, "m4a", "wav", URL(fileURLWithPath: entry?.source ?? "").pathExtension]) where !ext.isEmpty {
                    let u = base.appendingPathExtension(ext)
                    if fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u); Log.note("launch: removed half-written \(u.lastPathComponent)") }
                }
            }
            try? fm.removeItem(at: Paths.tracks(id))
            if let src = entry.map({ URL(fileURLWithPath: $0.source) }), fm.fileExists(atPath: src.path) {
                resumableImports.append((id, src))
                Log.note("launch: importing \(src.lastPathComponent) again (the app quit before it was ready)")
            } else {
                PendingImports.clear(id)
                delete(t)
                Log.note("launch: removed an import placeholder whose file is gone")
            }
        }
        PendingImports.keep(only: Set(transcripts.map(\.id)))
    }

    /// At launch: link downloads and their partial files older than a day are removed from `Paths.downloads` (a
    /// finished download moves out of it at once). Touches only the disk, so it runs on a background queue.
    nonisolated private static func cleanDownloads() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        let items = (try? fm.contentsOfDirectory(at: Paths.downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for u in items {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard m < cutoff else { continue }
            if (try? fm.removeItem(at: u)) != nil { removed += 1 }
        }
        if removed > 0 { Log.note("launch: removed \(removed) old file\(removed == 1 ? "" : "s") from downloads") }
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
    /// The folder is read, and each orphan's header repaired and length read, on a background queue; the orphans
    /// are adopted on the main actor afterward.
    private func recoverOrphans() {
        let taken = Set(transcripts.compactMap(\.audioFileName))
        // Names a transcript points at (its audio, or a continued recording waiting to be joined).
        let known = taken.union(transcripts.compactMap(\.pendingAppend))
        let folder = Paths.recordings, audio = Paths.audio
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A long recording interrupted mid-way left segment files (or a join it didn't finish): one recording
            // again first (it copies audio); the orphans are surfaced after it.
            let leftovers = RecordingSegments.hasLeftovers(in: folder)
            let skipped = leftovers ? RecordingSegments.joinLeftovers(in: folder) { name in
                taken.contains(name) || FileManager.default.fileExists(atPath: audio.appendingPathComponent(name).path)
            } : [:]
            let probe = Self.probeOrphans(in: folder, known: known)
            DispatchQueue.main.async {
                // Recordings recovered without a join are queued quietly, as the queue's resume at launch takes
                // them; after a join (a long recording put back together), the app says so.
                MainActor.assumeIsolated { self?.adoptOrphans(probe, skipped: skipped, announce: leftovers) }
            }
        }
    }

    /// The recordings folder's files, and the orphans among them with their lengths and dates.
    private struct OrphanProbe {
        var files: [URL]
        var orphans: [(url: URL, duration: Double, modified: Date)]
    }

    /// Lists the recordings folder and reads each orphan: not a name a transcript points at (as of `known`), not
    /// hidden, not a leftover segment, and not a recording in progress. Repairs WAV headers the app didn't close.
    nonisolated private static func probeOrphans(in folder: URL, known: Set<String>) -> OrphanProbe {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var orphans: [(url: URL, duration: Double, modified: Date)] = []
        for f in files where !known.contains(f.lastPathComponent) && !f.lastPathComponent.hasPrefix(".") && RecordingSegments.parse(f) == nil
            && !RecordingSegments.isActive(f)
            && ["wav", "m4a", "mp3", "mp4", "mov", "aiff"].contains(f.pathExtension.lowercased()) {
            WavRepair.fixHeader(f)   // the app quit before the recording was closed
            let dur = Player.duration(of: f)
            let when = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            orphans.append((f, dur, when))
        }
        return OrphanProbe(files: files, orphans: orphans)
    }

    /// Each orphan is queued to transcribe as "Recovered recording · <date>", or added to the transcript it was
    /// continuing (RecordingSafety.swift). Orphans of a second or less are deleted once they're a week old.
    private func adoptOrphans(_ probe: OrphanProbe, skipped: [String: [ClosedRange<Double>]], announce: Bool) {
        let fm = FileManager.default
        // Again now: transcripts may have changed while the folder was read.
        let known = Set(transcripts.compactMap(\.audioFileName)).union(transcripts.compactMap(\.pendingAppend))
        retryAdoptions(probe.files, known: known)
        var recovered: [UUID] = [], appended = false
        // Not a recording in progress (recovery may finish after a new one started).
        for (f, dur, when) in probe.orphans where !known.contains(f.lastPathComponent) && !RecordingSegments.isActive(f) {
            guard dur > 1 else {
                if Self.isStaleTinyOrphan(duration: dur, bytes: Self.fileSize(f), modified: when) {
                    try? fm.removeItem(at: f); Self.clearContinuation(f)
                    Log.note("recovery: deleted \(f.lastPathComponent), \(String(format: "%.1f", dur)) s and over a week old")
                }
                continue
            }
            if let id = recoverContinuation(f) { recovered.append(id); continue }
            guard let name = adoptRecording(f) else { continue }
            let t = Self.recoveredTranscript(audioFileName: name, duration: dur, recordedAt: when, skipped: skipped[f.lastPathComponent] ?? [])
            searchCache[t.id] = nil
            transcripts.append(t)
            appended = true
            save(t)
            recovered.append(t.id)
        }
        // Only when something was added: this runs after the first frame now, and every change re-renders.
        if appended { transcripts.sort { $0.createdAt > $1.createdAt } }
        if !recovered.isEmpty {
            Log.note("recovery: \(recovered.count) recording\(recovered.count == 1 ? "" : "s") queued")
            waitForWrites()
            onRecovered?(recovered, announce)
        }
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
        CloudSync.resolveTranscriptConflicts(url)
        guard let data = Cloud.read(url), var t = try? TranscriptFiles.dec.decode(Transcript.self, from: data) else { return nil }
        if let i = index(of: id) {
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
        // The other device wrote it at the same time and its version is newer: read that one.
        if CloudSync.resolveTranscriptConflicts(url) { ingest(url) }
    }

    /// A transcript file disappeared (deleted for good on the other device).
    func ingestRemoval(_ url: URL) {
        guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
        searchCache[id] = nil
        transcripts.removeAll { $0.id == id }
    }

    func ingestProjects() { ingestList(list: \.projects, sync: \.projectSync) }
    func ingestDictionary() { ingestList(list: \.dictionary, sync: \.dictionarySync) }

    // MARK: Profile (name and About me), synced as one small file

    struct SyncedProfile: Codable, Equatable { var name: String; var aboutMe: String }
    static let profileNameKey = "profile.name", profileAboutKey = "profile.aboutMe"
    private var lastProfile: SyncedProfile?
    private var profileObserver: NSObjectProtocol?

    private var localProfile: SyncedProfile {
        let d = UserDefaults.standard
        return SyncedProfile(name: d.string(forKey: Self.profileNameKey) ?? "", aboutMe: d.string(forKey: Self.profileAboutKey) ?? "")
    }

    /// At launch: takes the synced profile where this device has nothing, then writes back when either field changes.
    func startProfileSync() {
        if let d = Cloud.read(Paths.profileFile), let p = try? Self.dec.decode(SyncedProfile.self, from: d) {
            let here = localProfile
            let merged = SyncedProfile(name: here.name.isEmpty ? p.name : here.name, aboutMe: here.aboutMe.isEmpty ? p.aboutMe : here.aboutMe)
            apply(merged)
            lastProfile = p
        }
        saveProfileIfChanged()
        profileObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProfileIfChanged() }
        }
    }

    private func apply(_ p: SyncedProfile) {
        let d = UserDefaults.standard
        if d.string(forKey: Self.profileNameKey) ?? "" != p.name { d.set(p.name, forKey: Self.profileNameKey) }
        if d.string(forKey: Self.profileAboutKey) ?? "" != p.aboutMe { d.set(p.aboutMe, forKey: Self.profileAboutKey) }
    }

    private func saveProfileIfChanged() {
        let p = localProfile
        guard p != lastProfile, !(p.name.isEmpty && p.aboutMe.isEmpty && lastProfile == nil) else { return }
        lastProfile = p
        if let d = try? JSONEncoder().encode(p) { Cloud.write(d, to: Paths.profileFile) }
    }

    /// The other device changed your name or About me: the newer file wins.
    func ingestProfile() {
        guard let d = Cloud.read(Paths.profileFile), let p = try? Self.dec.decode(SyncedProfile.self, from: d), p != localProfile else { return }
        lastProfile = p
        apply(p)
    }

    func ingestSnippets() { ingestList(list: \.snippets, sync: \.snippetSync) }

    /// Snippets saved on this device (the Mac's settings) while the synced file can't be read yet: shown and used
    /// as they are, without counting as edits, and merged with the file once it reads.
    func seedSnippetsWhileUnreadable(_ local: [Snippet]) {
        guard !snippetSync.writable, snippets.isEmpty, !local.isEmpty else { return }
        loading = true; snippets = local; loading = false
    }

    /// Moves a finished recording from the local recordings folder into the synced audio folder.
    /// Returns its file name there.
    @discardableResult
    func adoptRecording(_ url: URL) -> String? {
        var dest = Paths.audio.appendingPathComponent(url.lastPathComponent)
        guard url.standardizedFileURL != dest.standardizedFileURL else { return url.lastPathComponent }
        // Never two transcripts on one file: a name already in the audio folder (or in use) gets a fresh one.
        let used = Set(transcripts.compactMap(\.audioFileName)).union(adopting.keys)
        if FileManager.default.fileExists(atPath: url.path) {
            var n = 2
            let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            while FileManager.default.fileExists(atPath: dest.path) || used.contains(dest.lastPathComponent) {
                dest = Paths.audio.appendingPathComponent("\(stem) \(n).\(ext)"); n += 1
            }
        }
        if Cloud.enabled {
            // Moving into iCloud (`setUbiquitous`) can wait on the iCloud daemon, so it never runs on the main
            // thread: the name is returned now and the move finishes in the background. Jobs that read the file
            // wait for it (`waitForAdoption`). If the move fails, the recording stays in the recordings folder and
            // the next launch moves it (`retryAdoptions`).
            guard FileManager.default.fileExists(atPath: url.path) else { Log.note("adoptRecording: \(url.lastPathComponent) isn't there"); return nil }
            moveIntoCloud(url, to: dest)
            return dest.lastPathComponent
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest.lastPathComponent
        } catch {
            Log.note("adoptRecording failed: \(error)")
            // The move didn't happen: the recording is still where it was, so say so rather than pointing at
            // some other file of the same name.
            return nil
        }
    }

    /// Moves into iCloud in progress, by file name in the audio folder.
    private var adopting: [String: Task<Void, Never>] = [:]

    private func moveIntoCloud(_ url: URL, to dest: URL) {
        let name = dest.lastPathComponent
        let task = Task.detached(priority: .userInitiated) {
            do { try FileManager.default.setUbiquitous(true, itemAt: url, destinationURL: dest) }
            catch { Log.note("adoptRecording: couldn't move \(name) into iCloud (\(error)); the next launch tries again") }
        }
        adopting[name] = task
        Task { [weak self] in
            await task.value
            self?.adopting[name] = nil
        }
    }

    /// Waits until a recording handed to iCloud (`adoptRecording`) is in the audio folder. Returns at once otherwise.
    func waitForAdoption(of url: URL) async {
        if let t = adopting[url.lastPathComponent] { await t.value }
    }

    /// At launch: a recording a transcript points at that's still in the recordings folder (its move into iCloud
    /// failed last time) is moved again.
    private func retryAdoptions(_ files: [URL], known: Set<String>) {
        let fm = FileManager.default
        for f in files where known.contains(f.lastPathComponent) && !RecordingSegments.isActive(f) {
            let dest = Paths.audio.appendingPathComponent(f.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path), adopting[dest.lastPathComponent] == nil else { continue }
            Log.note("recovery: moving \(f.lastPathComponent) into the audio folder again")
            if Cloud.enabled { moveIntoCloud(f, to: dest) } else { try? fm.moveItem(at: f, to: dest) }
        }
    }

    /// Where a new recording is written while it's being made.
    func newRecordingURL(ext: String = "wav") -> URL {
        Self.uniqueURL(in: Paths.recordings, ext: ext, used: Set(transcripts.compactMap(\.audioFileName)))
    }

    func update(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = index(of: id) else { return }
        searchCache[id] = nil
        change(&transcripts[i])
        save(transcripts[i])
    }

    /// Like `update`, but writes to disk a second after the last change: for typing.
    func updateDeferred(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = index(of: id) else { return }
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
        // Every name goes through LibraryFile: a record can never point a delete outside its folder.
        if let p = LibraryFile.url(t.pendingAppend, in: Paths.audio, field: "continued recording") { files.append(p) }
        if let th = LibraryFile.url(t.link?.thumbnailFile, in: Paths.thumbs, field: "thumbnail") { files.append(th) }
        LocalMedia.remove(t.id)
        if t.multitrack != nil { let tracks = Paths.tracks(t.id); TranscriptFiles.queue.async { try? FileManager.default.removeItem(at: tracks) } }
        // Note stills go too. Kept MP4/M4A files in the Keep folder are yours and stay.
        for f in t.notes.compactMap(\.frameFile) { if let u = LibraryFile.url(f, in: Paths.thumbs, field: "note still") { files.append(u) } }
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
            local += (["transcripts", "audio", "thumbs"] + Self.syncedListFiles).map { Paths.local.appendingPathComponent($0) }
        }
        LocalMedia.removeAll()
        TranscriptFiles.queue.async {
            local.forEach { try? fm.removeItem(at: $0) }
            for d in [Paths.downloads, Paths.models] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
            Paths.excludeModelsFromBackup()
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
        // The words, Cleaned text, summary, notes, and tags (LibrarySearch), built on first search and cached.
        let s = LibrarySearch.index(t)
        searchCache[t.id] = s
        return s
    }

    func transcript(_ id: UUID) -> Transcript? { index(of: id).map { transcripts[$0] } }

    /// Bumped on every change to `transcripts`, so the ID index knows when a miss may be stale.
    private var transcriptsGeneration = 0
    private var idIndex: [UUID: Int] = [:]
    private var idIndexGeneration = -1

    /// Where a transcript is in `transcripts`. The index is checked on each hit and rebuilt only when it's wrong
    /// and `transcripts` changed since it was built, so progress ticks (which change a transcript in place) and
    /// lookups of IDs that aren't there don't rebuild it.
    private func index(of id: UUID) -> Int? {
        if let i = idIndex[id], i < transcripts.count, transcripts[i].id == id { return i }
        guard idIndexGeneration != transcriptsGeneration else { return nil }
        var built: [UUID: Int] = [:]
        built.reserveCapacity(transcripts.count)
        for (i, t) in transcripts.enumerated() where built[t.id] == nil { built[t.id] = i }
        idIndex = built
        idIndexGeneration = transcriptsGeneration
        return built[id]
    }

    /// Display-only progress text; not written to disk.
    func setStage(_ id: UUID, _ stage: String) {
        guard let i = index(of: id), transcripts[i].stage != stage else { return }
        transcripts[i].stage = stage
    }

    func audioURL(for t: Transcript) -> URL? {
        LibraryFile.url(t.audioFileName, in: Paths.audio, field: "audio")
    }

    /// A new audio file in the synced audio folder: "<stamp> <random>.<ext>", a name no file and no transcript uses
    /// (`AudioNaming`), so two imports in the same second never share one.
    func newAudioURL(ext: String) -> URL { newAudioURL(ext: ext, avoiding: []) }

    /// A new audio file name that's not in use and isn't any of `avoiding`.
    func newAudioURL(ext: String, avoiding: [URL]) -> URL {
        var used = Set(transcripts.compactMap(\.audioFileName))
        used.formUnion(transcripts.compactMap(\.pendingAppend))
        used.formUnion(avoiding.map(\.lastPathComponent))
        return Self.uniqueURL(in: Paths.audio, ext: ext, used: used)
    }

    /// "<stamp> <random>.<ext>" in `folder`, not used by any file there (with this or a sibling extension) or `used`.
    nonisolated static func uniqueURL(in folder: URL, ext: String, used: Set<String> = []) -> URL {
        let stamp = Formats.fileStamp.string(from: Date())
        let name = AudioNaming.uniqueName(stamp: stamp, ext: ext) { stem, e in
            AudioNaming.taken(stem: stem, ext: e, in: folder, used: used)
        }
        return folder.appendingPathComponent(name)
    }

    // MARK: Projects and dictionary

    /// Reads a synced list file: missing, unavailable (not downloaded, unreadable, or not a list), or its entries.
    nonisolated static func readList<T: SyncEntry>(_ type: T.Type, at url: URL) -> ListRead<[T]> {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard fm.fileExists(atPath: url.path) else {
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return .unavailable("not downloaded yet")
            }
            return .missing
        }
        guard Cloud.isDownloaded(url) else {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .unavailable("not downloaded yet")
        }
        guard let data = Cloud.read(url) else { return .unavailable("couldn't be read") }
        // Same date format as `Store.dec` (ISO 8601); TranscriptFiles' decoder isn't tied to the main actor.
        guard let items = SyncMerge.decode(T.self, from: data, decoder: TranscriptFiles.dec) else { return .unavailable("couldn't be decoded") }
        return .ok(items)
    }

    nonisolated static func readTombstones(_ url: URL) -> [Tombstone] {
        guard let d = Cloud.read(url) else { return [] }
        return (try? TranscriptFiles.dec.decode([Tombstone].self, from: d)) ?? []
    }

    private func loadList<T: SyncEntry>(list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>) {
        var s = self[keyPath: skp]
        s.tombstones = Self.readTombstones(s.tombFile)
        let wasLoading = loading
        loading = true
        let read = Self.readList(T.self, at: s.file)
        s.writable = SyncMerge.mayWrite(after: read)
        switch read {
        case .missing:
            self[keyPath: kp] = []
        case .unavailable(let why):
            self[keyPath: kp] = []
            Log.note("sync: \(s.file.lastPathComponent) \(why); not writing it until it reads")
        case .ok(let items):
            self[keyPath: kp] = items
        }
        loading = wasLoading
        self[keyPath: skp] = s
    }

    /// The list changed here: new and changed entries are stamped, removed ones get tombstones, then it's written
    /// (or held until the file can be read).
    private func listEdited<T: SyncEntry>(old: [T], list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>) {
        guard !loading else { return }
        let s = SyncMerge.stamp(old: old, new: self[keyPath: kp])
        if s.items != self[keyPath: kp] { loading = true; self[keyPath: kp] = s.items; loading = false }
        if !s.deleted.isEmpty { self[keyPath: skp].tombstones = SyncMerge.mergeTombstones(self[keyPath: skp].tombstones, s.deleted) }
        writeList(list: kp, sync: skp)
    }

    private func writeList<T: SyncEntry>(list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>) {
        let s = self[keyPath: skp]
        guard s.writable else {
            if !s.dirty { Log.note("sync: \(s.file.lastPathComponent) can't be read yet; this change is merged in once it can") }
            self[keyPath: skp].dirty = true
            return
        }
        if let d = try? Self.enc.encode(self[keyPath: kp]) { Cloud.write(d, to: s.file) }
        if !s.tombstones.isEmpty || FileManager.default.fileExists(atPath: s.tombFile.path), let d = try? Self.enc.encode(s.tombstones) {
            Cloud.write(d, to: s.tombFile)
        }
        self[keyPath: skp].dirty = false
    }

    /// The list's file changed (usually on the other device): merged entry by entry with this device's copy, along
    /// with any conflicting versions iCloud kept. Written back only when the merge has something the file lacks.
    private func ingestList<T: SyncEntry>(list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>) {
        var s = self[keyPath: skp]
        switch Self.readList(T.self, at: s.file) {
        case .missing:
            // Nothing to merge with: a device that was waiting writes what it has.
            guard !s.writable else { return }
            s.writable = true
            self[keyPath: skp] = s
            if s.dirty || !self[keyPath: kp].isEmpty { writeList(list: kp, sync: skp) }
        case .unavailable(let why):
            if s.writable { Log.note("sync: \(s.file.lastPathComponent) \(why); not writing it until it reads") }
            self[keyPath: skp].writable = false
        case .ok(let fileContent):
            let remoteTombs = Self.readTombstones(s.tombFile)
            // Versions iCloud kept from a conflict: every one is merged in, then they're resolved.
            let conflicts = (NSFileVersion.unresolvedConflictVersionsOfItem(at: s.file) ?? []).compactMap { v -> [T]? in
                (try? Data(contentsOf: v.url)).flatMap { SyncMerge.decode(T.self, from: $0, decoder: TranscriptFiles.dec) }
            }
            var remote = fileContent
            for c in conflicts {
                remote = SyncMerge.merge(local: remote, remote: c, localTombstones: remoteTombs, remoteTombstones: []).items
            }
            let m = SyncMerge.merge(local: self[keyPath: kp], remote: remote, localTombstones: s.tombstones, remoteTombstones: remoteTombs)
            s.tombstones = m.tombstones
            s.writable = true
            let needsWrite = s.dirty || !conflicts.isEmpty || m.items != fileContent || m.tombstones != remoteTombs
            self[keyPath: skp] = s
            if m.items != self[keyPath: kp] { loading = true; self[keyPath: kp] = m.items; loading = false }
            if needsWrite { writeList(list: kp, sync: skp) }
            if !conflicts.isEmpty { CloudSync.resolveConflicts(s.file) }
        }
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
