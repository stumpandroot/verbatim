import Foundation
import Combine
import UIKit
import WatchConnectivity

// The iPhone's side of Apple Watch capture (DESIGN.md §20; mockup "Library features", section 4c). The watch sends
// each recording with `transferFile` and its `WatchTransfer` as metadata. Watch Connectivity is activated before launch
// finishes (PhoneAppDelegate), so iOS can hand a file over while Verbose runs in the background. The file is moved into
// the Watch inbox (Application Support) before the delegate returns, since iOS deletes it after; then it goes through
// the same import path as a shared or picked file (`importSources`), with the kind (a thought lands on today's page,
// from the Apple Watch), the marks as moments from the Apple Watch, and the transcription queue. Each recording is
// imported once, by its ID, however many times the watch sends it. The inbox keeps the audio until the import has it.
//
// The iPhone tells the watch today's thought count and its last capture (`updateApplicationContext`) when the library
// changes, for the watch's home screen, its complications, and the Smart Stack.

/// Recordings from the watch that haven't been imported yet: the audio and its transfer, side by side.
enum WatchInbox {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let u = base.appendingPathComponent("Watch inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Audio whose import failed: kept, never deleted, so nothing from the watch is lost.
    static var kept: URL {
        let u = folder.appendingPathComponent("Kept", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func details(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    /// Moves a file from the watch in, with its transfer beside it. False when it couldn't be kept.
    @discardableResult
    static func keep(_ file: URL, _ t: WatchTransfer) -> Bool {
        let ext = file.pathExtension.isEmpty ? "m4a" : file.pathExtension.lowercased()
        let audio = folder.appendingPathComponent("\(t.id.uuidString).\(ext)")
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: audio)
            do { try fm.moveItem(at: file, to: audio) } catch { try fm.copyItem(at: file, to: audio) }
            guard let data = t.encoded() else { return false }
            // The details last: a file without them is never imported half-written.
            try data.write(to: details(t.id), options: .atomic)
            return true
        } catch {
            Log.note("watch: couldn't keep a recording from the watch: \(error)")
            return false
        }
    }

    /// What's waiting, oldest first.
    static func pending() -> [(audio: URL, transfer: WatchTransfer)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let audio = files.filter { $0.pathExtension != "json" && !$0.hasDirectoryPath }
        return files.filter { $0.pathExtension == "json" }.compactMap { json -> (audio: URL, transfer: WatchTransfer)? in
            guard let data = try? Data(contentsOf: json), let t = WatchTransfer.decode(data),
                  let a = audio.first(where: { $0.deletingPathExtension().lastPathComponent == t.id.uuidString }) else { return nil }
            return (audio: a, transfer: t)
        }.sorted { $0.transfer.startedAt < $1.transfer.startedAt }
    }

    static func wasImported(_ id: UUID, _ d: UserDefaults = .standard) -> Bool {
        (d.stringArray(forKey: WatchImport.importedKey) ?? []).contains(id.uuidString)
    }

    /// The import has the audio (or gave up on it): remembered, and the inbox's copy deleted, or kept when it failed.
    static func finish(_ id: UUID, audio: URL, imported: Bool, _ d: UserDefaults = .standard) {
        d.set(WatchImport.remembering(id, in: d.stringArray(forKey: WatchImport.importedKey) ?? []), forKey: WatchImport.importedKey)
        try? FileManager.default.removeItem(at: details(id))
        if imported {
            try? FileManager.default.removeItem(at: audio)
        } else {
            let dest = kept.appendingPathComponent(audio.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: audio, to: dest)
            Log.note("watch: the import of \(id.uuidString) failed; its audio is kept in \(dest.path)")
        }
    }

    /// A transfer that was already imported: its copy goes.
    static func drop(_ id: UUID, audio: URL) {
        try? FileManager.default.removeItem(at: details(id))
        try? FileManager.default.removeItem(at: audio)
    }

    /// Imports running now, so becoming active while a file arrives never imports it twice.
    @MainActor static var inFlight = Set<UUID>()
}

/// Watch Connectivity on the iPhone. Its delegate calls come on a background queue; the import runs on the main actor.
final class PhoneWatchLink: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchLink()
    /// The app, once PhoneState is ready, and the library subscription.
    @MainActor private enum Host {
        static weak var app: PhoneState?
        static var bag = Set<AnyCancellable>()
    }
    @MainActor private var app: PhoneState? { Host.app }

    /// Before launch finishes (PhoneAppDelegate). Once per process.
    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.delegate !== self else { return }
        s.delegate = self
        s.activate()
    }

