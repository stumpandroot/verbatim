import Foundation
import Combine

/// How dictation starts and stops.
enum FlowMode: String, CaseIterable, Identifiable {
    case hybrid, hold, toggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hybrid: return "Tap or hold"
        case .hold: return "Hold to talk"
        case .toggle: return "Tap to start and stop"
        }
    }
    var note: String {
        switch self {
        case .hybrid: return "Hold the key to talk and let go to paste. Tap it once to keep listening hands-free, and tap again to paste."
        case .hold: return "Hold the key while you talk. Let go to paste."
        case .toggle: return "Tap the key to start listening. Tap it again to paste."
        }
    }
}

/// How much the words are edited before they're pasted: Literal, Clean, or Polished.
///
/// The raw values are the ones saved before the levels were renamed (none = Literal, light = Clean,
/// medium = Polished), so existing settings, History entries (`FlowInfo.level`), and documents keep their level
/// with no migration. Use `literal`, `clean`, and `polished` in new code.
enum CleanupLevel: String, CaseIterable, Identifiable {
    case none, light, medium

    static var literal: CleanupLevel { .none }
    static var clean: CleanupLevel { .light }
    static var polished: CleanupLevel { .medium }

    /// Reads a saved level: the stored raw values, or the new names ("literal", "clean", "polished").
    init?(stored: String) {
        switch stored.lowercased() {
        case "none", "literal": self = .none
        case "light", "clean": self = .light
        case "medium", "polished": self = .medium
        default: return nil
        }
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Literal"
        case .light: return "Clean"
        case .medium: return "Polished"
        }
    }
    var note: String {
        switch self {
        case .none: return "Pastes your words as spoken, with punctuation and capitals. Never rewords or reformats them, and works on every Mac."
        case .light: return "Removes ums, repeats, and false starts, keeps the final version of a self-correction, and writes numbers as digits. Turns spoken lists into lists and adds paragraph breaks. Keeps your wording."
        case .medium: return "Formats and tightens: everything Clean does, plus fixes grammar and smooths rambling sentences for the app you're in. Keeps your meaning, facts, order, and voice."
        }
    }
    /// A few words for menus.
    var shortNote: String {
        switch self {
        case .none: return "As spoken"
        case .light: return "Fillers, lists, paragraphs"
        case .medium: return "Formatted and tightened"
        }
    }
    /// Clean and Polished use Apple's on-device model; Literal never does. Without the model, Clean and Polished
    /// still remove repeats and format lists and paragraphs by rules (`DictationFormatter`).
    var usesModel: Bool { self != .none }

    /// The display name for a saved level string, such as `FlowInfo.level` ("light" → "Clean").
    static func title(stored: String) -> String {
        CleanupLevel(stored: stored)?.title ?? stored.capitalized
    }
}

/// A spoken shortcut: say the trigger, get the saved text.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

