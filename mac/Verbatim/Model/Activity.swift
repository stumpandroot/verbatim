import Foundation

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
}

@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()
    @Published private(set) var events: [ActivityEvent] = []
    private let file = Paths.local.appendingPathComponent("activity.json")
    private static let seededKey = "activity.seeded"

    private init() {
        if let data = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([ActivityEvent].self, from: data) { events = e }
    }

    func add(_ e: ActivityEvent) {
        events.removeAll { $0.id == e.id }
        events.append(e)
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
            guard let info = t.flow, info.instruction == nil else { continue }
            events.append(Self.event(id: t.id, date: t.createdAt, info: info, seconds: t.duration, fixes: t.corrections.count, transcribe: nil, cleanup: nil))
        }
        save()
    }

    static func event(id: UUID, date: Date, info: FlowInfo, seconds: Double, fixes: Int, transcribe: Double?, cleanup: Double?) -> ActivityEvent {
        let raw = Words.list(info.raw), out = Words.list(info.pasted)
        return ActivityEvent(id: id, date: date, words: out.count, seconds: seconds, transcribeSeconds: transcribe, cleanupSeconds: cleanup,
                             app: info.app, category: info.category, fillers: max(0, Words.fillers(raw) - Words.fillers(out)),
                             changed: Words.changed(raw, out), vocabularyFixes: fixes)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.local, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: file, options: .atomic) }
    }
}

/// Word counting shared by Activity's numbers and its word stats.
enum Words {
    static func list(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'’")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }.filter { !$0.isEmpty }
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

    /// Common words that say nothing about you, left out of "most-used word".
    static let stop: Set<String> = Set("""
    a about above after again all also am an and any are as at be because been before being both but by can could did do does doing \
    don't down during each few for from further get got had has have having he her here hers him his how i i'm i've i'll i'd if in into is \
    isn't it it's its just like me more most my no nor not now of off on once only or other our ours out over own really same she should \
    so some such than that that's the their theirs them then there there's these they they're this those through to too under until up \
    very was we we're were what when where which while who whom why will with would you you're your yours yeah okay ok gonna wanna um uh \
    going go know think want need let let's one two thing things kind sort maybe actually right well also still even much many way make
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
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
    var byCategory: [AppCategory: Int] = [:]
    var byApp: [String: Int] = [:]
    var byDay: [Date: Int] = [:]    // start of day → words
    var byHour: [Int: Int] = [:]    // weekday*100 + hour → words

    init(_ events: [ActivityEvent], since: Date?) {
        let cal = Calendar.current
        for e in events where since.map({ e.date >= $0 }) ?? true {
            words += e.words; seconds += e.seconds; dictations += 1
            fillers += e.fillers; changed += e.changed; vocabularyFixes += e.vocabularyFixes
            if let t = e.transcribeSeconds { processing.append(t + (e.cleanupSeconds ?? 0)) }
            byCategory[e.category, default: 0] += e.words
            byApp[e.app, default: 0] += e.words
            byDay[cal.startOfDay(for: e.date), default: 0] += e.words
            byHour[cal.component(.weekday, from: e.date) * 100 + cal.component(.hour, from: e.date), default: 0] += e.words
        }
    }

    /// Words per minute of recording, pauses included.
    var pace: Int? { seconds >= 20 ? Int((Double(words) / (seconds / 60)).rounded()) : nil }

    /// Typing the same words at `wpm`, minus the time spent talking and waiting. Editing time isn't counted.
    func secondsSaved(typingWPM wpm: Int) -> Double {
        max(0, Double(words) / Double(max(wpm, 1)) * 60 - seconds - processing.reduce(0, +))
    }

    var medianProcessing: Double? { percentile(0.5) }
    var slowProcessing: Double? { processing.count >= 10 ? percentile(0.9) : nil }
    private func percentile(_ p: Double) -> Double? {
        guard !processing.isEmpty else { return nil }
        let s = processing.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
    }

    /// "Wednesdays around noon": the weekday and hour with the most words.
    var peak: (weekday: Int, hour: Int)? {
        guard let best = byHour.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return (best.key / 100, best.key % 100)
    }
}

/// Word stats from the dictations you still have (Activity's numbers don't keep your words).
struct WordStats {
    var mostUsed: (String, Int)?
    var catchphrase: (String, Int)?
    var mostFixed: (String, Int)?

    init(_ transcripts: [Transcript], since: Date?) {
        var counts: [String: Int] = [:], phrases: [String: Int] = [:], fixed: [String: Int] = [:]
        for t in transcripts where t.source == .dictation && (since.map { t.createdAt >= $0 } ?? true) {
            guard let info = t.flow, info.instruction == nil else { continue }
            let w = Words.list(info.pasted)
            for x in w where x.count > 2 && !Words.stop.contains(x) && Int(x) == nil { counts[x, default: 0] += 1 }
            if w.count >= 3 {
                var seen = Set<String>()   // one count per dictation, so a repeated stutter isn't a catchphrase
                for i in 0...(w.count - 3) {
                    let p = w[i..<(i + 3)]
                    guard p.filter({ !Words.stop.contains($0) }).count >= 1, !p.contains(where: { Words.fillerWords.contains($0) }) else { continue }
                    seen.insert(p.joined(separator: " "))
                }
                for p in seen { phrases[p, default: 0] += 1 }
            }
            for c in t.corrections where c.byDictionary { fixed[c.to, default: 0] += 1 }
        }
        mostUsed = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }.map { ($0.key, $0.value) }
        catchphrase = phrases.filter { $0.value >= 3 }.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }.map { ($0.key, $0.value) }
        mostFixed = fixed.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }.map { ($0.key, $0.value) }
    }
}
