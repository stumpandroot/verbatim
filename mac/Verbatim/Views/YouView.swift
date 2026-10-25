import SwiftUI
import AppKit
import os

// brand: web style
//
// The You page (sidebar › You; it replaced Activity, and keeps its screen key "activity" so links still land):
// who you are, About me, cleanup, your voice, your week or month of dictation, and where you dictate, websites by
// domain only. Counted on this Mac; nothing here leaves it.

/// Your name and About me. About me uses the iPhone's key (`Profile.aboutMeKey`), so it's the same setting.
enum YouProfile {
    static let nameKey = "profile.name"
    static let aboutMeKey = "profile.aboutMe"
    static let aboutMeLimit = 300

    /// The saved name, or the Mac account's full name until you set one.
    static func displayName(_ stored: String) -> String {
        let s = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? "You" : full
    }

    static func initial(_ name: String) -> String { name.first.map { String($0).uppercased() } ?? "Y" }
}

/// Week and month ranges for the chart. Weeks start on the calendar's first weekday (from your region).
enum YouRange {
    enum Span: String, CaseIterable, Identifiable {
        case week, month
        var id: String { rawValue }
        var title: String { self == .week ? "Week" : "Month" }
    }

    static func interval(_ span: Span, containing date: Date, calendar: Calendar) -> DateInterval {
        let unit: Calendar.Component = span == .week ? .weekOfYear : .month
        if let i = calendar.dateInterval(of: unit, for: date) { return i }
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, duration: span == .week ? 7 * 86_400 : 30 * 86_400)
    }

    /// The start of each day in the interval.
    static func days(in interval: DateInterval, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var d = calendar.startOfDay(for: interval.start)
        while d < interval.end, out.count < 32 {
            out.append(d)
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    /// The same span `n` weeks or months away.
    static func shifted(_ date: Date, _ span: Span, by n: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: span == .week ? .weekOfYear : .month, value: n, to: date) ?? date
    }

    static func isCurrent(_ interval: DateInterval, now: Date = Date()) -> Bool { now >= interval.start && now < interval.end }
}

