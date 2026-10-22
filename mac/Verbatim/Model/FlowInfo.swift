import Foundation

// Shared by the Mac and iPhone apps: dictation records sync through iCloud with the rest of a transcript.

/// The kind of app you're writing into; decides the style.
enum AppCategory: String, CaseIterable, Identifiable, Codable, TolerantEnum {
    case email, work, personal, code, other
    /// A category a newer build added reads as Everything else, so the dictation still loads.
    static var fallback: AppCategory { .other }
    init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
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
enum FlowStyle: String, CaseIterable, Identifiable, Codable, TolerantEnum {
    case formal, casual, veryCasual, verbatim
    /// A style a newer build added reads as Casual, so the dictation still loads.
    static var fallback: FlowStyle { .casual }
    init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
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
    /// Why cleanup used the rules instead of the model (a timeout, a guard, cloud failing), so fallbacks can be
    /// counted. Nil when the model's text was used, and for dictations made before Verbatim kept it.
    var cleanupNote: String? = nil
    /// The company the words were sent to for cloud cleanup ("Anthropic", "OpenAI"), whether or not its text was
    /// used, for the transcript's data path badge. Nil when nothing left the device.
    var cloudCleanup: String? = nil
}

// MARK: Destination rules

extension AppCategory {
    /// The kind of app from its bundle ID, the front browser tab's host (domain only, from `SiteCapture`), and the
    /// window title. Browsers go by host first, then by the tab's title. Foundation only, so the rule tests run
    /// anywhere.
    static func classify(bundleID: String?, title: String, host: String? = nil) -> AppCategory {
        let id = (bundleID ?? "").lowercased()
        if let c = DestinationRules.byApp(id) { return c }
        guard DestinationRules.isBrowser(id) || id.isEmpty else { return .other }
        if let h = host, let c = DestinationRules.byHost(h) { return c }
        return DestinationRules.byTitle(title.lowercased()) ?? .other
    }
}

enum DestinationRules {
    static let emailApps = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.readdle.spark", "com.superhuman",
                            "com.mimestream", "it.bloop.airmail", "com.freron.mailmate", "com.postbox", "com.canarymail", "com.hey",
                            "org.mozilla.thunderbird", "ch.protonmail.desktop", "com.notion.mail"]
    /// Slack, Teams (classic and the new "com.microsoft.teams2"), Discord (it renders Markdown, like Slack), and more.
    static let workApps = ["com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.linear", "com.atlassian", "com.basecamp", "us.zoom.xos",
                           "com.figma", "com.hnc.discord", "mattermost.desktop", "org.zulip"]
    static let personalApps = ["com.apple.mobilesms", "com.apple.ichat", "net.whatsapp", "desktop.whatsapp", "ru.keepcoder.telegram",
                               "org.telegram", "org.whispersystems.signal", "com.facebook.archon", "com.facebook.messenger"]
    static let codeApps = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                           "io.alacritty", "com.github.wez.wezterm", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92",
                           "com.exafunction.windsurf", "com.apple.dt.xcode", "com.jetbrains", "dev.zed", "com.sublimetext", "com.panic.nova",
                           "com.barebones.bbedit"]
    /// Browsers, including Safari and Chrome web apps ("com.apple.Safari.WebApp.…", "com.google.Chrome.app.…").
    static let browsers = ["com.apple.safari", "com.google.chrome", "company.thebrowser", "com.brave", "org.mozilla.firefox", "com.microsoft.edgemac",
                           "com.operasoftware", "com.vivaldi", "com.kagi.kagimacos", "ai.perplexity.comet", "org.chromium.chromium"]

    static func byApp(_ id: String) -> AppCategory? {
        if emailApps.contains(where: { id.hasPrefix($0) }) { return .email }
        if codeApps.contains(where: { id.hasPrefix($0) }) { return .code }
        if workApps.contains(where: { id.hasPrefix($0) }) { return .work }
        if personalApps.contains(where: { id.hasPrefix($0) }) { return .personal }
        return nil
    }

    static func isBrowser(_ id: String) -> Bool { browsers.contains { id.hasPrefix($0) } }

    /// Web apps by host. A host matches its own entry or any subdomain of it ("acme.slack.com" → "slack.com").
    static let hosts: [(String, AppCategory)] = [
        ("mail.google.com", .email), ("outlook.office.com", .email), ("outlook.office365.com", .email), ("outlook.live.com", .email),
        ("outlook.cloud.microsoft", .email), ("mail.proton.me", .email), ("app.fastmail.com", .email), ("app.hey.com", .email),
        ("mail.superhuman.com", .email), ("mail.yahoo.com", .email), ("mail.aol.com", .email), ("mail.zoho.com", .email),
        ("mail.zoho.eu", .email), ("app.tuta.com", .email), ("mail.notion.so", .email),
        ("slack.com", .work), ("teams.microsoft.com", .work), ("teams.live.com", .work), ("teams.cloud.microsoft", .work),
        ("discord.com", .work), ("chat.google.com", .work), ("linear.app", .work), ("app.asana.com", .work), ("atlassian.net", .work),
        ("notion.so", .work), ("basecamp.com", .work), ("app.clickup.com", .work),
        ("web.whatsapp.com", .personal), ("messenger.com", .personal), ("messages.google.com", .personal), ("web.telegram.org", .personal),
        ("instagram.com", .personal),
        ("github.com", .code), ("github.dev", .code), ("gitlab.com", .code), ("replit.com", .code), ("colab.research.google.com", .code),
    ]
    private static let hostsLongestFirst = hosts.sorted { $0.0.count > $1.0.count }

    static func byHost(_ raw: String) -> AppCategory? {
        var h = raw.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        // Longest entry first, so "mail.notion.so" wins over "notion.so".
        for (d, c) in hostsLongestFirst where h == d || h.hasSuffix("." + d) { return c }
        return nil
    }

    static func byTitle(_ t: String) -> AppCategory? {
        if ["gmail", "outlook", "inbox", "mail -", "proton mail", "fastmail", "superhuman", "icloud mail", "yahoo mail"].contains(where: { t.contains($0) }) { return .email }
        if ["slack", "teams", "linear", "discord", "jira", "asana", "notion", "google chat"].contains(where: { t.contains($0) }) { return .work }
        if ["whatsapp", "messenger", "telegram", "instagram", "messages"].contains(where: { t.contains($0) }) { return .personal }
        if ["github", "gitlab", "codespaces", "replit", "colab"].contains(where: { t.contains($0) }) { return .code }
        return nil
    }
}
