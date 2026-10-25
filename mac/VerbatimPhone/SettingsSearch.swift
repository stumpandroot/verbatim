import SwiftUI

// MARK: - Index

/// Where a search result leads: a row on the Settings page (scroll to it and flash it), or a subpage to push.
enum SettingsSearchTarget: Equatable {
    case row
    case page(SettingsSubpage)
}

/// The Settings subpages a result can open. SettingsScreen maps each one to its navigation destination.
enum SettingsSubpage: Equatable {
    case aboutMe, dictionary, keyboard, snippets, actionButton, appearance, whatsNew
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

/// Every setting the search knows about, in the order Settings shows them. To make a new row findable, add an
/// entry here and give the row `.settingsSearchTarget("<id>", flash: searchFlash)`.
enum SettingsSearchIndex {
    static let all: [SettingsSearchEntry] = [
        // Personalization
        .init(id: "language", section: "Personalization", label: "Detect the language", keywords: ["language", "english", "spanish", "automatic", "locale", "multilingual", "parakeet v3"],
              description: "Use a model that knows each recording's language"),
        .init(id: "voice", section: "Personalization", label: "Your voice", keywords: ["speaker", "recognize", "me", "voice print"],
              description: "Recognize you in recordings"),
        .init(id: "aboutMe", section: "Personalization", label: "About me", keywords: ["profile", "context", "titles", "summaries", "bio"],
              description: "Context for titles and summaries", target: .page(.aboutMe)),
        .init(id: "dictionary", section: "Personalization", label: "Dictionary", keywords: ["words", "names", "spelling", "vocabulary", "custom words"],
              description: "Names and words to spell your way", target: .page(.dictionary)),
        .init(id: "builtInVocabulary", section: "Personalization", label: "Built-in vocabulary",
              keywords: ["modern words", "brands", "apps", "tech terms", "spelling", "chatgpt", "iphone", "youtube", "contacts", "suggestions"],
              description: "About 500 modern words spelled right", target: .page(.dictionary)),
        .init(id: "snippets", section: "Personalization", label: "Snippets in the keyboard", keywords: ["snippets", "trigger", "text expansion", "shortcut", "saved text"],
              description: "Say a trigger, get your saved text", target: .page(.snippets)),
        .init(id: "summaries", section: "Personalization", label: "Summaries", keywords: ["recap", "overview", "summary"],
              description: "For recordings over 5 minutes"),
        // Settings › Appearance: the look, light or dark, and Limit animation.
        .init(id: "look", section: "Appearance", label: "Look", keywords: ["native", "verbose style", "apple", "plain", "illustrated", "theme", "style", "keyboard look"],
              description: "Verbose style or Native", target: .page(.appearance)),
        .init(id: "appearance", section: "Appearance", label: "Light or dark", keywords: ["appearance", "dark mode", "light mode", "theme", "night", "color"],
              description: "Match the system, light, or dark", target: .page(.appearance)),
        .init(id: "limitMotion", section: "Appearance", label: "Limit animation", keywords: ["reduce motion", "animation", "accessibility", "movement"],
              description: "Fades instead of movement; illustrations stay still", target: .page(.appearance)),
        .init(id: "homeRecordCard", section: "Appearance", label: "Show the Record card", keywords: ["record card", "home", "record button", "native"],
              description: "Native: the Record card on Home", target: .page(.appearance)),

        // Recording
        .init(id: "recordLiveWords", section: "Recording", label: "Show words while you record",
              keywords: ["live text", "live words", "preview", "real time", "transcript", "voice note", "recorder", "battery"],
              description: "A preview of your words on the recorder"),

        // Keyboard (Settings › Keyboard)
        .init(id: "keyboard", section: "Keyboard", label: "Set up the Verbose keyboard", keywords: ["keyboard", "dictate", "add keyboard", "globe key", "extension"],
              description: "Dictate into any app", target: .page(.keyboard)),
        .init(id: "keyboardTimeout", section: "Keyboard", label: "End keyboard sessions after", keywords: ["session", "timeout", "idle", "microphone", "minutes", "hours", "until i end it", "orange dot"],
              description: "How long a session waits before it turns off the microphone", target: .page(.keyboard)),
        .init(id: "actionButton", section: "Personalization", label: "Action button",
              keywords: ["action button", "control center", "dynamic island", "lock screen", "shortcut", "siri", "press", "ribbon", "dictate anywhere", "voice note", "live captions", "clipboard", "what's playing", "broadcast", "thought pad", "quick capture"],
              description: "Dictate from any app without switching", target: .page(.actionButton)),
        .init(id: "actionButtonTimeout", section: "Personalization", label: "End the session after",
              keywords: ["action button", "idle", "timeout", "minutes", "hours", "microphone", "session", "until i end it"],
              description: "10 or 30 minutes, 1, 2, or 4 hours without dictation, or until you end it", target: .page(.actionButton)),
        .init(id: "keyboardAutoStart", section: "Keyboard", label: "Start dictating when you come back",
              keywords: ["auto start", "listen", "first tap", "second tap", "dictate", "microphone", "return", "switch back"],
              description: "The first tap opens Verbose and starts listening; no second tap", target: .page(.keyboard)),
        .init(id: "keyboardPolishAfter", section: "Keyboard", label: "Polish after inserting",
              keywords: ["polish", "cleanup", "clean up", "swap", "replace", "ums", "filler", "grammar", "faster", "speed", "insert"],
              description: "Your words appear right away; Verbose swaps in the cleaned-up version a moment later", target: .page(.keyboard)),
        .init(id: "keyboardLiveWords", section: "Keyboard", label: "Show words as you speak",
              keywords: ["live words", "preview", "streaming", "real time", "transcript", "see words"],
              description: "The keyboard shows your words while you talk", target: .page(.keyboard)),
        .init(id: "keyboardDictateButton", section: "Keyboard", label: "Dictate button",
              keywords: ["dictate button", "start button", "size", "large", "position", "left", "right", "center", "left-handed", "one-handed", "thumb", "outline", "filled", "butter"],
              description: "Size, position, and style of the keyboard's dictate button", target: .page(.keyboard)),
        .init(id: "keyboardIslandWords", section: "Keyboard", label: "Show words in the Dynamic Island",
              keywords: ["dynamic island", "live activity", "words", "notch", "live words", "privacy", "lock screen"],
              description: "The expanded Dynamic Island shows your last few words during a take", target: .page(.keyboard)),
        .init(id: "keyboardAlwaysCopy", section: "Keyboard", label: "Also copy each dictation",
              keywords: ["clipboard", "copy", "paste", "pasteboard", "recent", "history", "missed", "keep"],
              description: "Each keyboard dictation also goes on the clipboard", target: .page(.keyboard)),
        .init(id: "keyboardLowerAudio", section: "Keyboard", label: "Lower other audio while Verbose listens",
              keywords: ["duck", "music", "spotify", "youtube", "podcast", "volume", "quiet", "background sound"],
              description: "Other sound drops to a whisper so it doesn't reach the microphone", target: .page(.keyboard)),
        .init(id: "keyboardFullAccess", section: "Keyboard", label: "Allow Full Access for the keyboard", keywords: ["full access", "permission", "privacy"],
              description: "Lets the keyboard start a session and receive your words", target: .page(.keyboard)),

        // Transcription
        .init(id: "quality", section: "Transcription", label: "Quality", keywords: ["model", "accuracy", "speed", "preset", "language"],
              description: "Which transcription model runs on this iPhone"),
        .init(id: "cleanup", section: "Transcription", label: "Cleanup for keyboard dictation", keywords: ["cleanup", "ums", "filler", "grammar", "polish", "dictation"],
              description: "How much keyboard dictations are tidied"),
        .init(id: "spokenCorrections", section: "Transcription", label: "Understand spoken corrections",
              keywords: ["scratch that", "delete the last sentence", "start over", "actually", "no wait", "self-correction", "correction", "undo", "never mind"],
              description: "Say \u{201C}scratch that,\u{201D} \u{201C}delete the last sentence,\u{201D} or \u{201C}let me start over\u{201D} to fix what you said"),
        .init(id: "cloudCleanup", section: "Transcription", label: "Cloud cleanup",
              keywords: ["cloud", "claude", "anthropic", "openai", "chatgpt", "gpt", "api key", "keychain", "model", "grammar", "ai"],
              description: "Clean up with your own Anthropic or OpenAI key; off by default"),
        .init(id: "speakers", section: "Transcription", label: "Identify speakers", keywords: ["diarization", "voices", "people", "who spoke"]),
        .init(id: "recognizeVoices", section: "Transcription", label: "Recognize voices I\u{2019}ve named",
              keywords: ["voice match", "speaker names", "suggest", "people", "remember", "voices"],
              description: "Suggests names for voices you named; kept on this iPhone only"),
        .init(id: "clearVoices", section: "Transcription", label: "Clear saved voices", keywords: ["delete", "forget", "voices", "speakers"]),
        .init(id: "applyDictionary", section: "Transcription", label: "Apply Dictionary", keywords: ["words", "names", "spelling", "corrections"]),
        .init(id: "nameAndSort", section: "Transcription", label: "Name and sort recordings", keywords: ["titles", "tags", "kind", "auto label", "apple intelligence"],
              description: "Suggests a title, kind, and tags when a transcript is ready"),
        .init(id: "hideFiller", section: "Transcription", label: "Hide filler lines", keywords: ["um", "uh", "filler", "clean"],
              description: "Lines that are only \u{201C}um\u{201D} or \u{201C}uh\u{201D} stay out of view"),
        .init(id: "mainSpeaker", section: "Transcription", label: "Main speaker only", keywords: ["background voices", "speakers", "focus"],
              description: "In voice memos, other voices fold into a Background voices section"),
        .init(id: "skipSponsors", section: "Transcription", label: "Skip sponsor reads",
              keywords: ["sponsor", "sponsors", "ads", "ad read", "advertisement", "promo code", "podcast", "youtube", "skip"],
              description: "Playback jumps past sponsor reads in podcasts and videos"),
        .init(id: "audioTracks", section: "Transcription", label: "Files with several audio tracks",
              keywords: ["multiple audio tracks", "mkv", "video", "language", "commentary", "mix", "separate", "speakers", "import"],
              description: "Mix every track, or keep each track as a speaker"),

        // Sync and data
        .init(id: "sync", section: "Sync and data", label: "iCloud sync", keywords: ["cloud", "mac", "sync", "backup", "devices"],
              description: "Match your library with your Mac"),
        .init(id: "export", section: "Sync and data", label: "Export everything", keywords: ["backup", "download", "zip", "markdown", "json"],
              description: "Markdown and JSON in one zip"),
        .init(id: "deleteAll", section: "Sync and data", label: "Delete all data", keywords: ["erase", "reset", "remove", "wipe"]),

        // Support
        .init(id: "whatsNew", section: "Support", label: "What's new", keywords: ["release notes", "changes", "changelog", "version", "build", "update", "new features"],
              description: "What each build added", target: .page(.whatsNew)),
        .init(id: "support", section: "Support", label: "Contact support", keywords: ["help", "email", "problem", "bug"]),
        .init(id: "feedback", section: "Support", label: "Share feedback", keywords: ["idea", "suggestion", "email"]),
        .init(id: "log", section: "Support", label: "Send diagnostic log", keywords: ["logs", "debug", "diagnostics", "bug"],
              description: "7 days of app events, without links or folder names"),
        .init(id: "privacy", section: "Support", label: "Privacy policy", keywords: ["data", "legal"]),
        .init(id: "terms", section: "Support", label: "Terms of use", keywords: ["legal", "terms of service"]),
        .init(id: "share", section: "Support", label: "Share Verbose", keywords: ["invite", "recommend", "friend"]),
        .init(id: "acknowledgements", section: "Support", label: "Acknowledgements", keywords: ["ffmpeg", "lgpl", "open source", "license", "credits"],
              description: "Open-source software in Verbose and its licenses"),

        // Welcome tour
        .init(id: "tourOnLaunch", section: "Welcome tour", label: "Show the tour when Verbose opens", keywords: ["onboarding", "welcome", "launch", "intro"]),
        .init(id: "tour", section: "Welcome tour", label: "Show Tour", keywords: ["onboarding", "welcome", "intro", "walkthrough"]),
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
        case "look": return AppLook.current.label
        case "appearance": return app.appearance == "light" ? "Light" : app.appearance == "dark" ? "Dark" : "Match system"
        case "limitMotion": return onOff(d.bool(forKey: MotionPreference.key))
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
        case "keyboardDictateButton":
            let b = DictateButton.read(KeyboardBridge.defaults)
            return b.size.title + " · " + b.position.title
        case "keyboardIslandWords": return onOff(KeyboardBridge.defaults?.bool(forKey: Ribbon.islandWordsKey) ?? false)
        case "quality": return app.preset.title
        case "cloudCleanup": return onOff(CloudCleanup.enabled)
        case "speakers": return onOff(app.identifySpeakers)
        case "recognizeVoices": return onOff(SpeakerVoices.enabled)
        case "applyDictionary": return onOff(app.applyDictionary)
        case "nameAndSort": return onOff(d.object(forKey: AutoLabel.enabledKey) as? Bool ?? true)
        case "hideFiller": return onOff(d.object(forKey: Transcript.hideFillerKey) as? Bool ?? true)
        case "mainSpeaker": return onOff(d.bool(forKey: Transcript.mainSpeakerOnlyKey))
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

// MARK: - Field

/// The search field under the Settings title: the website's wash capsule (`PhoneSearchField`).
struct SettingsSearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        PhoneSearchField(text: $text, prompt: "Search settings", onSubmit: onSubmit)
    }
}

// MARK: - Results

/// Results grouped by section ("◇ KEYBOARD · 3"), each group a card of rows with the query highlighted.
struct SettingsSearchResults: View {
    var query: String
    var value: (String) -> String?
    var onPick: (SettingsSearchEntry) -> Void
    @ScaledMetric(relativeTo: .caption) private var overline: CGFloat = 11

