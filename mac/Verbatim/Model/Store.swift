import Foundation
import Combine
import Observation
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
    static func finishTurnOffIfNeeded(budget: LaunchBudget) {
        guard !wantsSync, container != nil, UserDefaults.standard.bool(forKey: copyPendingKey) else { return }
        let r = mirrorToDevice(download: false, budget: budget)
        UserDefaults.standard.set(Date(), forKey: offAtKey)
        UserDefaults.standard.removeObject(forKey: copyPendingKey)
        Log.note("iCloud sync off; final copy \(r.copied) files, \(r.failed) not downloaded")
    }

    /// Copies iCloud's library into `Paths.local` and removes local files iCloud no longer has, so the local
    /// folders match. With `download: false`, files not on this device are skipped (and kept locally if present).
    /// With a `budget` (at launch), coordination waits only until it runs out, then files on this device are copied directly.
    private static func mirrorToDevice(download: Bool, budget: LaunchBudget? = nil) -> (copied: Int, failed: Int) {
        guard let cloud = container else { return (0, 0) }
        let fm = FileManager.default
        var copied = 0, failed = 0
        func copy(_ src: URL, _ dst: URL) {
            if !download, !isDownloadedInCloud(src) { if !fm.fileExists(atPath: dst.path) { failed += 1 }; return }
            let body = { (u: URL) -> (ok: Bool, copied: Bool) in
                let fm = FileManager.default
                if fm.fileExists(atPath: dst.path) {
                    if sameFile(u, dst) { return (true, false) }
                    try? fm.removeItem(at: dst)
                }
                return (try? fm.copyItem(at: u, to: dst)) != nil ? (true, true) : (false, false)
            }
            let r: (ok: Bool, copied: Bool)?
            if let budget {
                r = withLaunchRead(src, budget: budget, body)
                if r == nil { if !fm.fileExists(atPath: dst.path) { failed += 1 }; return }
            } else {
                var err: NSError?, out: (ok: Bool, copied: Bool)?
                NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &err) { u in out = body(u) }
                r = out
            }
            if r?.copied == true { copied += 1 }
            if r?.ok != true { failed += 1 }
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

    /// Same size and modification date: the copy is already up to date.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let va = try? a.resourceValues(forKeys: keys), let vb = try? b.resourceValues(forKeys: keys) else { return false }
        return va.fileSize == vb.fileSize && va.contentModificationDate == vb.contentModificationDate
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

    // MARK: Launch reads and writes (LaunchBudget)

    /// Accessors for launch's coordinated reads and writes, and for the reads after the first frame. Never the main thread.
    private static let accessQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "co.stumpandroot.verbatim.cloud-access"
        q.qualityOfService = .userInitiated
        return q
    }()

    /// A launch read: the file's data (nil when it couldn't be read, as `read` answers), or skipped because iCloud
    /// held it past the budget and its bytes aren't on this device.
    enum LaunchRead { case read(Data?), skipped }

    /// `read` for launch: never waits on coordination past `budget` (see LaunchBudget).
    static func launchRead(_ url: URL, budget: LaunchBudget) -> LaunchRead {
        guard enabled else { return .read(try? Data(contentsOf: url)) }
        guard let d = withLaunchRead(url, budget: budget, { u in try? Data(contentsOf: u) }) else { return .skipped }
        return .read(d)
    }

    /// Runs `body` inside a coordinated read of `url` when the coordinator grants it before `budget` runs out;
    /// after that, on the file directly when its bytes are on this device. Nil when it didn't run.
    static func withLaunchRead<T>(_ url: URL, budget: LaunchBudget, _ body: @escaping (URL) -> T) -> T? {
        if !budget.isSpent {
            let gate = LaunchGate(), box = LaunchBox<T>()
            let coordinator = NSFileCoordinator()
            let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
            coordinator.coordinate(with: [intent], queue: accessQueue) { error in
                guard gate.enter() else { return }
                if error == nil { box.value = body(intent.url) }
                gate.leave()
            }
            if gate.wait(budget) { return box.value }
            coordinator.cancel()
            Log.note("launch: iCloud held \(url.lastPathComponent) past the launch budget")
        }
        guard LaunchBudget.fallback(localState(url)) == .readDirectly else { return nil }
        return body(url)
    }

    /// `write` for launch: a coordinated write that waits only until `budget` runs out; then the same write is queued
    /// on `TranscriptFiles.queue` (behind and ahead of the other writes, in order) and the file is noted in
    /// `deferredAtLaunch`, so launch reads it after the write lands instead of reading the old version. Never dropped.
    @MainActor static func launchWrite(_ data: Data, to url: URL, budget: LaunchBudget) {
        guard enabled else { try? data.write(to: url, options: .atomic); return }
        if !budget.isSpent {
            let gate = LaunchGate()
            let coordinator = NSFileCoordinator()
            let intent = NSFileAccessIntent.writingIntent(with: url, options: .forReplacing)
            coordinator.coordinate(with: [intent], queue: accessQueue) { error in
                guard gate.enter() else { return }
                if error == nil { try? data.write(to: intent.url, options: .atomic) }
                gate.leave()
            }
            if gate.wait(budget) { return }
            coordinator.cancel()
        }
        Log.note("launch: iCloud held \(url.lastPathComponent); writing it in the background")
        deferredAtLaunch.insert(launchKey(url))
        TranscriptFiles.queue.async { write(data, to: url) }
    }

    /// Files whose launch write was queued (`launchWrite`): launch reads them after the first frame, behind the write.
    @MainActor static var deferredAtLaunch: Set<String> = []
    /// "folder/name", so the same file matches however its URL was built.
    static func launchKey(_ url: URL) -> String { url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent }

    /// A coordinated read with no deadline that never blocks a thread while it waits: `done` gets the data (nil
    /// when it couldn't be read) on a background queue once iCloud grants access.
    static func readInBackground(_ url: URL, _ done: @escaping (Data?) -> Void) {
        guard enabled else { accessQueue.addOperation { done(try? Data(contentsOf: url)) }; return }
        let coordinator = NSFileCoordinator()
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
        coordinator.coordinate(with: [intent], queue: accessQueue) { error in
            withExtendedLifetime(coordinator) { done(error == nil ? try? Data(contentsOf: intent.url) : nil) }
        }
    }

    /// Where an iCloud file's bytes are, for `LaunchBudget.fallback`.
    private static func localState(_ url: URL) -> LaunchBudget.Local {
        guard let s = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus else { return .unknown }
        if s == .current { return .current }
        if s == .downloaded { return .downloaded }
        return .notDownloaded
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
    @MainActor static func migrateIfNeeded(budget: LaunchBudget) {
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
                    launchWrite(d, to: to, budget: budget); moved += 1
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
            if let d = try? Store.enc.encode(all) { launchWrite(d, to: dst, budget: budget) }
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
    /// Files launch didn't read in time (LaunchBudget), by index.
    private(set) var skipped: [Int] = []
    func skip(_ i: Int) { lock.lock(); skipped.append(i); lock.unlock() }
}

/// Transcripts live as one JSON file each in /transcripts, with audio beside them in /audio.
///
/// Observable (Observation, by hand rather than with the macro so each list keeps its change hook): a view tracks only
/// the lists it reads, and a Store change no longer goes through AppState's or PhoneState's `objectWillChange` to
/// re-render every view that holds the app state. Combine subscribers use the `…Publisher` properties, which give the
/// value now and then each new value, as `$transcripts` and the like did.
@MainActor
final class Store: Observable {
    private let registrar = ObservationRegistrar()

    private var _transcripts: [Transcript] = []
    private(set) var transcripts: [Transcript] {
        get { registrar.access(self, keyPath: \.transcripts); return _transcripts }
        set {
            registrar.withMutation(of: self, keyPath: \.transcripts) { _transcripts = newValue }
            transcriptsChanged()
            // A change to the whole list counts as a change to every transcript (per-transcript caches).
            revisions.removeAll(keepingCapacity: true)
            revisionFloor = transcriptsGeneration
        }
    }
    /// Replaces one transcript in place (`update`, `ingest`): the list isn't copied, and nothing else runs while it's
    /// being written, so a change closure that reads the Store never overlaps the write.
    private func replaceTranscript(at i: Int, with t: Transcript) {
        guard let at = i < _transcripts.count && _transcripts[i].id == t.id ? i : _transcripts.firstIndex(where: { $0.id == t.id }) else { return }
        registrar.withMutation(of: self, keyPath: \.transcripts) { _transcripts[at] = t }
        transcriptsChanged()
        revisions[t.id] = transcriptsGeneration
    }

    /// Each transcript's own generation: the `transcriptsGeneration` its last change made, for values worked out once
    /// per transcript (Store+Memo.swift). A change to the whole list (add, delete, sort, launch) counts for every one.
    private var revisions: [UUID: Int] = [:]
    private var revisionFloor = 0
    func revision(_ id: UUID) -> Int { max(revisions[id] ?? revisionFloor, revisionFloor) }
    private let transcriptsSubject = PassthroughSubject<[Transcript], Never>()
    /// `transcripts` now, then after every change.
    var transcriptsPublisher: AnyPublisher<[Transcript], Never> { transcriptsSubject.prepend(_transcripts).eraseToAnyPublisher() }
    private func transcriptsChanged() {
        transcriptsGeneration &+= 1
        transcriptsSubject.send(_transcripts)
        anyChangeSubject.send()
    }

    private var _projects: [Project] = []
    var projects: [Project] {
        get { registrar.access(self, keyPath: \.projects); return _projects }
        set {
            let old = _projects
            registrar.withMutation(of: self, keyPath: \.projects) { _projects = newValue }
            _projectsByID = Dictionary(newValue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            anyChangeSubject.send()
            listEdited(old: old, list: \.projects, sync: \.projectSync)
        }
    }
    private var _projectsByID: [UUID: Project] = [:]
    /// `projects` by ID, for rows that show their project's name (kept in step by `projects`' setter).
    var projectsByID: [UUID: Project] { registrar.access(self, keyPath: \.projects); return _projectsByID }

    private var _dictionary: [DictionaryEntry] = []
    var dictionary: [DictionaryEntry] {
        get { registrar.access(self, keyPath: \.dictionary); return _dictionary }
        set {
            let old = _dictionary
            registrar.withMutation(of: self, keyPath: \.dictionary) { _dictionary = newValue }
            dictionarySubject.send(newValue)
            anyChangeSubject.send()
            listEdited(old: old, list: \.dictionary, sync: \.dictionarySync)
        }
    }
    private let dictionarySubject = PassthroughSubject<[DictionaryEntry], Never>()
    /// `dictionary` now, then after every change.
    var dictionaryPublisher: AnyPublisher<[DictionaryEntry], Never> { dictionarySubject.prepend(_dictionary).eraseToAnyPublisher() }

    private var _snippets: [Snippet] = []
    /// Snippets for dictation. Synced like the Dictionary; the Mac mirrors them into `FlowSettings.snippets`.
    var snippets: [Snippet] {
        get { registrar.access(self, keyPath: \.snippets); return _snippets }
        set {
            let old = _snippets
            registrar.withMutation(of: self, keyPath: \.snippets) { _snippets = newValue }
            snippetsSubject.send(newValue)
            anyChangeSubject.send()
            listEdited(old: old, list: \.snippets, sync: \.snippetSync)
        }
    }
    private let snippetsSubject = PassthroughSubject<[Snippet], Never>()
    /// `snippets` now, then after every change.
    var snippetsPublisher: AnyPublisher<[Snippet], Never> { snippetsSubject.prepend(_snippets).eraseToAnyPublisher() }

    /// Whole-library work kept until `transcripts` changes, and per-transcript work kept until that transcript changes
    /// (Store+Memo.swift).
    let memoTable = LibraryMemo()
    let transcriptMemo = TranscriptMemo()
    /// `transcriptsGeneration`, read as `transcripts` is: a view that uses a memoized value re-renders when the
    /// library changes.
    var observedGeneration: Int { registrar.access(self, keyPath: \.transcripts); return transcriptsGeneration }

    private let anyChangeSubject = PassthroughSubject<Void, Never>()
    /// After any change to the transcripts, projects, Dictionary, or snippets (what `objectWillChange` told Spotlight).
    var anyChange: AnyPublisher<Void, Never> { anyChangeSubject.eraseToAnyPublisher() }

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
    /// Transcripts launch didn't read within its budget (LaunchBudget), being read in the background (`readLate`).
    private var lateTranscripts: Set<UUID> = []
    /// Synced lists launch didn't read within its budget, by file path: true when CloudSync asked for them meanwhile.
    private var lateLists: [String: Bool] = [:]
    /// Reads of synced lists and the profile that launch left for later: coordinated with no deadline, one at a time.
    nonisolated private static let lateQueue = DispatchQueue(label: "co.stumpandroot.verbatim.late-reads", qos: .utility)
    /// Called after a transcript arrives or changes from the other device (Mac: claim pending links).
    var onRemoteChange: ((Transcript) -> Void)?
    /// Recordings recovered after launch (queued to transcribe, or added to the transcript they continued): the
    /// app queues these IDs, and says so when `announce` is true (recovery after joining leftover segments).
    var onRecovered: ((_ ids: [UUID], _ announce: Bool) -> Void)?
    private var sync: CloudSync?

    init() {
        // Launch never waits on iCloud file coordination past this (LaunchBudget): iOS kills a scene that takes 10 s.
        let budget = LaunchBudget()
        loadStarted = Date()
        loadInterval = Perf.signposter.beginInterval("Store.load")
        Cloud.finishTurnOffIfNeeded(budget: budget)
        Cloud.migrateIfNeeded(budget: budget)
        for d in [Paths.transcripts, Paths.audio, Paths.models, Paths.downloads, Paths.thumbs, Paths.recordings] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        Paths.excludeModelsFromBackup()
        // The synced lists and the profile are small, and the app's start-up reads them (snippets, the Dictionary):
        // loaded now, before the first frame, as always.
        loadList(list: \.projects, sync: \.projectSync, budget: budget)
        loadList(list: \.dictionary, sync: \.dictionarySync, budget: budget)
        loadList(list: \.snippets, sync: \.snippetSync, budget: budget)
        startProfileSync(budget: budget)
        loading = false
        // The transcripts are decoded off the main thread, so the first frame never waits for a big library; screens
        // show a light placeholder until `isLoaded`, and the apps start their queues then (`whenLoaded`).
        decodeTranscripts(budget: budget)
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

    // MARK: Launch load

    private var _isLoaded = false
    /// The launch load has finished: every transcript launch could read is in `transcripts` (the rest are on their way,
    /// `readLate`), CloudSync is running, and the launch cleanup has run.
    private(set) var isLoaded: Bool {
        get { registrar.access(self, keyPath: \.isLoaded); return _isLoaded }
        set { registrar.withMutation(of: self, keyPath: \.isLoaded) { _isLoaded = newValue } }
    }
    private var loadStarted = Date()
    private var loadInterval: OSSignpostIntervalState?
    private var loadedCallbacks: [@MainActor () -> Void] = []

    /// Runs `body` once the library has loaded, on a later turn of the main queue (at once after it, as the launch
    /// steps that used to wait for the first frame did). The apps start their queues, resume imports, claim links,
    /// and run the self-tests from here.
    func whenLoaded(_ body: @escaping @MainActor () -> Void) {
        if isLoaded { DispatchQueue.main.async { MainActor.assumeIsolated { body() } } } else { loadedCallbacks.append(body) }
    }

    /// Reads and decodes every transcript file on a background queue, in parallel, within the launch budget; then
    /// `finishLoad` takes them on main.
    private func decodeTranscripts(budget: LaunchBudget) {
        let deferred = Cloud.deferredAtLaunch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(at: Paths.transcripts, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
            // Decoded in parallel: a big library is hundreds of files.
            let slots = LoadSlots(files.count)
            let decode = Perf.signposter.beginInterval("Store.decode", "\(files.count) files")
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let u = files[i]
                // iCloud held it past the launch budget (or its launch write is still queued): read after launch.
                if deferred.contains(Cloud.launchKey(u)) { slots.skip(i); return }
                guard case .read(let read) = Cloud.launchRead(u, budget: budget) else { slots.skip(i); return }
                guard let data = read else { return }
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
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishLoad(files: files, slots: slots) } }
        }
    }

    /// The decoded transcripts join the library, then everything launch did after reading them runs in the same
    /// order as before: legacy rewrites, stuck imports, housekeeping, orphan recovery or the late reads, CloudSync.
    private func finishLoad(files: [URL], slots: LoadSlots) {
        var list: [Transcript] = [], dates: [UUID: Date] = [:]
        var stuck: [UUID] = []
        for case let slot? in slots.items {
            var t = slot.t
            if Self.isStuckImport(t) { stuck.append(t.id) }
            else if t.status == .processing { t.stage = "Queued" }   // the app resumes these
            if t.status == .ready, t.pendingAppend == nil, t.stage != nil { t.stage = nil }   // a speaker pass that didn't finish
            // Only files that match memory exactly may be skipped by CloudSync's first pass; the rest are read again.
            if t == slot.t, let mod = slot.mod { dates[t.id] = mod }
            list.append(t)
        }
        // Anything added while the library loaded (a dictation, a recording) stays as it is in memory, which is newer
        // than its file (if its write landed before the folder was read).
        let early = _transcripts
        if !early.isEmpty {
            let ids = Set(early.map(\.id))
            list.removeAll { ids.contains($0.id) }
            stuck.removeAll { ids.contains($0) }
            for id in ids { dates[id] = nil }
            list += early
        }
        searchCache = [:]
        transcripts = list.sorted { $0.createdAt > $1.createdAt }
        loadedDates = dates
        let late = slots.skipped.map { files[$0] }
        lateTranscripts = Set(late.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        Perf.signposter.emitEvent("Store.late", "\(late.count) files")
        // Files from older builds that still hold absolute paths: rewritten once without them.
        for id in LocalMedia.takeLegacy() { if let t = transcript(id) { loadedDates[id] = nil; save(t) } }
        cleanUpStuckImports(stuck)
        // Housekeeping the library doesn't wait for: old downloads are removed on a background queue, the
        // recordings folder is checked for orphans on one (they're adopted here afterward), and expired items
        // leave Recently Deleted a run-loop turn later.
        DispatchQueue.global(qos: .utility).async { Self.cleanDownloads() }
        if late.isEmpty { recoverOrphans() } else {
            // A recording a late transcript points at isn't an orphan: recovery waits until they're all read.
            Log.note("load: \(late.count) transcript\(late.count == 1 ? "" : "s") not read within the launch budget; reading in the background")
            readLate(late)
        }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.purgeExpired() } }
        if Cloud.enabled { let s = CloudSync(store: self); sync = s; s.seed(loadedDates); s.start() }
        loadedDates = [:]
        Cloud.deferredAtLaunch = []
        if let interval = loadInterval { Perf.signposter.endInterval("Store.load", interval); loadInterval = nil }
        loadMs = Date().timeIntervalSince(loadStarted) * 1000
        Log.note("load: \(transcripts.count) transcripts in \(Int(loadMs.rounded())) ms")
        LaunchClock.libraryLoaded()
        isLoaded = true
        let waiting = loadedCallbacks
        loadedCallbacks = []
        for body in waiting { DispatchQueue.main.async { MainActor.assumeIsolated { body() } } }
    }

    // MARK: Late launch reads

    /// Transcripts launch skipped (iCloud held them past the budget): read once every write launch queued has landed,
    /// each through its own coordinated read that holds no thread while it waits, and merged in on main as they arrive.
    private func readLate(_ urls: [URL]) {
        TranscriptFiles.queue.async { [weak self] in
            for u in urls {
                Cloud.readInBackground(u) { data in
                    let t = data.flatMap { try? TranscriptFiles.dec.decode(Transcript.self, from: $0) }
                    if data != nil, t == nil { Log.note("load: couldn't read \(u.lastPathComponent)") }
                    let mod = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishLate(u, t, modified: mod) } }
                }
            }
        }
    }

    /// One late transcript arrived: added as launch would have added it, then anything CloudSync saw meanwhile is read.
    private func finishLate(_ url: URL, _ read: Transcript?, modified: Date?) {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), lateTranscripts.remove(id) != nil else { return }
        // Deleted for good (on the other device) while it was being read: stays gone.
        if var t = read, t.id == id, index(of: id) == nil, FileManager.default.fileExists(atPath: url.path) {
            let stuck = Self.isStuckImport(t)   // left as it is; the next launch cleans it up (its entry is kept)
            if !stuck, t.status == .processing { t.stage = "Queued" }
            if t.status == .ready, t.pendingAppend == nil, t.stage != nil { t.stage = nil }
            if t == read, let modified { sync?.seed([id: modified]) }
            searchCache[id] = nil
            transcripts.append(t)
            transcripts.sort { $0.createdAt > $1.createdAt }
            for legacy in LocalMedia.takeLegacy() { if let lt = transcript(legacy) { save(lt) } }
            onRemoteChange?(t)
            // This device's own job, which the queue's resume at launch couldn't see: queued now.
            if !stuck, t.processingDevice == Device.id, (t.status == .processing && t.audioFileName != nil) || t.pendingAppend != nil {
                onRecovered?([id], false)
            }
        }
        if inFlight[id] == nil, pendingSaves[id] == nil, let u = deferredIngest.removeValue(forKey: id) {
            let now = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if read == nil || now != modified { ingest(u) }
        }
        if lateTranscripts.isEmpty {
            Log.note("load: late transcripts read")
            recoverOrphans()
        }
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
        PendingImports.keep(only: Set(transcripts.map(\.id)).union(lateTranscripts))
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

    /// Transcripts that aren't in Recently Deleted (worked out once per library change, Store+Memo.swift).
    var live: [Transcript] { memo("live") { transcripts.filter { $0.deletedAt == nil } } }
    /// Recently Deleted, newest first.
    var trash: [Transcript] {
        memo("trash") { transcripts.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) } }
    }

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
        // A late launch read (`readLate`) is on its way: CloudSync's read waits for it, never on the main thread.
        if pendingSaves[id] != nil || inFlight[id] != nil || lateTranscripts.contains(id) { deferredIngest[id] = url; return nil }
        CloudSync.resolveTranscriptConflicts(url)
        guard let data = Cloud.read(url), var t = try? TranscriptFiles.dec.decode(Transcript.self, from: data) else { return nil }
        if let i = index(of: id) {
            // Memory as it shows: with the live progress label (StageClock) folded in.
            var current = transcripts[i]
            if let live = StageClock.shared.stage(id) { current.stage = live }
            // Keep this device's live progress label for jobs it's running.
            if t.status == .processing, t.processingDevice == Device.id { t.stage = current.stage }
            guard current != t else { return nil }
            StageClock.shared.take(id)
            searchCache[id] = nil
            replaceTranscript(at: i, with: t)
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
        StageClock.shared.take(id)
        transcripts.removeAll { $0.id == id }
    }

    func ingestProjects() { ingestList(list: \.projects, sync: \.projectSync) }
    func ingestDictionary() { ingestList(list: \.dictionary, sync: \.dictionarySync) }

    // MARK: Profile (name and About me), synced as one small file

    struct SyncedProfile: Codable, Equatable { var name: String; var aboutMe: String }
    static let profileNameKey = "profile.name", profileAboutKey = "profile.aboutMe"
    private var lastProfile: SyncedProfile?
    /// Launch's read of the profile is on its way (LaunchBudget): nil, or true when CloudSync asked for it meanwhile.
    private var profileLate: Bool?
    private var profileObserver: NSObjectProtocol?

    private var localProfile: SyncedProfile {
        let d = UserDefaults.standard
        return SyncedProfile(name: d.string(forKey: Self.profileNameKey) ?? "", aboutMe: d.string(forKey: Self.profileAboutKey) ?? "")
    }

    /// At launch: takes the synced profile where this device has nothing, then writes back when either field changes.
    func startProfileSync(budget: LaunchBudget? = nil) {
        let read: Cloud.LaunchRead = budget.map { Cloud.launchRead(Paths.profileFile, budget: $0) } ?? .read(Cloud.read(Paths.profileFile))
        guard case .read(let d) = read else {
            // iCloud held it past the launch budget: read in the background, then merged as below. Nothing is written
            // before then, so the file's About me can't be replaced by an empty one.
            profileLate = false
            Self.lateQueue.async { [weak self] in
                let d = Cloud.read(Paths.profileFile)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let again = self.profileLate ?? false
                        self.profileLate = nil
                        self.startProfileSync(read: d)
                        if again { self.ingestProfile() }
                    }
                }
            }
            return
        }
        startProfileSync(read: d)
    }

    private func startProfileSync(read d: Data?) {
        if let d, let p = try? Self.dec.decode(SyncedProfile.self, from: d) {
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
        // On the write queue, in order, so the main thread never waits on iCloud (LaunchBudget).
        if let d = try? JSONEncoder().encode(p) { TranscriptFiles.queue.async { Cloud.write(d, to: Paths.profileFile) } }
    }

    /// The other device changed your name or About me: the newer file wins.
    func ingestProfile() {
        if profileLate != nil { profileLate = true; return }
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
        save(applyChange(change, at: i))
    }

    /// Like `update`, but writes to disk a second after the last change: for typing.
    func updateDeferred(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = index(of: id) else { return }
        searchCache[id] = nil
        applyChange(change, at: i)
        pendingSaves[id]?.cancel()
        let w = DispatchWorkItem { [weak self] in if let t = self?.transcript(id) { self?.save(t) } }
        pendingSaves[id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    /// A change to the transcript at `i`, with its live progress label (StageClock) folded in first, so the change and
    /// what's saved start from the transcript as it showed (as when `setStage` wrote the label into it).
    @discardableResult private func applyChange(_ change: (inout Transcript) -> Void, at i: Int) -> Transcript {
        var t = _transcripts[i]
        if let live = StageClock.shared.take(t.id) { t.stage = live }
        change(&t)
        replaceTranscript(at: i, with: t)
        return t
    }

    /// Permanent: removes the transcript, its audio, and its thumbnail.
    func delete(_ t: Transcript) {
        transcripts.removeAll { $0.id == t.id }
        searchCache[t.id] = nil
        StageClock.shared.take(t.id)
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

    /// Bumped on every change to `transcripts`, so the ID index knows when a miss may be stale and the library memo
    /// (Store+Memo.swift) when to work things out again.
    private(set) var transcriptsGeneration = 0
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

    /// Display-only progress text; not written to disk. It goes to the StageClock, so a tick re-renders only the
    /// progress views (`LiveStage`), not every view that reads `transcripts`; the next `update` folds it in.
    func setStage(_ id: UUID, _ stage: String) {
        guard let i = index(of: id), (StageClock.shared.stage(id) ?? transcripts[i].stage) != stage else { return }
        StageClock.shared.set(id, stage)
    }

    /// The transcript as it shows, with its live progress label (StageClock) folded in.
    func shown(_ id: UUID) -> Transcript? { transcript(id).map(StageClock.shared.applied(to:)) }

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
        readList(type, at: url, budget: nil).read
    }

    /// `readList`, with a launch budget: `late` when iCloud held the file past it (the list is then unavailable).
    nonisolated static func readList<T: SyncEntry>(_ type: T.Type, at url: URL, budget: LaunchBudget?) -> (read: ListRead<[T]>, late: Bool) {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard fm.fileExists(atPath: url.path) else {
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return (.unavailable("not downloaded yet"), false)
            }
            return (.missing, false)
        }
        guard Cloud.isDownloaded(url) else {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return (.unavailable("not downloaded yet"), false)
        }
        let data: Data?
        if let budget {
            guard case .read(let d) = Cloud.launchRead(url, budget: budget) else { return (.unavailable("held by iCloud at launch"), true) }
            data = d
        } else {
            data = Cloud.read(url)
        }
        guard let data else { return (.unavailable("couldn't be read"), false) }
        // Same date format as `Store.dec` (ISO 8601); TranscriptFiles' decoder isn't tied to the main actor.
        guard let items = SyncMerge.decode(T.self, from: data, decoder: TranscriptFiles.dec) else { return (.unavailable("couldn't be decoded"), false) }
        return (.ok(items), false)
    }

    nonisolated static func readTombstones(_ url: URL) -> [Tombstone] {
        guard let d = Cloud.read(url) else { return [] }
        return (try? TranscriptFiles.dec.decode([Tombstone].self, from: d)) ?? []
    }

    /// `readTombstones` for launch: nil when iCloud held the file past the budget.
    nonisolated static func readTombstones(_ url: URL, budget: LaunchBudget) -> [Tombstone]? {
        guard case .read(let d) = Cloud.launchRead(url, budget: budget) else { return nil }
        return d.flatMap { try? TranscriptFiles.dec.decode([Tombstone].self, from: $0) } ?? []
    }

    private func loadList<T: SyncEntry>(list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>, budget: LaunchBudget) {
        var s = self[keyPath: skp]
        let wasLoading = loading
        loading = true
        // Its launch write is still queued, or iCloud held it or its deletes past the budget: unavailable for now (so
        // never written over), and read in the background after the first frame (`readListLate`).
        let deferred = Cloud.deferredAtLaunch.contains(Cloud.launchKey(s.file)) || Cloud.deferredAtLaunch.contains(Cloud.launchKey(s.tombFile))
        let tombs = deferred ? nil : Self.readTombstones(s.tombFile, budget: budget)
        let r: (read: ListRead<[T]>, late: Bool) = tombs == nil ? (.unavailable("held by iCloud at launch"), true) : Self.readList(T.self, at: s.file, budget: budget)
        let read = r.read
        s.tombstones = tombs ?? []
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
        if r.late { readListLate(list: kp, sync: skp) }
    }

    /// A list launch left for later: read off the main thread once every write launch queued has landed, then merged
    /// on main exactly as CloudSync's `ingestList` merges a change. CloudSync's own requests meanwhile wait for it.
    private func readListLate<T: SyncEntry>(list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>) {
        let s = self[keyPath: skp]
        lateLists[s.file.path] = false
        TranscriptFiles.queue.async { [weak self] in
            Self.lateQueue.async {
                let read = Self.readList(T.self, at: s.file)
                let tombs = Self.readTombstones(s.tombFile)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let again = self.lateLists.removeValue(forKey: s.file.path) ?? false
                        self.applyList(read, remoteTombstones: { tombs }, list: kp, sync: skp)
                        if again { self.readListLate(list: kp, sync: skp) }
                    }
                }
            }
        }
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
        // On the write queue, in order, so the main thread never waits on iCloud (LaunchBudget).
        if let d = try? Self.enc.encode(self[keyPath: kp]) { TranscriptFiles.queue.async { Cloud.write(d, to: s.file) } }
        if !s.tombstones.isEmpty || FileManager.default.fileExists(atPath: s.tombFile.path), let d = try? Self.enc.encode(s.tombstones) {
            TranscriptFiles.queue.async { Cloud.write(d, to: s.tombFile) }
        }
        self[keyPath: skp].dirty = false
    }

    /// The list's file changed (usually on the other device): merged entry by entry with this device's copy, along
    /// with any conflicting versions iCloud kept. Written back only when the merge has something the file lacks.
    private func ingestList<T: SyncEntry>(list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>) {
        let s = self[keyPath: skp]
        // Launch's late read of this list is on its way: it reads again once that lands, never on the main thread.
        if lateLists[s.file.path] != nil { lateLists[s.file.path] = true; return }
        applyList(Self.readList(T.self, at: s.file), remoteTombstones: { Self.readTombstones(s.tombFile) }, list: kp, sync: skp)
    }

    /// Merges a read of a list's file (and, when it read, its deletes) into this device's copy.
    private func applyList<T: SyncEntry>(_ listRead: ListRead<[T]>, remoteTombstones: () -> [Tombstone],
                                         list kp: ReferenceWritableKeyPath<Store, [T]>, sync skp: ReferenceWritableKeyPath<Store, ListSync>) {
        var s = self[keyPath: skp]
        switch listRead {
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
            let remoteTombs = remoteTombstones()
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
