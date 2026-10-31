import SwiftUI

// MARK: - Index

/// Where a search result leads: a row on the Settings page (scroll to it and flash it), or a subpage to push.
enum SettingsSearchTarget: Equatable {
    case row
    case page(SettingsSubpage)
}

/// The Settings subpages a result can open. Raw values are the page names in PhoneSettingsMap and the names
/// `SettingsPage.open(_:)` takes; SettingsScreen maps each one to its navigation destination.
enum SettingsSubpage: String, CaseIterable, Equatable {
    case aboutMe, dictionary, keyboard, snippets, actionButton, appearance, whatsNew
    case speakers, moreTranscription, cloudCleanup, privacy, tour, widgets, shortcuts, customizeHome, thoughts, tabBar
    case templates

    /// The page's title, as its navigation bar shows it.
    var title: String {
        switch self {
        case .aboutMe: return "About me"
        case .dictionary: return "Dictionary"
        case .keyboard: return "Keyboard"
        case .snippets: return "Snippets"
        case .actionButton: return "Action button"
        case .appearance: return "Appearance"
        case .whatsNew: return "What's new"
        case .speakers: return "Speakers"
        case .moreTranscription: return "More transcription options"
        case .cloudCleanup: return "Cloud cleanup"
        case .privacy: return "Privacy"
        case .tour: return "Welcome tour"
        case .widgets: return "Widgets and controls"
        case .shortcuts: return "Shortcuts and Siri"
        case .customizeHome: return "Customize Home"
        case .thoughts: return "Thoughts"
        case .tabBar: return "Tab bar"
        case .templates: return "Templates"
        }
    }
}

/// One searchable setting. `id` matches the row's `.settingsSearchTarget(_:flash:)` id on the Settings page.
struct SettingsSearchEntry: Identifiable, Equatable {
    var id: String
    var section: String
    var label: String
    var keywords: [String] = []
    var description: String? = nil
    var target: SettingsSearchTarget = .row
}

/// One section's worth of results.
struct SettingsSearchGroup: Identifiable {
    var section: String
    var entries: [SettingsSearchEntry]
    var id: String { section }
}

/// Every setting the search knows about, in the order Settings shows them. Sections are the seven groups of
/// PhoneSettingsMap, and a setting that sits on a page targets that page (mac/tools/test-settings-map.sh checks both).
/// To make a new row findable, add it to PhoneSettingsMap, add an entry here, and give the row
/// `.settingsSearchTarget("<id>", flash: searchFlash)`.
enum SettingsSearchIndex {
    private static let personalization = PhoneSettingsMap.personalization
    private static let recording = PhoneSettingsMap.recording
    private static let dictation = PhoneSettingsMap.dictation
    private static let sync = PhoneSettingsMap.sync
    private static let account = PhoneSettingsMap.account
    private static let support = PhoneSettingsMap.support
    private static let features = PhoneSettingsMap.features

