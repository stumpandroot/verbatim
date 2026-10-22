import Foundation
import AppKit
import CoreServices
import UserNotifications

/// A folder Verbatim watches. New audio and video in it is transcribed through the normal import path, then
/// exported to `destination` (or next to the original) in the chosen formats with the saved export options.
struct WatchedFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Security-scoped bookmark (a plain bookmark if the system won't make a scoped one).
    var bookmark: Data
    /// The last resolved path, for display and for matching file events.
    var path: String
    var includeSubfolders = false
    var enabled = true
    /// ExportFormat raw values. Empty: the transcript stays in the Library, nothing is exported.
    var formats: [String] = []
    /// Where exports go; nil means next to the original file.
    var destination: Data? = nil
    var destinationPath: String? = nil
    /// "{original name}", "{title}", and "{date}" fill in; the format's extension is added.
    var namePattern = "{original name}"
    var notify = true
    var addedAt = Date()

    var exportFormats: [ExportFormat] { ExportFormat.allCases.filter { formats.contains($0.rawValue) } }

    static func display(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

/// One line in the watched-folder activity list.
struct WatchEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case queued, exported, ready, failed }
    var id = UUID()
    var date = Date()
    var folder: String
    var file: String
    var kind: Kind
    var detail: String
    var transcriptID: UUID? = nil
}

