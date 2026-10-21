import SwiftUI
import AppKit

// The Settings window's building blocks: the panes and their sidebar groups, the searchable index every row is
// built from, and the row, group, and header views (paper page, reader-white cards, mono overlines, serif titles).

// MARK: - Panes

/// A Settings pane. Raw values persist in "settingsTab"; `general`, `dictate`, `actions`, and `storage` keep the
/// values the old tabbed window used, so links from the floating button and the welcome tour still land.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictate, floatingButton, actions
    case models = "transcription", speakers, captions
    case watched, export, storage, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictate: return "Dictation"
        case .floatingButton: return "Floating button"
        case .actions: return "Actions"
        case .models: return "Models and language"
        case .speakers: return "Speakers and your voice"
        case .captions: return "Live captions"
        case .watched: return "Watched folders"
        case .export: return "Export"
        case .storage: return "Storage and iCloud"
        case .about: return "About"
        }
    }

    /// The sidebar group, also the pane's overline.
    var group: String {
        switch self {
        case .general, .dictate, .floatingButton, .actions: return "App"
        case .models, .speakers, .captions: return "Transcription"
        case .watched, .export, .storage, .about: return "Files"
        }
    }

    /// One line under the pane's title.
    var blurb: String {
        switch self {
        case .general: return "How Verbatim looks, sounds, and stays up to date."
        case .dictate: return "Dictate into any app: the hotkey, cleanup, the tone for each kind of app, and snippets."
        case .floatingButton: return "The small button at the edge of your screen that starts and pastes a dictation."
        case .actions: return "Instructions you save once and run on any text: a selection in any app, a dictation, or a whole transcript. Everything runs on this Mac."
        case .models: return "Which model transcribes your recordings, and what Verbatim does to a transcript when it's ready."
        case .speakers: return "Who's talking in a recording, how Verbatim knows your voice, and which microphone records you."
        case .captions: return "Live captions for whatever your Mac is playing or hearing."
        case .watched: return "Drop audio or video into a watched folder and Verbatim transcribes it, then exports the results where you choose."
        case .export: return "What goes into an export or a copy: which text, speaker names, and timecodes."
        case .storage: return "Where your library, models, and kept video live, and whether they sync with your iPhone."
        case .about: return "Version, help, and the fine print."
        }
    }

    static let groups: [(title: String, tabs: [SettingsTab])] = [
        ("App", [.general, .dictate, .floatingButton, .actions]),
        ("Transcription", [.models, .speakers, .captions]),
        ("Files", [.watched, .export, .storage, .about]),
    ]
}

// MARK: - Search index

/// One searchable setting. Rows are built from these (label and description come from here), so what search
/// finds is exactly what the pane shows.
struct SettingsEntry: Identifiable, Hashable {
    let id: String
    let section: SettingsTab
    let label: String
    let detail: String
    let keywords: String

    init(_ id: String, _ section: SettingsTab, _ label: String, _ detail: String = "", keywords: String = "") {
        self.id = id; self.section = section; self.label = label; self.detail = detail; self.keywords = keywords
    }
}

