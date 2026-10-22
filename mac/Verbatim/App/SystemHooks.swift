import AppKit
import Combine
import CoreSpotlight
import UniformTypeIdentifiers

/// The Mac's system hooks: Transcribe with Verbatim in Finder (a Service, NSServices in project.yml), Spotlight
/// results for transcripts, and the app the Shortcuts actions (App/VerbatimIntents.swift) talk to.
@MainActor
enum SystemHooks {
    /// The running app, once its state exists. Services and intents that arrive earlier wait for it.
    private(set) static weak var app: AppState?

    static func attach(_ app: AppState) {
        self.app = app
        NSApp.servicesProvider = ServiceProvider.shared
        NSUpdateDynamicServices()
        ServiceProvider.shared.deliverPending()
        SpotlightIndex.shared.attach(app.store)
    }

    /// Waits up to `seconds` for the app's state (an intent or Service can launch Verbatim before its window exists).
    static func waitForApp(seconds: Double = 10) async -> AppState? {
        let end = Date().addingTimeInterval(seconds)
        while app == nil, Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
        return app
    }

    /// Brings the main window forward and opens a transcript.
    static func open(_ id: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        app?.mainWindow?.makeKeyAndOrderFront(nil)
        if app?.store.transcript(id) != nil { app?.go(.transcript(id)) }
    }
}

// MARK: - Services: Transcribe with Verbatim

/// Handles the "Transcribe with Verbatim" Service, which Finder shows for audio and video files (right-click ›
/// Quick Actions or Services). The files are imported like the open panel's: each gets a Library entry and joins
/// the queue.
@MainActor
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()
    private var pending: [URL] = []

    /// NSMessage "transcribeFiles" in Info.plist. Services arrive on the main thread.
    @objc func transcribeFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Choose audio or video files to transcribe." as NSString
            return
        }
        Log.note("service: transcribe \(urls.count) file(s)")
        pending += urls
        deliverPending()
    }

    func deliverPending() {
        guard let app = SystemHooks.app, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        NSApp.activate(ignoringOtherApps: true)
        let added = app.importFiles(urls)
        if added.count == 1, let id = added.first?.0 { app.go(.transcript(id)) } else if !added.isEmpty { app.go(.queue) }
    }
}

// MARK: - Spotlight

/// Keeps a CoreSpotlight index of finished transcripts (title, the first words, date, and kind), updated when
/// transcripts are saved or deleted. Settings › Privacy › Show transcripts in Spotlight turns it off and removes the
/// index. Indexing stays on this Mac, so Local Only doesn't affect it.
@MainActor
final class SpotlightIndex {
    static let shared = SpotlightIndex()
    static let enabledKey = "spotlight.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static let domain = "co.stumpandroot.verbatim.transcripts"

    private weak var store: Store?
    private var bag = Set<AnyCancellable>()
    /// What's in the index now, by transcript: a signature of the indexed fields.
    private var indexed: [UUID: Int] = [:]
    private var pendingWork: DispatchWorkItem?

    func attach(_ store: Store) {
        self.store = store
        guard !UITest.enabled, !Bench.isRequested else { return }
        // Store publishes on the main thread.
        store.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }.store(in: &bag)
        schedule(after: 3)
    }

    /// Turns indexing on or off (the Settings switch).
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { indexed = [:]; schedule(after: 0.2) } else { removeAll() }
    }

    private func schedule(after delay: Double = 2) {
        pendingWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sync() } }
        pendingWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func sync() {
        guard Self.enabled, let store, CSSearchableIndex.isIndexingAvailable() else { return }
        var want: [UUID: (Int, Transcript)] = [:]
        for t in store.live where t.status == .ready {
            want[t.id] = (Self.signature(t), t)
        }
        let gone = indexed.keys.filter { want[$0] == nil }
        let changed = want.filter { indexed[$0.key] != $0.value.0 }
        guard !gone.isEmpty || !changed.isEmpty else { return }
        let items = changed.map { Self.item($0.value.1) }
        let index = CSSearchableIndex.default()
        if !items.isEmpty {
            index.indexSearchableItems(items) { e in if let e { Log.note("spotlight: index failed: \(e.localizedDescription)") } }
        }
        if !gone.isEmpty {
            index.deleteSearchableItems(withIdentifiers: gone.map(\.uuidString)) { e in if let e { Log.note("spotlight: delete failed: \(e.localizedDescription)") } }
        }
        for id in gone { indexed[id] = nil }
        for (id, v) in changed { indexed[id] = v.0 }
    }

    private func removeAll() {
        indexed = [:]
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in }
    }

    private static func signature(_ t: Transcript) -> Int {
        var h = Hasher()
        h.combine(t.title); h.combine(t.kind?.rawValue); h.combine(t.tags); h.combine(t.createdAt)
        h.combine(t.document); h.combine(t.segments.count); h.combine(t.segments.first?.text); h.combine(t.segments.last?.text)
        h.combine(t.corrections.count)
        return h.finalize()
    }

    /// The first words, for the result's description.
    static func snippet(_ t: Transcript) -> String {
        let s = (t.document ?? t.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 240 ? String(s.prefix(240)) + "…" : s
    }

    private static func item(_ t: Transcript) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        a.title = t.title
        a.contentDescription = snippet(t)
        // The words themselves, so a search for something said finds the transcript (capped for very long ones).
        let words = t.document ?? t.text
        a.textContent = words.count > 20_000 ? String(words.prefix(20_000)) : words
        a.contentCreationDate = t.createdAt
        a.contentModificationDate = t.createdAt
        a.duration = NSNumber(value: t.duration)
        a.kind = t.isDictation ? "Dictation" : (t.kind?.label ?? "Transcript")
        a.keywords = ["Verbose", "transcript"] + t.tags + [t.kind?.label].compactMap { $0 }
        return CSSearchableItem(uniqueIdentifier: t.id.uuidString, domainIdentifier: domain, attributeSet: a)
    }
}

// MARK: - App delegate: Spotlight results, and Services before the window exists

extension QuitGuard {
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set early, so a Service that launched Verbatim is delivered (and held until the app's state exists).
        NSApp.servicesProvider = ServiceProvider.shared
    }

    /// A Spotlight result: open its transcript.
    @MainActor
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let raw = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let id = UUID(uuidString: raw) else { return false }
        Task { @MainActor in
            _ = await SystemHooks.waitForApp()
            SystemHooks.open(id)
        }
        return true
    }
}