    static let all: [SettingsSearchEntry] = [
        // Personalization and preferences. Settings › Appearance: the palette, and light or dark.
        .init(id: "palette", section: personalization, label: "Palette", keywords: ["color", "colour", "soft", "full", "tint", "muted", "bright", "pastel", "record card", "tiles", "look", "style"],
              description: "Full color or soft tints on the Record card and tiles", target: .page(.appearance)),
        .init(id: "appearance", section: personalization, label: "Light or dark", keywords: ["appearance", "dark mode", "light mode", "theme", "night", "color"],
              description: "Match the system, light, or dark", target: .page(.appearance)),
        .init(id: "customizeHome", section: personalization, label: "Customize Home", keywords: ["edit home", "home", "sections", "reorder", "tiles", "shortcut tiles", "compact", "large", "hide"],
              description: "Show, hide, reorder, and resize Home's sections", target: .page(.customizeHome)),
        .init(id: "tabBar", section: personalization, label: "Tab bar", keywords: ["tabs", "tab bar", "bottom bar", "thoughts tab", "journal tab", "projects", "dictations", "reorder", "customize"],
              description: "Choose up to four tabs after Home", target: .page(.tabBar)),
        .init(id: "aboutMe", section: personalization, label: "About me", keywords: ["profile", "context", "titles", "summaries", "bio"],
              description: "Context for titles and summaries", target: .page(.aboutMe)),
        .init(id: "voice", section: personalization, label: "Your voice", keywords: ["speaker", "recognize", "me", "voice print", "voice profile"],
              description: "Recognize you in recordings"),
        .init(id: "dictionary", section: personalization, label: "Dictionary", keywords: ["words", "names", "spelling", "vocabulary", "custom words"],
              description: "Names and words to spell your way", target: .page(.dictionary)),
        .init(id: "builtInVocabulary", section: personalization, label: "Built-in vocabulary",
              keywords: ["modern words", "brands", "apps", "tech terms", "spelling", "chatgpt", "iphone", "youtube", "contacts", "suggestions", "names", "places", "mix-ups"],
              description: "About 800 modern words and names spelled right", target: .page(.dictionary)),
        .init(id: "language", section: personalization, label: "Detect the language", keywords: ["language", "english", "spanish", "automatic", "locale", "multilingual", "parakeet v3"],
              description: "Use a model that knows each recording's language"),
        .init(id: "limitMotion", section: personalization, label: "Limit animation", keywords: ["reduce motion", "animation", "accessibility", "movement"],
              description: "Fades instead of movement; illustrations stay still"),
        .init(id: "haptics", section: personalization, label: "Haptics", keywords: ["vibration", "vibrate", "taps", "feedback", "buzz", "accessibility", "apple watch", "keyboard"],
              description: "Taps when you record, stop, mark, or copy, here, in the keyboard, and on Apple Watch"),

        // Recording and transcription
        .init(id: "quality", section: recording, label: "Quality", keywords: ["model", "accuracy", "speed", "preset", "language"],
              description: "Which transcription model runs on this iPhone"),
        .init(id: "speakers", section: recording, label: "Identify speakers", keywords: ["diarization", "voices", "people", "who spoke", "speakers"],
              target: .page(.speakers)),
        .init(id: "mainSpeaker", section: recording, label: "Main speaker only", keywords: ["background voices", "speakers", "focus"],
              description: "In voice memos, other voices fold into a Background voices section", target: .page(.speakers)),
        .init(id: "recognizeVoices", section: recording, label: "Recognize voices I\u{2019}ve named",
              keywords: ["voice match", "speaker names", "suggest", "people", "remember", "voices"],
              description: "Suggests names for voices you named; kept on this iPhone only", target: .page(.speakers)),
        .init(id: "clearVoices", section: recording, label: "Clear saved voices", keywords: ["delete", "forget", "voices", "speakers"], target: .page(.speakers)),
        .init(id: "summaries", section: recording, label: "Summaries", keywords: ["recap", "overview", "summary", "write a summary", "key points"],
              description: "A short overview and key points when a transcript finishes"),
        .init(id: "nameAndSort", section: recording, label: "Name and sort recordings", keywords: ["titles", "tags", "kind", "auto label", "apple intelligence"],
              description: "Suggests a title, kind, and tags when a transcript is ready"),
        .init(id: "recordLiveWords", section: recording, label: "Show words while you record",
              keywords: ["live text", "live words", "preview", "real time", "transcript", "voice note", "recorder", "battery"],
              description: "A preview of your words on the recorder"),
        .init(id: "hideFiller", section: recording, label: "Hide filler lines", keywords: ["um", "uh", "filler", "clean"],
              description: "Lines that are only \u{201C}um\u{201D} or \u{201C}uh\u{201D} stay out of view", target: .page(.moreTranscription)),
        .init(id: "applyDictionary", section: recording, label: "Apply Dictionary", keywords: ["words", "names", "spelling", "corrections"],
              target: .page(.moreTranscription)),
        .init(id: "audioTracks", section: recording, label: "Files with several audio tracks",
              keywords: ["multiple audio tracks", "mkv", "video", "language", "commentary", "mix", "separate", "speakers", "import"],
              description: "Mix every track, or keep each track as a speaker", target: .page(.moreTranscription)),
        .init(id: "skipSponsors", section: recording, label: "Skip sponsor reads",
              keywords: ["sponsor", "sponsors", "ads", "ad read", "advertisement", "promo code", "podcast", "youtube", "skip"],
              description: "Playback jumps past sponsor reads in podcasts and videos", target: .page(.moreTranscription)),

        // Dictation and keyboard. Settings › Keyboard.
        .init(id: "keyboard", section: dictation, label: "Set up the Verbose keyboard", keywords: ["keyboard", "dictate", "add keyboard", "globe key", "extension"],
              description: "Dictate into any app", target: .page(.keyboard)),
        .init(id: "keyboardFullAccess", section: dictation, label: "Allow Full Access for the keyboard", keywords: ["full access", "permission", "privacy"],
              description: "Lets the keyboard start a session and receive your words", target: .page(.keyboard)),
        .init(id: "keyboardTimeout", section: dictation, label: "End keyboard sessions after", keywords: ["session", "timeout", "idle", "microphone", "minutes", "hours", "until i end it", "orange dot"],
              description: "How long a session waits before it turns off the microphone", target: .page(.keyboard)),
        .init(id: "keyboardAutoStart", section: dictation, label: "Start dictating when you come back",
              keywords: ["auto start", "listen", "first tap", "second tap", "dictate", "microphone", "return", "switch back"],
              description: "The first tap opens Verbose and starts listening; no second tap", target: .page(.keyboard)),
        .init(id: "keyboardPolishAfter", section: dictation, label: "Polish after inserting",
              keywords: ["polish", "cleanup", "clean up", "swap", "replace", "ums", "filler", "grammar", "faster", "speed", "insert"],
              description: "Your words appear right away; Verbose swaps in the cleaned-up version a moment later", target: .page(.keyboard)),
        .init(id: "keyboardLiveWords", section: dictation, label: "Show words as you speak",
              keywords: ["live words", "preview", "streaming", "real time", "transcript", "see words"],
              description: "The keyboard shows your words while you talk", target: .page(.keyboard)),
        .init(id: "keyboardDictateButton", section: dictation, label: "Dictate button",
              keywords: ["dictate button", "start button", "size", "large", "position", "left", "right", "center", "left-handed", "one-handed", "thumb", "outline", "filled", "butter"],
              description: "Size, position, and style of the keyboard's dictate button", target: .page(.keyboard)),
        .init(id: "keyboardIslandWords", section: dictation, label: "Show words in the Dynamic Island",
              keywords: ["dynamic island", "live activity", "words", "notch", "live words", "privacy", "lock screen"],
              description: "The expanded Dynamic Island shows your last few words during a take", target: .page(.keyboard)),
        .init(id: "keyboardAlwaysCopy", section: dictation, label: "Also copy each dictation",
              keywords: ["clipboard", "copy", "paste", "pasteboard", "recent", "history", "missed", "keep"],
              description: "Each keyboard dictation also goes on the clipboard", target: .page(.keyboard)),
        .init(id: "keyboardLowerAudio", section: dictation, label: "Lower other audio while Verbose listens",
              keywords: ["duck", "music", "spotify", "youtube", "podcast", "volume", "quiet", "background sound"],
              description: "Other sound drops to a whisper so it doesn't reach the microphone", target: .page(.keyboard)),
        .init(id: "keyboardTypingHaptics", section: dictation, label: "Typing haptics",
              keywords: ["haptics", "vibration", "vibrate", "keys", "typing", "tap", "feedback", "battery"],
              description: "A light tap with each key you type in the Verbose keyboard", target: .page(.keyboard)),
        // Settings › Action button.
        .init(id: "actionButton", section: dictation, label: "Action button",
              keywords: ["action button", "control center", "dynamic island", "lock screen", "shortcut", "siri", "press", "ribbon", "dictate anywhere", "voice note", "live captions", "clipboard", "what's playing", "broadcast", "thought pad", "quick capture"],
              description: "Dictate from any app without switching", target: .page(.actionButton)),
        .init(id: "actionButtonTimeout", section: dictation, label: "End the session after",
              keywords: ["action button", "idle", "timeout", "minutes", "hours", "microphone", "session", "until i end it"],
              description: "10 or 30 minutes, 1, 2, or 4 hours without dictation, or until you end it", target: .page(.actionButton)),
        .init(id: "cleanup", section: dictation, label: "Cleanup for keyboard dictation", keywords: ["cleanup", "ums", "filler", "grammar", "polish", "dictation", "literal", "clean", "polished"],
              description: "How much keyboard dictations are tidied"),
        .init(id: "spokenCorrections", section: dictation, label: "Understand spoken corrections",
              keywords: ["scratch that", "delete the last sentence", "start over", "actually", "no wait", "self-correction", "correction", "undo", "never mind", "spoken corrections"],
              description: "Say \u{201C}scratch that,\u{201D} \u{201C}delete the last sentence,\u{201D} or \u{201C}let me start over\u{201D} to fix what you said"),
        .init(id: "snippets", section: dictation, label: "Snippets in the keyboard", keywords: ["snippets", "trigger", "text expansion", "shortcut", "saved text"],
              description: "Say a trigger, get your saved text", target: .page(.snippets)),
        // Settings › Cloud cleanup.
        .init(id: "cloudCleanup", section: dictation, label: "Cloud cleanup",
              keywords: ["cloud", "claude", "anthropic", "openai", "chatgpt", "gpt", "api key", "keychain", "model", "grammar", "ai"],
              description: "Clean up with your own Anthropic or OpenAI key; off by default", target: .page(.cloudCleanup)),
        .init(id: "cloudProvider", section: dictation, label: "Cloud cleanup provider", keywords: ["anthropic", "openai", "claude", "gpt", "cloud", "provider"],
              description: "Who cleans up your words when cloud cleanup is on", target: .page(.cloudCleanup)),

        // Sync and storage. Settings › Privacy (PhoneTrust.swift).
        .init(id: "localOnly", section: sync, label: "Local Only", keywords: ["offline", "airplane", "network", "internet", "block", "privacy", "no analytics", "account"],
              description: "Nothing leaves this iPhone except iCloud sync", target: .page(.privacy)),
        .init(id: "networkActivity", section: sync, label: "Network activity", keywords: ["log", "requests", "hosts", "connections", "downloads", "privacy"],
              description: "Every time Verbose used the network", target: .page(.privacy)),
        .init(id: "sync", section: sync, label: "iCloud sync", keywords: ["cloud", "mac", "sync", "backup", "devices"],
              description: "Match your library with your Mac"),
        .init(id: "export", section: sync, label: "Export everything", keywords: ["backup", "download", "zip", "markdown", "json"],
              description: "Markdown and JSON in one zip"),
        .init(id: "deleteAll", section: sync, label: "Delete all data", keywords: ["erase", "reset", "remove", "wipe"]),

        // Account and plan
        .init(id: "yourName", section: account, label: "Your name", keywords: ["name", "profile", "greeting", "sign-off", "you"],
              description: "Greets you on Home; edited in About me", target: .page(.aboutMe)),

        // Support and feedback
        .init(id: "support", section: support, label: "Contact support", keywords: ["help", "email", "problem", "bug"]),
        .init(id: "feedback", section: support, label: "Share feedback", keywords: ["idea", "suggestion", "email"]),
        .init(id: "log", section: support, label: "Send diagnostic log", keywords: ["logs", "debug", "diagnostics", "bug"],
              description: "7 days of app events, without links or folder names"),
        .init(id: "privacy", section: support, label: "Privacy policy", keywords: ["data", "legal"]),
        .init(id: "terms", section: support, label: "Terms of use", keywords: ["legal", "terms of service"]),
        .init(id: "share", section: support, label: "Share Verbose", keywords: ["invite", "recommend", "friend"]),
        .init(id: "acknowledgements", section: support, label: "Acknowledgements", keywords: ["ffmpeg", "lgpl", "open source", "license", "credits"],
              description: "Open-source software in Verbose and its licenses"),
        .init(id: "whatsNew", section: support, label: "What's new", keywords: ["release notes", "changes", "changelog", "version", "build", "update", "new features"],
              description: "What each build added", target: .page(.whatsNew)),

        // Features
        .init(id: "thoughtsWaysIn", section: features, label: "Thoughts", keywords: ["new thought", "idea", "ideas", "action button", "back tap", "siri", "control center", "lock screen", "widget", "dynamic island", "live activity"],
              description: "Ways to start a thought from anywhere, and how to set up the Action button and Back Tap", target: .page(.thoughts)),
        .init(id: "thoughtsInPlace", section: features, label: "Record without opening Verbose", keywords: ["thought", "live activity", "in place", "background", "widget"],
              description: "New thought records behind a Live Activity", target: .page(.thoughts)),
        .init(id: "thoughtsIslandWords", section: features, label: "Show words in the Dynamic Island", keywords: ["thought", "live words", "island", "privacy"],
              description: "Your words while a thought records, never on the Lock Screen", target: .page(.thoughts)),
        .init(id: "thoughtsNewPage", section: features, label: "New page each day at", keywords: ["thought", "day", "midnight", "page", "journal", "by day"],
              description: "When today's Thoughts page starts", target: .page(.thoughts)),
        .init(id: "templatesAuto", section: features, label: "Run templates automatically", keywords: ["templates", "meeting notes", "auto", "automatic", "kind", "apple intelligence", "notes", "summary"],
              description: "A template for each kind of recording, run when it finishes", target: .page(.templates)),
        .init(id: "templatesSkipShort", section: features, label: "Skip short recordings", keywords: ["templates", "short", "two minutes"],
              description: "Templates don't run automatically on recordings under 2 minutes", target: .page(.templates)),
        .init(id: "templatesShowFirst", section: features, label: "Show the result first", keywords: ["templates", "open", "result", "tab"],
              description: "Transcripts open on a template's automatic result", target: .page(.templates)),
        .init(id: "templatesNotify", section: features, label: "Notify me when it's done", keywords: ["templates", "notification", "long recordings"],
              description: "A notification when a template finishes on a recording over 20 minutes", target: .page(.templates)),
        .init(id: "askRecipes", section: features, label: "Recipes", keywords: ["recipes", "ask", "saved questions", "digest", "weekly", "schedule"],
              description: "Show recipes in Ask: questions you save and run again", target: .page(.templates)),
        .init(id: "widgets", section: features, label: "Widgets and controls", keywords: ["widget", "home screen", "lock screen", "control center", "controls", "this week", "recent recordings", "quick capture"],
              description: "Which widgets and controls Verbose has, and how to add them", target: .page(.widgets)),
        .init(id: "shortcuts", section: features, label: "Shortcuts and Siri", keywords: ["shortcuts", "siri", "app intents", "automation", "voice command", "hey siri"],
              description: "What you can ask Siri and use in Shortcuts", target: .page(.shortcuts)),
        .init(id: "tourOnLaunch", section: features, label: "Show the tour when Verbose opens", keywords: ["onboarding", "welcome", "launch", "intro"],
              target: .page(.tour)),
        .init(id: "tour", section: features, label: "Show Tour", keywords: ["onboarding", "welcome", "intro", "walkthrough", "welcome tour"],
              target: .page(.tour)),
    ]