enum SettingsIndex {
    static let all: [SettingsEntry] = [
        // General
        .init("general.appearance", .general, "Appearance", "Match the system, or always light or dark.", keywords: "dark mode light theme color"),
        .init("general.limitMotion", .general, "Limit animation", "Fades instead of movement; illustrations stay still. Always on when Reduce Motion is on in System Settings.", keywords: "reduce motion accessibility animations"),
        .init("general.menuBar", .general, "Show in menu bar", "Record from anywhere with the menu bar item, or press ⌥⇧R while Verbatim is running.", keywords: "menubar status item record shortcut"),
        .init("general.sounds", .general, "Sounds", "A short chime when recording starts and a tick when a transcript is ready. Off automatically with Reduce Motion.", keywords: "chime audio feedback"),
        .init("general.welcomeCard", .general, "Show the Method cards on Home", "Capture, Refine, and Understand, with your latest counts.", keywords: "welcome card hero intro method capture refine understand"),
        .init("general.tourOnLaunch", .general, "Show the welcome tour when Verbatim opens", keywords: "onboarding launch"),
        .init("general.tour", .general, "Welcome tour", "Walk through the basics again.", keywords: "onboarding intro help"),
        .init("general.autoUpdate", .general, "Check for updates automatically", keywords: "sparkle update"),
        .init("general.beta", .general, "Get beta builds", "Beta builds arrive with every change to Verbatim; leave this off for tested releases only.", keywords: "update prerelease"),
        .init("general.version", .general, "Check for updates", "A check sends your IP address and Verbatim's version to GitHub, nothing else.", keywords: "version update check now"),
        .init("general.name", .general, "Your name", "Shown on the You page.", keywords: "profile name you"),
        .init("general.aboutMe", .general, "About me", "A few lines about you. Verbatim uses this to spell names and word titles and summaries.", keywords: "profile context bio titles summaries you"),
        .init("general.countSites", .general, "Count websites", "When you dictate into Safari, Chrome, Arc, Edge, or Brave, the You page shows which websites, by domain only, never full addresses. macOS asks once per browser.", keywords: "domains browser where you dictate activity stats privacy"),

        // Dictation
        .init("dictate.enabled", .dictate, "Dictate anywhere", "Hold or press your hotkey in any app and Verbatim types what you say.", keywords: "dictation voice typing"),
        .init("dictate.hotkey", .dictate, "Hotkey", "The key that starts dictation.", keywords: "shortcut key fn option"),
        .init("dictate.mode", .dictate, "Mode", "Hold to talk, or press once to start and again to stop. Press Esc to cancel.", keywords: "push to talk toggle hands-free"),
        .init("dictate.shortcuts", .dictate, "Other shortcuts", "Paste last dictation, copy last dictation, and the Thought pad.", keywords: "paste again thought pad hotkey"),
        .init("dictate.recall", .dictate, "Recent dictations", "Shows your last 10 dictations in any app, so you can copy one or paste it again. Press 1–0 to copy, or hold ⇧ to paste. While it's set, the shortcut does nothing else, such as Paste Style (⌥⌘V) in Pages and TextEdit.", keywords: "history recent clipboard copy paste again missed failed lost shortcut hotkey panel"),
        .init("dictate.alwaysCopy", .dictate, "Also copy each dictation to the clipboard", "Each dictation stays on the clipboard after it's pasted, instead of what you copied before.", keywords: "clipboard copy keep paste pasteboard"),
        .init("dictate.maxMinutes", .dictate, "Stop dictating after", "A minute before, the button says so. Your words up to the stop are pasted, never thrown away.", keywords: "limit time minutes"),
        .init("dictate.cleanup", .dictate, "Cleanup", "How much Verbatim tidies what you say before it's pasted.", keywords: "polish clean literal filler punctuation"),
        .init("dictate.cloud", .dictate, "Cloud cleanup", "Clean up dictation with Anthropic Claude or OpenAI, using your own API key. Off by default.", keywords: "claude anthropic openai chatgpt gpt api cloud grammar ai"),
        .init("dictate.cloudProvider", .dictate, "Provider", "Who cleans up your words when cloud cleanup is on.", keywords: "anthropic openai claude gpt cloud"),
        .init("dictate.cloudKey", .dictate, "API key", "Your own key, saved in your Keychain on this Mac only.", keywords: "api key keychain secret cloud"),
        .init("dictate.cloudModel", .dictate, "Model", "The model that cleans up your words.", keywords: "haiku gpt mini cloud model"),
        .init("dictate.cleanupHelp", .dictate, "Punctuation, lists, and paragraphs by voice", "Say “comma,” “period,” “new line,” or “new paragraph.” Announce a list to get one.", keywords: "comma period list bullet numbered"),
        .init("dictate.styles", .dictate, "Style for each kind of app", "Formal, casual, very casual, or as spoken, by app.", keywords: "tone email chat messages code"),
        .init("dictate.context", .dictate, "Use the text around your cursor", "Verbatim reads the app's name and the text near your cursor so names are spelled right and the tone matches. Password fields are never read, and nothing leaves this Mac.", keywords: "context privacy"),
        .init("dictate.boost", .dictate, "Listen for my Dictionary words", "Parakeet listens for the words in your Dictionary as you speak (a small extra model downloads once). Works best with fewer than 100 words.", keywords: "vocabulary accuracy boost"),
        .init("dictate.autoLearn", .dictate, "Learn from my fixes", "When you correct a name or term right after it's pasted, the floating button asks whether to remember it. Nothing is learned unless you say yes.", keywords: "dictionary corrections learn"),
        .init("dictate.snippets", .dictate, "Snippets", "Say a trigger like “my calendar link” and Verbatim pastes the saved text: a link, an address, a sign-off.", keywords: "text expansion shortcut"),
        .init("dictate.accessibility", .dictate, "Accessibility access", "macOS requires this so Verbatim can notice the hotkey, see which app and text field you're in, and press ⌘V there.", keywords: "permission privacy system settings"),
        .init("dictate.typeInstead", .dictate, "Type instead of paste", "For apps that block ⌘V or paste the wrong thing.", keywords: "paste clipboard typing apps"),

        // Floating button
        .init("float.show", .floatingButton, "Show the floating button", "Click it to start, click again to paste. Drag it to the bottom, left, or right edge; right-click it for options.", keywords: "flow bar ribbon pill"),
        .init("float.style", .floatingButton, "Style", "Paper is a light tab with ink type. Ink is a dark tab with paper type.", keywords: "look paper ink appearance"),
        .init("float.mark", .floatingButton, "Voice mark", "Moves with your voice while you dictate.", keywords: "bars rings level meter"),
        .init("float.liveWords", .floatingButton, "Show words as you speak", "A preview of your words in the floating button while you dictate, recognized on this Mac. What's pasted still comes from Verbatim's own transcription.", keywords: "live words preview streaming"),

        // Actions
        .init("actions.list", .actions, "Saved actions", "Name, instruction, and how long text is handled.", keywords: "prompt rewrite summarize instruction"),
        .init("actions.add", .actions, "Add an action", keywords: "new create"),
        .init("actions.restore", .actions, "Restore built-in actions", "Replaces your actions with the eight that come with Verbatim.", keywords: "reset defaults"),

        // Models and language
        .init("models.quality", .models, "Quality", "Parakeet is the default: fast on Apple silicon with word timings. Whisper is the alternate for languages Parakeet misses.", keywords: "model engine whisper parakeet language accuracy speed"),
        .init("models.engine", .models, "Engine and model", "Shown when Quality is Advanced.", keywords: "whisper parakeet advanced"),
        .init("models.applyDictionary", .models, "Apply Dictionary to new transcripts", "Only words listed under “Heard as” are replaced, and every fix shows on the transcript.", keywords: "vocabulary corrections replace"),
        .init("models.builtInVocabulary", .models, "Built-in vocabulary", "Verbatim spells about 500 modern words right, like ChatGPT, GitHub, and macOS. Your Dictionary always wins. Turn off single terms on the Dictionary page.", keywords: "modern words brands apps tech terms spelling names chatgpt iphone youtube boost"),
        .init("models.projectVocab", .models, "Project vocabulary", "Dictionary fixes you save from a transcript inside a project apply only to that project. Off, every fix applies everywhere.", keywords: "dictionary project scope"),
        .init("models.nameSort", .models, "Name and sort recordings", "Apple Intelligence suggests a title, kind, and tags when a transcript is ready. Anything you rename or change stays.", keywords: "auto label title tags kind"),
        .init("models.summary", .models, "Write a summary when a transcript finishes", "Apple Intelligence writes a short overview and key points at the top of the transcript. A summary you edit stays. When this is off, choose Actions › Summarize.", keywords: "summary summaries overview key points recap"),
        .init("models.hideFiller", .models, "Hide filler lines", "Lines that are only “um” or “uh” stay out of view. Nothing is deleted; Show brings them back.", keywords: "um uh filler"),
        .init("models.offline", .models, "Where models run", "Models download once from Hugging Face and run on this Mac. Transcription never leaves your computer.", keywords: "privacy offline download hugging face"),

        // Speakers and your voice
        .init("speakers.voiceProfile", .speakers, "Voice profile", "Teach Verbatim your voice so transcripts label you as You.", keywords: "enroll my voice recognize me you"),
        .init("speakers.onlyMyVoice", .speakers, "Only keep my voice in dictation", "When someone nearby talks while you dictate, Verbatim pastes only your words.", keywords: "voice filter background people dictation me"),
        .init("speakers.identify", .speakers, "Identify speakers", "Labels turns as Speaker 1, Speaker 2… so you can name them. Runs on this Mac and adds time to each transcript.", keywords: "diarization speaker labels who"),
        .init("speakers.mainOnly", .speakers, "Main speaker only", "Other voices fold into a Background voices section under the transcript.", keywords: "background voices"),
        .init("speakers.mic", .speakers, "Record from", "Built-in mic, a USB interface, AirPods, or your iPhone (Continuity). “System default” follows the Mac's Sound settings.", keywords: "microphone input device airpods"),

        // Live captions
        .init("captions.size", .captions, "Text size", "How big captions read in the captions bar.", keywords: "subtitles captions live font large"),
        .init("captions.soon", .captions, "Show the time in the header", "Open live captions from Home, the menu bar, or ⌥⌘C. Captions are made on this Mac.", keywords: "subtitles captions live timecode clock"),
        .init("captions.above", .captions, "Keep captions above full-screen apps", keywords: "subtitles captions floating window full screen"),

        // Watched folders
        .init("watched.folders", .watched, "Watched folders", "New audio and video in these folders is transcribed automatically.", keywords: "watch folder automatic import hot folder"),
        .init("watched.add", .watched, "Add folder…", "Files already in the folder are left alone; anything new is transcribed.", keywords: "watch new folder"),
        .init("watched.activity", .watched, "Open activity", "What each watched folder has transcribed and exported.", keywords: "log history"),
        .init("watched.enabled", .watched, "Watch this folder", "Pause a folder without removing it.", keywords: "pause resume"),
        .init("watched.subfolders", .watched, "Include subfolders", keywords: "recursive nested"),
        .init("watched.location", .watched, "Folder", "Show it in Finder, or stop watching it.", keywords: "remove stop finder reveal"),
        .init("watched.formats", .watched, "Export formats", "SRT, Plain text, VTT, Word, Markdown, or JSON, written when each transcript is ready.", keywords: "auto-export subtitles srt vtt docx markdown json"),
        .init("watched.exportOptions", .watched, "Auto-export uses your Export settings", "Which text, speaker names, and timecodes come from Settings › Export.", keywords: "timecode timecodes speakers options"),
        .init("watched.saveTo", .watched, "Save to", "The folder exports go to, or next to the original file.", keywords: "destination output folder"),
        .init("watched.fileName", .watched, "File name", "{original name}, {title}, and {date} fill in for each file.", keywords: "pattern naming rename"),
        .init("watched.notify", .watched, "When it's done", "A notification when a file is transcribed and exported.", keywords: "notification alert notify"),

        // Export
        .init("export.source", .export, "Text", "Document is paragraphs with your edits and polish. Transcript is line by line, as transcribed.", keywords: "document transcript source"),
        .init("export.speakers", .export, "Speaker names", "Each speaker's name before their words.", keywords: "labels speakers"),
        .init("export.timecodes", .export, "Include timecodes", "A timecode at the start of every line, like [00:12:04]. Subtitles always have them.", keywords: "timecode timestamps time"),
        .init("export.single", .export, "One paragraph", "Everything joined into a single paragraph.", keywords: "line breaks join"),
        .init("export.provenance", .export, "Add a “transcribed with” footer", "Title, source, length, model, and date at the end.", keywords: "provenance credit footer"),
        .init("export.watched", .export, "Watched folders export with these options", keywords: "auto-export timecode"),

        // Storage and iCloud
        .init("storage.icloud", .storage, "Sync with iCloud", "Transcripts, notes, projects, and the Dictionary match your iPhone.", keywords: "icloud sync iphone cloud"),
        .init("storage.library", .storage, "Transcripts and audio", "Your library on this Mac.", keywords: "finder reveal files location folder"),
        .init("storage.models", .storage, "Models", "Downloaded transcription models.", keywords: "finder reveal disk space"),
        .init("storage.keepFolder", .storage, "Keep folder", "Where kept video and audio from links go.", keywords: "keep download video folder"),
        .init("storage.keepVideo", .storage, "Keep the video of every link I transcribe", "Video is saved as MP4 (H.264, up to 1080p) with its sound; audio as M4A. Nothing is re-encoded.", keywords: "keep download youtube mp4"),
        .init("storage.deleteAll", .storage, "Delete all data", "Removes every transcript, dictation, and recording, plus projects, the Dictionary, snippets, Activity, the Thought pad, and downloaded models. Settings stay.", keywords: "erase reset privacy remove"),

        // About
        .init("about.version", .about, "Version", keywords: "build number"),
        .init("about.support", .about, "Help", "Write to support.", keywords: "contact email support help"),
        .init("about.log", .about, "Diagnostic log", "A record of what Verbatim did, to help fix problems. It keeps 7 days, leaves out links and folder names, and stays on this Mac unless you send it.", keywords: "logs debug send support"),
        .init("about.legal", .about, "Legal", "Privacy, Terms, and Refunds.", keywords: "privacy policy terms refunds"),
    ]