    var body: some View {
        let groups = SettingsSearchIndex.search(query)
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text("No settings match \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}.")
                    .font(.body).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 24)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.section) \u{00B7} \(group.entries.count)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.lookDim)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("\(group.section), \(group.entries.count) \(group.entries.count == 1 ? "result" : "results")")
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, entry in
                            if i > 0 { Rectangle().fill(.lookHairline).frame(height: 1).padding(.leading, 14) }
                            Button { onPick(entry) } label: {
                                SettingsSearchResultRow(entry: entry, query: query, value: value(entry.id))
                            }
                            .buttonStyle(SettingsRowPress())
                        }
                    }
                    .cardSurface(radius: Radius.row)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                }
                .padding(.top, 22)
            }
            Text("Clear the search to see every setting.")
                .font(.footnote).foregroundStyle(.lookMute)
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
                Text(labelHit.text).font(.body).foregroundStyle(.lookInk)
                    .fixedSize(horizontal: false, vertical: true)
                if !labelHit.matched, let descHit, descHit.matched {
                    Text(descHit.text).font(.footnote).foregroundStyle(.lookMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if let value { Text(value).font(.body).foregroundStyle(.lookMute).lineLimit(1) }
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
        case .page(.aboutMe): return "Opens About me"
        case .page(.dictionary): return "Opens Dictionary"
        case .page(.keyboard): return "Opens Keyboard settings"
        case .page(.snippets): return "Opens Snippets"
        case .page(.actionButton): return "Opens Action button settings"
        case .page(.appearance): return "Opens Appearance"
        case .page(.whatsNew): return "Opens What's new"
        }
    }

    /// `text` with each occurrence of the whole query (or else of each query word) on a persimmon tint.
    static func highlighted(_ text: String, query: String) -> (text: AttributedString, matched: Bool) {
        var out = AttributedString(text)
        let full = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needles = text.localizedStandardContains(full) ? [full] : full.split(whereSeparator: \.isWhitespace).map(String.init)
        var matched = false
        for needle in needles where !needle.isEmpty {
            var from = out.startIndex
            while from < out.endIndex,
                  let r = out[from...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                out[r].backgroundColor = Ink.persimmonTint
                out[r].foregroundColor = Ink.ink
                matched = true
                from = r.upperBound
            }
        }
        return (out, matched)
    }
}

// MARK: - Row target

extension View {
    /// Gives a Settings row the id search scrolls to, and a brief persimmon-tint wash while `flash` names it.
    func settingsSearchTarget(_ id: String, flash: String?) -> some View {
        self
            .background(Ink.persimmonTint.opacity(flash == id ? 1 : 0).allowsHitTesting(false))
            .animation(Motion.fade, value: flash == id)
            .id(id)
    }
}