/// Watches the folders in Settings › Watched folders with FSEvents. A new media file waits until its size and
/// modification date hold still for 3 seconds (a copy or a recorder still writing), is skipped if it was seen
/// before (by path, size, and modification date), then goes through `AppState.importFiles`. When its
/// transcript is ready, each chosen format is written with `Exporter` and the saved `ExportOptions`.
@MainActor
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()

    static let foldersKey = "watch.folders", eventsKey = "watch.events", processedKey = "watch.processed", inFlightKey = "watch.inflight"
    static let stableSeconds: TimeInterval = 3

    @Changed var folders: [WatchedFolder] = [] { didSet { saveFolders(); if oldValue.map(\.path) != folders.map(\.path) || oldValue.map(\.enabled) != folders.map(\.enabled) { restartStream() } } }
    @Changed var events: [WatchEvent] = []
    /// Folders whose bookmark no longer resolves (moved, deleted, or permission revoked).
    @Changed var needsAccess: Set<UUID> = []
    /// Files waiting to settle or transcribing, by folder, for the status line.
    @Changed var busy: [UUID: Int] = [:]

    private weak var app: AppState?
    private var stream: FSEventStreamRef?
    private var scoped: [UUID: URL] = [:]
    private var resolved: [UUID: URL] = [:]
    private struct Candidate { var folder: UUID; var size: Int; var mtime: TimeInterval; var stableSince: Date }
    private var candidates: [String: Candidate] = [:]
    private var timer: Timer?
    private var scanGen: [UUID: Int] = [:]
    /// Transcript id → (folder id, original file path), persisted so exports still happen after a relaunch.
    private var inFlight: [String: [String]] = [:]
    private var processed: [String] = []
    private var processedSet: Set<String> = []
    private var loading = false

    private init() {}

    // MARK: Lifecycle

    func attach(_ app: AppState) {
        self.app = app
        loading = true
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.foldersKey), let f = try? JSONDecoder().decode([WatchedFolder].self, from: data) { folders = f }
        if let data = d.data(forKey: Self.eventsKey), let e = try? JSONDecoder().decode([WatchEvent].self, from: data) { events = e }
        processed = d.stringArray(forKey: Self.processedKey) ?? []
        processedSet = Set(processed)
        inFlight = (d.dictionary(forKey: Self.inFlightKey) as? [String: [String]]) ?? [:]
        loading = false
        guard !Bench.isRequested else { return }
        resolveAll()
        restartStream()
        // Files that arrived while Verbatim was closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scanAll() }
        updateBusy()
    }

    // MARK: Editing (Settings)

    /// Asks for a folder and starts watching it. What's already in it is left alone.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch This Folder"
        panel.message = "New audio and video in this folder will be transcribed. Files already in it are left alone."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    @discardableResult
    func add(_ url: URL, formats: [ExportFormat] = [.txt]) -> WatchedFolder? {
        guard let bm = Self.bookmark(url) else { app?.toast = Toast("Verbose couldn't keep access to that folder."); return nil }
        if let existing = folders.first(where: { $0.path == url.path }) { return existing }
        let first = folders.isEmpty
        let f = WatchedFolder(name: FileManager.default.displayName(atPath: url.path), bookmark: bm, path: url.path,
                              formats: formats.map(\.rawValue))
        startAccess(f.id, url)
        baseline(f, url)
        folders.append(f)
        if first { requestNotificationPermission() }
        return f
    }

    /// Asks again for a folder whose bookmark stopped resolving.
    func reconnect(_ id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folders[i].path).deletingLastPathComponent()
        panel.prompt = "Give Access"
        panel.message = "Choose “\(folders[i].name)” again so Verbose can keep watching it."
        guard panel.runModal() == .OK, let url = panel.url, let bm = Self.bookmark(url) else { return }
        stopAccess(id)
        startAccess(id, url)
        needsAccess.remove(id)
        folders[i].bookmark = bm; folders[i].path = url.path
        baseline(folders[i], url)
        scheduleScan(id)
    }

    /// Picks where a folder's exports go.
    func chooseDestination(_ id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Exports from “\(folders[i].name)” go to this folder."
        if let p = folders[i].destinationPath { panel.directoryURL = URL(fileURLWithPath: p) }
        guard panel.runModal() == .OK, let url = panel.url, let bm = Self.bookmark(url) else { return }
        folders[i].destination = bm; folders[i].destinationPath = url.path
    }

    func remove(_ id: UUID) {
        stopAccess(id)
        needsAccess.remove(id)
        candidates = candidates.filter { $0.value.folder != id }
        folders.removeAll { $0.id == id }
        updateBusy()
    }

    func update(_ id: UUID, _ change: (inout WatchedFolder) -> Void) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var f = folders[i]
        change(&f)
        let resumed = f.enabled && !folders[i].enabled, subfolders = f.includeSubfolders != folders[i].includeSubfolders
        folders[i] = f
        if subfolders, let u = resolved[id] { baseline(f, u) }   // turning subfolders on doesn't transcribe their old files
        if resumed { scheduleScan(id) }
    }

    func reveal(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resolved[id] ?? URL(fileURLWithPath: f.path)])
    }

    // MARK: Access

    nonisolated static func bookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    nonisolated static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        if let u = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { return (u, stale) }
        if let u = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) { return (u, stale) }
        return nil
    }

    private func resolveAll() {
        for f in folders {
            var isDir: ObjCBool = false
            guard let r = Self.resolve(f.bookmark), FileManager.default.fileExists(atPath: r.url.path, isDirectory: &isDir), isDir.boolValue else {
                needsAccess.insert(f.id); continue
            }
            startAccess(f.id, r.url)
            needsAccess.remove(f.id)
            if r.stale || r.url.path != f.path, let bm = Self.bookmark(r.url) {
                update(f.id) { $0.bookmark = bm; $0.path = r.url.path }
            }
        }
    }

    private func startAccess(_ id: UUID, _ url: URL) {
        resolved[id] = url
        if url.startAccessingSecurityScopedResource() { scoped[id] = url }
    }

    private func stopAccess(_ id: UUID) {
        scoped.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        resolved.removeValue(forKey: id)
    }

    // MARK: FSEvents

    private func restartStream() {
        guard !loading, app != nil else { return }
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        let paths = folders.filter { $0.enabled && !needsAccess.contains($0.id) }.compactMap { resolved[$0.id]?.path }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.handle(Array(list.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            Log.note("watch: couldn't create the event stream"); return
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
        Log.note("watch: watching \(paths.count) folder\(paths.count == 1 ? "" : "s")")
    }

    private func handle(_ paths: [String]) {
        var touched = Set<UUID>()
        for p in paths {
            for f in folders where f.enabled {
                guard let root = resolved[f.id]?.path else { continue }
                if p == root || p.hasPrefix(root + "/") { touched.insert(f.id) }
                // The folder itself moved or vanished.
                if p == root && !FileManager.default.fileExists(atPath: root) { needsAccess.insert(f.id); restartStream() }
            }
        }
        touched.forEach(scheduleScan)
    }

    // MARK: Scanning

    func scanAll() { folders.filter(\.enabled).forEach { scheduleScan($0.id) } }

    private func scheduleScan(_ id: UUID) {
        // Coalesces a burst of file events into one scan, half a second after the last.
        let g = (scanGen[id] ?? 0) + 1
        scanGen[id] = g
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.scanGen[id] == g else { return }
            self.scan(id)
        }
    }

    /// Media files in a folder (and its subfolders, when on), skipping hidden files and packages.
    nonisolated static func mediaFiles(in root: URL, subfolders: Bool) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var out: [URL] = []
        if subfolders {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            for case let u as URL in en where MediaImport.isMedia(u) { out.append(u) }
        } else {
            out = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []).filter { MediaImport.isMedia($0) }
        }
        return out.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    nonisolated static func stat(_ u: URL) -> (size: Int, mtime: TimeInterval)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let size = (a[.size] as? NSNumber)?.intValue, let date = a[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970)
    }

    /// The "seen before" key: the same path with the same size and modification date is the same file.
    nonisolated static func processedKey(path: String, size: Int, mtime: TimeInterval) -> String { "\(path)|\(size)|\(Int(mtime))" }

    /// Marks everything already in a folder as seen, so adding a folder doesn't transcribe its back catalog.
    private func baseline(_ f: WatchedFolder, _ url: URL) {
        for u in Self.mediaFiles(in: url, subfolders: f.includeSubfolders) {
            if let s = Self.stat(u) { markProcessed(Self.processedKey(path: u.path, size: s.size, mtime: s.mtime)) }
        }
    }

    private func scan(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }), f.enabled, let root = resolved[id] else { return }
        let inFlightPaths = Set(inFlight.values.compactMap { $0.count > 1 ? $0[1] : nil })
        for u in Self.mediaFiles(in: root, subfolders: f.includeSubfolders) {
            guard let s = Self.stat(u), s.size > 0 else { continue }
            let key = Self.processedKey(path: u.path, size: s.size, mtime: s.mtime)
            if processedSet.contains(key) || inFlightPaths.contains(u.path) { continue }
            if var c = candidates[u.path] {
                if c.size != s.size || c.mtime != s.mtime { c.size = s.size; c.mtime = s.mtime; c.stableSince = Date(); candidates[u.path] = c }
            } else {
                candidates[u.path] = Candidate(folder: id, size: s.size, mtime: s.mtime, stableSince: Date())
            }
        }
        updateBusy()
        if !candidates.isEmpty && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkStable() } }
        }
    }

    /// Imports files whose size and date have held still long enough.
    private func checkStable() {
        var ready: [UUID: [URL]] = [:]
        let now = Date()
        for (path, c) in candidates {
            let u = URL(fileURLWithPath: path)
            guard let s = Self.stat(u) else { candidates.removeValue(forKey: path); continue }   // moved away or deleted
            if s.size != c.size || s.mtime != c.mtime {
                candidates[path] = Candidate(folder: c.folder, size: s.size, mtime: s.mtime, stableSince: now)
            } else if now.timeIntervalSince(c.stableSince) >= Self.stableSeconds {
                candidates.removeValue(forKey: path)
                guard folders.first(where: { $0.id == c.folder })?.enabled == true else { continue }
                markProcessed(Self.processedKey(path: path, size: s.size, mtime: s.mtime))
                ready[c.folder, default: []].append(u)
            }
        }
        if candidates.isEmpty { timer?.invalidate(); timer = nil }
        for (id, urls) in ready { enqueue(urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, from: id) }
        updateBusy()
    }

    private func enqueue(_ urls: [URL], from id: UUID) {
        guard let app, let f = folders.first(where: { $0.id == id }) else { return }
        let added = app.importFiles(urls, useLibraryProject: false, announce: false)
        for (tid, src) in added {
            inFlight[tid.uuidString] = [id.uuidString, src.path]
            log(.init(folder: f.name, file: src.lastPathComponent, kind: .queued, detail: "Transcribing", transcriptID: tid))
        }
        saveInFlight()
        Log.note("watch: queued \(added.count) file\(added.count == 1 ? "" : "s") from a watched folder")
        updateBusy()
    }

    // MARK: Finished transcripts

    /// Called by AppState when a transcript is ready. Exports it if it came from a watched folder.
    func transcriptReady(_ tid: UUID) {
        guard let job = inFlight.removeValue(forKey: tid.uuidString), job.count == 2 else { return }
        saveInFlight()
        defer { updateBusy() }
        let source = URL(fileURLWithPath: job[1])
        guard let f = folders.first(where: { $0.id.uuidString == job[0] }), let t = app?.store.transcript(tid), t.status == .ready else { return }
        let result = Self.export(t, folder: f, source: source)
        let names = f.exportFormats.map(\.rawValue)
        if let error = result.error {
            log(.init(folder: f.name, file: source.lastPathComponent, kind: .failed, detail: "Transcribed, but the export failed: \(error)", transcriptID: tid))
            if f.notify { post(title: "Couldn't export “\(source.lastPathComponent)”", body: error) }
        } else if result.written.isEmpty {
            log(.init(folder: f.name, file: source.lastPathComponent, kind: .ready, detail: "In the Library", transcriptID: tid))
            if f.notify { post(title: "Transcribed “\(source.lastPathComponent)”", body: "It's in your Library.") }
        } else {
            let dir = WatchedFolder.display(result.written[0].deletingLastPathComponent().path)
            log(.init(folder: f.name, file: source.lastPathComponent, kind: .exported, detail: "\(Self.list(names)) → \(dir)", transcriptID: tid))
            if f.notify { post(title: "Transcribed “\(source.lastPathComponent)”", body: "Saved \(Self.list(names)) to \(dir).") }
        }
    }

    func transcriptFailed(_ tid: UUID, error: Error) {
        guard let job = inFlight.removeValue(forKey: tid.uuidString), job.count == 2 else { return }
        saveInFlight()
        updateBusy()
        let file = URL(fileURLWithPath: job[1]).lastPathComponent
        guard let f = folders.first(where: { $0.id.uuidString == job[0] }) else { return }
        log(.init(folder: f.name, file: file, kind: .failed, detail: error.localizedDescription, transcriptID: tid))
        if f.notify { post(title: "Couldn't transcribe “\(file)”", body: error.localizedDescription) }
    }

    /// Writes each chosen format. Uses the options from Settings › Export.
    static func export(_ t: Transcript, folder f: WatchedFolder, source: URL, options: ExportOptions = .saved) -> (written: [URL], error: String?) {
        let formats = f.exportFormats
        guard !formats.isEmpty else { return ([], nil) }
        var dir = source.deletingLastPathComponent()
        var scopedDir: URL? = nil
        if let d = f.destination {
            guard let r = resolve(d) else { return ([], "Verbose lost access to the Save to folder. Choose it again in Settings › Watched folders.") }
            dir = r.url
            if r.url.startAccessingSecurityScopedResource() { scopedDir = r.url }
        }
        defer { scopedDir?.stopAccessingSecurityScopedResource() }
        var written: [URL] = []
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = fileName(pattern: f.namePattern, original: source, title: t.title, date: t.createdAt)
            for format in formats {
                let url = uniqueURL(in: dir, base: base, ext: format.ext)
                if format == .docx { try Exporter.writeDocx(t, options: options, to: url) }
                else { try Exporter.render(t, as: format, options: options).write(to: url, atomically: true, encoding: .utf8) }
                written.append(url)
            }
        } catch {
            return (written, error.localizedDescription)
        }
        return (written, nil)
    }

    /// The export's base name from the folder's pattern, safe for any file system.
    nonisolated static func fileName(pattern: String, original: URL, title: String, date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        let originalName = original.deletingPathExtension().lastPathComponent
        var s = pattern.isEmpty ? "{original name}" : pattern
        s = s.replacingOccurrences(of: "{original name}", with: originalName)
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{date}", with: df.string(from: date))
        s = s.replacingOccurrences(of: "[/:\\\\?%*|\"<>\\n]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? originalName : String(s.prefix(200))
    }

    nonisolated static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base + "." + ext), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return url
    }

    nonisolated static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        guard !UITest.enabled, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.note("watch: notifications \(granted ? "allowed" : "not allowed")")
        }
    }

    private func post(title: String, body: String) {
        guard !UITest.enabled, Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Status and persistence

    /// The status line for a folder in Settings.
    enum Status { case watching, paused, needsAccess }
    func status(_ f: WatchedFolder) -> Status { needsAccess.contains(f.id) ? .needsAccess : f.enabled ? .watching : .paused }

    private func updateBusy() {
        // Drop jobs whose transcript was deleted or cancelled; they'll never come back ready.
        let stale = inFlight.keys.filter { k in
            guard let id = UUID(uuidString: k), let t = app?.store.transcript(id) else { return app != nil }
            return t.status == .failed
        }
        if !stale.isEmpty { stale.forEach { inFlight.removeValue(forKey: $0) }; saveInFlight() }
        var b: [UUID: Int] = [:]
        for c in candidates.values { b[c.folder, default: 0] += 1 }
        for v in inFlight.values { if let id = v.first.flatMap(UUID.init(uuidString:)) { b[id, default: 0] += 1 } }
        busy = b
    }

    private func log(_ e: WatchEvent) {
        // A file's later line replaces its "Transcribing" line.
        var list = events
        if let tid = e.transcriptID, e.kind != .queued { list.removeAll { $0.transcriptID == tid && $0.kind == .queued } }
        list.insert(e, at: 0)
        events = Array(list.prefix(200))
        if let data = try? JSONEncoder().encode(events) { UserDefaults.standard.set(data, forKey: Self.eventsKey) }
    }

    private func markProcessed(_ key: String) {
        guard processedSet.insert(key).inserted else { return }
        processed.append(key)
        if processed.count > 5000 { let drop = processed.prefix(processed.count - 5000); processed.removeFirst(drop.count); drop.forEach { processedSet.remove($0) } }
        UserDefaults.standard.set(processed, forKey: Self.processedKey)
    }

    private func saveFolders() {
        guard !loading, let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: Self.foldersKey)
    }

    private func saveInFlight() { UserDefaults.standard.set(inFlight, forKey: Self.inFlightKey) }
}
