import Foundation

/// One of the actions that turn a whole transcript into something new: a plan, a journal entry, a draft, study
/// notes, key points. Shared by the Mac (where they sit alongside the saved actions in Settings › Actions and stay
/// editable) and the iPhone (built-in list).
struct TranscriptActionSpec: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var instruction: String
    var symbol: String
    /// True when the result pulls things together (long text is done in parts, then merged); false when it
    /// rewrites the words in order (parts are joined).
    var extracts: Bool
    /// True when the model sees each line's [mm:ss] time, for quotes with timestamps.
    var timestamps: Bool = false
}

/// The transcript actions: their specs and the rule every prompt carries. Two are built in (Write a draft and Study
/// notes); the consolidation (October 28, 2026) retired three, whose specs stay in `retired` so their results, notes,
/// and saved copies still read: Make a plan merged into Plan my day, Journal entry into Daily reflection, and Key
/// points was cut (the automatic summary lists key points). Pure Foundation, so the templates
/// built on them (Templates.swift) are checked on Linux; how they run is in Transcription/TranscriptActions.swift.
///
/// How they run:
///
/// Every action runs on the Original text with your corrections (the segments), never on the Cleaned text, so the
/// result comes from what was said. Each instruction ends with `noAddRule`, and the session's own instructions
/// repeat it. When Apple's model declines a part (its guardrails trip on everyday talk about weapons, health,
/// crime, and the like), the part is tried once more with the relaxed guardrails Apple provides for transforming
/// the person's own text (`OnDeviceText`), the same fallback the Summarizer uses.
enum TranscriptActions {
    static let noAddRule = "Use only what the transcript says. Never add facts, names, numbers, or advice."

    /// The heading on every result and on notes saved from one.
    static let madeByLabel = "Made by Apple Intelligence from this transcript"

    /// Too little to work on below this many words.
    static let minWords = 12

    /// Write a draft and Study notes.
    static let builtIn: [TranscriptActionSpec] = all.filter { !retiredIDs.contains($0.id) }

    /// Make a plan, Journal entry, and Key points, retired in the consolidation. Never offered; kept so the templates
    /// that replace them can be found (`TemplateLibrary.current`) and saved copies compared with what they were.
    static let retired: [TranscriptActionSpec] = all.filter { retiredIDs.contains($0.id) }
    static let makeAPlanID = UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000001")!
    static let journalEntryID = UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000002")!
    static let keyPointsID = UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000005")!
    static let retiredIDs: Set<UUID> = [makeAPlanID, journalEntryID, keyPointsID]

    /// The five as they shipped before the consolidation, in their old order.
    private static let all: [TranscriptActionSpec] = [
        TranscriptActionSpec(
            id: UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000001")!,
            name: "Make a plan",
            instruction: "Turn this into an organized plan. Group the tasks under short headings when they cover more than one area, and write each task as a checklist line that starts with \"- [ ] \". Add an owner or a date to a task only when the transcript states it. Keep the order the speaker gave. If the transcript has no tasks, say so in one line. " + noAddRule,
            symbol: "list.bullet.clipboard", extracts: true),
        TranscriptActionSpec(
            id: UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000002")!,
            name: "Journal entry",
            instruction: "Rewrite this as a journal entry in readable paragraphs, in the first person and in the speaker's own voice. Keep the same substance and order. Remove filler words, repeats, and false starts. Don't add reflections, feelings, lessons, or conclusions the speaker didn't say. " + noAddRule,
            symbol: "book.closed", extracts: false),
        TranscriptActionSpec(
            id: UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000003")!,
            name: "Write a draft",
            instruction: "Turn these thoughts into a draft email or message, whichever the transcript asks for (a message when it's unclear). Use short paragraphs. Keep every fact, name, number, and date exactly as said. Never invent details, recipients, dates, or commitments. Add a greeting or a sign-off only if the speaker said one. " + noAddRule,
            symbol: "square.and.pencil", extracts: true),
        TranscriptActionSpec(
            id: UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000004")!,
            name: "Study notes",
            instruction: "Write study notes: a short heading for each topic, in the order the topics come up, with bullet points under each. Put key terms in bold, and define a term only when the transcript defines it. Take every note from the transcript. " + noAddRule,
            symbol: "graduationcap", extracts: true),
        TranscriptActionSpec(
            id: UUID(uuidString: "5E7B0A01-F1A0-4C00-9000-000000000005")!,
            name: "Key points",
            instruction: "Write three sections. Key ideas: the main ideas as bullet points. Notable quotes: a few lines quoted word for word in quotation marks, each followed by the [mm:ss] time of its line when the transcript shows one. Action items: checklist lines that start with \"- [ ] \", or \"None stated\". Never change the words inside quotation marks. " + noAddRule,
            symbol: "text.quote", extracts: true, timestamps: true),
    ]

    static let builtInIDs: Set<UUID> = Set(builtIn.map(\.id))
    static func isBuiltIn(_ id: UUID) -> Bool { builtInIDs.contains(id) }
    static func spec(_ id: UUID) -> TranscriptActionSpec? { builtIn.first { $0.id == id } }
    /// A built-in or retired action's spec, as it shipped.
    static func anySpec(_ id: UUID) -> TranscriptActionSpec? { all.first { $0.id == id } }

    /// The instruction with the no-add rule, even after someone edits it out.
    static func withRule(_ instruction: String) -> String {
        let i = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return i.contains(noAddRule) ? i : (i.isEmpty ? noAddRule : i + " " + noAddRule)
    }
}
