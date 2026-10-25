import Foundation
import Combine

/// One dictation's numbers, kept apart from the dictation itself so you can delete dictations and keep your
/// totals, or reset the totals and keep your dictations. Stored on this Mac only (never synced).
struct ActivityEvent: Codable, Identifiable, Equatable {
    var id: UUID                    // the dictation's transcript ID
    var date: Date
    var words: Int                  // words pasted
    var seconds: Double             // recording length, pauses included
    var transcribeSeconds: Double?  // nil for dictations made before Verbatim timed them
    var cleanupSeconds: Double?
    var app: String
    var category: AppCategory
    var fillers: Int                // filler words removed ("um", "uh")
    var changed: Int                // words cleanup changed, added, or removed
    var vocabularyFixes: Int        // Dictionary replacements
    var cleanupNote: String? = nil  // why cleanup fell back to the rules (FlowInfo.cleanupNote); nil when it didn't
}

@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()
    @Published private(set) var events: [ActivityEvent] = [] { didSet { generation &+= 1 } }
    /// Bumped on every change to `events`, so `week(now:)` knows when to count again.
    private var generation = 0
    private var weekMemo: (generation: Int, day: Int, week: HomeWeek)?

    /// This week's numbers for Home (This week), worked out once per change and per day instead of on every render.
    func week(now: Date) -> HomeWeek {
        let day = Store.dayKey(now)
        if let m = weekMemo, m.generation == generation, m.day == day { return m.week }
        let w = HomeWeek(events.map { HomeWordEntry(date: $0.date, words: $0.words, seconds: $0.seconds) }, now: now)
        weekMemo = (generation, day, w)
        return w
    }
    /// The screenshot tour writes made-up numbers to its own file, never to your real Activity.
    private let file = Paths.local.appendingPathComponent(ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" ? "activity-uitest.json" : "activity.json")
    private static let seededKey = "activity.seeded"

    private init() {
        if let data = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([ActivityEvent].self, from: data) { events = e }
    }

    func add(_ e: ActivityEvent) {
        events.removeAll { $0.id == e.id }
        events.append(e)
        save()
    }

    /// Adds many events with one save (the screenshot tour's sample data).
    func addAll(_ list: [ActivityEvent]) {
        let ids = Set(list.map(\.id))
        events.removeAll { ids.contains($0.id) }
        events.append(contentsOf: list)
        save()
    }

    /// Clears the numbers. Dictations and transcripts aren't touched.
    func reset() {
        events = []
        UserDefaults.standard.set(true, forKey: Self.seededKey)  // don't refill from history after a reset
        save()
    }

    /// The first time Activity opens, counts the dictations already in your history.
    func seedIfNeeded(from transcripts: [Transcript]) {
        guard !UserDefaults.standard.bool(forKey: Self.seededKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.seededKey)
        let known = Set(events.map(\.id))
        for t in transcripts where t.source == .dictation && t.status == .ready && !known.contains(t.id) {
            guard let info = t.flow, info.instruction == nil, !info.pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            events.append(Self.event(id: t.id, date: t.createdAt, info: info, seconds: t.duration, fixes: t.corrections.count, transcribe: nil, cleanup: nil))
        }
        save()
    }

    static func event(id: UUID, date: Date, info: FlowInfo, seconds: Double, fixes: Int, transcribe: Double?, cleanup: Double?) -> ActivityEvent {
        let raw = Words.list(info.raw), out = Words.list(info.pasted)
        return ActivityEvent(id: id, date: date, words: out.count, seconds: seconds, transcribeSeconds: transcribe, cleanupSeconds: cleanup,
                             app: info.app, category: info.category, fillers: max(0, Words.fillers(raw) - Words.fillers(out)),
                             changed: Words.changed(raw, out), vocabularyFixes: fixes, cleanupNote: info.cleanupNote)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.local, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: file, options: .atomic) }
    }
}

/// Word counting shared by Activity's numbers and its word stats.
enum Words {
    static func list(_ s: String) -> [String] {
        s.replacingOccurrences(of: "’", with: "'").lowercased().components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }

    static let fillerWords: Set<String> = ["um", "uh", "umm", "uhh", "er", "erm", "ah", "hmm", "mm"]
    static func fillers(_ words: [String]) -> Int { words.filter { fillerWords.contains($0) }.count }

    /// Words in one list and not the other, counted with repeats: a rough measure of how much cleanup changed.
    static func changed(_ a: [String], _ b: [String]) -> Int {
        var counts: [String: Int] = [:]
        for w in a { counts[w, default: 0] += 1 }
        for w in b { counts[w, default: 0] -= 1 }
        return counts.values.reduce(0) { $0 + abs($1) }
    }
}

/// The numbers Activity shows for a period.
struct ActivityStats {
    var words = 0
    var seconds = 0.0
    var dictations = 0
    var fillers = 0
    var changed = 0
    var vocabularyFixes = 0
    var processing: [Double] = []   // transcription + cleanup, per dictation
    var byApp: [String: Int] = [:]
    var byDay: [Date: Int] = [:]    // start of day → words

    init(_ events: [ActivityEvent], since: Date?) {
        let cal = Calendar.current
        for e in events where since.map({ e.date >= $0 }) ?? true {
            words += e.words; seconds += e.seconds; dictations += 1
            fillers += e.fillers; changed += e.changed; vocabularyFixes += e.vocabularyFixes
            if let t = e.transcribeSeconds { processing.append(t + (e.cleanupSeconds ?? 0)) }
            byApp[e.app, default: 0] += e.words
            byDay[cal.startOfDay(for: e.date), default: 0] += e.words
        }
    }

    /// Words per minute of recording, pauses included.
    var pace: Int? { seconds >= 20 ? Int((Double(words) / (seconds / 60)).rounded()) : nil }

    /// Typing the same words at `wpm`, minus the time spent talking and waiting. Editing time isn't counted.
    func secondsSaved(typingWPM wpm: Int) -> Double {
        max(0, Double(words) / Double(max(wpm, 1)) * 60 - seconds - processing.reduce(0, +))
    }
}
