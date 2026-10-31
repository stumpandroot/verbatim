import SwiftUI
import UIKit

/// About me: a few lines of context in UserDefaults. With iCloud sync on, it travels with your name to your Mac
/// (Store.SyncedProfile).
enum Profile {
    static let aboutMeKey = "profile.aboutMe"
    static let aboutMeLimit = 300
}

extension Notification.Name {
    /// Scrolls Settings to a row or group id (`group-3`, `settings-footer`), for the screenshot tour.
    static let verbatimSettingsScroll = Notification.Name("verbatimSettingsScroll")
}

/// Settings (DESIGN.md §13; mockup "Verbose Refined Look", PhoneSettings): the large serif "Settings", the system search field, the You card (your initial on persimmon, your name,
/// and what's inside; it opens the You page, YouScreen.swift), then the seven groups of PhoneSettingsMap, each a label
/// over cards: the rows that open a page, run something, or choose from a menu, each with its colored icon square
/// (persimmon, butter, sage, petal down the card, `RefinedRules.settingsHue`), its value in `mute`, and a chevron;
/// then the group's switches in a card of their own, with no squares, in the system's green. A destructive row has a
/// neutral square and a red title, in a card of its own. Rarely changed switches sit one level down on a page
/// (SettingsPages.swift). The version sits at the foot; tapping it opens What's new (WhatsNewScreen.swift). Apple
/// draws the chrome: the pages push on the system's navigation bar, and the menus, alerts, and switches are the
/// system's.
struct SettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    /// Done beside the title closes the sheet Settings opens in (`SettingsSheet`).
    var onDone: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage(MotionPreference.key) private var motionLimited = false
    @AppStorage(AutoLabel.enabledKey) private var autoLabels = true
    @AppStorage(Summarizer.autoKey) private var autoSummary = true
    /// Check each recording's language and pick a model that knows it (LanguageCheck.swift). On by default.
    @AppStorage(LanguageDetection.enabledKey) private var detectLanguage = true
    @AppStorage(CloudCleanup.enabledKey) private var cloudCleanupOn = false
    @State private var showAcknowledgements = false
    /// Show words while you record (RecorderSheet.swift). On by default.
    @AppStorage(RecordingLiveText.enabledKey) private var recordLiveWords = true
    /// Haptics (Haptics.swift's `Haptics`). On by default, per device, in the App Group so the keyboard follows it.
    @AppStorage(Haptics.enabledKey, store: Haptics.store) private var hapticsOn = true
    /// Understand spoken corrections, in the App Group so the keyboard's live words follow it.
    @AppStorage(SpokenCorrections.enabledKey, store: SpokenCorrections.store) private var spokenCorrections = true
    /// Dictation cleanup level (the Mac's `flow.cleanup` key; per device, never synced).
    @ObservedObject private var flow = FlowSettings.shared
    /// The tab bar's picks, for the Tab bar row's value.
    @ObservedObject private var tabBarStore = PhoneTabBarStore.shared
    /// "Library, Thoughts": the tabs after Home, or "Home only" with none.
    private var tabBarValue: String {
        let m = tabBarStore.bar.middle
        return m.isEmpty ? "Home only" : m.map(\.title).joined(separator: ", ")
    }
    /// The page pushed from a root row, a search result, or a request (SettingsPage).
    @State private var page: SettingsSubpage? = nil
    /// The You page (YouScreen.swift): the You card, and Home's This week card.
    @State private var showYou = false
    /// A row the You page asked for (Cloud cleanup): its page opens, or the row is scrolled to and flashed, once the
    /// You page has closed.
    @State private var pendingRow: String? = nil
    /// Settings › Action button's choice (Ribbon.ActionChoice), for the row's value.
    @AppStorage(Ribbon.actionChoiceKey) private var actionChoice = Ribbon.ActionChoice.dictate.rawValue
    @State private var showVoice = false
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
    /// How many Settings roots are on screen (the self-test checks Settings draws).
    static var onScreen = 0

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    LargeSerifTitle(title: "Settings")
                    Spacer(minLength: 12)
                    if let onDone {
                        Button("Done", action: onDone)
                            .refinedFont(.rowTitle, weight: .semibold)
                            .foregroundStyle(Refined.accentText)
                            .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("settings.done")
                    }
                }
                .padding(.top, 8)
                .id("settings-top")
                SystemSearchField(text: $search.query, prompt: "Search settings") {
                    if let first = SettingsSearchIndex.search(search.query).first?.entries.first { pickSearchResult(first, proxy) }
                }
                .frame(minHeight: 38)
                .padding(.top, 14)
                if search.isActive {
                    SettingsSearchResults(query: search.query, value: { SettingsSearchIndex.value(for: $0, app: app) }) { pickSearchResult($0, proxy) }
                } else {
                    youCard
                        .padding(.top, 14)
                    group(1, PhoneSettingsMap.personalization) { personalization }
                    group(2, PhoneSettingsMap.recording,
                          footer: "Transcription runs on this iPhone. The first time, the model downloads once (about 200–600 MB). Links download and transcribe on this iPhone; a few sites need your Mac to fetch them. Naming and sorting use Apple Intelligence on this iPhone; where it isn't available, titles use the first words and the kind is a best guess. Nothing you rename or change is overwritten.") { recording }
                    group(3, PhoneSettingsMap.dictation, footer: "Cleanup: " + Self.cleanupNote(flow.cleanup)) { dictation }
                    group(4, PhoneSettingsMap.sync) { syncAndStorage }
                    group(5, PhoneSettingsMap.account) { account }
                    group(6, PhoneSettingsMap.support) { support }
                    group(7, PhoneSettingsMap.features) { features }
                    footer
                        .padding(.top, 30)
                        .id("settings-footer")
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: pendingRow) { _, row in
            guard let row else { return }
            pendingRow = nil
            // A setting on a page (You › Cloud cleanup) opens that page; one on the root flashes.
            if let p = PhoneSettingsMap.page(of: row).flatMap(SettingsSubpage.init(rawValue:)) {
                open(p)
            } else {
                flashRow(row, label: SettingsSearchIndex.all.first { $0.id == row }?.label ?? "", proxy)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimSettingsScroll)) { note in
            guard let id = note.object as? String else { return }
            withAnimation(nil) { proxy.scrollTo(id, anchor: .top) }
        }
        }
        .background(Refined.paper.ignoresSafeArea())
        // The serif title is on the page; the bar's title names the pages' Back button.
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $page) { p in destination(p).settingsSubpage(p) }
        .navigationDestination(isPresented: $showYou) {
            YouScreen { row in
                showYou = false
                // The row's page opens (or the row flashes) after the pop has finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pendingRow = row }
            }
        }
        .navigationDestination(isPresented: $showVoice) { VoiceProfileScreen(preview: voicePreview) }
        .navigationDestination(isPresented: $showAcknowledgements) { AcknowledgementsView().navigationTitle("Acknowledgements") }
        // Home's This week card opens the You page, and its keyboard row opens Keyboard (SettingsPage, HomeScreen.swift).
        // On the tab's first appearance (Home's What's new note creates it), the push waits a turn of the main loop: a
        // destination presented during the stack's own first appearance can push before the stack is in the window.
        .onAppear { Self.onScreen += 1; DispatchQueue.main.async { openRequestedPage() } }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
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
            Button("Turn off") { turnSyncOff() }
        } message: {
            Text("Verbose copies your library onto this iPhone, then stops syncing the next time it opens. Your Mac keeps what's already in iCloud.")
        }
        .alert("Delete all data?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                // The second question waits for the first alert to finish closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmDeleteFinal = true }
            }
        } message: {
            Text(Cloud.enabled
                 ? "This removes everything Verbose keeps: transcripts, recordings, projects, plans, templates, your Dictionary, your name, and your voice profile and the voices you named, from this iPhone and from iCloud, so they're gone from your Mac too. It can't be undone."
                 : "This removes everything Verbose keeps on this iPhone: transcripts, recordings, projects, plans, templates, your Dictionary, your name, and your voice profile and the voices you named. It can't be undone.")
        }
        .alert(deleteTitle, isPresented: $confirmDeleteFinal) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) { app.deleteAllData() }
        } message: {
            Text(deleteDetail)
        }
    }

    /// Each page a root row, a search result, or a request opens.
    @ViewBuilder private func destination(_ p: SettingsSubpage) -> some View {
        switch p {
        case .aboutMe: AboutMeScreen()
        case .dictionary: DictionaryScreen()
        case .keyboard: KeyboardSetupScreen()
        case .snippets: SnippetsScreen()
        case .actionButton: ActionButtonScreen()
        case .appearance: AppearanceScreen()
        case .whatsNew: WhatsNewScreen()
        case .speakers: SpeakersSettingsScreen()
        case .moreTranscription: MoreTranscriptionScreen()
        case .cloudCleanup: CloudCleanupScreen()
        case .privacy: PhonePrivacyScreen()
        case .tour: WelcomeTourScreen()
        case .widgets: WidgetsInfoScreen()
        case .shortcuts: ShortcutsInfoScreen()
        case .customizeHome: CustomizeHomeDestination()
        case .thoughts: ThoughtsSettingsScreen()
        case .tabBar: TabBarSettingsScreen()
        case .templates: TemplatesAutoScreen()
        }
    }

    // MARK: You

    @AppStorage("profile.name") private var profileName = ""

    /// The You card (mockup): your initial on persimmon, your name, and what's inside, with a chevron. Opens the You
    /// page.
    private var youCard: some View {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button { showYou = true } label: {
            HStack(spacing: 12) {
                InitialBadge(name: name, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? "You" : name).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                    Text("About me, your voice, your week, and cleanup").refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
        }
        .buttonStyle(RefinedPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.isEmpty ? "You" : name)
        .accessibilityValue("About me, your voice, your week, and cleanup")
        .accessibilityHint("Opens your You page.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Rows

    /// A root row that opens a page: its square, the title, the value, and a chevron.
    private func pageRow(_ id: String, _ p: SettingsSubpage, _ index: Int, art: BrandArt, title: String, value: String? = nil) -> some View {
        Button { open(p) } label: {
            SettingsRow(hue: RefinedRules.settingsHue(index), art: art, title: title) {
                if let value { SettingsValue(value) }
                SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .accessibilityHint("Opens \(p.title)")
        .settingsSearchTarget(id, flash: searchFlash)
    }

    /// A root row that runs an action or opens a link: its square, the title, and a chevron.
    private func actionRow(_ id: String, _ index: Int, art: BrandArt, title: String, value: String? = nil, hint: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsRow(hue: RefinedRules.settingsHue(index), art: art, title: title) {
                if let value { SettingsValue(value) }
                SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .accessibilityHint(hint ?? "")
        .settingsSearchTarget(id, flash: searchFlash)
    }

    /// A root row that chooses from a menu (Quality, Cleanup): its square, the title, the choice, and the menu mark.
    private func menuRow<Choices: View>(_ id: String, _ index: Int, art: BrandArt, title: String, value: String,
                                        @ViewBuilder choices: () -> Choices) -> some View {
        let menu = choices()
        return Menu { menu } label: {
            SettingsRow(hue: RefinedRules.settingsHue(index), art: art, title: title) {
                SettingsValue(value); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        .accessibilityHint("Shows the choices")
        .settingsSearchTarget(id, flash: searchFlash)
    }

    /// The hairline between rows with squares, inset to where the titles start.
    private var squareDivider: some View { PaperDivider(leading: 56) }

    // MARK: Groups

    @ViewBuilder private var personalization: some View {
        PaperCard {
            pageRow("appearanceRow", .appearance, 0, art: .iconAppearance, title: "Appearance", value: Self.appearanceLabel(app.appearance))
            // Customize Home (the Edit Home branch): off the root until its screen lands (CustomizeHomeEntry).
            if CustomizeHomeEntry.isAvailable {
                squareDivider
                pageRow("customizeHomeRow", .customizeHome, 1, art: .iconHome, title: "Customize Home")
            }
            squareDivider
            pageRow("tabBarRow", .tabBar, 2, art: .iconTabBar, title: "Tab bar", value: tabBarValue)
            squareDivider
            pageRow("aboutMeRow", .aboutMe, 3, art: .iconAboutMe, title: "About me", value: aboutMe.isEmpty ? "Add" : "Added")
            squareDivider
            actionRow("voice", 4, art: .iconVoice, title: "Your voice", value: voice.isEnrolled ? "On" : "Set up", hint: "Opens Your voice") {
                voicePreview = false; showVoice = true
            }
            squareDivider
            pageRow("dictionaryRow", .dictionary, 5, art: .iconDictionary, title: "Dictionary",
                    value: app.store.dictionary.count == 1 ? "1 word" : "\(app.store.dictionary.count) words")
        }
        PaperCard {
            SettingsToggleRow(title: "Detect the language", isOn: $detectLanguage)
                .settingsSearchTarget("language", flash: searchFlash)
            SettingsDivider()
            SettingsToggleRow(title: "Limit animation", isOn: $motionLimited)
                .settingsSearchTarget("limitMotion", flash: searchFlash)
            SettingsDivider()
            SettingsToggleRow(title: "Haptics", subtitle: "Taps when you record, stop, mark, or copy, here, in the keyboard, and on Apple Watch", isOn: $hapticsOn)
                .settingsSearchTarget("haptics", flash: searchFlash)
                // The Apple Watch follows this switch through the context the iPhone sends it.
                .onChange(of: hapticsOn) { _, _ in PhoneWatchLink.shared.publish(app.store) }
        }
    }

    @ViewBuilder private var recording: some View {
        PaperCard {
            menuRow("quality", 0, art: .iconQuality, title: "Quality", value: app.preset.title) {
                Picker("Quality", selection: $app.presetRaw) {
                    ForEach(QualityPreset.allCases.filter { $0 != .advanced }) { p in Text(p.title).tag(p.rawValue) }
                }
            }
            squareDivider
            pageRow("speakersRow", .speakers, 1, art: .iconSpeakers, title: "Speakers", value: app.identifySpeakers ? "Identify" : "Off")
            squareDivider
            pageRow("moreTranscriptionRow", .moreTranscription, 2, art: .iconMultitrack, title: "More transcription options")
        }
        PaperCard {
            SettingsToggleRow(title: "Summaries", subtitle: Summarizer.unavailableReason, isOn: $autoSummary)
                .settingsSearchTarget("summaries", flash: searchFlash)
            SettingsDivider()
            SettingsToggleRow(title: "Name and sort recordings", isOn: $autoLabels)
                .settingsSearchTarget("nameAndSort", flash: searchFlash)
            SettingsDivider()
            SettingsToggleRow(title: "Show words while you record", isOn: $recordLiveWords)
                .settingsSearchTarget("recordLiveWords", flash: searchFlash)
        }
    }

    @ViewBuilder private var dictation: some View {
        PaperCard {
            pageRow("keyboardRow", .keyboard, 0, art: .iconDictations, title: "Keyboard", value: "Set up")
            squareDivider
            pageRow("actionButtonRow", .actionButton, 1, art: .iconActionButton, title: "Action button",
                    value: Ribbon.actionChoice(actionChoice).shortTitle)
            squareDivider
            menuRow("cleanup", 2, art: .refine, title: "Cleanup", value: flow.cleanup.title) {
                Picker("Cleanup", selection: $flow.cleanup) {
                    ForEach(CleanupLevel.allCases) { l in Text(l.title).tag(l) }
                }
            }
            squareDivider
            pageRow("snippetsRow", .snippets, 3, art: .iconQuote, title: "Snippets", value: "\(app.store.snippets.count)")
            squareDivider
            pageRow("cloudCleanupRow", .cloudCleanup, 4, art: .iconServer, title: "Cloud cleanup", value: cloudCleanupOn ? "On" : "Off")
        }
        PaperCard {
            SettingsToggleRow(title: "Spoken corrections", isOn: $spokenCorrections)
                .settingsSearchTarget("spokenCorrections", flash: searchFlash)
        }
    }

    @ViewBuilder private var syncAndStorage: some View {
        PaperCard {
            // Local Only, Network activity, and what leaves this iPhone (PhoneTrust.swift).
            PhonePrivacyRow(hue: RefinedRules.settingsHue(0)) { open(.privacy) }
                .settingsSearchTarget("privacyRow", flash: searchFlash)
            squareDivider
            Button {
                exporting = true
                Task {
                    exportURL = await app.exportEverything()
                    exporting = false
                }
            } label: {
                SettingsRow(hue: RefinedRules.settingsHue(1), art: .iconExport, title: "Export everything") {
                    if exporting { ProgressView().controlSize(.small) } else { SettingsValue("Zip"); SettingsChevron() }
                }
            }
            .buttonStyle(SettingsRowPress())
            .disabled(exporting)
            .accessibilityHint("Markdown and JSON in one zip")
            .settingsSearchTarget("export", flash: searchFlash)
        }
        PaperCard {
            if Cloud.available {
                SettingsToggleRow(title: "iCloud sync", subtitle: syncSubtitle, isOn: Binding(get: { syncWanted }, set: { on in
                    if on { syncWanted = true; Cloud.setWantsSync(true) } else { confirmSyncOff = true }
                }))
                .disabled(copyingDown)
                .settingsSearchTarget("sync", flash: searchFlash)
            } else {
                SettingsRow(hue: .neutral, art: .iconSyncOff, title: "iCloud is off",
                            subtitle: "Sign in to iCloud in the Settings app to sync with your Mac. Until then, everything stays on this iPhone.",
                            subtitleLines: nil) { EmptyView() }
                    .accessibilityElement(children: .combine)
                    .settingsSearchTarget("sync", flash: searchFlash)
            }
        }
        PaperCard {
            Button { confirmDelete = true } label: {
                SettingsRow(hue: RefinedRules.settingsHue(0, destructive: true), art: .iconDeleteAll, title: "Delete all data", danger: true) { EmptyView() }
            }
            .buttonStyle(SettingsRowPress())
            .accessibilityHint("Asks twice before it deletes anything")
            .settingsSearchTarget("deleteAll", flash: searchFlash)
        }
    }

    @ViewBuilder private var account: some View {
        // Verbose has no account; your name is shown here and edited in About me.
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        PaperCard {
            pageRow("yourNameRow", .aboutMe, 0, art: .iconAboutMe, title: "Your name", value: name.isEmpty ? "Add" : name)
        }
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

    /// Appearance's value on the root: light or dark, as the mockup shows it.
    static func appearanceLabel(_ raw: String) -> String {
        AppearanceScreen.modes.first { $0.0 == raw }?.1 ?? "Match the system"
    }

    /// The sync row's line while something is happening; nil once it has settled (the switch says the rest).
    private var syncSubtitle: String? {
        if copyingDown { return "Copying your library to this iPhone…" }
        if copyFailed > 0 { return "\(copyFailed) file\(copyFailed == 1 ? "" : "s") couldn't be downloaded from iCloud, so sync is still on. Check your connection and try again." }
        if syncWanted != Cloud.enabled {
            return syncWanted ? "Starts the next time you open Verbose." : "Your library is on this iPhone. Syncing stops the next time you open Verbose (swipe it away to finish now)."
        }
        return nil
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
        PaperCard {
            actionRow("support", 0, art: .iconSupport, title: "Contact support", hint: "Writes an email to support") {
                if let u = Links.mail(subject: "Verbose support") { openURL(u) }
            }
            squareDivider
            actionRow("feedback", 1, art: .iconFeedback, title: "Share feedback", hint: "Writes an email with your feedback") {
                if let u = Links.mail(subject: "Verbose feedback") { openURL(u) }
            }
            squareDivider
            ShareLink(item: Log.file, subject: Text("Verbose diagnostic log"),
                      message: Text("Send to \(Links.supportEmail)")) {
                SettingsRow(hue: RefinedRules.settingsHue(2), art: .iconDiagnosticLog, title: "Send diagnostic log") { SettingsChevron() }
            }
            .buttonStyle(SettingsRowPress())
            .simultaneousGesture(TapGesture().onEnded { Log.trimNow() })
            .accessibilityHint("7 days of app events, without links or folder names")
            .settingsSearchTarget("log", flash: searchFlash)
            squareDivider
            actionRow("privacy", 3, art: .iconPrivacy, title: "Privacy policy", hint: "Opens the privacy policy") { openURL(Links.privacy) }
            squareDivider
            actionRow("terms", 4, art: .iconTerms, title: "Terms of use", hint: "Opens the terms of use") { openURL(Links.terms) }
            squareDivider
            ShareLink(item: Links.base) {
                SettingsRow(hue: RefinedRules.settingsHue(5), art: .iconShare, title: "Share Verbose") { SettingsChevron() }
            }
            .buttonStyle(SettingsRowPress())
            .settingsSearchTarget("share", flash: searchFlash)
            squareDivider
            actionRow("acknowledgements", 6, art: .iconDetails, title: "Acknowledgements", hint: "Open-source software in Verbose and its licenses") {
                showAcknowledgements = true
            }
        }
    }

    @ViewBuilder private var features: some View {
        PaperCard {
            pageRow("thoughtsRow", .thoughts, 0, art: .iconThought, title: "Thoughts",
                    value: Self.thoughtsValue(app.store.todaysThoughts().count))
            squareDivider
            pageRow("templatesRow", .templates, 1, art: .iconSummaries, title: "Templates",
                    value: Self.templatesValue(TemplateSettingsModel.shared.settings.assignedCount))
            squareDivider
            pageRow("widgetsRow", .widgets, 2, art: .iconHome, title: "Widgets and controls")
            squareDivider
            pageRow("shortcutsRow", .shortcuts, 3, art: .iconAI, title: "Shortcuts and Siri")
            squareDivider
            pageRow("tourRow", .tour, 4, art: .iconTour, title: "Welcome tour")
        }
    }

    /// Thoughts' row: today's count ("3 today"), or nothing yet.
    static func thoughtsValue(_ n: Int) -> String? { n > 0 ? "\(n) today" : nil }

    /// Templates' row: how many kinds run one automatically ("2 automatic"), or Off.
    static func templatesValue(_ n: Int) -> String { n > 0 ? "\(n) automatic" : "Off" }

    /// The lockup (DESIGN.md §4) and the tagline in the serif, then "Version 1.0 beta (217)" (the marketing version,
    /// the channel, and the build, VERSIONING.md) with What's new as a link.
    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                BarsMark(color: Refined.persimmon).frame(width: 17, height: 18)
                Refined.wordmark(22, color: Refined.ink)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")
            Text(Refined.tagline).font(.system(.callout, design: .serif)).foregroundStyle(Refined.dim).padding(.bottom, 6)
            // The version opens What's new.
            Button { open(.whatsNew) } label: {
                VStack(spacing: 2) {
                    Text("Version \(AppVersion.label)").foregroundStyle(Refined.mute)
                    Text("What's new").fontWeight(.semibold).foregroundStyle(Refined.accentText)
                }
                .refinedFont(.meta)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Version \(AppVersion.spoken). What's new")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows what's new in each build")
            .settingsSearchTarget("version", flash: searchFlash)
            Text("Verbose · Stump & Root Co.").refinedFont(.meta).foregroundStyle(Refined.mute)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: Helpers

    /// A group (mockup): its label over its cards, then its note.
    private func group<Cards: View>(_ index: Int, _ title: String, footer: String? = nil, @ViewBuilder _ cards: () -> Cards) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).refinedFont(.meta).foregroundStyle(Refined.mute)
                .padding(.horizontal, 14)
                .accessibilityAddTraits(.isHeader)
            cards()
            if let footer {
                Text(footer).refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.top, 22)
        .id("group-\(index)")
    }

    /// Pushes a page. Asking for one while another is showing swaps it, so a request always lands on its page.
    private func open(_ p: SettingsSubpage) {
        if p == .customizeHome && !CustomizeHomeEntry.isAvailable { return }
        page = p
    }

    private func openRequestedPage() {
        guard let name = SettingsPage.take() else { return }
        switch name {
        case "you": showYou = true
        // Back to Settings itself (the screenshot tour, between subpages).
        case "root": page = nil
        default: if let p = SettingsSubpage(rawValue: name) { open(p) }
        }
    }

    /// A search result was chosen: clear the search, then push its subpage, or scroll to its row and flash it.
    private func pickSearchResult(_ entry: SettingsSearchEntry, _ proxy: ScrollViewProxy) {
        search.query = ""
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        switch entry.target {
        case .page(let p): open(p)
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

/// A settings row's square and text (the refined kit's `IconSquare`): the colored square with its glyph, the title,
/// and an optional line under it. A destructive row has a neutral square and a red title (`Refined.danger`).
struct SettingsLabel: View {
    var hue: RefinedHue = .neutral
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var danger = false

    var body: some View {
        HStack(spacing: 12) {
            IconSquare(art: art ?? .iconDetails, hue: danger ? .neutral : hue)
            if !title.isEmpty || subtitle != nil {
                SettingsRowText(title: title, subtitle: subtitle, subtitleLines: subtitleLines, danger: danger)
            }
        }
    }
}

/// A row's title over its optional line, in the kit's body and meta styles.
struct SettingsRowText: View {
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var danger = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).refinedFont(.body).foregroundStyle(danger ? Refined.danger : Refined.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).refinedFont(.meta).foregroundStyle(Refined.mute)
                    .lineLimit(subtitleLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

/// One settings row that opens, runs, or chooses something: its square, the title and line, then a value, chevron,
/// or control. At least 52 pt tall (44 pt to tap, as the mockup's rows). VoiceOver reads the title, the line, and
/// the value as one element.
struct SettingsRow<Trailing: View>: View {
    var hue: RefinedHue = .neutral
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var danger = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(hue: hue, art: art, title: title, subtitle: subtitle, subtitleLines: subtitleLines, danger: danger)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A switch row (mockup): the title and its line, then the system switch in its green. No square: switches sit in a
/// card of their own. VoiceOver reads it as a switch with the title.
struct SettingsToggleRow: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowText(title: title, subtitle: subtitle, subtitleLines: nil)
        }
        .toggleStyle(.switch)
        .refinedSwitchTint()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }
}

/// A row's value, in `mute`.
struct SettingsValue: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).refinedFont(.body).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1) }
}

/// The chevron at the end of a row that opens something.
struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Refined.faint).accessibilityHidden(true)
    }
}

/// Marks a row that opens a menu of choices.
struct SettingsMenuMark: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Refined.faint).accessibilityHidden(true)
    }
}