    /// Rows that live on another branch (iphone-polish adds Snippets and the Cleanup picker). Their entries are
    /// registered so search finds them once that branch merges; until then they stay out of results.
    /// Empty this set when iphone-polish lands, and give its rows their `.settingsSearchTarget` ids.
    static let unavailable: Set<String> = []

    /// Entries matching `query`, grouped by section in index order. Every word of the query must match the label,
    /// a keyword, the description, or the section (case- and accent-insensitive). Label matches sort first.
    static func search(_ query: String) -> [SettingsSearchGroup] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let full = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = all.enumerated().compactMap { i, e -> (Int, Int, SettingsSearchEntry)? in
            guard !unavailable.contains(e.id) else { return nil }
            let hay = [e.label, e.description ?? "", e.section] + e.keywords
            guard words.allSatisfy({ w in hay.contains { $0.localizedStandardContains(w) } }) else { return nil }
            let rank = e.label.localizedStandardRange(of: full).map { $0.lowerBound == e.label.startIndex ? 0 : 1 } ?? 2
            return (rank, i, e)
        }
        var order: [String] = []
        var groups: [String: [(Int, Int, SettingsSearchEntry)]] = [:]
        for h in hits {
            if groups[h.2.section] == nil { order.append(h.2.section) }
            groups[h.2.section, default: []].append(h)
        }
        return order.map { s in
            SettingsSearchGroup(section: s, entries: groups[s, default: []].sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 })
        }
    }

    /// The current value shown at the trailing edge of a result, read from the same places the rows read.
    @MainActor static func value(for id: String, app: PhoneState) -> String? {
        let d = UserDefaults.standard
        func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
        switch id {
        case "language": return onOff(LanguageDetection.isEnabled)
        case "voice": return VoiceProfileStatus.shared.isEnrolled ? "On" : "Set up"
        case "summaries": return onOff(d.object(forKey: Summarizer.autoKey) as? Bool ?? true)
        case "aboutMe": return (d.string(forKey: Profile.aboutMeKey) ?? "").isEmpty ? "Add" : "Added"
        case "dictionary": return "\(app.store.dictionary.count)"
        case "builtInVocabulary": return onOff(BuiltInVocabulary.isOn)
        case "palette": return AppPalette.current.label
        case "appearance": return app.appearance == "light" ? "Light" : app.appearance == "dark" ? "Dark" : "Match system"
        case "limitMotion": return onOff(d.bool(forKey: MotionPreference.key))
        case "haptics": return onOff(Haptics.enabled)
        case "recordLiveWords": return onOff(RecordingLiveText.enabled)
        case "audioTracks": return AudioTracksPreference.current == .separate ? "Separate" : "Mix"
        case "keyboardTimeout":
            return Ribbon.timeoutShortLabel(app.session.timeoutSeconds)
        case "actionButton": return Ribbon.actionChoice(d.string(forKey: Ribbon.actionChoiceKey)).shortTitle
        case "actionButtonTimeout": return Ribbon.timeoutShortLabel(app.session.timeoutSeconds)
        case "keyboardAutoStart": return onOff(KeyboardBridge.autoStart)
        case "keyboardPolishAfter": return onOff(KeyboardBridge.polishAfter)
        case "keyboardLiveWords": return onOff(KeyboardBridge.liveWords)
        case "keyboardAlwaysCopy": return onOff(KeyboardBridge.alwaysCopy)
        case "keyboardTypingHaptics": return onOff(HapticSettings.typingKeys(in: KeyboardBridge.defaults))
        case "keyboardDictateButton":
            let b = DictateButton.read(KeyboardBridge.defaults)
            return b.size.title + " · " + b.position.title
        case "keyboardIslandWords": return onOff(KeyboardBridge.defaults?.bool(forKey: Ribbon.islandWordsKey) ?? false)
        case "thoughtsInPlace": return onOff(ThoughtRules.inPlace())
        case "thoughtsIslandWords": return onOff(ThoughtRules.islandWords())
        case "thoughtsNewPage": return DayPages.hourLabel(DayPages.storedHour())
        case "quality": return app.preset.title
        case "cloudCleanup": return onOff(CloudCleanup.enabled)
        case "speakers": return onOff(app.identifySpeakers)
        case "recognizeVoices": return onOff(SpeakerVoices.enabled)
        case "applyDictionary": return onOff(app.applyDictionary)
        case "nameAndSort": return onOff(d.object(forKey: AutoLabel.enabledKey) as? Bool ?? true)
        case "hideFiller": return onOff(d.object(forKey: Transcript.hideFillerKey) as? Bool ?? true)
        case "mainSpeaker": return onOff(d.bool(forKey: Transcript.mainSpeakerOnlyKey))
        case "skipSponsors": return onOff(d.object(forKey: Transcript.skipSponsorsKey) as? Bool ?? true)
        case "cleanup": return FlowSettings.shared.cleanup.title
        case "cloudProvider": return (CloudCleanup.Provider(rawValue: d.string(forKey: CloudCleanup.providerKey) ?? "") ?? .anthropic).title
        case "localOnly": return onOff(NetworkActivityModel.shared.localOnly)
        case "yourName":
            let name = (d.string(forKey: "profile.name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Add" : name
        case "sync": return Cloud.available ? onOff(Cloud.wantsSync) : "Off"
        case "tourOnLaunch": return onOff(Onboarding.showOnLaunch)
        default: return nil
        }
    }
}

/// The search text, shared so it survives tab switches and so the screenshot tour can type into it.
@MainActor
final class SettingsSearchModel: ObservableObject {
    static let shared = SettingsSearchModel()
    @Published var query = ""
    var isActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Results

/// Results grouped by section ("Dictation and keyboard · 3"), each group a card of rows with the query highlighted
/// (the refined kit's `PaperSection`).
struct SettingsSearchResults: View {
    var query: String
    var value: (String) -> String?
    var onPick: (SettingsSearchEntry) -> Void

    var body: some View {
        let groups = SettingsSearchIndex.search(query)
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text("No settings match \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}.")
                    .refinedFont(.body).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 24)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.section) \u{00B7} \(group.entries.count)")
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                        .padding(.horizontal, 14)
                        .accessibilityLabel("\(group.section), \(group.entries.count) \(group.entries.count == 1 ? "result" : "results")")
                        .accessibilityAddTraits(.isHeader)
                    PaperCard {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, entry in
                            if i > 0 { PaperDivider(leading: 14) }
                            Button { onPick(entry) } label: {
                                SettingsSearchResultRow(entry: entry, query: query, value: value(entry.id))
                            }
                            .buttonStyle(SettingsRowPress())
                        }
                    }
                }
                .padding(.top, 22)
            }
            Text("Clear the search to see every setting.")
                .refinedFont(.meta).foregroundStyle(Refined.mute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
        }
    }
}

