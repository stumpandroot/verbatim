import SwiftUI

// MARK: - Index

/// Where a search result leads: a row on the Settings page (scroll to it and flash it), or a subpage to push.
enum SettingsSearchTarget: Equatable {
    case row
    case page(SettingsSubpage)
}

/// The Settings subpages a result can open. SettingsScreen maps each one to its navigation destination.
enum SettingsSubpage: Equatable {
    case aboutMe, dictionary, keyboard, snippets
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
        .init(id: "language", section: "Personalization", label: "Language", keywords: ["english", "automatic", "locale", "multilingual"],
              description: "English or automatic"),
        .init(id: "voice", section: "Personalization", label: "Your voice", keywords: ["speaker", "recognize", "me", "voice print"],
              description: "Recognize you in recordings"),
        .init(id: "aboutMe", section: "Personalization", label: "About me", keywords: ["profile", "context", "titles", "summaries", "bio"],
              description: "Context for titles and summaries", target: .page(.aboutMe)),
        .init(id: "dictionary", section: "Personalization", label: "Dictionary", keywords: ["words", "names", "spelling", "vocabulary", "custom words"],
              description: "Names and words to spell your way", target: .page(.dictionary)),
        .init(id: "snippets", section: "Personalization", label: "Snippets in the keyboard", keywords: ["snippets", "trigger", "text expansion", "shortcut", "saved text"],
              description: "Say a trigger, get your saved text", target: .page(.snippets)),
        .init(id: "summaries", section: "Personalization", label: "Summaries", keywords: ["recap", "overview", "summary"],
              description: "For recordings over 5 minutes"),
        .init(id: "appearance", section: "Personalization", label: "Appearance", keywords: ["dark mode", "light mode", "theme", "night", "color"],
              description: "Match the system, light, or dark"),
        .init(id: "limitMotion", section: "Personalization", label: "Limit animation", keywords: ["reduce motion", "animation", "accessibility", "movement"],
              description: "Fades instead of movement; illustrations stay still"),

        // Keyboard (Settings › Keyboard)
        .init(id: "keyboard", section: "Keyboard", label: "Set up the Verbatim keyboard", keywords: ["keyboard", "dictate", "add keyboard", "globe key", "extension"],
              description: "Dictate into any app", target: .page(.keyboard)),
        .init(id: "keyboardTimeout", section: "Keyboard", label: "End keyboard sessions after", keywords: ["session", "timeout", "idle", "microphone", "minutes"],
              description: "How long a session waits before it turns off the microphone", target: .page(.keyboard)),
        .init(id: "keyboardAutoStart", section: "Keyboard", label: "Start dictating when you come back",
              keywords: ["auto start", "listen", "first tap", "second tap", "dictate", "microphone", "return", "switch back"],
              description: "The first tap opens Verbatim and starts listening; no second tap", target: .page(.keyboard)),
        .init(id: "keyboardFullAccess", section: "Keyboard", label: "Allow Full Access for the keyboard", keywords: ["full access", "permission", "privacy"],
              description: "Lets the keyboard start a session and receive your words", target: .page(.keyboard)),

        // Transcription
        .init(id: "quality", section: "Transcription", label: "Quality", keywords: ["model", "accuracy", "speed", "preset", "language"],
              description: "Which transcription model runs on this iPhone"),
        .init(id: "cleanup", section: "Transcription", label: "Cleanup for keyboard dictation", keywords: ["cleanup", "ums", "filler", "grammar", "polish", "dictation"],
              description: "How much keyboard dictations are tidied"),
        .init(id: "speakers", section: "Transcription", label: "Identify speakers", keywords: ["diarization", "voices", "people", "who spoke"]),
        .init(id: "applyDictionary", section: "Transcription", label: "Apply Dictionary", keywords: ["words", "names", "spelling", "corrections"]),
        .init(id: "nameAndSort", section: "Transcription", label: "Name and sort recordings", keywords: ["titles", "tags", "kind", "auto label", "apple intelligence"],
              description: "Suggests a title, kind, and tags when a transcript is ready"),
        .init(id: "hideFiller", section: "Transcription", label: "Hide filler lines", keywords: ["um", "uh", "filler", "clean"],
              description: "Lines that are only \u{201C}um\u{201D} or \u{201C}uh\u{201D} stay out of view"),
        .init(id: "mainSpeaker", section: "Transcription", label: "Main speaker only", keywords: ["background voices", "speakers", "focus"],
              description: "Other voices fold into a Background voices section"),