/// The hairline between rows in a card, inset to where a row's text starts (14 pt; 56 pt past a square).
struct SettingsDivider: View {
    var leading: CGFloat = 14
    var body: some View { PaperDivider(leading: leading) }
}

/// Rows take the neutral wash while pressed (a color change, not movement).
struct SettingsRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Refined.neutral.opacity(configuration.isPressed ? 1 : 0))
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
        SettingsPageScaffold(title: "About me") {
            SettingsPageGroup(title: "Your name", first: true) {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .refinedFont(.body).foregroundStyle(Refined.ink)
                    .padding(.horizontal, 14).frame(minHeight: 48)
                    .accessibilityLabel("Your name")
            }
            SettingsPageGroup(title: "About me") {
                ZStack(alignment: .topLeading) {
                    if aboutMe.isEmpty {
                        Text("For example: I'm a teacher. I record lessons and parent meetings, and often mention Room 12 and the spring fair.")
                            .refinedFont(.body).foregroundStyle(Refined.mute)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $aboutMe)
                        .focused($focused)
                        .refinedFont(.body).foregroundStyle(Refined.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .accessibilityLabel("About me")
                }
                .padding(10)
                .onChange(of: aboutMe) { _, v in
                    if v.count > Profile.aboutMeLimit { aboutMe = String(v.prefix(Profile.aboutMeLimit)) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Verbose uses this on device to spell names correctly and to write titles and summaries. It syncs with your Mac when iCloud sync is on.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(aboutMe.count)/\(Profile.aboutMeLimit)").refinedFont(.caption).monospacedDigit().foregroundStyle(Refined.mute)
                    .accessibilityLabel("\(aboutMe.count) of \(Profile.aboutMeLimit) characters")
            }
            .padding(.horizontal, 14).padding(.top, 8)
        }
        .onAppear { Self.visible = true; if aboutMe.isEmpty, !PhoneUITest.enabled { focused = true } }
        .onDisappear { Self.visible = false }
    }
}
