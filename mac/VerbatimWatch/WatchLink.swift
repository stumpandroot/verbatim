import Foundation
import WatchConnectivity
import WatchKit
import WidgetKit
import os

// The watch's side of Watch Connectivity (DESIGN.md §20). Each recording goes to the iPhone with `transferFile`, which
// the system queues until the iPhone is in reach, even across launches. The audio stays in the watch's outbox, with
// its `WatchTransfer` beside it, until the transfer finishes without an error; then the watch deletes it. Anything in
// the outbox that isn't on its way (a transfer that failed, or the app closed before it was queued) is sent again at
// the next launch or when the iPhone comes back in reach; the iPhone imports each recording once, by its ID. The iPhone
// sends today's thought count and its last capture with `updateApplicationContext`; the watch keeps them in the App
// Group for its complications.

let watchLog = Logger(subsystem: "co.stumpandroot.verbatim.watch", category: "watch")

/// Where the watch keeps audio: the recording in progress (with its details beside it, so a recording the app was
/// closed in the middle of still goes to the iPhone) and the outbox of recordings waiting for the iPhone.
enum WatchStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Verbose", isDirectory: true)
    }
    static var recordingFolder: URL { folder("Recording") }
    static var outbox: URL { folder("Outbox") }

    private static func folder(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func recordingURL(_ id: UUID) -> URL { recordingFolder.appendingPathComponent("\(id.uuidString).m4a") }
    static func outboxURL(_ id: UUID) -> URL { outbox.appendingPathComponent("\(id.uuidString).m4a") }
    /// The transfer's details beside its audio.
    static func details(_ audio: URL) -> URL { audio.deletingPathExtension().appendingPathExtension("json") }

    static func writeDetails(_ t: WatchTransfer, beside audio: URL) {
        guard let data = t.encoded() else { return }
        try? data.write(to: details(audio), options: .atomic)
    }

    /// The recordings in a folder that have both their audio and their details, oldest first.
    static func items(in folder: URL) -> [(audio: URL, transfer: WatchTransfer)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { json -> (audio: URL, transfer: WatchTransfer)? in
            guard let data = try? Data(contentsOf: json), let t = WatchTransfer.decode(data) else { return nil }
            let audio = json.deletingPathExtension().appendingPathExtension("m4a")
            guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
            return (audio: audio, transfer: t)
        }.sorted { $0.transfer.startedAt < $1.transfer.startedAt }
    }

    static func remove(_ audio: URL) {
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: details(audio))
    }

    /// Free space on the watch, in bytes; nil when the system doesn't say.
    static func freeBytes() -> Int64? {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    static var shared: UserDefaults { UserDefaults(suiteName: WatchRules.appGroup) ?? .standard }
}

