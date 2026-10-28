import Foundation

// Plan my day outside a recording (approved mockup "Verbose Brain Dump", sections 6, 8, and 9, October 27, 2026):
// Organize today's thoughts runs it over a day's thoughts as one text with each thought's time as its anchor, and the
// Mac's brain dump window runs it over its note, a line for each paragraph. The plan is kept with the day
// (`DayPlanRecord`, `plans.json`); each task links back to the thought or paragraph it came from. It never runs on its
// own: new thoughts after a plan show "2 new thoughts since 3:20 PM" and the plan offers Run again, so a plan you sent
// never changes under you. Without Apple Intelligence it fails the way every template does (`TemplateCenter`).

@MainActor
final class DayPlanCenter: ObservableObject {
    static let shared = DayPlanCenter()

    /// Plans being made, by record ID.
    @Published private(set) var running: Set<UUID> = []
    /// Why the last plan you asked for didn't finish, by record ID.
    @Published private(set) var failures: [UUID: String] = [:]
    /// The self-tests' canned result: used instead of Apple Intelligence (never call the model in tests).
    var canned: ((_ lines: [String]) -> String)? = nil

    func isRunning(_ day: Date, _ source: DayPlanRecord.Source) -> Bool {
        running.contains(DayPlanRecord.id(day: DayPlanRecord.dayKey(day), source: source))
    }
    func failure(_ day: Date, _ source: DayPlanRecord.Source) -> String? {
        failures[DayPlanRecord.id(day: DayPlanRecord.dayKey(day), source: source)]
    }

    /// The thoughts on a day's page with words, in time order, as the lines Plan my day reads.
    static func lines(_ thoughts: [Transcript]) -> [(id: UUID, text: String)] {
        thoughts.compactMap { t in
            let w = ThoughtText.words(t).trimmingCharacters(in: .whitespacesAndNewlines)
            return w.isEmpty ? nil : (t.id, w)
        }
    }

    /// Organize today's thoughts: Plan my day over the day's thoughts, kept with the day. Run again replaces the plan
    /// and keeps what was sent to Reminders (tasks match by their words and their thought).
    func organize(day: Date, thoughts: [Transcript], store: Store) {
        let pairs = Self.lines(thoughts)
        let key = DayPlanRecord.dayKey(day)
        let rid = DayPlanRecord.id(day: key, source: .thoughts)
        guard !pairs.isEmpty else { failures[rid] = "There are no thoughts with words on this page yet."; return }
        run(rid, lines: pairs.map(\.text), title: DayPages.title("Thoughts", day: day), createdAt: day, store: store, day: day, source: .thoughts) { r, text in
            r.text = text
            r.thoughtIDs = pairs.map(\.id)
        }
    }

    /// Plan my day on the Mac's today's note (Views/DayNote.swift): over the note's paragraphs.
    func planNote(day: Date, note: String, store: Store) {
        let paragraphs = DayPlan.paragraphs(note)
        let rid = DayPlanRecord.id(day: DayPlanRecord.dayKey(day), source: .note)
        guard !paragraphs.isEmpty else { failures[rid] = "Say or type what's on your mind first."; return }
        run(rid, lines: paragraphs, title: "Brain dump", createdAt: day, store: store, day: day, source: .note) { r, text in
            r.text = text
            r.paragraphs = paragraphs
        }
    }

    private func run(_ rid: UUID, lines: [String], title: String, createdAt: Date, store: Store, day: Date, source: DayPlanRecord.Source,
                     apply: @escaping (inout DayPlanRecord, String) -> Void) {
        guard !running.contains(rid) else { return }
        failures[rid] = nil
        if let canned {
            let text = canned(lines)
            store.updateDayPlan(day, source: source) { r in apply(&r, text); r.madeAt = Date(); r.madeOn = TemplateCenter.here }
            return
        }
        if let why = TemplateCenter.unavailableReason { failures[rid] = why; return }
        guard let tpl = TemplateLibrary.template(TemplateLibrary.planMyDayID, yours: store.templates) else { return }
        let instruction = TemplatePrompt.instruction(tpl)
        let input = DayPlan.input(lines, title: title, createdAt: createdAt)
        running.insert(rid)
        Task { @MainActor in
            defer { self.running.remove(rid) }
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    try await TranscriptActions.run(instruction: instruction, extracts: true, timestamps: true, on: input)
                }.value
                store.updateDayPlan(day, source: source) { r in apply(&r, out.text); r.madeAt = Date(); r.madeOn = TemplateCenter.here }
                Log.note("plans: made a plan from \(lines.count) line(s) (\(source.rawValue))")
            } catch is CancellationError {
            } catch {
                self.failures[rid] = (error as? LocalizedError)?.errorDescription ?? "Apple\u{2019}s on-device model didn\u{2019}t answer. Try again."
            }
        }
    }

    /// The Mac's note changed: kept with the day as you type or dictate (the plan stays as it was made).
    func saveNote(day: Date, note: String, store: Store) {
        guard store.dayPlan(day, source: .note)?.note != note else { return }
        store.updateDayPlan(day, source: .note) { $0.note = note }
    }

    /// Send to Reminders finished on a day's plan: the reminders it added are kept with it.
    func recordSent(_ added: [String: String], day: Date, source: DayPlanRecord.Source, store: Store) {
        guard !added.isEmpty else { return }
        store.updateDayPlan(day, source: source) { r in r.sent.merge(added) { _, new in new } }
    }
}