    private static let byID: [String: SettingsEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func entry(_ id: String) -> SettingsEntry? { byID[id] }

    /// The query's words, lowercased. Every word has to match somewhere in an entry.
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    /// Entries matching every word of the query (label, description, keywords, or pane title), in pane order.
    static func search(_ query: String) -> [SettingsEntry] {
        let words = terms(query)
        guard !words.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: SettingsTab.allCases.enumerated().map { ($1, $0) })
        return all.filter { e in
            let hay = [e.label, e.detail, e.keywords, e.section.title].joined(separator: " ")
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        .enumerated()
        .sorted { a, b in
            let pa = order[a.element.section] ?? 0, pb = order[b.element.section] ?? 0
            return pa != pb ? pa < pb : a.offset < b.offset
        }
        .map(\.element)
    }

    /// Matching panes with how many of their settings match, in sidebar order.
    static func sectionCounts(_ results: [SettingsEntry]) -> [(tab: SettingsTab, count: Int)] {
        SettingsTab.allCases.compactMap { tab in
            let n = results.filter { $0.section == tab }.count
            return n > 0 ? (tab, n) : nil
        }
    }

    /// `s` with every occurrence of each query word on a persimmon tint.
    static func highlighted(_ s: String, terms: [String]) -> AttributedString {
        var a = AttributedString(s)
        for t in terms {
            var from = s.startIndex
            while from < s.endIndex, let r = s.range(of: t, options: [.caseInsensitive, .diacriticInsensitive], range: from..<s.endIndex) {
                if let ar = Range(r, in: a) {
                    a[ar][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Ink.persimmonTint
                    a[ar][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Ink.ink
                }
                from = r.upperBound
            }
        }
        return a
    }
}

// MARK: - Search and navigation state

/// The window's search text and the row a search result asked to show. Shared so the UI self-test can drive it.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    // @Changed, not @Published: text fields write their binding back on every update (see Changed.swift).
    @Changed var query = ""
    /// A row to scroll to once its pane is showing.
    @Changed var focusID: String? = nil
    /// The row that's briefly tinted after a search result opened it.
    @Changed var flashID: String? = nil
    weak var window: NSWindow?

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Opens a setting's pane and shows the row.
    func open(_ e: SettingsEntry) {
        UserDefaults.standard.set(e.section.rawValue, forKey: "settingsTab")
        query = ""
        focusID = e.id
    }

    func flash(_ id: String) {
        flashID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if flashID == id { flashID = nil }
        }
    }
}

// MARK: - Page structure

/// A mono overline, the pane's serif title, and its one-line description.
struct SettingsPaneHeader: View {
    var overline: String
    var title: String
    var blurb: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(overline.uppercased()).font(Ink.mono(11, weight: .medium)).tracking(2).foregroundStyle(Ink.mute)
            Text(title).font(Ink.serif(40)).foregroundStyle(Ink.ink).padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            if let blurb {
                Text(blurb).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Ink.dim)
                    .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }
}

