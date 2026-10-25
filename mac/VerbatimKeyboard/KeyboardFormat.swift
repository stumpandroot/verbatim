import UIKit

// MARK: - Distribution (the App Store switch)

/// What this build may do. One build setting, `VERBATIM_APP_STORE=YES` (the AppStore configuration sets it; see
/// mac/APP_STORE.md), defines the `APP_STORE` compilation condition in every iPhone target. With it, the private
/// interfaces automated review detects (`_hostBundleID`, `_systemNavigationAction`, `LSApplicationWorkspace`) are
/// compiled out, and the seams that used them report "unavailable", so the public fallbacks show instead. The
/// keyboard opening Verbose stays in every build: a deliberate guideline 4.4.1 risk Tim accepted (October 2026).
/// Compiled into the app and the keyboard.
enum Distribution {
    /// True in App Store builds.
    static var isAppStore: Bool {
        #if APP_STORE
        return true
        #else
        return false
        #endif
    }

    /// The features that depend on undocumented iOS interfaces or on fetching YouTube on the device.
    struct Abilities: Equatable {
        /// The keyboard reads the bundle ID of the app you're typing in (`_hostBundleID`).
        var readsHostApp: Bool
        /// The keyboard opens Verbatim to start a session (`openURL:options:completionHandler:` by selector). True
        /// in every build, App Store included (accepted 4.4.1 risk; the first thing to remove if App Review rejects).
        var keyboardOpensVerbatim: Bool
        /// The app switches back to the app you came from (`_systemNavigationAction`, `LSApplicationWorkspace`).
        var returnsToHostApp: Bool
        /// The iPhone fetches YouTube audio itself (YouTubeKit). Off: YouTube links go to the Mac's Queue.
        var youTubeOnDevice: Bool
    }

    /// The abilities of a build, from the flag. Pure, so the self-tests can check both kinds of build.
    static func abilities(appStore: Bool) -> Abilities {
        Abilities(readsHostApp: !appStore, keyboardOpensVerbatim: true, returnsToHostApp: !appStore,
                  youTubeOnDevice: !appStore && youTubeCompiledIn)
    }

    /// This build's abilities.
    static var current: Abilities { abilities(appStore: isAppStore) }

    private static var youTubeCompiledIn: Bool {
        #if YOUTUBE_ON_DEVICE
        return true
        #else
        // The keyboard and widget targets never define it; only the app's answer matters there.
        return !isAppStore
        #endif
    }
}

// MARK: - Format chip

