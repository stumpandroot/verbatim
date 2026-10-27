import Foundation

// Recipes (mockup "Library features", section 2c): questions you ask again, each with its scope. A recipe syncs with the
// library as `recipes.json` (the Store's synced lists, like templates); its weekly schedule and when it last ran stay
// on each device, so the weekly digest can run on the Mac only. Every run's answer is kept on this device as a digest,
// with its citations, in Ask › Recipes. Pure, so the scheduling rules are checked on Linux (mac/tools/test-ask.sh).

struct AskRecipe: Codable, Equatable, Identifiable, Hashable, SyncEntry {
    var id = UUID()
    var question: String
    var scope: AskScope
    var createdAt = Date()
    var updatedAt: Date? = nil

    init(id: UUID = UUID(), question: String, scope: AskScope, createdAt: Date = Date()) {
        self.id = id; self.question = question; self.scope = scope; self.createdAt = createdAt
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case id, question, scope, createdAt, updatedAt }
        let c = try d.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? "Untitled question"
        scope = (try? c.decodeIfPresent(AskScope.self, forKey: .scope)) ?? .all
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil
    }

    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A weekly time: a weekday (Calendar's numbering, 1 is Sunday), an hour, and a minute. `since` is when it was set, so a
/// time already past that day doesn't run at once.
struct RecipeSchedule: Codable, Equatable {
    var weekday: Int
    var hour: Int
    var minute: Int
    var since: Date

    init(weekday: Int, hour: Int, minute: Int, since: Date = Date()) {
        self.weekday = min(7, max(1, weekday)); self.hour = min(23, max(0, hour)); self.minute = min(59, max(0, minute)); self.since = since
    }

    private static let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static func dayName(_ weekday: Int) -> String { names[min(6, max(0, weekday - 1))] }

    /// "4:00 PM".
    var time: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", h12, minute, hour < 12 ? "AM" : "PM")
    }
    /// "Every Friday at 4:00 PM".
    var label: String { "Every \(Self.dayName(weekday)) at \(time)" }
    /// "Fridays, 4:00 PM" (Premium Native).
    var shortLabel: String { "\(Self.dayName(weekday))s, \(time)" }
}

enum RecipeScheduling {
    /// The latest scheduled time at or before `now`.
    static func last(onOrBefore now: Date, _ s: RecipeSchedule, calendar: Calendar = .current) -> Date? {
        let back = (calendar.component(.weekday, from: now) - s.weekday + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)),
              let t = calendar.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day) else { return nil }
        if t <= now { return t }
        guard let earlier = calendar.date(byAdding: .day, value: -7, to: day) else { return nil }
        return calendar.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: earlier)
    }

    /// The next scheduled time after `now`.
    static func next(after now: Date, _ s: RecipeSchedule, calendar: Calendar = .current) -> Date? {
        guard let t = last(onOrBefore: now, s, calendar: calendar),
              let day = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: t)) else { return nil }
        return calendar.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day)
    }

    /// The scheduled time a run is owed for, or nil: the latest one that has passed since the schedule was set and
    /// since the recipe last ran on this device. Missed several weeks, it's owed once (for the latest), not once a week.
    static func due(_ s: RecipeSchedule, lastRun: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        guard let t = last(onOrBefore: now, s, calendar: calendar) else { return nil }
        let after = max(lastRun ?? .distantPast, s.since)
        return t > after ? t : nil
    }
}

/// This device's schedules and last runs, by recipe (UserDefaults, never synced).
struct RecipeDeviceState: Codable, Equatable {
    var schedules: [UUID: RecipeSchedule] = [:]
    var lastRun: [UUID: Date] = [:]

    static let key = "ask.recipeSchedules"

    static func load(_ d: UserDefaults = .standard) -> RecipeDeviceState {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(RecipeDeviceState.self, from: data) else { return RecipeDeviceState() }
        return s
    }
    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    /// Recipes owed a run now, oldest owed first, with the time each is owed for.
    func due(_ recipes: [AskRecipe], now: Date, calendar: Calendar = .current) -> [(AskRecipe, Date)] {
        recipes.compactMap { r in
            guard let s = schedules[r.id], let t = RecipeScheduling.due(s, lastRun: lastRun[r.id], now: now, calendar: calendar) else { return nil }
            return (r, t)
        }
        .sorted { $0.1 < $1.1 }
    }

    /// The soonest next run among the recipes that have a schedule (for iOS's background refresh).
    func nextRun(_ recipes: [AskRecipe], after now: Date, calendar: Calendar = .current) -> Date? {
        recipes.compactMap { r in schedules[r.id].flatMap { RecipeScheduling.next(after: now, $0, calendar: calendar) } }.min()
    }

    /// Schedules of recipes that no longer exist are dropped.
    func pruned(_ recipes: [AskRecipe]) -> RecipeDeviceState {
        let ids = Set(recipes.map(\.id))
        return RecipeDeviceState(schedules: schedules.filter { ids.contains($0.key) }, lastRun: lastRun.filter { ids.contains($0.key) })
    }
}

/// One run of a recipe, kept on this device: the answer and its citations.
struct AskDigest: Codable, Equatable, Identifiable {
    var id = UUID()
    var recipeId: UUID
    var ranAt: Date
    /// Ran on its schedule (not Run now).
    var scheduled: Bool
    var result: AskResult

    static let maxKept = 60

    /// Newest first, at most `maxKept`, and at most 8 per recipe.
    static func trimmed(_ list: [AskDigest]) -> [AskDigest] {
        var per: [UUID: Int] = [:]
        return list.sorted { $0.ranAt > $1.ranAt }.filter { d in
            per[d.recipeId, default: 0] += 1
            return per[d.recipeId]! <= 8
        }.prefix(maxKept).map { $0 }
    }
}

/// The three examples the empty state offers (seeded only when you tap one).
enum RecipeSuggestions {
    struct Suggestion: Equatable {
        var question: String
        var scope: AskScope
        var schedule: (weekday: Int, hour: Int, minute: Int)?
        static func == (a: Suggestion, b: Suggestion) -> Bool { a.question == b.question && a.scope == b.scope }
    }

    /// Weekly digest of my thoughts (Fridays at 4 PM), Action items from this week's meetings (Mondays at 8:30 AM), and
    /// What did I say about <your first project> (any time; This week's decisions when there's no project).
    static func all(projects: [(UUID, String)]) -> [Suggestion] {
        var out = [Suggestion(question: "Weekly digest of my thoughts", scope: AskScope(range: .thisWeek, source: .thoughts), schedule: (6, 16, 0)),
                   Suggestion(question: "Action items from this week\u{2019}s meetings", scope: AskScope(range: .thisWeek, source: .meetings), schedule: (2, 8, 30))]
        if let p = projects.first {
            out.append(Suggestion(question: "What did I say about \(p.1)", scope: AskScope(range: .allTime, source: .project(p.0)), schedule: nil))
        } else {
            out.append(Suggestion(question: "What did I decide this week", scope: AskScope(range: .thisWeek, source: .all), schedule: nil))
        }
        return out
    }
}
