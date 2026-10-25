import SwiftUI
import UIKit

/// About me: a few lines of context in UserDefaults. With iCloud sync on, it travels with your name to your Mac
/// (Store.SyncedProfile).
enum Profile {
    static let aboutMeKey = "profile.aboutMe"
    static let aboutMeLimit = 300
}

/// Settings in the website style, close to a native iOS list: the compact serif title, search, a card for You at the
/// top (your initial and your name; it opens the You page, YouScreen.swift), then grouped cards with mono section labels,
/// colored icon squares, values, chevrons, and standard switches. The version sits at the foot.
struct SettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.openURL) private var openURL
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage(MotionPreference.key) private var motionLimited = false
    @AppStorage(AutoLabel.enabledKey) private var autoLabels = true
    @AppStorage(Summarizer.autoKey) private var autoSummary = true
    @AppStorage(Transcript.hideFillerKey) private var hideFiller = true
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false
    @AppStorage(Transcript.skipSponsorsKey) private var skipSponsors = true
    /// Check each recording's language and pick a model that knows it (LanguageCheck.swift). On by default.
    @AppStorage(LanguageDetection.enabledKey) private var detectLanguage = true
    @AppStorage(AudioTracksPreference.key) private var audioTracks = AudioTracksPreference.mix.rawValue
    /// Recognize voices I've named (SpeakerVoices): on device only, never synced.
    @AppStorage(SpeakerVoices.enabledKey) private var recognizeVoices = true
    @State private var savedVoices = 0
    @State private var confirmClearVoices = false
    @State private var showAcknowledgements = false
    /// Show words while you record (MiniRecorder.swift). On by default.
    @AppStorage(RecordingLiveText.enabledKey) private var recordLiveWords = true
    /// Understand spoken corrections, in the App Group so the keyboard's live words follow it.
    @AppStorage(SpokenCorrections.enabledKey, store: SpokenCorrections.store) private var spokenCorrections = true
    /// Dictation cleanup level (the Mac's `flow.cleanup` key; per device, never synced).
    @ObservedObject private var flow = FlowSettings.shared
    /// Groups stagger in when you switch to Settings.
    @State private var seen = SeenRows()
    @State private var entrance = 0
    /// Tap counts per row: each change gives that row's icon one small bounce.
    @State private var bumps: [String: Int] = [:]
    @State private var showDictionary = false
    @State private var showSnippets = false
    @State private var showAboutMe = false
    /// The You page (YouScreen.swift): the You card, and Home's This week card.
    @State private var showYou = false
    /// A row the You page asked for (Cloud cleanup): scrolled to and flashed once the You page has closed.
    @State private var pendingRow: String? = nil
    @State private var showKeyboard = false
    @State private var showActionButton = false
    /// Settings › Action button's choice (Ribbon.ActionChoice), for the row's value.
    @AppStorage(Ribbon.actionChoiceKey) private var actionChoice = Ribbon.ActionChoice.dictate.rawValue
    @State private var showVoice = false
    /// Settings › Privacy (PhoneTrust.swift).
    @State private var showPrivacy = false
    @State private var voicePreview = false
    @ObservedObject private var voice = VoiceProfileStatus.shared
    @State private var exporting = false
    @State private var exportURL: URL? = nil
    @State private var confirmDelete = false
    @State private var confirmDeleteFinal = false
    /// iCloud switch: the preference for next launch, the turn-off question, and the copy that runs first.
    @State private var syncWanted = Cloud.wantsSync
    @State private var confirmSyncOff = false
    @State private var copyingDown = false
    @State private var copyFailed = 0
    /// Search: the shared query, and the row that flashes after a result scrolls to it.
    @ObservedObject private var search = SettingsSearchModel.shared
    @State private var searchFlash: String? = nil
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PhoneCompactTitle(title: "Settings")
                    .padding(.top, 2)
                    .riseIn("title", index: 0, seen: seen, epoch: entrance)
                SettingsSearchField(text: $search.query) {
                    if let first = SettingsSearchIndex.search(search.query).first?.entries.first { pickSearchResult(first, proxy) }
                }
                .padding(.top, 14)
                .riseIn("search", index: 0, seen: seen, epoch: entrance)
                if search.isActive {
                    SettingsSearchResults(query: search.query, value: { SettingsSearchIndex.value(for: $0, app: app) }) { pickSearchResult($0, proxy) }
                } else {
                youCard
                    .padding(.top, 18)
                    .riseIn("you", index: 1, seen: seen, epoch: entrance)
                group(1, "Personalization") { personalization }
                group(2, "Recording") { recording }
                group(3, "Transcription", footer: "Transcription runs on this iPhone. The first time, the model downloads once (about 200–600 MB). Links download and transcribe on this iPhone; a few sites need your Mac to fetch them. Naming and sorting use Apple Intelligence on this iPhone; where it isn't available, titles use the first words and the kind is a best guess. Nothing you rename or change is overwritten.") { transcription }
                group(4, "Sync and data") { syncAndData }
                group(5, "Support") { support }
                group(6, "Welcome tour") { tour }
                footer
                    .padding(.top, 30)
                    .riseIn("footer", index: 7, seen: seen, epoch: entrance)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: pendingRow) { _, row in
            guard let row else { return }
            pendingRow = nil
            flashRow(row, label: SettingsSearchIndex.all.first { $0.id == row }?.label ?? "", proxy)
        }
        }
        .tabEntrance(.settings) { seen.entered(); entrance += 1 }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Settings")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showDictionary) { DictionaryScreen() }
        .navigationDestination(isPresented: $showSnippets) { SnippetsScreen() }
        .navigationDestination(isPresented: $showAboutMe) { AboutMeScreen() }
        .navigationDestination(isPresented: $showYou) {
            YouScreen { row in
                showYou = false
                // The row flashes after the pop has finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pendingRow = row }
            }
        }
        .navigationDestination(isPresented: $showKeyboard) { KeyboardSetupScreen() }
        .navigationDestination(isPresented: $showActionButton) { ActionButtonScreen() }
        .navigationDestination(isPresented: $showVoice) { VoiceProfileScreen(preview: voicePreview) }
        .navigationDestination(isPresented: $showPrivacy) { PhonePrivacyScreen() }
        .navigationDestination(isPresented: $showAcknowledgements) { AcknowledgementsView().navigationTitle("Acknowledgements") }
        // Home's This week card opens the You page, and its keyboard row opens Keyboard (SettingsPage, HomeScreen.swift).
        .onAppear { openRequestedPage() }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimOpenSettingsPage)) { _ in openRequestedPage() }
        // UI tour: `false` closes the You page (and anything pushed from it).
        .onReceive(NotificationCenter.default.publisher(for: .verbatimYouPage)) { note in
            if note.object as? Bool == false { showYou = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimShowVoiceProfile)) { note in
            let open = note.object as? Bool ?? false
            voicePreview = open
            showVoice = open
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .alert("Turn off iCloud sync?", isPresented: $confirmSyncOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off") { turnSyncOff() }
        } message: {
            Text("Verbose copies your library onto this iPhone, then stops syncing the next time it opens. Your Mac keeps what's already in iCloud.")
        }
        .alert("Clear saved voices?", isPresented: $confirmClearVoices) {
            Button("Clear", role: .destructive) { SpeakerVoices.clear(); savedVoices = 0 }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Verbose forgets the voices of the speakers you\u{2019}ve named. Names you gave stay.")
        }
        .alert("Delete all data?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                // The second question waits for the first alert to finish closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmDeleteFinal = true }
            }
        } message: {
            Text(Cloud.enabled
                 ? "This removes your transcripts, recordings, projects, and Dictionary from this iPhone and from iCloud, so they're gone from your Mac too. It can't be undone."
                 : "This removes your transcripts, recordings, projects, and Dictionary from this iPhone. It can't be undone.")
        }
        .alert(deleteTitle, isPresented: $confirmDeleteFinal) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) { app.deleteAllData() }
        } message: {
            Text(deleteDetail)
        }
    }

    // MARK: You

    @AppStorage("profile.name") private var profileName = ""

    /// You: your initial on the record color, your name in the serif (the last name in italic), and what's inside.
    /// Opens the You page.
    private var youCard: some View {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        return Button { showYou = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(PhoneInk.record)
                    Circle().strokeBorder(Ink.inkFixed, lineWidth: 1.5)
                    if let first = name.first {
                        Text(String(first).uppercased()).font(Ink.serif(26)).foregroundStyle(Ink.inkFixed)
                    } else {
                        IconGlyph(art: .iconAboutMe, size: 24, color: Ink.inkFixed)
                    }
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if parts.count == 2 { Text("\(parts[0]) ") + Text(parts[1]).italic() }
                        else { Text(name.isEmpty ? "You" : name) }
                    }
                    .font(Ink.serif(youSize)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.8)
                    Text("About me, your voice, your week, and cleanup").font(.system(size: 13)).foregroundStyle(Ink.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .phoneOutlined(radius: Radius.record)
            .contentShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "You" : name)
        .accessibilityHint("Opens your You page: About me, your voice, your week, and cleanup.")
    }

    @ScaledMetric(relativeTo: .title2) private var youSize: CGFloat = 22

    // MARK: Groups

    @ViewBuilder private var personalization: some View {
        SettingsToggleRow(icon: "globe", tint: Ink.sageTint, art: .iconLanguage, title: "Detect the language",
                          subtitle: "Verbose listens to the first 30 seconds and uses a model that knows that language. To change one transcript's language, tap its language under the title.",
                          isOn: $detectLanguage)
            .settingsSearchTarget("language", flash: searchFlash)
        SettingsDivider()
        Button { bump("voice"); voicePreview = false; showVoice = true } label: {
            SettingsRow(icon: "waveform", tint: Ink.persimmonTint, art: .iconVoice, title: "Your voice", subtitle: "Recognize you in recordings", bounce: bumps["voice", default: 0]) {
                SettingsValue(voice.isEnrolled ? "On" : "Set up"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("voice", flash: searchFlash)
        SettingsDivider()
        Button { bump("me"); showAboutMe = true } label: {
            SettingsRow(icon: "person", tint: Ink.petalTint, art: .iconAboutMe, title: "About me", subtitle: "Context for titles and summaries", bounce: bumps["me", default: 0]) {
                SettingsValue(aboutMe.isEmpty ? "Add" : "Added"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("aboutMe", flash: searchFlash)
        SettingsDivider()
        Button { bump("dict"); showDictionary = true } label: {
            SettingsRow(icon: "book.closed", tint: Ink.sageTint, art: .iconDictionary, title: "Dictionary", subtitle: "Names and words to spell your way", bounce: bumps["dict", default: 0]) {
                SettingsValue("\(app.store.dictionary.count)"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("dictionary", flash: searchFlash)
        SettingsDivider()
        Button { bump("snippets"); showSnippets = true } label: {
            SettingsRow(icon: "text.badge.plus", tint: Ink.petalTint, art: .iconQuote, title: "Snippets", subtitle: "Say a trigger, get your saved text", bounce: bumps["snippets", default: 0]) {
                SettingsValue("\(app.store.snippets.count)"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("snippets", flash: searchFlash)
        SettingsDivider()
        Button { bump("keyboard"); showKeyboard = true } label: {
            SettingsRow(icon: "keyboard", tint: Ink.butterTint, art: .iconDictations, title: "Keyboard", subtitle: "Dictate into any app", bounce: bumps["keyboard", default: 0]) {
                SettingsValue("Set up"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("keyboardRow", flash: searchFlash)
        SettingsDivider()
        Button { bump("actionButton"); showActionButton = true } label: {
            SettingsRow(icon: "button.horizontal.top.press", tint: Ink.butterTint, art: .iconActionButton, title: "Action button",
                        subtitle: "Dictate from any app without switching", bounce: bumps["actionButton", default: 0]) {
                SettingsValue(Ribbon.actionChoice(actionChoice).shortTitle)
                SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("actionButtonRow", flash: searchFlash)
        SettingsDivider()
        Menu {
            Picker("Appearance", selection: $app.appearance) {
                Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
        } label: {
            SettingsRow(icon: "moon", tint: Ink.petalTint, art: .iconAppearance, title: "Appearance", bounce: app.appearance) {
                SettingsValue(app.appearance == "light" ? "Light" : app.appearance == "dark" ? "Dark" : "Match system"); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("appearance", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "tortoise", tint: Ink.sageTint, art: .iconLimitMotion, title: "Limit animation",
                          subtitle: "Fades instead of movement; illustrations stay still.", isOn: $motionLimited)
            .settingsSearchTarget("limitMotion", flash: searchFlash)
    }

    @ViewBuilder private var recording: some View {
        SettingsToggleRow(icon: "text.bubble", tint: Ink.persimmonTint, art: .iconDictations, title: "Show words while you record",
                          subtitle: "A preview of your words on the recorder, made on this iPhone. The saved transcript comes from the full model after you stop.",
                          isOn: $recordLiveWords)
            .settingsSearchTarget("recordLiveWords", flash: searchFlash)
    }

    @ViewBuilder private var transcription: some View {
        Menu {
            Picker("Quality", selection: $app.presetRaw) {
                ForEach(QualityPreset.allCases.filter { $0 != .advanced }) { p in Text(p.title).tag(p.rawValue) }
            }
        } label: {
            SettingsRow(icon: "chart.line.uptrend.xyaxis", tint: Ink.sageTint, art: .iconQuality, title: "Quality", subtitle: app.preset.note, bounce: app.presetRaw) {
                SettingsValue(app.preset.title); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("quality", flash: searchFlash)
        SettingsDivider()
        Menu {
            Picker("Cleanup", selection: $flow.cleanup) {
                ForEach(CleanupLevel.allCases) { l in Text(l.title).tag(l) }
            }
        } label: {
            SettingsRow(icon: "wand.and.stars", tint: Ink.butterTint, art: .refine, title: "Cleanup", subtitle: Self.cleanupNote(flow.cleanup), subtitleLines: nil, bounce: flow.cleanup.rawValue) {
                SettingsValue(flow.cleanup.title); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("cleanup", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "arrow.uturn.backward", tint: Ink.butterTint, title: "Understand spoken corrections",
                          subtitle: "Say \u{201C}scratch that,\u{201D} \u{201C}delete the last sentence,\u{201D} or \u{201C}let me start over\u{201D} to fix what you said.",
                          isOn: $spokenCorrections)
            .settingsSearchTarget("spokenCorrections", flash: searchFlash)
        SettingsDivider()
        CloudCleanupRows(searchFlash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "person.2", tint: Ink.persimmonTint, art: .iconSpeakers, title: "Identify speakers", isOn: $app.identifySpeakers)
            .settingsSearchTarget("speakers", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "person.2", tint: Ink.petalTint, art: .iconVoice, title: "Recognize voices I\u{2019}ve named",
                          subtitle: "Suggests a name when a new speaker sounds like someone you named. The voices stay on this iPhone and are never synced.",
                          isOn: $recognizeVoices)
            .settingsSearchTarget("recognizeVoices", flash: searchFlash)
        SettingsDivider()
        Button { bump("clearVoices"); confirmClearVoices = true } label: {
            SettingsRow(icon: "trash", tint: Ink.petalTint, art: .iconDeleteAll, title: "Clear saved voices",
                        subtitle: savedVoices == 0 ? "No saved voices" : "\(savedVoices) saved voice\(savedVoices == 1 ? "" : "s"), on this iPhone only",
                        bounce: bumps["clearVoices", default: 0]) { EmptyView() }
        }
        .buttonStyle(SettingsRowPress())
        .disabled(savedVoices == 0)
        .onAppear { savedVoices = SpeakerVoices.namedCount }
        .settingsSearchTarget("clearVoices", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "checkmark", tint: Ink.sageTint, art: .iconApplyDictionary, title: "Apply Dictionary", isOn: $app.applyDictionary)
            .settingsSearchTarget("applyDictionary", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "sparkle", tint: Ink.butterTint, art: .iconNameAndSort, title: "Name and sort recordings",
                          subtitle: "Suggests a title, kind, and tags when a transcript is ready", isOn: $autoLabels)
            .settingsSearchTarget("nameAndSort", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "text.quote", tint: Ink.butterTint, art: .iconSummaries, title: "Write a summary when a transcript finishes",
                          subtitle: Summarizer.unavailableReason ?? "A short overview and key points at the top of the transcript", isOn: $autoSummary)
            .settingsSearchTarget("summaries", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "eye.slash", tint: Ink.petalTint, art: .iconFiller, title: "Hide filler lines",
                          subtitle: "Lines that are only \u{201C}um\u{201D} or \u{201C}uh\u{201D} stay out of view, never deleted", isOn: $hideFiller)
            .settingsSearchTarget("hideFiller", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "person", tint: Ink.sageTint, art: .iconMainSpeaker, title: "Main speaker only",
                          subtitle: "In voice memos, other voices fold into a Background voices section", isOn: $mainSpeakerOnly)
            .settingsSearchTarget("mainSpeaker", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "tag", tint: Ink.butterTint, art: .iconSponsor, title: "Skip sponsor reads",
                          subtitle: "In podcasts and videos, playback jumps past sponsor reads, and they fold into a line", isOn: $skipSponsors)
            .settingsSearchTarget("skipSponsors", flash: searchFlash)
        SettingsDivider()
        Menu {
            Picker("Files with several audio tracks", selection: $audioTracks) {
                ForEach(AudioTracksPreference.allCases) { Text($0.title).tag($0.rawValue) }
            }
        } label: {
            SettingsRow(icon: "square.stack.3d.up", tint: Ink.petalTint, art: .iconMultitrack, title: "Files with several audio tracks",
                        subtitle: audioTracks == AudioTracksPreference.separate.rawValue
                            ? "Each track is transcribed on its own as a speaker you can rename"
                            : "Every track is mixed into one transcript",
                        subtitleLines: nil, bounce: audioTracks) {
                SettingsValue(audioTracks == AudioTracksPreference.separate.rawValue ? "Separate" : "Mix"); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("audioTracks", flash: searchFlash)
    }

    @ViewBuilder private var syncAndData: some View {
        // Local Only, Network activity, and what leaves this iPhone (PhoneTrust.swift).
        PhonePrivacyRow(bounce: bumps["privacyScreen", default: 0]) { bump("privacyScreen"); showPrivacy = true }
        SettingsDivider()
        if Cloud.available {
            Toggle(isOn: Binding(get: { syncWanted }, set: { on in
                if on { syncWanted = true; Cloud.setWantsSync(true) } else { confirmSyncOff = true }
            })) {
                SettingsLabel(icon: syncWanted ? "icloud" : "icloud.slash", tint: Ink.sageTint, art: syncWanted ? .iconSync : .iconSyncOff, title: "iCloud sync",
                              subtitle: syncSubtitle, subtitleLines: nil, bounce: syncWanted)
            }
            .toggleStyle(.switch).tint(PhoneInk.switchOn)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 50)
            .disabled(copyingDown)
            .settingsSearchTarget("sync", flash: searchFlash)
        } else {
            SettingsRow(icon: "icloud.slash", tint: Ink.sageTint, art: .iconSyncOff, title: "iCloud is off",
                        subtitle: "Sign in to iCloud in the Settings app to sync with your Mac. Until then, everything stays on this iPhone.",
                        subtitleLines: nil) { EmptyView() }
                .accessibilityElement(children: .combine)
                .settingsSearchTarget("sync", flash: searchFlash)
        }
        SettingsDivider()
        Button {
            bump("export")
            exporting = true
            Task {
                exportURL = await app.exportEverything()
                exporting = false
            }
        } label: {
            SettingsRow(icon: "square.and.arrow.down", tint: Ink.petalTint, art: .iconExport, title: "Export everything", subtitle: "Markdown and JSON in one zip", bounce: bumps["export", default: 0]) {
                if exporting { ProgressView().controlSize(.small) } else { SettingsChevron() }
            }
        }
        .buttonStyle(SettingsRowPress())
        .disabled(exporting)
        .settingsSearchTarget("export", flash: searchFlash)
        SettingsDivider()
        Button { bump("delete"); confirmDelete = true } label: {
            SettingsRow(icon: "trash", tint: Ink.persimmonTint, art: .iconDeleteAll, title: "Delete all data", bounce: bumps["delete", default: 0], danger: true) { EmptyView() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("deleteAll", flash: searchFlash)
    }

    /// What the cleanup level does to keyboard dictations, and what happens without Apple Intelligence. Also on the
    /// You page.
    static func cleanupNote(_ level: CleanupLevel) -> String {
        let what: String
        switch level {
        case .none: what = "Keyboard dictations go in as spoken, with punctuation and capitals."
        case .light: what = "Removes ums, repeats, and false starts, and turns spoken lists into lists. Keeps your wording."
        case .medium: what = "Everything Clean does, plus fixes grammar, splits run-on sentences, and smooths rambling. Keeps your meaning and voice."
        }
        guard level.usesModel, !FlowCleanup.available else { return what }
        return what + " Without Apple Intelligence on this iPhone, rules remove ums, repeats, and false starts, fix capitals and “a” or “an,” and make lists and paragraphs."
    }

    private var syncSubtitle: String {
        if copyingDown { return "Copying your library to this iPhone…" }
        if copyFailed > 0 { return "\(copyFailed) file\(copyFailed == 1 ? "" : "s") couldn't be downloaded from iCloud, so sync is still on. Check your connection and try again." }
        if syncWanted != Cloud.enabled {
            return syncWanted ? "Starts the next time you open Verbose." : "Your library is on this iPhone. Syncing stops the next time you open Verbose (swipe it away to finish now)."
        }
        return syncWanted
            ? "Transcripts, notes, projects, and the Dictionary match your Mac. Audio from the other device downloads when you play it."
            : "Everything stays on this iPhone."
    }

    private func turnSyncOff() {
        guard Cloud.enabled else { syncWanted = false; Cloud.setWantsSync(false); return }
        copyingDown = true; copyFailed = 0
        Task {
            app.store.flush()
            let r = await Task.detached(priority: .userInitiated) { () -> (copied: Int, failed: Int) in
                TranscriptFiles.queue.sync {}   // queued saves land in iCloud before the copy reads it
                return Cloud.copyToDevice()
            }.value
            copyFailed = r.failed
            if r.failed == 0 { Cloud.setWantsSync(false); syncWanted = false }
            copyingDown = false
        }
    }

    @ViewBuilder private var support: some View {
        Button { bump("support"); if let u = Links.mail(subject: "Verbose support") { openURL(u) } } label: {
            SettingsRow(icon: "bubble.left", tint: Ink.sageTint, art: .iconSupport, title: "Contact support", bounce: bumps["support", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("support", flash: searchFlash)
        SettingsDivider()
        Button { bump("feedback"); if let u = Links.mail(subject: "Verbose feedback") { openURL(u) } } label: {
            SettingsRow(icon: "pencil", tint: Ink.persimmonTint, art: .iconFeedback, title: "Share feedback", bounce: bumps["feedback", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("feedback", flash: searchFlash)
        SettingsDivider()
        ShareLink(item: Log.file, subject: Text("Verbose diagnostic log"),
                  message: Text("Send to \(Links.supportEmail)")) {
            SettingsRow(icon: "stethoscope", tint: Ink.petalTint, art: .iconDiagnosticLog, title: "Send diagnostic log",
                        subtitle: "7 days of app events, without links or folder names", bounce: bumps["log", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .simultaneousGesture(TapGesture().onEnded { bump("log"); Log.trimNow() })
        .settingsSearchTarget("log", flash: searchFlash)
        SettingsDivider()
        Button { bump("privacy"); openURL(Links.privacy) } label: {
            SettingsRow(icon: "lock", tint: Ink.petalTint, art: .iconPrivacy, title: "Privacy policy", bounce: bumps["privacy", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("privacy", flash: searchFlash)
        SettingsDivider()
        Button { bump("terms"); openURL(Links.terms) } label: {
            SettingsRow(icon: "doc.text", tint: Ink.sageTint, art: .iconTerms, title: "Terms of use", bounce: bumps["terms", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("terms", flash: searchFlash)
        SettingsDivider()
        ShareLink(item: Links.base) {
            SettingsRow(icon: "square.and.arrow.up", tint: Ink.persimmonTint, art: .iconShare, title: "Share Verbose", bounce: bumps["share", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .simultaneousGesture(TapGesture().onEnded { bump("share") })
        .settingsSearchTarget("share", flash: searchFlash)
        SettingsDivider()
        Button { bump("acknowledgements"); showAcknowledgements = true } label: {
            SettingsRow(icon: "doc.plaintext", tint: Ink.sageTint, art: .iconTerms, title: "Acknowledgements", subtitle: "Open-source software and its licenses",
                        bounce: bumps["acknowledgements", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("acknowledgements", flash: searchFlash)
    }

    @ViewBuilder private var tour: some View {
        SettingsToggleRow(icon: "sparkles", tint: Ink.petalTint, art: .iconTour, title: "Show it when Verbose opens",
                          isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0; app.objectWillChange.send() }))
            .settingsSearchTarget("tourOnLaunch", flash: searchFlash)
        SettingsDivider()
        Button { bump("tour"); app.showOnboarding = true } label: {
            SettingsRow(icon: "play.rectangle", tint: Ink.sageTint, art: .iconTour, title: "Show Tour", bounce: bumps["tour", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("tour", flash: searchFlash)
    }

    private var footer: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return VStack(spacing: 6) {
            // The lockup (DESIGN.md §4) and the tagline in the serif.
            HStack(spacing: 8) {
                BarsMark(color: Ink.persimmon).frame(width: 17, height: 18)
                Ink.wordmark(22)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")
            Text(Ink.tagline).font(Ink.serif(16)).foregroundStyle(Ink.dim).padding(.bottom, 6)
            Text("Version \(version) (\(build))")
            Text("Verbose · Stump & Root Co.")
        }
        .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Helpers

    private func group<Rows: View>(_ index: Int, _ title: String, footer: String? = nil, @ViewBuilder _ rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { rows() }
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.record, style: .continuous).strokeBorder(Ink.hairline))
            if let footer {
                Text(footer).font(.system(size: 13)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 22)
        .riseIn("group-\(index)", index: index, seen: seen, epoch: entrance)
    }

    private func bump(_ key: String) { bumps[key, default: 0] += 1 }

    private func openRequestedPage() {
        switch SettingsPage.take() {
        case "aboutMe"?: showAboutMe = true
        case "you"?: showYou = true
        case "keyboard"?: showKeyboard = true
        case "actionButton"?: showActionButton = true
        // Back to Settings itself (the screenshot tour, between subpages).
        case "root"?: showKeyboard = false; showActionButton = false
        default: break
        }
    }

    /// A search result was chosen: clear the search, then push its subpage, or scroll to its row and flash it.
    private func pickSearchResult(_ entry: SettingsSearchEntry, _ proxy: ScrollViewProxy) {
        search.query = ""
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        switch entry.target {
        case .page(.aboutMe): showAboutMe = true
        case .page(.dictionary): showDictionary = true
        case .page(.keyboard): showKeyboard = true
        case .page(.actionButton): showActionButton = true
        case .page(.snippets): showSnippets = true
        case .row: flashRow(entry.id, label: entry.label, proxy)
        }
    }

    /// Scrolls to a row and flashes it (a search result, or a row the You page links to).
    private func flashRow(_ id: String, label: String, _ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)   // the groups lay out again first
            withAnimation(limitMotion ? nil : Motion.nav) { proxy.scrollTo(id, anchor: .center) }
            searchFlash = id
            if !label.isEmpty { AccessibilityNotification.Announcement(label).post() }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if searchFlash == id { searchFlash = nil }
        }
    }

    private var deleteTitle: String {
        let n = app.store.transcripts.count
        return n == 1 ? "Delete 1 transcript?" : "Delete \(n) transcripts?"
    }

    private var deleteDetail: String {
        let n = app.store.transcripts.count, p = app.store.projects.count, w = app.store.dictionary.count
        let things = n == 1 ? "the 1 transcript" : "all \(n) transcripts"
        let projects = p == 1 ? "1 project" : "\(p) projects"
        let words = w == 1 ? "1 Dictionary word" : "\(w) Dictionary words"
        return "Verbose deletes \(things) (Recently Deleted too) with their audio, plus \(projects) and \(words), for good."
    }
}

// MARK: - Rows

/// The icon tile and the text of a settings row. The icon bounces once each time `bounce` changes.
struct SettingsLabel: View {
    var icon: String
    var tint: Color
    /// A fine-line Verbatim icon in place of the symbol.
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var bounce: AnyHashable = 0
    var danger = false
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                // The website style's colored squares: the row's tint at full strength, ink on top. Destructive
                // rows stay neutral with the danger color.
                let square = danger ? Ink.neutralChip : SettingsLabel.square(for: tint)
                let on = danger ? Ink.danger : (square == PhoneInk.wash ? Ink.ink : Ink.inkFixed)
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(square)
                if let art {
                    IconGlyph(art: art, size: 17, color: on)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on)
                        .symbolEffect(.bounce, value: bounce)
                        .symbolEffectsRemoved(limitMotion)
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(danger ? Ink.danger : Ink.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Ink.mute)
                        .lineLimit(subtitleLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
        }
    }

    /// The full panel color behind a row's tint (`Ink.*Tint` → `PhoneInk.*`); anything else is the wash.
    static func square(for tint: Color) -> Color {
        if tint == Ink.persimmonTint { return PhoneInk.record }
        if tint == Ink.butterTint { return PhoneInk.butter }
        if tint == Ink.sageTint { return PhoneInk.sage }
        if tint == Ink.petalTint { return PhoneInk.petal }
        return PhoneInk.wash
    }
}

/// One settings row: icon tile, title and subtitle, then a value, chevron, or control.
struct SettingsRow<Trailing: View>: View {
    var icon: String
    var tint: Color
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var bounce: AnyHashable = 0
    var danger = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(icon: icon, tint: tint, art: art, title: title, subtitle: subtitle, subtitleLines: subtitleLines, bounce: bounce, danger: danger)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// A row with a switch that settles with a small spring. The icon bounces when it changes.
struct SettingsToggleRow: View {
    var icon: String
    var tint: Color
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(icon: icon, tint: tint, art: art, title: title, subtitle: subtitle, subtitleLines: nil, bounce: isOn)
        }
        .toggleStyle(.switch).tint(PhoneInk.switchOn)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
    }
}

struct SettingsValue: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 16)).foregroundStyle(Ink.mute).lineLimit(1) }
}

struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.mute).accessibilityHidden(true)
    }
}

/// Marks a row that opens a menu of choices.
struct SettingsMenuMark: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute).accessibilityHidden(true)
    }
}

/// The hairline between rows, inset past the icon tile.
struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 56) }
}

/// Rows highlight while pressed (a color change, not movement).
struct SettingsRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Ink.ink.opacity(configuration.isPressed ? 0.05 : 0))
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - About me

/// Your name (Home greeting, email sign-offs) and a few lines of context (up to 300 characters) for wording titles
/// and summaries. Both sync with your Mac through iCloud when sync is on.
struct AboutMeScreen: View {
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage("profile.name") private var name = ""
    @FocusState private var focused: Bool
    /// Whether About me is on screen, for the UI tour's checks.
    static var visible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your name").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute).padding(.horizontal, 4)
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .font(.system(size: 16)).foregroundStyle(Ink.ink)
                    .padding(.horizontal, 14).frame(height: 48)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
                    .accessibilityLabel("Your name")
                Text("About me").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute).padding(.horizontal, 4).padding(.top, 10)
                ZStack(alignment: .topLeading) {
                    if aboutMe.isEmpty {
                        Text("For example: I'm a teacher. I record lessons and parent meetings, and often mention Room 12 and the spring fair.")
                            .font(.system(size: 16)).foregroundStyle(Ink.faint)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $aboutMe)
                        .focused($focused)
                        .font(.system(size: 16)).foregroundStyle(Ink.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .accessibilityLabel("About me")
                }
                .padding(10)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
                .onChange(of: aboutMe) { _, v in
                    if v.count > Profile.aboutMeLimit { aboutMe = String(v.prefix(Profile.aboutMeLimit)) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Verbose uses this on device to spell names and word titles and summaries. It syncs with your Mac when iCloud sync is on.")
                        .font(.system(size: 13)).foregroundStyle(Ink.mute)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(aboutMe.count)/\(Profile.aboutMeLimit)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.mute)
                        .accessibilityLabel("\(aboutMe.count) of \(Profile.aboutMeLimit) characters")
                }
                .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("About me")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Self.visible = true; if aboutMe.isEmpty, !PhoneUITest.enabled { focused = true } }
        .onDisappear { Self.visible = false }
    }
}