struct YouView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var sites = SiteLog.shared
    @ObservedObject private var settings = FlowSettings.shared
    @ObservedObject private var voice = VoiceProfileStatus.shared
    @AppStorage(YouProfile.nameKey) private var storedName = ""
    @AppStorage(YouProfile.aboutMeKey) private var aboutMe = ""
    @AppStorage(CloudCleanup.enabledKey) private var cloudCleanup = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.limitMotion) private var limitMotion
    @State private var span: YouRange.Span = .week
    @State private var anchor = Date()
    @State private var confirmReset = false
    @State private var editingAbout = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var collapsed: Set<String> = []
    @State private var aboutDown = false
    @State private var voiceDown = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let cal = Calendar.current
        let range = YouRange.interval(span, containing: anchor, calendar: cal)
        let events = log.events.filter { $0.date >= range.start && $0.date < range.end }
        let stats = ActivityStats(events, since: nil)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                RatioRow(weights: [1.15, 1, 0.85], spacing: 16, stackBelow: 640) {
                    aboutCard
                    cleanupCard
                    voiceCard
                }
                .padding(.top, 26)
                RatioRow(weights: [1.6, 1], spacing: 16, stackBelow: 720) {
                    weekCard(range, stats, cal)
                    whereCard(range, events, stats)
                }
                .padding(.top, 16)
                footer.padding(.top, 18)
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .onAppear { log.seedIfNeeded(from: app.store.live); voice.refresh() }
        .sheet(isPresented: $editingAbout) { AboutMeSheet() }
        .confirmationDialog("Reset activity?", isPresented: $confirmReset) {
            Button("Reset activity", role: .destructive) { log.reset(); sites.reset() }
        } message: {
            Text("Clears these numbers and starts counting again. Your dictations and transcripts aren't touched.")
        }
    }

    // MARK: Header

    /// The avatar (your initial on the Record color, ink outline), a mono eyebrow, your name in the serif with the last
    /// name in italic (click to change it), and the privacy note on the right.
    private var header: some View {
        let name = YouProfile.displayName(storedName)
        let parts = WebText.splitLastWord(name)
        return HStack(alignment: .center, spacing: 18) {
            Text(YouProfile.initial(name))
                .font(Ink.serif(32)).foregroundStyle(Ink.inkFixed)
                .frame(width: 64, height: 64)
                .background(Ink.panelRecord, in: Circle())
                .overlay(Circle().inset(by: -0.75).stroke(Ink.inkFixed, lineWidth: 1.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "You")
                if editingName {
                    TextField("Your name", text: $nameDraft)
                        .textFieldStyle(.plain).font(Ink.serif(44)).foregroundStyle(Ink.ink)
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onExitCommand { editingName = false }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                } else {
                    Button { nameDraft = name; editingName = true; nameFocused = true } label: {
                        WebText.serif(parts.0, italic: parts.1, size: 44)
                            .tracking(-0.8)
                            .foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Change your name")
                    .accessibilityLabel(name)
                    .accessibilityHint("Changes your name")
                    .accessibilityAddTraits(.isHeader)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text("Everything here stays on this Mac.\nMirrored in Settings.")
                .font(Ink.mono(12)).foregroundStyle(Ink.mute).multilineTextAlignment(.trailing).lineSpacing(4)
                .fixedSize()
        }
    }

    private func commitName() {
        guard editingName else { return }
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Your Mac account's name again means "follow it": nothing is saved.
        storedName = n == NSFullUserName() ? "" : n
        editingName = false
    }

    // MARK: Cards

    /// About me: the whole card opens the editor, so it tilts like the other big cards.
    private var aboutCard: some View {
        HomeCard(tilt: 1.5, radius: Radius.record, shadow: false, onPress: { aboutDown = $0 }, action: { editingAbout = true }) { hovering in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    YouCardTitle(text: "About me")
                    Spacer(minLength: 8)
                    Text(aboutMe.isEmpty ? "Add" : "Edit").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                }
                Text(aboutMe.isEmpty ? "A line or two about you and your work, and the names you use often." : aboutMe)
                    .font(.system(size: 14.5)).lineSpacing(4)
                    .foregroundStyle(aboutMe.isEmpty ? Ink.mute : Ink.ink)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("Verbose uses this to spell names and word titles and summaries.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .modifier(YouCardFace(hover: hovering, pressed: aboutDown))
        }
        .help(aboutMe.isEmpty ? "Add About me" : "Edit About me")
        .accessibilityLabel(aboutMe.isEmpty ? "Add About me" : "Edit About me")
        .accessibilityValue(aboutMe)
    }

    private var cleanupCard: some View {
        YouPanel(spacing: 14) {
            YouCardTitle(text: "Cleanup and grammar")
            YouToggle(label: "Cleanup level", options: CleanupLevel.allCases, selection: $settings.cleanup, title: { $0.title })
            VStack(spacing: 0) {
                // Grammar fixes follow the cleanup level; there's no separate switch, so this opens Cleanup.
                settingLink("Grammar check", value: "Settings") { openCleanupSetting("dictate.cleanup") }
                settingLink("Tone", value: "Match the app") { openCleanupSetting("dictate.styles") }
                settingLink("Cloud cleanup", value: cloudCleanup ? "On" : "Off") { openCleanupSetting("dictate.cloud") }
            }
        }
    }

    private func settingLink(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Ink.ink)
                Spacer()
                Text("\(value) ›").foregroundStyle(Ink.mute)
            }
            .font(.system(size: 13.5))
            .padding(.vertical, 9)
            .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Opens Settings")
    }

    /// Opens Settings at a dictation setting.
    private func openCleanupSetting(_ id: String) {
        if let e = SettingsIndex.entry(id) { SettingsModel.shared.open(e) }
        else { UserDefaults.standard.set(SettingsTab.dictate.rawValue, forKey: "settingsTab") }
        openSettings()
    }

    /// Your voice on a sage panel with grain and the breathing rings in the bottom-right corner. The corner is kept
    /// clear in the layout, so the drawing never sits under text. The whole card opens voice setup.
    private var voiceCard: some View {
        let known = voice.isEnrolled || voice.isPartial
        let line = Self.voiceLine(voice.line)
        return HomeCard(tilt: 1.5, radius: Radius.record, shadow: false, onPress: { voiceDown = $0 },
                        action: { VoiceEnrollmentSheet.present(readMore: known) }) { hovering in
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Your voice", color: Ink.panelInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.0).font(Ink.serif(24))
                    if let italic = line.1 { Text(italic).font(Ink.serif(24).italic()) }
                }
                .foregroundStyle(Ink.panelInk).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(alignment: .bottom, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(known ? "Read more passages" : "Set up your voice")
                        ArtIcon(art: .webArrow, size: 13, lineWidth: 1.5)
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.panelInk)
                    .fixedSize()
                    Spacer(minLength: 0)
                    // The rings' corner: 88 × 92 pt of the panel, less the padding.
                    Color.clear.frame(width: 64, height: 70).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .colorPanel(Ink.panelSage, radius: Radius.record) {
                Color.clear.overlay(alignment: .bottomTrailing) {
                    PanelArt(kind: .rings).frame(width: 122, height: 122).offset(x: 34, y: 30)
                }
            }
            .inkEdge(outline: hovering, shadow: InkEdge.card(hover: hovering, pressed: voiceDown), radius: Radius.record)
        }
        .help(known ? "Read more passages" : "Set up your voice")
        .accessibilityLabel("Your voice. \(voice.line)")
        .accessibilityHint(known ? "Read more passages" : "Set up your voice")
    }

    /// The voice sentence with its last three words in italic on their own line ("Good. A little more / *makes it
    /// great.*"); short sentences stay upright.
    static func voiceLine(_ s: String) -> (String, String?) {
        let words = s.split(separator: " ")
        guard words.count >= 5 else { return (s, nil) }
        return (words.dropLast(3).joined(separator: " "), words.suffix(3).joined(separator: " "))
    }

    // MARK: Your week

    private func weekCard(_ range: DateInterval, _ stats: ActivityStats, _ cal: Calendar) -> some View {
        let current = YouRange.isCurrent(range)
        return YouPanel(spacing: 14) {
            HStack(alignment: .center, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    YouCardTitle(text: span == .week ? "Your week" : "Your month")
                    Text(Self.rangeLabel(range, span, cal)).font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 8)
                arrow("chevron.left", span == .week ? "Previous week" : "Previous month", enabled: true) { step(-1) }
                arrow("chevron.right", span == .week ? "Next week" : "Next month", enabled: !current) { step(1) }
                YouToggle(label: "Range", options: YouRange.Span.allCases, selection: Binding(get: { span }, set: { s in
                    withAnimation(limitMotion ? nil : Motion.snap) { span = s; anchor = Date() }
                }), title: { $0.title }, small: true)
                .padding(.leading, 4)
            }
            HStack(alignment: .top, spacing: 34) {
                bigStat(stats.words.formatted(), "words dictated")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.duration(stats.secondsSaved(typingWPM: settings.typingWPM))).font(Ink.serif(32)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.6)
                    HStack(spacing: 3) {
                        Text("saved vs. typing at").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                        Menu {
                            ForEach([20, 30, 40, 50, 60, 70, 80, 100, 120], id: \.self) { w in
                                Button { settings.typingWPM = w } label: { Text("\(w) wpm") }
                            }
                        } label: {
                            Text("\(settings.typingWPM) wpm").font(.system(size: 12.5, weight: .semibold)).underline().foregroundStyle(Ink.ink)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Your typing speed")
                        .accessibilityLabel("Typing speed, \(settings.typingWPM) words per minute")
                    }
                }
                bigStat(stats.pace.map { "\($0)" } ?? "–", "words per minute")
            }
            DayBars(days: YouRange.days(in: range, calendar: cal), byDay: stats.byDay, span: span, calendar: cal)
                .frame(minHeight: 200)
            if log.events.isEmpty {
                Text("Dictate into any app with \(app.dictation.hotkey.shortTitle) or \(DictationSurface.stored().clickHint). Your totals show up here.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
        }
    }

    private func step(_ n: Int) {
        let next = YouRange.shifted(anchor, span, by: n, calendar: .current)
        withAnimation(limitMotion ? nil : Motion.snap) { anchor = min(next, Date()) }
    }

    /// A 26 pt round arrow with a hairline ring.
    private func arrow(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Ink.hairline, lineWidth: 1))
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Ink.serif(32)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineSpacing(2)
                .frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Where you dictate

    private func whereCard(_ range: DateInterval, _ events: [ActivityEvent], _ stats: ActivityStats) -> some View {
        let apps = stats.byApp.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(6)
        let top = max(1, apps.first?.value ?? 1)
        return YouPanel(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                YouCardTitle(text: "Where you dictate")
                Text(Self.whereLabel(range, span)).font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            if apps.isEmpty {
                Text(span == .week ? "Nothing dictated this week." : "Nothing dictated this month.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
            }
            VStack(spacing: 2) {
                ForEach(Array(apps.enumerated()), id: \.element.key) { _, entry in
                    appRow(entry.key, entry.value, share: Double(entry.value) / Double(top), hosts: Self.hosts(for: entry.key, events, sites.hosts))
                }
            }
            Spacer(minLength: 4)
            Text("Websites are counted by domain only, never full addresses. macOS asks once per browser.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// An app: its icon, its name, a butter bar for its share (against the app with the most words), and the words in
    /// mono. An app with websites opens to show them.
    private func appRow(_ name: String, _ words: Int, share: Double, hosts: [(String, Int)]) -> some View {
        let open = !hosts.isEmpty && !collapsed.contains(name)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !hosts.isEmpty else { return }
                withAnimation(limitMotion ? nil : .spring(duration: 0.3, bounce: 0)) {
                    if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
                }
            } label: {
                HStack(spacing: 10) {
                    YouAppIcon(name: name).frame(width: 16, height: 16)
                    HStack(spacing: 5) {
                        Text(name).font(.system(size: 13.5)).foregroundStyle(Ink.ink).lineLimit(1).truncationMode(.tail)
                        if !hosts.isEmpty {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.mute)
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                    }
                    .frame(width: 96, alignment: .leading)
                    YouShareBar(share: share, height: 8)
                    Text(words.formatted()).font(Ink.mono(12)).foregroundStyle(Ink.dim).lineLimit(1)
                        .frame(width: 46, alignment: .trailing)
                }
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hosts.isEmpty)
            .accessibilityLabel("\(name), \(words.formatted()) words")
            .accessibilityHint(hosts.isEmpty ? "" : (open ? "Hides websites" : "Shows websites"))
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(hosts.enumerated()), id: \.offset) { _, h in
                        hostRow(h.0, h.1, share: Double(h.1) / Double(max(words, 1)))
                    }
                }
                .padding(.leading, 26).padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }

    private func hostRow(_ host: String, _ n: Int, share: Double) -> some View {
        HStack(spacing: 10) {
            Text(host).font(.system(size: 13)).foregroundStyle(host == Self.otherPages ? Ink.mute : Ink.dim).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            YouShareBar(share: share, height: 5).frame(width: 90)
            Text(n.formatted()).font(Ink.mono(12)).foregroundStyle(Ink.mute).frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(host), \(n.formatted()) words")
    }

    static let otherPages = "Other pages"

    /// An app's websites in the range, most words first: the top five, then the rest as "Other pages" (words from
    /// pages not counted, such as before you allowed it).
    static func hosts(for app: String, _ events: [ActivityEvent], _ map: [UUID: String]) -> [(String, Int)] {
        var by: [String: Int] = [:], total = 0, counted = 0
        for e in events where e.app == app {
            total += e.words
            if let h = map[e.id] { by[h, default: 0] += e.words; counted += e.words }
        }
        guard !by.isEmpty else { return [] }
        let sorted = by.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        var out = Array(sorted.prefix(5)).map { ($0.key, $0.value) }
        let rest = sorted.dropFirst(5).reduce(0) { $0 + $1.value } + (total - counted)
        if rest > 0 { out.append((otherPages, rest)) }
        return out
    }

    // MARK: Footer

    private var footer: some View {
        let files = app.store.live.filter { $0.source != .dictation && $0.status == .ready }
        let seconds = files.reduce(0) { $0 + $1.duration }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !files.isEmpty {
                Text("You've also transcribed \(Self.duration(seconds)) across \(files.count) \(files.count == 1 ? "recording" : "recordings and links").")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            if !log.events.isEmpty {
                Button { confirmReset = true } label: {
                    Text("Reset activity…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear these numbers and start counting again")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Formatting

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        if s < 60 { return "\(Int(s.rounded())) s" }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// "Oct 19 – 25", "Sep 28 – Oct 4", or "October 2026".
    static func rangeLabel(_ r: DateInterval, _ span: YouRange.Span, _ cal: Calendar) -> String {
        if span == .month { return Formats.pattern("MMMM yyyy").string(from: r.start) }
        let last = r.end.addingTimeInterval(-1)
        let a = Formats.pattern("MMM d").string(from: r.start)
        let b = cal.isDate(r.start, equalTo: last, toGranularity: .month) ? Formats.pattern("d").string(from: last) : Formats.pattern("MMM d").string(from: last)
        return "\(a) – \(b)"
    }

    static func whereLabel(_ r: DateInterval, _ span: YouRange.Span) -> String {
        if YouRange.isCurrent(r) { return span == .week ? "This week" : "This month" }
        return span == .week ? rangeLabel(r, span, .current) : Formats.pattern("MMMM").string(from: r.start)
    }
}

// MARK: - Chart

/// Words per day (website style): ink bars, today in butter with an ink outline, days to come as hairline stubs,
/// values and day letters in mono.
struct DayBars: View {
    var days: [Date]
    var byDay: [Date: Int]
    var span: YouRange.Span
    var calendar: Calendar
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        let today = calendar.startOfDay(for: Date())
        let maxWords = max(1, days.map { byDay[$0] ?? 0 }.max() ?? 1)
        let peak = days.max { (byDay[$0] ?? 0) < (byDay[$1] ?? 0) }
        GeometryReader { g in
            let barMax = max(40, g.size.height - 48)
            HStack(alignment: .bottom, spacing: span == .week ? 18 : 3) {
                ForEach(days, id: \.self) { day in
                    column(day, today: today, maxWords: maxWords, barMax: barMax, labeled: span == .week || day == today || day == peak)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .padding(.top, 6)
        .animation(limitMotion ? nil : .spring(duration: 0.3, bounce: 0), value: days)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Words per day")
    }

    private func column(_ day: Date, today: Date, maxWords: Int, barMax: CGFloat, labeled: Bool) -> some View {
        let n = byDay[day] ?? 0
        let future = day > today
        let isToday = day == today
        let stub = future || n == 0
        let h: CGFloat = stub ? 4 : max(6, barMax * CGFloat(n) / CGFloat(maxWords))
        let fill: Color = stub ? Ink.hairline : (isToday ? Ink.panelButter : Ink.ink)
        let bar = RoundedRectangle(cornerRadius: span == .week ? 3 : 2, style: .continuous)
        return VStack(spacing: 6) {
            Text(future ? "—" : (labeled ? n.formatted() : " "))
                .font(Ink.mono(12)).foregroundStyle(isToday ? Ink.ink : Ink.dim)
                .lineLimit(1).fixedSize()
                .frame(height: 15)
            bar.fill(fill)
                .overlay { if isToday && !stub { bar.strokeBorder(Ink.ink, lineWidth: 1.5) } }
                .frame(maxWidth: span == .week ? 34 : .infinity)
                .frame(height: h)
            Text(dayLabel(day, isToday: isToday))
                .font(Ink.mono(12, weight: isToday ? .medium : .regular))
                .foregroundStyle(isToday ? Ink.ink : Ink.mute)
                .lineLimit(1).fixedSize()
                .frame(height: 15)
        }
        .frame(maxWidth: .infinity)
        .help(future ? "" : "\(Formats.style(date: .medium, time: .none).string(from: day)): \(n.formatted()) words")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formats.style(date: .full, time: .none).string(from: day))
        .accessibilityValue(future ? "Still to come" : "\(n.formatted()) words")
    }

    private func dayLabel(_ day: Date, isToday: Bool) -> String {
        if span == .week { return Formats.pattern("EEEEE").string(from: day) }
        let d = calendar.component(.day, from: day)
        return (isToday || d == 1 || d % 7 == 1) ? "\(d)" : " "
    }
}

// MARK: - Pieces

/// A card's serif title (22 pt).
private struct YouCardTitle: View {
    var text: String
    var body: some View {
        Text(text).font(Ink.serif(22)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The You page's card face (website style): card white with the panel radius and an ink outline; the hard shadow
/// shows under the pointer, (7, 9), and (2, 3) while pressed.
private struct YouCardFace: ViewModifier {
    var hover: Bool
    var pressed = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .inkEdge(outline: true, shadow: InkEdge.card(hover: hover, pressed: pressed), radius: Radius.record)
    }
}

/// A big card that holds its own controls (Cleanup, Your week, Where you dictate). It picks up the hard shadow under
/// the pointer but doesn't tilt: on macOS 26 a rotated ancestor loses clicks for its children.
private struct YouPanel<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .modifier(YouCardFace(hover: hover))
            .onHover { hover = $0 }
    }
}

/// A share bar: a hairline track with a butter fill.
private struct YouShareBar: View {
    var share: Double
    var height: CGFloat
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.hairline)
                Capsule().fill(Ink.panelButter).frame(width: max(height, g.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// An app's own icon, found by name in the usual Applications folders (activity keeps names, not bundle IDs); a
/// neutral square while it loads (`AppIconCache`, off the main thread) and when it can't be found.
private struct YouAppIcon: View {
    var name: String

    var body: some View {
        AppIcon(key: name.isEmpty ? nil : .name(name)) {
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.neutralChip)
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.hairline))
        }
        .accessibilityHidden(true)
    }
}

/// Lays out its views side by side in proportion to `weights`, all as tall as the tallest; stacks them when the
/// row is narrower than `stackBelow`.
struct RatioRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 14
    var stackBelow: CGFloat = 640

    private func widths(_ total: CGFloat, _ n: Int) -> [CGFloat] {
        let w = (0..<n).map { $0 < weights.count ? weights[$0] : 1 }
        let sum = max(w.reduce(0, +), 0.001)
        let room = max(0, total - spacing * CGFloat(max(0, n - 1)))
        return w.map { room * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        if width < stackBelow {
            let hs = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: hs.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
        }
        let ws = widths(width, subviews.count)
        let h = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if bounds.width < stackBelow {
            var y = bounds.minY
            for s in subviews {
                let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
            return
        }
        var x = bounds.minX
        for (s, w) in zip(subviews, widths(bounds.width, subviews.count)) {
            s.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

/// The website's segmented toggle: a soft wash capsule track with the chosen option as an ink pill (paper text).
/// Each option is a button, so it works with the keyboard and VoiceOver. `small` is the Week | Month size.
private struct YouToggle<T: Hashable>: View {
    var label: String
    var options: [T]
    @Binding var selection: T
    var title: (T) -> String
    var small = false
    @Namespace private var ns
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { withAnimation(limitMotion ? nil : Motion.snap) { selection = o } } label: {
                    Text(title(o))
                        .font(.system(size: small ? 12 : 13.5, weight: .semibold))
                        .foregroundStyle(on ? Ink.paper : Ink.ink)
                        .lineLimit(1)
                        .padding(.horizontal, small ? 12 : 16)
                        .frame(height: small ? 24 : 30)
                        .background {
                            if on { Capsule().fill(Ink.ink).matchedGeometryEffect(id: "on", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(o))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(small ? 3 : 4)
        .background(Ink.chip, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - About me

/// Edits About me (300 characters, as on iPhone). Opened from the You page and from Settings › General.
struct AboutMeSheet: View {
    @AppStorage(YouProfile.aboutMeKey) private var aboutMe = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("You").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                Text("About me").font(Ink.serif(32)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
                Text("A few lines about you and your work. Verbose uses this to spell names and word titles and summaries. It stays on this Mac.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $aboutMe)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(10)
                    .accessibilityLabel("About me")
                if aboutMe.isEmpty {
                    Text("For example: I produce videos for a small studio. I work with Riverside Farms and the Hollis Group.")
                        .font(.system(size: 14)).foregroundStyle(Ink.faint)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 140)
            .cardSurface(radius: Radius.row)
            HStack {
                Text("\(aboutMe.count)/\(YouProfile.aboutMeLimit)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.mute)
                    .accessibilityLabel("\(aboutMe.count) of \(YouProfile.aboutMeLimit) characters")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.brandPrimary)
            }
        }
        .padding(28)
        .frame(width: 480)
        .background(Ink.paper)
        .onChange(of: aboutMe) { _, v in
            if v.count > YouProfile.aboutMeLimit { aboutMe = String(v.prefix(YouProfile.aboutMeLimit)) }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Settings › General › You

/// Your name, About me, and Count websites: the same settings the You page shows.
struct YouSettingsSection: View {
    @AppStorage(YouProfile.nameKey) private var name = ""
    @AppStorage(YouProfile.aboutMeKey) private var aboutMe = ""
    @AppStorage(SiteCapture.countKey) private var countSites = true
    @State private var editing = false

    var body: some View {
        SettingsGroup(title: "You") {
            SettingsRow("general.name") {
                TextField("Your name", text: $name, prompt: Text(NSFullUserName()))
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
            }
            SettingsRow("general.aboutMe", detail: aboutMe.isEmpty ? nil : "\(aboutMe.count) of \(YouProfile.aboutMeLimit) characters. Verbose uses this to spell names and word titles and summaries.") {
                Button(aboutMe.isEmpty ? "Add…" : "Edit…") { editing = true }.buttonStyle(PillButtonStyle(kind: .line, size: .mini))
            }
            SettingsToggleRow("general.countSites", isOn: $countSites)
        }
        .sheet(isPresented: $editing) { AboutMeSheet() }
    }
}

// MARK: - Screenshot tour

/// Made-up dictations into Chrome with their websites, for the You page in the screenshot tour.
enum YouTourSeed {
    @MainActor static func run() {
        guard SiteLog.shared.hosts.isEmpty else { return }
        let cal = Calendar.current
        let hosts = ["mail.google.com", "mail.google.com", "claude.ai", "notion.so", "mail.google.com", "claude.ai", "docs.google.com"]
        var events: [ActivityEvent] = [], map: [UUID: String] = [:]
        for day in 0..<40 {
            guard let date = cal.date(byAdding: .day, value: -day, to: cal.date(bySettingHour: 10, minute: 40, second: 0, of: Date()) ?? Date()) else { continue }
            for k in 0..<(1 + day % 3) {
                let words = 60 + (day * 29 + k * 41) % 260
                let e = ActivityEvent(id: UUID(), date: date.addingTimeInterval(Double(k) * 1_200), words: words, seconds: Double(words) / 2.4,
                                      transcribeSeconds: 0.7, cleanupSeconds: 0.5, app: "Google Chrome", category: .other,
                                      fillers: k % 3, changed: 3, vocabularyFixes: 0)
                events.append(e)
                if (day + k) % 6 != 5 { map[e.id] = hosts[(day + k * 2) % hosts.count] }
            }
        }
        ActivityLog.shared.addAll(events)
        SiteLog.shared.setAll(map)
    }
}