    /// PhoneState is ready: import what's waiting, and keep the watch's count current as the library changes.
    @MainActor func attach(_ app: PhoneState) {
        Host.app = app
        app.importWatchInbox()
        // The screenshot tour's made-up library never reaches a watch.
        guard !PhoneUITest.enabled, Host.bag.isEmpty else { return }
        app.store.transcriptsPublisher
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self, weak app] _ in
                guard let self, let app else { return }
                self.publish(app.store)
            }
            .store(in: &Host.bag)
    }

    /// The same path a file from the watch takes, from the delegate or the self-test: kept in the inbox, then imported.
    /// False when it isn't one of Verbose's recordings or couldn't be kept.
    @discardableResult
    func receive(fileAt url: URL, metadata: [String: Any]?) -> Bool {
        guard let t = WatchTransfer.from(metadata: metadata) else {
            Log.note("watch: a file without Verbose's details; ignored")
            return false
        }
        guard WatchInbox.keep(url, t) else { return false }
        Log.note("watch: received a \(t.kind.rawValue) of \(Int(t.duration)) s with \(t.marks.count) marks")
        Task { @MainActor in self.app?.importWatchInbox() }
        return true
    }

    // MARK: Today's count for the watch

    /// What the watch shows: today's thoughts (with Settings › Features › Thoughts › New page each day at) and the
    /// newest recording.
    @MainActor static func context(_ store: Store, now: Date = Date()) -> WatchContext {
        let hour = DayPages.storedHour()
        let page = DayPages.pageInterval(DayPages.today(now: now, hour: hour), hour: hour)
        return WatchImport.context(today: store.todaysThoughts(now: now), pageEnds: page.end, live: store.live, now: now)
    }

    @MainActor func publish(_ store: Store) {
        guard WCSession.isSupported(), store.isLoaded else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        do { try s.updateApplicationContext(Self.context(store).dictionary()) } catch { Log.note("watch: couldn't update the watch: \(error)") }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error { Log.note("watch: activation: \(error)") }
        Task { @MainActor in
            guard let app = self.app else { return }
            app.store.whenLoaded { [weak self, weak app] in
                guard let self, let app else { return }
                self.publish(app.store)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another watch: activate again for the new one.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in if let app = self.app { self.publish(app.store) } }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is gone once this returns, so it's moved into the inbox here.
        receive(fileAt: file.fileURL, metadata: file.metadata)
    }
}

extension PhoneState {
    /// Imports the Watch inbox through `importSources`: once the library has loaded, each recording once.
    func importWatchInbox() {
        guard store.isLoaded else { store.whenLoaded { [weak self] in self?.importWatchInbox() }; return }
        var sources: [ImportSource] = []
        var transfers: [WatchTransfer] = []
        // The transcript each import made, filled in once `importSources` returns (before any import finishes).
        let made = WatchImportMade()
        for item in WatchInbox.pending() {
            let t = item.transfer
            if WatchInbox.wasImported(t.id) { WatchInbox.drop(t.id, audio: item.audio); continue }
            guard !WatchInbox.inFlight.contains(t.id) else { continue }
            WatchInbox.inFlight.insert(t.id)
            let plan = WatchImport.plan(t)
            let audio = item.audio
            transfers.append(t)
            sources.append(ImportSource(url: audio, title: plan.title, label: plan.label, source: .voiceMemo, createdAt: plan.createdAt,
                                        kind: plan.kind, notes: plan.notes, finished: { [weak self] in
                let ok = made.ids[t.id].flatMap { self?.store.transcript($0)?.audioFileName } != nil
                WatchInbox.finish(t.id, audio: audio, imported: ok)
                WatchInbox.inFlight.remove(t.id)
            }))
        }
        guard !sources.isEmpty else { return }
        let ids = importSources(sources)
        for (t, id) in zip(transfers, ids) { made.ids[t.id] = id }
        Log.note("watch: importing \(ids.count) recording\(ids.count == 1 ? "" : "s") from the Apple Watch")
        if UIApplication.shared.applicationState == .active {
            if ids.count > 1 { say("Added \(ids.count) recordings from your Apple Watch") }
            else { say(transfers.first?.kind == .thought ? "Added to Thoughts from your Apple Watch" : "Added from your Apple Watch") }
        }
    }
}

/// Which transcript each watch recording became, for the import's `finished`.
private final class WatchImportMade {
    var ids: [UUID: UUID] = [:]
}