/// One result: the label (or the matching description) with the query highlighted, then the value and a chevron.
struct SettingsSearchResultRow: View {
    var entry: SettingsSearchEntry
    var query: String
    var value: String?

    var body: some View {
        let labelHit = Self.highlighted(entry.label, query: query)
        let descHit = entry.description.map { Self.highlighted($0, query: query) }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(labelHit.text).refinedFont(.body).foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !labelHit.matched, let descHit, descHit.matched {
                    Text(descHit.text).refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if let value { SettingsValue(value) }
            SettingsChevron()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([entry.label, value].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }

    private var hint: String {
        switch entry.target {
        case .row: return "Shows this setting in \(entry.section)"
        case .page(let page): return "Opens \(page.title)"
        }
    }

    /// `text` with each occurrence of the whole query (or else of each query word) in ink on the persimmon tint.
    static func highlighted(_ text: String, query: String) -> (text: AttributedString, matched: Bool) {
        var out = AttributedString(text)
        let full = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needles = text.localizedStandardContains(full) ? [full] : full.split(whereSeparator: \.isWhitespace).map(String.init)
        var matched = false
        for needle in needles where !needle.isEmpty {
            var from = out.startIndex
            while from < out.endIndex,
                  let r = out[from...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                out[r].backgroundColor = Refined.persimmonTint
                out[r].foregroundColor = Refined.ink
                matched = true
                from = r.upperBound
            }
        }
        return (out, matched)
    }
}

// MARK: - Row target

extension View {
    /// Gives a Settings row the id search scrolls to, and a brief persimmon-tint wash while `flash` names it. The row
    /// counts itself on screen while it's laid out (SettingsRowRegistry), for the self-test.
    func settingsSearchTarget(_ id: String, flash: String?) -> some View {
        self
            .background(Rectangle().fill(Refined.persimmonTint).opacity(flash == id ? 1 : 0).allowsHitTesting(false))
            .animation(Motion.fade, value: flash == id)
            .id(id)
            .onAppear { SettingsRowRegistry.appeared(id) }
            .onDisappear { SettingsRowRegistry.disappeared(id) }
    }
}

/// The Settings rows laid out now, by search id, and the Settings subpage on screen. Settings pages are plain stacks
/// (not lazy), so every row of a page that's showing counts. The self-test checks every search entry against it.
/// Only views (on the main thread) and the self-test touch it.
enum SettingsRowRegistry {
    private static var counts: [String: Int] = [:]
    /// The subpage pushed on Settings, or nil on the root.
    static var page: SettingsSubpage? = nil

    static func appeared(_ id: String) { counts[id, default: 0] += 1 }
    static func disappeared(_ id: String) {
        let n = (counts[id] ?? 0) - 1
        counts[id] = n > 0 ? n : nil
    }
    static func isOnScreen(_ id: String) -> Bool { (counts[id] ?? 0) > 0 }
}
