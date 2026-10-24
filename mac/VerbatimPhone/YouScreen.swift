import SwiftUI

// brand: web style
//
// The You page on iPhone (Settings › You, and Home's This week card): who you are, About me, your voice, your week of
// dictation, and cleanup, in the website style. The iPhone's keyboard can't tell which app a dictation went to, so
// there's no "Where you dictate" here, and it keeps no separate activity log, so there's nothing to reset: the week
// is counted from your dictations, the same as Home's This week card.

extension Notification.Name {
    /// UI tour: opens About me from the You page (`true`), or closes the You page (`false`).
    static let verbatimYouPage = Notification.Name("verbatimYouPage")
}

struct YouScreen: View {
    @EnvironmentObject var app: PhoneState
    /// Leaves the You page for a row in Settings (Cloud cleanup): Settings pops back and flashes the row.
    var openSettingsRow: (String) -> Void = { _ in }

    @AppStorage("profile.name") private var storedName = ""
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage(CloudCleanup.enabledKey) private var cloudCleanup = false
    @ObservedObject private var flow = FlowSettings.shared
    @ObservedObject private var voice = VoiceProfileStatus.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editingAbout = false
    @State private var showVoice = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var seen = SeenRows()
    @State private var now = Date()

    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var cardTitle: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var voiceSize: CGFloat = 24
    @ScaledMetric(relativeTo: .title) private var statSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var body15: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var small: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var label: CGFloat = 12.5
    @ScaledMetric(relativeTo: .caption) private var monoSize: CGFloat = 12
    @ScaledMetric(relativeTo: .largeTitle) private var avatar: CGFloat = 60

    /// Whether the You page is on screen, for the UI tour's checks.
    static var visible = false

    var body: some View {
        let week = HomeWeek(HomeCounts.entries(fromDictations: app.store.live), now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .riseIn("header", index: 0, seen: seen, epoch: 0, scrollRise: false)
                aboutCard.padding(.top, 22)
                    .riseIn("about", index: 1, seen: seen, epoch: 0)
                voicePanel.padding(.top, 14)
                    .riseIn("voice", index: 2, seen: seen, epoch: 0)
                weekCard(week).padding(.top, 14)
                    .riseIn("week", index: 3, seen: seen, epoch: 0)
                cleanupCard.padding(.top, 14)
                    .riseIn("cleanup", index: 4, seen: seen, epoch: 0)
                footer.padding(.top, 18)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .navigationDestination(isPresented: $editingAbout) { AboutMeScreen() }
        .navigationDestination(isPresented: $showVoice) { VoiceProfileScreen(preview: false) }
        .onAppear { Self.visible = true; now = Date(); voice.refresh() }
        .onDisappear { Self.visible = false; commitName() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimYouPage)) { note in
            if note.object as? Bool == true { editingAbout = true }
        }
    }

    // MARK: Header

