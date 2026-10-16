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

/// How much the words are edited before they're pasted.
enum CleanupLevel: String, CaseIterable, Identifiable {
    case none, light, medium
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        }
    }
    var note: String {
        switch self {
        case .none: return "Exactly what you said, with punctuation."
        case .light: return "Removes ums, repeats, and false starts, and fixes grammar. Keeps your wording."
        case .medium: return "Also tightens rambling sentences. Keeps every point."
        }
    }
}

/// A spoken shortcut: say the trigger, get the saved text.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

/// Where the floating button sits.
enum BarEdge: String, Codable { case bottom, left, right }

/// Every setting for Verbatim Flow (system-wide dictation), saved in UserDefaults.
@MainActor
final class FlowSettings: ObservableObject {
    static let shared = FlowSettings()
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

    struct BarPosition: Codable, Equatable { var edge: BarEdge; var along: Double }

    private init() {
        showBar = d.object(forKey: "flow.showBar") as? Bool ?? true
        mode = FlowMode(rawValue: d.string(forKey: "flow.mode") ?? "") ?? .hybrid
        cleanup = CleanupLevel(rawValue: d.string(forKey: "flow.cleanup") ?? "") ?? .light
        useContext = d.object(forKey: "flow.context") as? Bool ?? true
        autoLearn = d.object(forKey: "flow.autoLearn") as? Bool ?? true
        boostVocabulary = d.object(forKey: "flow.boost") as? Bool ?? true
        keepDays = d.object(forKey: "flow.keepDays") as? Int ?? 0
        hiddenUntil = d.object(forKey: "flow.hiddenUntil") as? Date
        styles = Self.load([AppCategory: FlowStyle].self, "flow.styles") ?? [.email: .formal, .work: .casual, .personal: .casual, .code: .verbatim, .other: .casual]
        snippets = Self.load([Snippet].self, "flow.snippets") ?? []
        positions = Self.load([String: BarPosition].self, "flow.positions") ?? [:]
    }

    func style(for c: AppCategory) -> FlowStyle { c == .code ? .verbatim : (styles[c] ?? .casual) }

    var barHidden: Bool { !showBar || (hiddenUntil.map { $0 > Date() } ?? false) }

    private func save<T: Encodable>(_ v: T, _ key: String) { d.set(try? JSONEncoder().encode(v), forKey: key) }
    private static func load<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(t, from: data)
    }
}