final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()

    /// Recordings in the outbox, waiting for the iPhone.
    @Published private(set) var waiting = 0
    /// The iPhone's last word: today's thoughts and the last capture.
    @Published private(set) var context: WatchContext?
    /// Thoughts recorded on the watch that haven't reached the iPhone, by when they started.
    @Published private(set) var unsentThoughts: [Date] = []
    @Published private(set) var reachable = false

    private var held: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var retryScheduled = false

    /// Today's count, as the home screen shows it.
    var thoughtsToday: Int { WatchRules.thoughtsToday(context: context, unsent: unsentThoughts) }

    func activate() {
        if let data = WatchStore.shared.data(forKey: WatchRules.contextKey) { context = WatchContext.decode(data) }
        refreshOutbox()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.delegate !== self else { return }
        s.delegate = self
        s.activate()
    }

    // MARK: Sending

    /// Moves a finished recording into the outbox and sends it. The audio stays until the iPhone has it.
    func enqueue(file: URL, transfer t: WatchTransfer) {
        let dest = WatchStore.outboxURL(t.id)
        do {
            if file.standardizedFileURL != dest.standardizedFileURL {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: file, to: dest)
            }
        } catch {
            // Never lose it: send it from where it is, and keep its details beside it.
            watchLog.error("couldn't move the recording into the outbox: \(error.localizedDescription, privacy: .public)")
            WatchStore.writeDetails(t, beside: file)
            send(file, t)
            refreshOutbox()
            return
        }
        WatchStore.writeDetails(t, beside: dest)
        try? FileManager.default.removeItem(at: WatchStore.details(file))
        send(dest, t)
        refreshOutbox()
    }

    private func send(_ audio: URL, _ t: WatchTransfer) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        // Before activation finishes, the outbox goes out from `activationDidComplete`.
        guard s.activationState == .activated else { return }
        s.transferFile(audio, metadata: t.metadata())
        watchLog.notice("queued \(t.id.uuidString, privacy: .public) for the iPhone (\(Int(t.duration)) s, \(t.marks.count) marks)")
    }

    /// Sends everything in the outbox that isn't already on its way. (A recording that never stopped is moved into the
    /// outbox at launch, WatchRecorder.recoverLeftovers.)
    func resendPending() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        let sending = Set(s.outstandingFileTransfers.compactMap { WatchTransfer.from(metadata: $0.file.metadata)?.id })
        for item in WatchStore.items(in: WatchStore.outbox) where !sending.contains(item.transfer.id) {
            s.transferFile(item.audio, metadata: item.transfer.metadata())
            watchLog.notice("sent \(item.transfer.id.uuidString, privacy: .public) again")
        }
    }

    /// Counts the outbox and tells the complications about unsent thoughts.
    func refreshOutbox() {
        let items = WatchStore.items(in: WatchStore.outbox)
        let thoughts = items.filter { $0.transfer.kind == .thought }.map(\.transfer.startedAt)
        WatchStore.shared.set(thoughts, forKey: WatchRules.unsentThoughtsKey)
        DispatchQueue.main.async {
            self.waiting = items.count
            if self.unsentThoughts != thoughts { self.unsentThoughts = thoughts; WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.retryScheduled = false
            self?.resendPending()
        }
    }

    // MARK: Background refresh

    /// A background task watchOS gives the app when the iPhone sends something; completed once nothing is pending.
    func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        held.append(task)
        activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.completeHeld(force: true) }
        completeHeld(force: false)
    }

    private func completeHeld(force: Bool) {
        DispatchQueue.main.async {
            guard !self.held.isEmpty else { return }
            let s = WCSession.default
            guard force || (s.activationState == .activated && !s.hasContentPending) else { return }
            self.held.forEach { $0.setTaskCompletedWithSnapshot(false) }
            self.held.removeAll()
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error { watchLog.error("activation: \(error.localizedDescription, privacy: .public)") }
        let ctx = session.receivedApplicationContext
        DispatchQueue.main.async {
            self.reachable = session.isReachable
            if !ctx.isEmpty { self.apply(ctx) }
            self.resendPending()
            self.completeHeld(force: false)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.reachable = session.isReachable
            if session.isReachable { self.resendPending() }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.apply(applicationContext)
            self.completeHeld(force: false)
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file
        guard let t = WatchTransfer.from(metadata: file.metadata) else { return }
        if let error {
            // Kept: it goes again at the next launch, when the iPhone comes back, or in two minutes.
            watchLog.error("transfer \(t.id.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { self.scheduleRetry() }
        } else {
            // The iPhone has it: the watch keeps nothing but what the iPhone shows.
            WatchStore.remove(WatchStore.outboxURL(t.id))
            if file.fileURL.standardizedFileURL != WatchStore.outboxURL(t.id).standardizedFileURL { WatchStore.remove(file.fileURL) }
            watchLog.notice("the iPhone has \(t.id.uuidString, privacy: .public)")
        }
        refreshOutbox()
    }

    private func apply(_ dictionary: [String: Any]) {
        guard let c = WatchContext(dictionary: dictionary) else { return }
        if let data = c.encoded() { WatchStore.shared.set(data, forKey: WatchRules.contextKey) }
        context = c
        WidgetCenter.shared.reloadAllTimelines()
    }
}