/// The keyboard's format chip: what kind of writing a dictation is for, which picks the app's cleanup category.
/// Auto (the default) works it out from the host app when the build can read it, and otherwise from what the
/// text field tells every keyboard: its return key, content type, and the text before the cursor.
enum KeyboardFormat: String, CaseIterable, Identifiable {
    case auto, email, message, note
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .email: return "Email"
        case .message: return "Message"
        case .note: return "Note"
        }
    }

    /// The next choice when you tap the chip: Auto, Email, Message, Note, then Auto again.
    var next: KeyboardFormat {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The cleanup category the app uses (`AppCategory.rawValue`): email, personal, work, or other. A message
    /// in a work chat app (when the host is known) is work; any other message is personal.
    func category(hostKind: HostKind?) -> String {
        switch self {
        case .email: return "email"
        case .message: return hostKind == .work ? "work" : "personal"
        case .note: return "other"
        case .auto:
            switch hostKind {
            case .email?: return "email"
            case .personal?: return "personal"
            case .work?: return "work"
            case .note?: return "other"
            case nil: return "personal"
            }
        }
    }

    // MARK: Host apps (full builds only)

    /// What kind of app a known host is.
    enum HostKind: String, Equatable { case email, personal, work, note }

    /// Known hosts: bundle ID → kind and the short name the chip shows ("Auto · Mail").
    static let hosts: [String: (kind: HostKind, name: String)] = [
        // Email
        "com.apple.mobilemail": (.email, "Mail"),
        "com.microsoft.Office.Outlook": (.email, "Outlook"),
        "com.google.Gmail": (.email, "Gmail"),
        "com.readdle.smartemail": (.email, "Spark"),
        "com.superhuman.Superhuman": (.email, "Superhuman"),
        "ch.protonmail.protonmail": (.email, "Proton Mail"),
        "com.yahoo.Aerogram": (.email, "Yahoo Mail"),
        // Personal messages
        "com.apple.MobileSMS": (.personal, "Messages"),
        "net.whatsapp.WhatsApp": (.personal, "WhatsApp"),
        "ph.telegra.Telegraph": (.personal, "Telegram"),
        "org.whispersystems.signal": (.personal, "Signal"),
        "com.facebook.Messenger": (.personal, "Messenger"),
        "com.burbn.instagram": (.personal, "Instagram"),
        // Work messages
        "com.tinyspeck.chatlyio": (.work, "Slack"),
        "com.microsoft.skype.teams": (.work, "Teams"),
        "com.hammerandchisel.discord": (.work, "Discord"),
        "com.google.chat": (.work, "Google Chat"),
        "com.linear": (.work, "Linear"),
        // Notes and documents
        "com.apple.mobilenotes": (.note, "Notes"),
        "com.apple.reminders": (.note, "Reminders"),
        "notion.id": (.note, "Notion"),
        "net.shinyfrog.bear-iOS": (.note, "Bear"),
        "md.obsidian": (.note, "Obsidian"),
        "com.agiletortoise.Drafts5": (.note, "Drafts"),
        "com.apple.Pages": (.note, "Pages"),
        "com.microsoft.Office.Word": (.note, "Word"),
        "com.google.Docs": (.note, "Docs"),
    ]

    /// The kind and name of a host app, or nil when it's unknown (or the build can't read hosts).
    static func classify(host: String?) -> (kind: HostKind, name: String)? {
        guard let host, !host.isEmpty else { return nil }
        return hosts[host]
    }

    // MARK: Inferring from the text field (every build)

    /// What the text field tells a keyboard through public `UITextDocumentProxy` traits.
    struct FieldTraits: Equatable {
        var keyboardType: UIKeyboardType? = nil
        var textContentType: UITextContentType? = nil
        var returnKeyType: UIReturnKeyType? = nil
        /// `documentContextBeforeInput`: iOS may cut it short, often at a paragraph.
        var before: String? = nil
    }

    /// Prose longer than this before the cursor reads as a note or document rather than a chat message.
    static let longProse = 280

    private static let greetings = ["hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening", "greetings", "to whom it may concern"]
    private static let signOffs = ["best,", "best regards", "kind regards", "regards,", "sincerely", "cheers,", "thanks,\n", "thank you,\n", "warm regards", "all the best"]

    /// The format Auto picks from the field alone. Never `.auto`.
    ///
    /// 1. An address, URL, or search field isn't body text: Note (plain cleanup), never Email.
    /// 2. A greeting line ("Hi Sarah,") or email sign-off or quote before the cursor: Email.
    /// 3. A Send return key: Message.
    /// 4. Long prose or paragraphs before the cursor: Note.
    /// 5. Otherwise (empty, or short chat-like text): Message.
    static func infer(_ t: FieldTraits) -> KeyboardFormat {
        if let k = t.keyboardType, [.emailAddress, .URL, .webSearch, .twitter].contains(k) { return .note }
        if let c = t.textContentType, [.emailAddress, .URL, .username, .password, .newPassword, .oneTimeCode, .telephoneNumber].contains(c) { return .note }
        let before = t.before ?? ""
        if looksLikeEmail(before) { return .email }
        if t.returnKeyType == .send { return .message }
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > longProse || trimmed.contains("\n\n") { return .note }
        return .message
    }

    /// True for a greeting on its own line ("Hi Sarah," then a line break, or as the whole text so far), an
    /// email sign-off, or a quoted reply header ("On Monday, Sam wrote:").
    static func looksLikeEmail(_ text: String) -> Bool {
        let lower = text.lowercased()
        if signOffs.contains(where: { lower.contains($0) }) { return true }
        if lower.range(of: #"(^|\n)on .{3,80} wrote:"#, options: .regularExpression) != nil { return true }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !line.isEmpty, line.count <= 48 else { continue }
            guard greetings.contains(where: { line == $0 || line.hasPrefix($0 + " ") || line.hasPrefix($0 + ",") }) else { continue }
            // "Hi Sarah," with a comma, or a greeting followed by more lines.
            if line.hasSuffix(",") || i < lines.count - 1 { return true }
        }
        return false
    }

    /// What the chip says and what the app gets, for a chosen format, the host (nil when unknown or in App
    /// Store builds), and the field. Auto shows the host's name when it's known ("Auto · Mail"), otherwise what
    /// it inferred ("Auto · Email").
    static func resolve(_ choice: KeyboardFormat, host: String?, traits: FieldTraits) -> (label: String, category: String) {
        let known = classify(host: host)
        guard choice == .auto else { return (choice.title, choice.category(hostKind: known?.kind)) }
        if let known { return ("Auto · " + known.name, KeyboardFormat.auto.category(hostKind: known.kind)) }
        let inferred = infer(traits)
        return ("Auto · " + inferred.title, inferred.category(hostKind: nil))
    }
}

// MARK: - The format in the App Group

extension KeyboardBridge {
    /// The chip's choice for this session (KeyboardFormat.rawValue). The app clears it when a session starts, so
    /// each session begins on Auto.
    static let formatKey = "kb.format"
    /// "<dictation UUID> <category>": the cleanup category the keyboard picked for a dictation.
    static let categoryKey = "kb.d.category"

    static var format: KeyboardFormat {
        get { defaults?.string(forKey: formatKey).flatMap(KeyboardFormat.init(rawValue:)) ?? .auto }
        set { defaults?.set(newValue.rawValue, forKey: formatKey) }
    }

    static func writeCategory(_ category: String, for dictation: UUID) {
        defaults?.set(dictation.uuidString + " " + category, forKey: categoryKey)
    }

    /// The category the keyboard picked for `dictation`, or nil when it picked none (an older keyboard).
    static func category(for dictation: UUID) -> String? {
        guard let s = defaults?.string(forKey: categoryKey) else { return nil }
        return parseCategory(s, for: dictation)
    }

    /// Pure half of `category(for:)`.
    static func parseCategory(_ stored: String, for dictation: UUID) -> String? {
        let parts = stored.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == dictation.uuidString, !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}