/// A saved action: a named instruction that rewrites text or pulls something out of it.
/// Runs on selected text in any app (from the floating button's menu, or by saying its name in edit-by-voice),
/// on a dictation, or on a whole transcript.
struct FlowAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Changes the text itself (tighten, translate, reformat). Long text is done in parts and joined.
        case rewrite
        /// Pulls something out (decisions, a brief). Long text is done in parts, then the parts are merged.
        case extract
        var id: String { rawValue }
        var title: String { self == .rewrite ? "Rewrites the text" : "Pulls out a summary" }
    }
    var id = UUID()
    var name: String
    var instruction: String
    var symbol: String = "wand.and.stars"
    var kind: Kind = .rewrite

    static let builtIn: [FlowAction] = [
        FlowAction(name: "Clean up, keep my wording", instruction: "Fix grammar, punctuation, and capitalization, and remove filler words, stutters, and false starts. Keep the author's wording, voice, and sentence order.", symbol: "sparkles"),
        FlowAction(name: "Client email", instruction: "Turn this into a clear, warm, professional email to a client. Use short paragraphs. Keep every fact, name, number, and date. Add a greeting and a sign-off only if the recipient is clear from the text.", symbol: "envelope"),
        FlowAction(name: "Decisions and next steps", instruction: "List the decisions that were made, then the next steps as a checklist. Include the owner and due date of a step only when the text states them; never invent them. If the text has no decisions or next steps, say so in one line.", symbol: "checklist", kind: .extract),
        FlowAction(name: "Project brief", instruction: "Write a concise project brief with these headings: Goal, Audience, Deliverables, Timeline, Open questions. Use only what the text says, and write \"Not stated\" under a heading the text doesn't cover.", symbol: "doc.text", kind: .extract),
        FlowAction(name: "Bullet points", instruction: "Turn this into concise bullet points. Keep every point and the order of ideas.", symbol: "list.bullet"),
        FlowAction(name: "Tighten", instruction: "Make this shorter and clearer. Keep every point, fact, name, and number.", symbol: "arrow.down.right.and.arrow.up.left"),
        FlowAction(name: "Translate to Spanish", instruction: "Translate this into Spanish. Keep names, brands, and product names exactly as written.", symbol: "globe"),
        FlowAction(name: "Screenplay dialogue", instruction: "Format this as screenplay dialogue: each CHARACTER NAME in capitals on its own line, followed by the line of dialogue. Put actions in brief present-tense lines of their own. Keep the spoken words.", symbol: "film"),
    ] + transcriptBuiltIn

    /// The five transcript actions (TranscriptActions), with their fixed IDs, after the eight above.
    static let transcriptBuiltIn: [FlowAction] = TranscriptActions.builtIn.map {
        FlowAction(id: $0.id, name: $0.name, instruction: $0.instruction, symbol: $0.symbol, kind: $0.extracts ? .extract : .rewrite)
    }

    /// Lowercased letters and digits only, for matching a spoken name ("client email.") to an action.
    static func norm(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Where the floating button sits.
enum BarEdge: String, Codable { case bottom, left, right }

/// Every setting for Verbatim Flow (system-wide dictation), saved in UserDefaults.
@MainActor
final class FlowSettings: ObservableObject {
    static let shared = FlowSettings()
    /// Push-to-talk and hands-free dictation stop (and paste) after this many minutes; 0 means no limit.
    /// In-app recording isn't limited. UserDefaults key `flow.maxDictationMinutes`, default 10 (no picker yet).
    static let maxDictationMinutesKey = "flow.maxDictationMinutes"
    static var maxDictationMinutes: Double {
        let v = UserDefaults.standard.object(forKey: maxDictationMinutesKey) as? Double ?? 10
        return max(0, v)
    }
    private let d = UserDefaults.standard

    @Published var showBar: Bool { didSet { d.set(showBar, forKey: "flow.showBar") } }
    @Published var mode: FlowMode { didSet { d.set(mode.rawValue, forKey: "flow.mode") } }
    @Published var cleanup: CleanupLevel { didSet { d.set(cleanup.rawValue, forKey: "flow.cleanup") } }
    @Published var styles: [AppCategory: FlowStyle] { didSet { save(styles, "flow.styles") } }
    @Published var useContext: Bool { didSet { d.set(useContext, forKey: "flow.context") } }
    @Published var autoLearn: Bool { didSet { d.set(autoLearn, forKey: "flow.autoLearn") } }
    @Published var boostVocabulary: Bool { didSet { d.set(boostVocabulary, forKey: "flow.boost") } }
    /// Days to keep dictations; 0 keeps them forever.
    @Published var keepDays: Int { didSet { d.set(keepDays, forKey: "flow.keepDays") } }
    @Published var snippets: [Snippet] { didSet { save(snippets, "flow.snippets") } }
    /// Hidden from the screen until this time ("Hide for 1 hour").
    @Published var hiddenUntil: Date? { didSet { d.set(hiddenUntil, forKey: "flow.hiddenUntil") } }
    /// Position per display: edge plus where along it (0…1).
    @Published var positions: [String: BarPosition] { didSet { save(positions, "flow.positions") } }

    /// Saved actions, in menu order.
    @Published var actions: [FlowAction] { didSet { save(actions, "flow.actions") } }
    /// Your typing speed, for Activity's time-saved estimate.
    @Published var typingWPM: Int { didSet { d.set(typingWPM, forKey: "flow.typingWPM") } }
    /// The project dictations go into: its Dictionary words apply, and each dictation is filed there. nil = none.
    @Published var activeProject: UUID? { didSet { d.set(activeProject?.uuidString, forKey: "flow.activeProject") } }
    /// Word fixes you said "Not now" to ("heard→fixed"), so Verbatim doesn't ask about them again.
    @Published var declinedFixes: [String] { didSet { d.set(declinedFixes, forKey: "flow.declinedFixes") } }

    struct BarPosition: Codable, Equatable { var edge: BarEdge; var along: Double }

    private init() {
        showBar = d.object(forKey: "flow.showBar") as? Bool ?? true
        mode = FlowMode(rawValue: d.string(forKey: "flow.mode") ?? "") ?? .hybrid
        // Polished ("format and tighten") is the default. The level is saved only when you pick one, so anyone who
        // never picked gets the new default, and a level you picked stays.
        cleanup = CleanupLevel(stored: d.string(forKey: "flow.cleanup") ?? "") ?? .polished
        useContext = d.object(forKey: "flow.context") as? Bool ?? true
        autoLearn = d.object(forKey: "flow.autoLearn") as? Bool ?? true
        boostVocabulary = d.object(forKey: "flow.boost") as? Bool ?? true
        keepDays = d.object(forKey: "flow.keepDays") as? Int ?? 0
        hiddenUntil = d.object(forKey: "flow.hiddenUntil") as? Date
        styles = Self.load([AppCategory: FlowStyle].self, "flow.styles") ?? [.email: .formal, .work: .casual, .personal: .casual, .code: .verbatim, .other: .casual]
        snippets = Self.load([Snippet].self, "flow.snippets") ?? []
        positions = Self.load([String: BarPosition].self, "flow.positions") ?? [:]
        // Saved actions from before the transcript actions: add the five once, after yours (deleting one later sticks).
        var saved = Self.load([FlowAction].self, "flow.actions") ?? FlowAction.builtIn
        if !d.bool(forKey: "flow.actions.transcriptAdded") {
            d.set(true, forKey: "flow.actions.transcriptAdded")
            let have = Set(saved.map(\.id))
            let missing = FlowAction.transcriptBuiltIn.filter { !have.contains($0.id) }
            if !missing.isEmpty { saved += missing; d.set(try? JSONEncoder().encode(saved), forKey: "flow.actions") }
        }
        actions = saved
        typingWPM = d.object(forKey: "flow.typingWPM") as? Int ?? 40
        activeProject = d.string(forKey: "flow.activeProject").flatMap(UUID.init(uuidString:))
        declinedFixes = d.stringArray(forKey: "flow.declinedFixes") ?? []
    }

    func style(for c: AppCategory) -> FlowStyle { c == .code ? .verbatim : (styles[c] ?? .casual) }

    var barHidden: Bool { !showBar || (hiddenUntil.map { $0 > Date() } ?? false) }

    private func save<T: Encodable>(_ v: T, _ key: String) { d.set(try? JSONEncoder().encode(v), forKey: key) }
    private static func load<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(t, from: data)
    }
}

