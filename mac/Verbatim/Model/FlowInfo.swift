import Foundation

// Shared by the Mac and iPhone apps: dictation records sync through iCloud with the rest of a transcript.

/// The kind of app you're writing into; decides the style.
enum AppCategory: String, CaseIterable, Identifiable, Codable {
    case email, work, personal, code, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .email: return "Email"
        case .work: return "Work messages"
        case .personal: return "Personal messages"
        case .code: return "Code and terminal"
        case .other: return "Everything else"
        }
    }
    var examples: String {
        switch self {
        case .email: return "Mail, Outlook, Gmail, Superhuman, Spark"
        case .work: return "Slack, Teams, Linear, Discord servers"
        case .personal: return "Messages, WhatsApp, Signal, Telegram"
        case .code: return "Terminal, Xcode, VS Code, Cursor"
        case .other: return "Notes, documents, browsers, everything else"
        }
    }
}

/// The tone for a category.
enum FlowStyle: String, CaseIterable, Identifiable, Codable {
    case formal, casual, veryCasual, verbatim
    var id: String { rawValue }
    var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        case .verbatim: return "As spoken"
        }
    }
}

/// What happened to one dictation, kept with the transcript so History can show and redo it.
struct FlowInfo: Codable, Equatable {
    var app: String
    var bundleID: String?
    var category: AppCategory
    var style: FlowStyle
    var level: String
    /// The text before cleanup (Dictionary fixes applied), and what was pasted.
    var raw: String
    var pasted: String
    var pastedOK: Bool
    /// Set for command mode: the spoken instruction and the selected text it changed.
    var instruction: String? = nil
    var selection: String? = nil
}