/// A scrolling pane: header, then groups. Scrolls to and flashes the row a search result opened.
struct SettingsPane<Content: View>: View {
    var tab: SettingsTab
    @ViewBuilder var content: () -> Content
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsPaneHeader(overline: tab.group, title: tab.title, blurb: tab.blurb)
                    content()
                }
                .padding(.horizontal, 48).padding(.top, 40).padding(.bottom, 40)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .onAppear { reveal(proxy) }
            .onChange(of: model.focusID) { _, _ in reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = model.focusID, SettingsIndex.entry(id)?.section == tab else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(limitMotion ? nil : Motion.nav) { proxy.scrollTo(id, anchor: .center) }
            model.flash(id)
            if model.focusID == id { model.focusID = nil }
        }
    }
}

/// An optional mono overline over a reader-white card of rows, with an optional note under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).font(Ink.mono(11, weight: .medium)).tracking(1.8).foregroundStyle(Ink.mute).padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                // Each row draws a hairline above itself; the first one tucks under the card's edge.
                .padding(.top, -1)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .cardSurface(radius: 16)
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

/// The hairline between rows in a card.
struct RowRule: View {
    var body: some View { Rectangle().fill(Ink.hairline.opacity(0.6)).frame(height: 1) }
}

/// Marks a view as the target of a search result: it can be scrolled to, and it tints briefly when opened.
struct SettingsAnchor: ViewModifier {
    var id: String
    var radius: CGFloat = 0
    @ObservedObject private var model = SettingsModel.shared
    func body(content: Content) -> some View {
        content
            .background(Ink.persimmonTint.opacity(model.flashID == id ? 1 : 0), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(.easeOut(duration: 0.6), value: model.flashID == id)
            .id(id)
    }
}
extension View {
    func settingsAnchor(_ id: String, radius: CGFloat = 0) -> some View { modifier(SettingsAnchor(id: id, radius: radius)) }
}

/// One setting: label and description from the index on the left, its control on the right (or below, `stacked`).
struct SettingsRow<Control: View>: View {
    var id: String
    /// Replaces the index's description when it depends on state (a status, the chosen option's note).
    var detail: String? = nil
    var detailColor: Color = Ink.mute
    var stacked = false
    @ViewBuilder var control: () -> Control

