import SwiftUI

// The You page on iPhone (Settings › You, and Home's This week card) in the refined look (DESIGN.md §13): who you are, your week of dictation, About me, your voice, and cleanup, built from the kit. The
// iPhone's keyboard can't tell which app a dictation went to, so there's no "Where you dictate" here (the Mac's You
// page lists apps and websites), and it keeps no separate activity log, so there's nothing to reset: the week is
// counted from your dictations, the same as Home's This week card.

extension Notification.Name {
    /// UI tour: opens About me from the You page (`true`), or closes the You page (`false`).
    static let verbatimYouPage = Notification.Name("verbatimYouPage")
}

struct YouScreen: View {
    /// Ticks `now` once a minute: one timer for every render. Built in `body`, each render made a new timer and
    /// restarted the minute, so under frequent renders (transcribing, playing, dictating) it never fired.
    private static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @EnvironmentObject var app: PhoneState
    /// Leaves the You page for a row in Settings (Cloud cleanup): Settings pops back and flashes the row.
    var openSettingsRow: (String) -> Void = { _ in }

    @AppStorage("profile.name") private var storedName = ""
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage(CloudCleanup.enabledKey) private var cloudCleanup = false
    @ObservedObject private var flow = FlowSettings.shared
    @ObservedObject private var voice = VoiceProfileStatus.shared
    @State private var editingAbout = false
    @State private var showVoice = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var now = Date()

    /// Whether the You page is on screen, for the UI tour's checks.
    static var visible = false
    /// How many You pages are on screen (the self-test checks the page draws).
    static var onScreen = 0