        // Sync and data
        .init(id: "sync", section: "Sync and data", label: "iCloud sync", keywords: ["cloud", "mac", "sync", "backup", "devices"],
              description: "Match your library with your Mac"),
        .init(id: "export", section: "Sync and data", label: "Export everything", keywords: ["backup", "download", "zip", "markdown", "json"],
              description: "Markdown and JSON in one zip"),
        .init(id: "deleteAll", section: "Sync and data", label: "Delete all data", keywords: ["erase", "reset", "remove", "wipe"]),

        // Support
        .init(id: "support", section: "Support", label: "Contact support", keywords: ["help", "email", "problem", "bug"]),
        .init(id: "feedback", section: "Support", label: "Share feedback", keywords: ["idea", "suggestion", "email"]),
        .init(id: "log", section: "Support", label: "Send diagnostic log", keywords: ["logs", "debug", "diagnostics", "bug"],
              description: "7 days of app events, without links or folder names"),
        .init(id: "privacy", section: "Support", label: "Privacy policy", keywords: ["data", "legal"]),
        .init(id: "terms", section: "Support", label: "Terms of use", keywords: ["legal", "terms of service"]),
        .init(id: "share", section: "Support", label: "Share Verbatim", keywords: ["invite", "recommend", "friend"]),

        // Welcome tour
        .init(id: "tourOnLaunch", section: "Welcome tour", label: "Show the tour when Verbatim opens", keywords: ["onboarding", "welcome", "launch", "intro"]),
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
        case "language": return app.preset == .english ? "English" : "Automatic"
        case "voice": return VoiceProfileStatus.shared.isEnrolled ? "On" : "Set up"
        case "summaries": return onOff(d.object(forKey: Summarizer.autoKey) as? Bool ?? true)
        case "aboutMe": return (d.string(forKey: Profile.aboutMeKey) ?? "").isEmpty ? "Add" : "Added"
        case "dictionary": return "\(app.store.dictionary.count)"
        case "appearance": return app.appearance == "light" ? "Light" : app.appearance == "dark" ? "Dark" : "Match system"
        case "limitMotion": return onOff(d.bool(forKey: MotionPreference.key))
        case "keyboardTimeout":
            let s = app.session.timeoutSeconds
            return s == 0 ? KeyboardSession.label(s) : KeyboardSession.label(s).replacingOccurrences(of: "minutes", with: "min").replacingOccurrences(of: "minute", with: "min")
        case "keyboardAutoStart": return onOff(KeyboardBridge.autoStart)
        case "quality": return app.preset.title
        case "speakers": return onOff(app.identifySpeakers)
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

/// The search field under the Settings title: a paper field with a persimmon ring while focused.
struct SettingsSearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 15

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(Ink.mute)
                .accessibilityHidden(true)
            TextField("Search settings", text: $text, prompt: Text("Search settings").foregroundStyle(Ink.mute))
                .font(.body)
                .foregroundStyle(Ink.ink)
                .tint(Ink.accentText)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .accessibilityLabel("Search settings")
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: glyph + 1))
                        .foregroundStyle(Ink.faint)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12).padding(.trailing, text.isEmpty ? 12 : 0)
        .frame(minHeight: height)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Ink.persimmon : Ink.hairline, lineWidth: focused ? 1.5 : 1)
        )
        .animation(Motion.fade, value: focused)
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
                    .font(.body).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 24)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\u{25C7} \(group.section.uppercased()) \u{00B7} \(group.entries.count)")
                        .font(Ink.mono(overline, weight: .medium)).tracking(1.8).foregroundStyle(Ink.dim)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("\(group.section), \(group.entries.count) \(group.entries.count == 1 ? "result" : "results")")
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, entry in
                            if i > 0 { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 14) }
                            Button { onPick(entry) } label: {
                                SettingsSearchResultRow(entry: entry, query: query, value: value(entry.id))
                            }
                            .buttonStyle(SettingsRowPress())
                        }
                    }
                    .cardSurface(radius: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 22)
            }
            Text("Clear the search to see every setting.")
                .font(.footnote).foregroundStyle(Ink.mute)
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
                Text(labelHit.text).font(.body).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !labelHit.matched, let descHit, descHit.matched {
                    Text(descHit.text).font(.footnote).foregroundStyle(Ink.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if let value { Text(value).font(.body).foregroundStyle(Ink.mute).lineLimit(1) }
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