    init(_ id: String, detail: String? = nil, detailColor: Color = Ink.mute, stacked: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.id = id; self.detail = detail; self.detailColor = detailColor; self.stacked = stacked; self.control = control
    }

    private var entry: SettingsEntry? { SettingsIndex.entry(id) }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 12) { text; control() }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    control()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsAnchor(id)
        .overlay(alignment: .top) { RowRule() }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry?.label ?? id).font(.system(size: 14)).foregroundStyle(Ink.ink)
            let d = detail ?? entry?.detail ?? ""
            if !d.isEmpty {
                Text(d).font(.system(size: 12.5)).foregroundStyle(detailColor).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
extension SettingsRow where Control == EmptyView {
    init(_ id: String, detail: String? = nil, detailColor: Color = Ink.mute) {
        self.init(id, detail: detail, detailColor: detailColor, stacked: false) { EmptyView() }
    }
}

/// A row whose control is a switch, labelled for VoiceOver with the row's label.
struct SettingsToggleRow: View {
    var id: String
    @Binding var isOn: Bool
    var detail: String? = nil
    var disabled = false
    init(_ id: String, isOn: Binding<Bool>, detail: String? = nil, disabled: Bool = false) {
        self.id = id; self._isOn = isOn; self.detail = detail; self.disabled = disabled
    }
    var body: some View {
        SettingsRow(id, detail: detail) {
            Toggle(SettingsIndex.entry(id)?.label ?? id, isOn: $isOn)
                .toggleStyle(.switch).labelsHidden().tint(Ink.switchOn).disabled(disabled)
        }
    }
}

/// Lays out a LabeledContent as label left, content right, for rows hosted outside a Form.
struct SettingsLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label.font(.system(size: 13.5)).foregroundStyle(Ink.ink)
            Spacer(minLength: 12)
            configuration.content
        }
    }
}

/// A toggle as label left, switch right, for rows hosted outside a Form.
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.font(.system(size: 13.5)).foregroundStyle(Ink.ink)
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden().tint(Ink.switchOn)
        }
    }
}

extension View {
    /// Form-style rows (LabeledContent, Toggle, notes) shared with other screens, laid out for a Settings card.
    func settingsFormRows() -> some View {
        labeledContentStyle(SettingsLabeledStyle()).toggleStyle(SettingsToggleStyle())
    }
}

/// A small text pill: format chips, status tags.
struct SettingsChip: View {
    var title: String
    var on: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Text(title)
            .font(.system(size: 12.5))
            .foregroundStyle(on ? Ink.onInteractive : Ink.ink)
            .padding(.horizontal, 11).frame(height: 28)
            .background(on ? Ink.interactive : Ink.ink.opacity(hover ? 0.12 : 0.08), in: Capsule())
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(Motion.touch, value: hover)
            .tapArea(action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
    }
}