    var body: some View {
        let week = app.store.dictationWeek(now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                weekSection(week).padding(.top, 26)
                aboutSection.padding(.top, 26)
                voiceSection.padding(.top, 26)
                cleanupSection.padding(.top, 26)
                footer.padding(.top, 18)
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .navigationDestination(isPresented: $editingAbout) { AboutMeScreen() }
        .navigationDestination(isPresented: $showVoice) { VoiceProfileScreen(preview: false) }
        .onAppear { Self.visible = true; Self.onScreen += 1; now = Date(); voice.refresh() }
        .onDisappear { Self.visible = false; Self.onScreen = max(0, Self.onScreen - 1); commitName() }
        .onReceive(Self.minute) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimYouPage)) { note in
            if note.object as? Bool == true { editingAbout = true }
        }
    }

    // MARK: Header

    /// Your initial on persimmon, "You", and your name in the large serif (tap it to change it in place), then where
    /// these settings live.
    private var header: some View {
        let name = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                InitialBadge(name: name, size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You").refinedFont(.meta).foregroundStyle(Refined.mute)
                    if editingName {
                        TextField("Your name", text: $nameDraft)
                            .refinedFont(.largeTitle).foregroundStyle(Refined.ink)
                            .tint(Refined.accentText)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .focused($nameFocused)
                            .onSubmit { commitName() }
                            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                            .accessibilityLabel("Your name")
                    } else {
                        Button { beginName(name) } label: {
                            Text(name.isEmpty ? "Add your name" : name)
                                .refinedFont(.largeTitle)
                                .foregroundStyle(name.isEmpty ? Refined.mute : Refined.ink)
                                .lineLimit(3).minimumScaleFactor(0.7)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name.isEmpty ? "Add your name" : name)
                        .accessibilityHint("Changes your name. It greets you on Home.")
                        .accessibilityAddTraits(.isHeader)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(privacyLine).refinedFont(.meta).foregroundStyle(Refined.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Your name and About me travel with iCloud sync (Store.SyncedProfile); the voice profile never leaves.
    private var privacyLine: String {
        Cloud.enabled
            ? "Your name and About me sync with your Mac. Your voice stays on this iPhone."
            : "Everything here stays on this iPhone."
    }

    private func beginName(_ name: String) {
        nameDraft = name
        editingName = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitName() {
        guard editingName else { return }
        storedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingName = false
    }

    // MARK: Your week

    /// The week (the same count as Home): This week's card with its words, the time saved, and seven bars, today's in
    /// persimmon; then your typing speed, which the time saved compares against, and your pace.
    private func weekSection(_ week: HomeWeek) -> some View {
        let saved = HomeWeek.savedText(week.secondsSaved(typingWPM: flow.typingWPM))
        let pace = Self.pace(words: week.words, seconds: week.seconds)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Your week") {
                Text(Self.rangeLabel(week)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1)
            }
            WeekCard(words: week.words, detail: week.words == 1 ? "word dictated" : "words dictated", saved: "\(saved) saved", days: week.cardDays)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated, \(saved) saved typing.")
                .accessibilityIdentifier("you.week")
            PaperCard {
                Menu {
                    Picker("Your typing speed", selection: $flow.typingWPM) {
                        ForEach(Self.typingSpeeds(flow.typingWPM), id: \.self) { w in Text("\(w) wpm").tag(w) }
                    }
                } label: {
                    SettingsRow(hue: RefinedRules.settingsHue(0), art: .iconFeedback, title: "Typing speed",
                                subtitle: "Time saved compares dictating with typing at this speed") {
                        SettingsValue("\(flow.typingWPM) wpm"); SettingsMenuMark()
                    }
                }
                .buttonStyle(SettingsRowPress())
                .accessibilityHint("Shows the speeds")
                PaperDivider(leading: 56)
                SettingsRow(hue: RefinedRules.settingsHue(1), art: .iconVoice, title: "Your pace",
                            subtitle: pace == nil ? "After 20 seconds of dictation" : nil) {
                    SettingsValue(pace.map { "\($0) wpm" } ?? "–")
                }
                .accessibilityLabel(pace.map { "Your pace, \($0) words per minute" } ?? "Your pace: not enough dictation yet")
            }
            if week.words == 0 {
                Text("Dictate with the Verbose keyboard or the Action button. Your totals show up here.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }

    /// Words per minute while talking, once there's 20 seconds of dictation to judge by (the Mac's rule).
    static func pace(words: Int, seconds: Double) -> Int? {
        seconds >= 20 ? Int((Double(words) / (seconds / 60)).rounded()) : nil
    }

    /// The speeds the typing menu offers, with yours included if it's something else.
    static func typingSpeeds(_ current: Int) -> [Int] {
        var speeds = [20, 30, 40, 50, 60, 70, 80, 100, 120]
        if !speeds.contains(current) { speeds.append(current); speeds.sort() }
        return speeds
    }

    /// "Oct 19 – 25" or "Sep 28 – Oct 4".
    static func rangeLabel(_ week: HomeWeek, calendar: Calendar = .current) -> String {
        guard let first = week.days.first?.start, let last = week.days.last?.start else { return "This week" }
        let a = Formats.pattern("MMM d").string(from: first)
        let b = calendar.isDate(first, equalTo: last, toGranularity: .month)
            ? Formats.pattern("d").string(from: last) : Formats.pattern("MMM d").string(from: last)
        return "\(a) – \(b)"
    }

    // MARK: About me

    static let aboutPlaceholder = "A line or two about you and your work, and the names you use often."

    /// About me in a card: what you wrote (or a suggestion), and what Verbose does with it. The whole card opens the
    /// editor (300 characters, with its counter).
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("About me", link: aboutMe.isEmpty ? "Add" : "Edit") { commitName(); editingAbout = true }
            Button { commitName(); editingAbout = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(aboutMe.isEmpty ? Self.aboutPlaceholder : aboutMe)
                        .refinedFont(.body)
                        .foregroundStyle(aboutMe.isEmpty ? Refined.mute : Refined.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Verbose uses this to spell names correctly and to write titles and summaries.")
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
            }
            .buttonStyle(RefinedPress())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(aboutMe.isEmpty ? "Add About me" : "Edit About me")
            .accessibilityValue(aboutMe.isEmpty ? Self.aboutPlaceholder : aboutMe)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Verbose uses this to spell names correctly and to write titles and summaries.")
        }
    }

    // MARK: Your voice

    /// Your voice: how well Verbose knows it, and a row that sets it up or reads more passages.
    private var voiceSection: some View {
        let known = voice.isEnrolled || voice.isPartial
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Your voice")
            PaperCard {
                Button { commitName(); showVoice = true } label: {
                    SettingsRow(hue: RefinedRules.settingsHue(2), art: .iconVoice, title: known ? "Read more passages" : "Set up your voice",
                                subtitle: voice.line, subtitleLines: nil) {
                        SettingsChevron()
                    }
                }
                .buttonStyle(SettingsRowPress())
                .accessibilityHint(known ? "Read more passages so Verbose knows your voice better." : "Set up your voice.")
            }
        }
    }

    // MARK: Cleanup

    /// The cleanup level (the same setting as Settings › Cleanup), what it does, and a link to Cloud cleanup.
    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Cleanup")
            PaperCard {
                VStack(alignment: .leading, spacing: 10) {
                    RefinedSegmented(label: "Cleanup level", options: CleanupLevel.allCases.map { ($0, $0.title) }, selection: $flow.cleanup)
                    Text(SettingsScreen.cleanupNote(flow.cleanup))
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                PaperDivider(leading: 14)
                Button { commitName(); openSettingsRow("cloudCleanup") } label: {
                    SettingsRow(hue: RefinedRules.settingsHue(3), art: .iconServer, title: "Cloud cleanup",
                                subtitle: cloudCleanup ? "On, with your own key" : "Off. Cleanup runs on this iPhone.") {
                        SettingsValue("Settings"); SettingsChevron()
                    }
                }
                .buttonStyle(SettingsRowPress())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Cloud cleanup")
                .accessibilityValue(cloudCleanup ? "On" : "Off")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens it in Settings.")
            }
        }
    }

    // MARK: Footer

    /// Everything else you've transcribed on any device (recordings, imports, links).
    private var footer: some View {
        let files = app.store.memo("phone.you-files") { app.store.live.filter { !$0.isDictation && $0.status == .ready } }
        let seconds = files.reduce(0) { $0 + $1.duration }
        return Group {
            if !files.isEmpty {
                Text("You've also transcribed \(Self.total(seconds)) across \(files.count) \(files.count == 1 ? "recording or link" : "recordings and links").")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }

    /// "42 s", "18 min", "2 h", "2 h 14 min".
    static func total(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}
