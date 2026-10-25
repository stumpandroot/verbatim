import Foundation
import Combine
import WidgetKit

/// Keeps the widgets' snapshot (VerbatimWidgets/WidgetSnapshot.swift) current, on the Mac and iPhone: the five newest
/// recordings and dictations (short titles, dates, lengths, and labels only), how many you've kept, this week's
/// dictated words per day, and the look. Written to the App Group container when the library, the Mac's Activity, or
/// the look changes, and only when the snapshot differs from the file; then the widgets reload. The screenshot tour
/// and the bench never write it, so made-up recordings never reach your widgets.
@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()
    private var bag = Set<AnyCancellable>()
    private var look = AppLook.current
    /// Counting this week's words reads dictations' text, so the snapshot is built off the main thread.
    private static let queue = DispatchQueue(label: "co.stumpandroot.verbatim.widget-feed", qos: .utility)

    func attach(_ store: Store) {
        #if os(macOS)
        guard !UITest.enabled, !Bench.isRequested else { return }
        #else
        guard !PhoneUITest.enabled else { return }
        #endif
        guard bag.isEmpty else { return }
        var changes = store.transcriptsPublisher.map { _ in () }.eraseToAnyPublisher()
        #if os(macOS)
        // This week on the Mac counts Activity's events, which outlive deleted dictations (Flow/Activity.swift).
        changes = changes.merge(with: ActivityLog.shared.$events.map { _ in () }).eraseToAnyPublisher()
        #endif
        // Settings › Appearance or General › Look: the widgets switch with the app.
        let lookChanges = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .filter { [weak self] _ in self.map { $0.look != AppLook.current } ?? false }
            .map { _ in () }
        changes.merge(with: lookChanges)
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self, weak store] in
                guard let self, let store else { return }
                self.publish(store)
            }
            .store(in: &bag)
    }

    private func publish(_ store: Store) {
        look = AppLook.current
        let lookRaw = look.rawValue
        let all = store.transcripts
        #if os(macOS)
        let events = ActivityLog.shared.events.map { (date: $0.date, words: $0.words) }
        #endif
        Self.queue.async {
            let live = all.filter { $0.deletedAt == nil }
            let recent = live.sorted { $0.createdAt > $1.createdAt }.prefix(WidgetSnapshot.maxRecent).map(Self.item)
            #if os(macOS)
            let entries = events
            #else
            let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
            let entries = HomeCounts.entries(fromDictations: live.filter { $0.createdAt >= weekStart }).map { (date: $0.date, words: $0.words) }
            #endif
            let snapshot = WidgetSnapshot.make(items: Array(recent), kept: live.count, entries: entries, look: lookRaw)
            guard let data = snapshot.encoded(), WidgetSnapshotStore.write(data) else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// A row for Recent recordings: the transcript's title (cut short by the snapshot), when, how long, and what it is.
    nonisolated static func item(_ t: Transcript) -> WidgetSnapshot.Item {
        let source: WidgetSnapshot.Item.Source
        if t.isDictation {
            source = .dictation
        } else if LibrarySource.isLink(t) {
            source = .link
        } else {
            switch t.source {
            case .app: source = .app
            case .file: source = .file
            default: source = .voice
            }
        }
        let fallback: String
        switch source {
        case .voice: fallback = "Voice note"
        case .link: fallback = "Link"
        case .file: fallback = "File"
        case .app: fallback = "App audio"
        case .dictation: fallback = "Dictation"
        }
        let label = t.isDictation ? "Dictation" : (t.kind?.label ?? fallback)
        return WidgetSnapshot.Item(id: t.id, title: t.title, date: t.createdAt, duration: t.duration, source: source, label: label)
    }
}