    /// Your initial on the record color with an ink outline, the mono eyebrow, and your name in the serif with the last
    /// name in italic. Tap the name to change it in place.
    private var header: some View {
        let name = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = Self.nameParts(name)
        let circle = min(avatar, 96)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(PhoneInk.record)
                    Circle().strokeBorder(Ink.inkFixed, lineWidth: 1.5)
                    if let first = name.first {
                        Text(String(first).uppercased()).font(Ink.serif(circle * 0.47)).foregroundStyle(Ink.inkFixed)
                    } else {
                        IconGlyph(art: .iconAboutMe, size: circle * 0.42, color: Ink.inkFixed)
                    }
                }
                .frame(width: circle, height: circle)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    PhoneEyebrow(text: "You")
                    if editingName {
                        TextField("Your name", text: $nameDraft)
                            .font(Ink.serif(nameSize)).foregroundStyle(Ink.ink)
                            .tint(Ink.accentText)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .focused($nameFocused)
                            .onSubmit { commitName() }
                            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                            .accessibilityLabel("Your name")
                    } else {
                        Button { beginName(name) } label: {
                            Group {
                                if name.isEmpty {
                                    Text("Add your name").italic().foregroundStyle(Ink.mute)
                                } else if let last = parts.1 {
                                    Text(parts.0 + " ") + Text(last).italic()
                                } else {
                                    Text(parts.0)
                                }
                            }
                            .font(Ink.serif(nameSize)).tracking(-0.6)
                            .foregroundStyle(Ink.ink)
                            .lineLimit(3).minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(privacyLine).font(Ink.mono(monoSize)).foregroundStyle(Ink.mute)
                .lineSpacing(3)
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

    /// "Tim Medina" → ("Tim", "Medina"); one word → (word, nil). The last word is the italic one.
    static func nameParts(_ name: String) -> (String, String?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = n.lastIndex(of: " ") else { return (n, nil) }
        let first = n[..<space].trimmingCharacters(in: .whitespaces)
        let last = n[n.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return last.isEmpty || first.isEmpty ? (n, nil) : (first, last)
    }

    // MARK: About me

    static let aboutPlaceholder = "A line or two about you and your work, and the names you use often."

    /// A paper card with an ink outline. The whole card opens the About me editor (300 characters, with its counter).
    private var aboutCard: some View {
        Button { commitName(); editingAbout = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("About me").font(Ink.serif(cardTitle)).foregroundStyle(Ink.ink)
                    Spacer(minLength: 8)
                    Text(aboutMe.isEmpty ? "Add" : "Edit")
                        .font(.system(size: small + 1, weight: .semibold)).foregroundStyle(Ink.accentText)
                }
                Text(aboutMe.isEmpty ? Self.aboutPlaceholder : aboutMe)
                    .font(.system(size: body15)).lineSpacing(3)
                    .foregroundStyle(aboutMe.isEmpty ? Ink.mute : Ink.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Verbose uses this to spell names and word titles and summaries.")
                    .font(.system(size: small)).foregroundStyle(Ink.mute)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .phoneOutlined(radius: Radius.record)
            .contentShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(aboutMe.isEmpty ? "Add About me" : "Edit About me")
        .accessibilityValue(aboutMe.isEmpty ? Self.aboutPlaceholder : aboutMe)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Verbose uses this to spell names and word titles and summaries.")
    }

    // MARK: Your voice

    /// A sage panel with grain and the rings in the bottom-right corner. The corner is kept clear in the layout, so
    /// the drawing never sits under text. The whole panel opens Your voice.
    private var voicePanel: some View {
        let known = voice.isEnrolled || voice.isPartial
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        return Button { commitName(); showVoice = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                PhoneEyebrow(text: "Your voice", color: Ink.inkFixed)
                Text(voice.line).font(Ink.serif(voiceSize)).foregroundStyle(Ink.inkFixed)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .bottom, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(known ? "Read more passages" : "Set up your voice")
                        Image(systemName: "arrow.right").font(.system(size: small, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: small + 1, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    // The rings' corner (the drawing shows about 90 × 92 pt of it, less the padding).
                    Color.clear.frame(width: 74, height: 76).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .bottomTrailing) {
                    PhonePanelFill(color: PhoneInk.sage, shape: shape)
                    PhonePanelArt(kind: .rings).frame(width: 124, height: 124).offset(x: 32, y: 30)
                }
                .clipShape(shape)
            }
            .contentShape(shape)
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your voice")
        .accessibilityValue(voice.line)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(known ? "Read more passages so Verbose knows your voice better." : "Set up your voice.")
    }

    // MARK: Your week

    /// The week's words, the time saved against typing, and your speaking pace, then a bar for each day: today in
    /// butter with an ink outline, earlier days in ink, days still to come as stubs. The same count as Home.
    private func weekCard(_ week: HomeWeek) -> some View {
        let saved = HomeScreen.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM))
        let pace = Self.pace(words: week.words, seconds: week.seconds)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Your week").font(Ink.serif(cardTitle)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.rangeLabel(week)).font(Ink.mono(monoSize)).foregroundStyle(Ink.mute)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
            layout {
                stat(week.words.formatted(), "words dictated")
                    .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 2) {
                    statValue(saved)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("saved vs. typing at").font(.system(size: label)).foregroundStyle(Ink.dim)
                        Menu {
                            Picker("Your typing speed", selection: $flow.typingWPM) {
                                ForEach(Self.typingSpeeds(flow.typingWPM), id: \.self) { w in Text("\(w) wpm").tag(w) }
                            }
                        } label: {
                            Text("\(flow.typingWPM) wpm").font(.system(size: label, weight: .semibold)).underline()
                                .foregroundStyle(Ink.ink)
                                .frame(minHeight: 28, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Typing speed")
                        .accessibilityValue("\(flow.typingWPM) words per minute")
                        .accessibilityHint("Time saved compares dictating with typing at this speed.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                stat(pace.map { "\($0)" } ?? "–", "words per minute")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pace.map { "\($0) words per minute" } ?? "Words per minute: not enough dictation yet")
            }
            YouWeekBars(week: week)
                .frame(height: 132)
            if week.words == 0 {
                Text("Dictate with the Verbose keyboard or the Action button. Your totals show up here.")
                    .font(.system(size: small)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneOutlined(radius: Radius.record)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            statValue(value)
            Text(caption).font(.system(size: label)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statValue(_ value: String) -> some View {
        Text(value).font(Ink.serif(statSize)).foregroundStyle(Ink.ink)
            .lineLimit(1).minimumScaleFactor(0.55)
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

    // MARK: Cleanup

    /// The cleanup level (the same setting as Settings › Cleanup), what it does, and a link to Cloud cleanup.
    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cleanup").font(Ink.serif(cardTitle)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    PhoneSegmented(options: CleanupLevel.allCases.map { ($0, $0.title) }, selection: $flow.cleanup)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Cleanup level")
                    Picker("Cleanup level", selection: $flow.cleanup) {
                        ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).tint(Ink.ink)
                }
                Text(SettingsScreen.cleanupNote(flow.cleanup))
                    .font(.system(size: small)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Rectangle().fill(Ink.hairline).frame(height: 1)
            Button { commitName(); openSettingsRow("cloudCleanup") } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloud cleanup").font(.system(size: body15 + 1)).foregroundStyle(Ink.ink)
                        Text(cloudCleanup ? "On, with your own key" : "Off. Cleanup runs on this iPhone.")
                            .font(.system(size: small)).foregroundStyle(Ink.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text("Settings").font(.system(size: body15)).foregroundStyle(Ink.mute)
                    SettingsChevron()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowPress())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cloud cleanup")
            .accessibilityValue(cloudCleanup ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens it in Settings.")
        }
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.record, style: .continuous).strokeBorder(Ink.hairline))
    }

    // MARK: Footer

    /// Everything else you've transcribed on any device (recordings, imports, links).
    private var footer: some View {
        let files = app.store.live.filter { !$0.isDictation && $0.status == .ready }
        let seconds = files.reduce(0) { $0 + $1.duration }
        return Group {
            if !files.isEmpty {
                Text("You've also transcribed \(Self.total(seconds)) across \(files.count) \(files.count == 1 ? "recording or link" : "recordings and links").")
                    .font(.system(size: small)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
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

// MARK: - Week bars

/// Seven day bars over mono day letters. Today is butter with an ink outline, earlier days ink, and days still to
/// come a short stub. Scaled to the week's busiest day.
struct YouWeekBars: View {
    var week: HomeWeek
    @ScaledMetric(relativeTo: .caption) private var monoSize: CGFloat = 12

    var body: some View {
        let peak = CGFloat(max(1, week.peak))
        let letters = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 6) {
                    GeometryReader { g in
                        let full = g.size.height
                        let h: CGFloat = day.isFuture || day.words == 0 ? 3 : max(6, full * CGFloat(day.words) / peak)
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            bar(day, height: day.isToday ? max(h, 8) : h)
                        }
                        .frame(width: g.size.width, height: full)
                    }
                    Text(letters[(Calendar.current.component(.weekday, from: day.start) - 1) % letters.count])
                        .font(Ink.mono(monoSize, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? Ink.ink : Ink.mute)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words by day")
        .accessibilityValue(summary)
    }

    @ViewBuilder private func bar(_ day: HomeWeek.Day, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if day.isToday {
            shape.fill(PhoneInk.butter)
                .overlay(shape.strokeBorder(Ink.ink, lineWidth: 1.5))
                .frame(maxWidth: 30).frame(height: height)
        } else if day.isFuture || day.words == 0 {
            shape.fill(Ink.ink.opacity(day.isFuture ? 0.18 : 0.32))
                .frame(maxWidth: 30).frame(height: height)
        } else {
            shape.fill(Ink.ink).frame(maxWidth: 30).frame(height: height)
        }
    }

    /// "Monday 120 words, Tuesday none, Wednesday (today) 40 words, Thursday to come…"
    private var summary: String {
        week.days.map { day in
            let name = Formats.pattern("EEEE").string(from: day.start)
            if day.isFuture { return "\(name), to come" }
            let words = day.words == 0 ? "no words" : HomeCounts.countLabel(day.words, "word", "words")
            return day.isToday ? "\(name), today, \(words)" : "\(name), \(words)"
        }
        .joined(separator: "; ")
    }
}
