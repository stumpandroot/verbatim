import SwiftUI
import AppKit

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
    @Environment(\.openSettings) private var openSettings
    @Environment(\.limitMotion) private var limitMotion
    @State private var span: YouRange.Span = .week
    @State private var anchor = Date()
    @State private var confirmReset = false
    @State private var editingAbout = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var collapsed: Set<String> = []
    @FocusState private var nameFocused: Bool

    var body: some View {
        let cal = Calendar.current
        let range = YouRange.interval(span, containing: anchor, calendar: cal)
        let events = log.events.filter { $0.date >= range.start && $0.date < range.end }
        let stats = ActivityStats(events, since: nil)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                RatioRow(weights: [1.15, 1, 0.85], stackBelow: 640) {
                    aboutCard
                    cleanupCard
                    voiceCard
                }
                RatioRow(weights: [1.6, 1], stackBelow: 720) {
                    weekCard(range, stats, cal)
                    whereCard(range, events, stats)
                }
                footer
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 32)
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

    private var header: some View {
        let name = YouProfile.displayName(storedName)
        return HStack(alignment: .bottom, spacing: 20) {
            Text(YouProfile.initial(name))
                .font(Ink.serif(28)).foregroundStyle(Ink.ink)
                .frame(width: 64, height: 64)
                .background(Ink.card, in: Circle())
                .overlay(Circle().strokeBorder(Ink.hairline))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                if editingName {
                    TextField("Your name", text: $nameDraft)
                        .textFieldStyle(.plain).font(Ink.serif(40)).foregroundStyle(Ink.ink)
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onExitCommand { editingName = false }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                } else {
                    Button { nameDraft = name; editingName = true; nameFocused = true } label: {
                        Text(name).font(Ink.serif(40)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .buttonStyle(.plain)
                    .help("Change your name")
                    .accessibilityLabel(name)
                    .accessibilityHint("Changes your name")
                    .accessibilityAddTraits(.isHeader)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Everything here stays on this Mac.\nMirrored in Settings.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.mute).multilineTextAlignment(.trailing).lineSpacing(2)
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

    private var aboutCard: some View {
        YouCard {
            HStack(alignment: .firstTextBaseline) {
                Text("About me").font(Ink.serif(20)).foregroundStyle(Ink.ink)
                Spacer()
                Button(aboutMe.isEmpty ? "Add" : "Edit") { editingAbout = true }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Ink.accentText)
                    .accessibilityLabel(aboutMe.isEmpty ? "Add About me" : "Edit About me")
            }
            Text(aboutMe.isEmpty ? "A line or two about you and your work, and the names you use often." : aboutMe)
                .font(.system(size: 13.5)).lineSpacing(3)
                .foregroundStyle(aboutMe.isEmpty ? Ink.mute : Ink.dim)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text("Verbatim uses this to spell names and word titles and summaries.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cleanupCard: some View {
        YouCard(spacing: 10) {
            Text("Cleanup and grammar").font(Ink.serif(20)).foregroundStyle(Ink.ink)
            InkSegmented(label: "Cleanup level", options: CleanupLevel.allCases, selection: $settings.cleanup, title: { $0.title })
            VStack(spacing: 0) {
                // TODO(cleanup-strength): bind Grammar check to its setting once it lands (another branch adds it).
                settingLink("Grammar check", value: "Settings") { openCleanupSetting("dictate.cleanup") }
                RowRule()
                settingLink("Tone", value: "Match the app") { openCleanupSetting("dictate.styles") }
                RowRule()
                // TODO(cleanup-strength): bind Cloud cleanup to its setting once it lands (another branch adds it).
                settingLink("Cloud cleanup", value: "Settings") { openCleanupSetting("dictate.cleanup") }
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
            .font(.system(size: 13))
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Opens Settings")
    }

    /// Opens Settings at a dictation setting. TODO(cleanup-strength): bind — the one place to change when Grammar
    /// check and Cloud cleanup get their own settings: bind them in `cleanupCard` and keep this for Tone.
    private func openCleanupSetting(_ id: String) {
        if let e = SettingsIndex.entry(id) { SettingsModel.shared.open(e) }
        else { UserDefaults.standard.set(SettingsTab.dictate.rawValue, forKey: "settingsTab") }
        openSettings()
    }

    private var voiceCard: some View {
        let known = voice.isEnrolled || voice.isPartial
        return VStack(alignment: .leading, spacing: 6) {
            Text("Your voice").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
            IconGlyph(art: .iconVoice, size: 40, color: Ink.ink).padding(.vertical, 12)
            Text(voice.line).font(Ink.serif(19)).foregroundStyle(Ink.ink).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(known ? "Read more passages →" : "Set up your voice →") { VoiceEnrollmentSheet.present(readMore: known) }
                .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.ink)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Neutral: sage means Import, so the voice card is paper with a hairline.
        .cardSurface(radius: Radius.tile)
    }

    // MARK: Your week

    private func weekCard(_ range: DateInterval, _ stats: ActivityStats, _ cal: Calendar) -> some View {
        let current = YouRange.isCurrent(range)
        return YouCard(spacing: 14, padding: 20) {
            HStack(spacing: 12) {
                Text(span == .week ? "Your week" : "Your month").font(Ink.serif(22)).foregroundStyle(Ink.ink)
                Text(Self.rangeLabel(range, span, cal)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.mute)
                Spacer(minLength: 8)
                arrow("chevron.left", span == .week ? "Previous week" : "Previous month", enabled: true) { step(-1) }
                arrow("chevron.right", span == .week ? "Next week" : "Next month", enabled: !current) { step(1) }
                InkSegmented(label: "Range", options: YouRange.Span.allCases, selection: Binding(get: { span }, set: { s in
                    withAnimation(limitMotion ? nil : Motion.snap) { span = s; anchor = Date() }
                }), title: { $0.title }, fill: false, height: 24, fontSize: 12)
                .fixedSize()
            }
            HStack(alignment: .top, spacing: 28) {
                bigStat(stats.words.formatted(), "words dictated")
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.duration(stats.secondsSaved(typingWPM: settings.typingWPM))).font(Ink.serif(34)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.6)
                    HStack(spacing: 3) {
                        Text("saved vs. typing at").font(.system(size: 12)).foregroundStyle(Ink.mute)
                        Menu {
                            ForEach([20, 30, 40, 50, 60, 70, 80, 100, 120], id: \.self) { w in
                                Button { settings.typingWPM = w } label: { Text("\(w) wpm") }
                            }
                        } label: {
                            Text("\(settings.typingWPM) wpm").font(.system(size: 12)).foregroundStyle(Ink.accentText)
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
                Text("Dictate into any app with \(app.dictation.hotkey.shortTitle) or the floating button. Your totals show up here.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
        }
    }

    private func step(_ n: Int) {
        let next = YouRange.shifted(anchor, span, by: n, calendar: .current)
        withAnimation(limitMotion ? nil : Motion.snap) { anchor = min(next, Date()) }
    }

    private func arrow(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Ink.ink : Ink.faint)
                .frame(width: 28, height: 28)
                .background(Ink.ink.opacity(enabled ? 0.07 : 0.04), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Ink.serif(34)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.mute)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Where you dictate

    private func whereCard(_ range: DateInterval, _ events: [ActivityEvent], _ stats: ActivityStats) -> some View {
        let apps = stats.byApp.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(6)
        return YouCard(spacing: 12, padding: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where you dictate").font(Ink.serif(22)).foregroundStyle(Ink.ink)
                Spacer()
                Text(Self.whereLabel(range, span)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.mute)
            }
            if apps.isEmpty {
                Text(span == .week ? "Nothing dictated this week." : "Nothing dictated this month.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.key) { i, entry in
                    appRow(entry.key, entry.value, hosts: Self.hosts(for: entry.key, events, sites.hosts), last: i == apps.count - 1)
                }
            }
            Spacer(minLength: 4)
            Text("Websites are counted by domain only, never full addresses. macOS asks once per browser.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func appRow(_ name: String, _ words: Int, hosts: [(String, Int)], last: Bool) -> some View {
        let open = !hosts.isEmpty && !collapsed.contains(name)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !hosts.isEmpty else { return }
                withAnimation(limitMotion ? nil : .spring(duration: 0.3, bounce: 0)) {
                    if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13.5, weight: hosts.isEmpty ? .regular : .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    if !hosts.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.mute)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    Spacer()
                    Text(words.formatted()).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Ink.mute)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hosts.isEmpty)
            .accessibilityLabel("\(name), \(words.formatted()) words")
            .accessibilityHint(hosts.isEmpty ? "" : (open ? "Hides websites" : "Shows websites"))
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(hosts.enumerated()), id: \.offset) { _, h in
                        hostRow(h.0, h.1, share: Double(h.1) / Double(max(words, 1)))
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Ink.hairline.opacity(0.6)).frame(height: 1) } }
    }

    private func hostRow(_ host: String, _ n: Int, share: Double) -> some View {
        HStack(spacing: 8) {
            Text(host).font(.system(size: 13)).foregroundStyle(host == Self.otherPages ? Ink.mute : Ink.dim).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.track)
                Capsule().fill(Ink.butter).frame(width: max(4, 90 * min(1, share)))
            }
            .frame(width: 90, height: 5)
            Text(n.formatted()).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.mute).frame(width: 46, alignment: .trailing)
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
        return HStack(alignment: .firstTextBaseline) {
            if !files.isEmpty {
                Text("You've also transcribed \(Self.duration(seconds)) across \(files.count) \(files.count == 1 ? "recording" : "recordings and links").")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
            Spacer()
            if !log.events.isEmpty {
                Button("Reset activity…") { confirmReset = true }.buttonStyle(.link).font(.system(size: 12.5))
            }
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

/// Words per day: today in persimmon, days to come as hairline stubs, values in mono over each bar.
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
            let barMax = max(40, g.size.height - 44)
            HStack(alignment: .bottom, spacing: span == .week ? 14 : 3) {
                ForEach(days, id: \.self) { day in
                    column(day, today: today, maxWords: maxWords, barMax: barMax, labeled: span == .week || day == today || day == peak)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .padding(.top, 8)
        .animation(limitMotion ? nil : .spring(duration: 0.3, bounce: 0), value: days)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Words per day")
    }

    private func column(_ day: Date, today: Date, maxWords: Int, barMax: CGFloat, labeled: Bool) -> some View {
        let n = byDay[day] ?? 0
        let future = day > today
        let isToday = day == today
        let h: CGFloat = future || n == 0 ? 4 : max(6, barMax * CGFloat(n) / CGFloat(maxWords))
        let fill: Color = future || n == 0 ? Ink.hairline : (isToday ? Ink.butter : Ink.ink)
        let radius: CGFloat = span == .week ? 6 : 3
        return VStack(spacing: 6) {
            Text(future ? "—" : (labeled ? n.formatted() : " "))
                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(future ? Ink.faint : Ink.mute)
                .lineLimit(1).fixedSize()
                .frame(height: 13)
            UnevenRoundedRectangle(topLeadingRadius: n == 0 || future ? 2 : radius, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: n == 0 || future ? 2 : radius, style: .continuous)
                .fill(fill)
                .frame(maxWidth: .infinity)
                .frame(height: h)
            Text(dayLabel(day, isToday: isToday))
                .font(.system(size: span == .week ? 12 : 10.5, weight: isToday ? .semibold : .regular))
                .foregroundStyle(future ? Ink.faint : (isToday ? Ink.ink : Ink.mute))
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
        if span == .week { return Formats.pattern("EEE").string(from: day) }
        let d = calendar.component(.day, from: day)
        return (isToday || d == 1 || d % 7 == 1) ? "\(d)" : " "
    }
}

// MARK: - Pieces

/// A reader-white card that fills its slot in a `RatioRow`.
struct YouCard<Content: View>: View {
    var spacing: CGFloat = 8
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(.horizontal, padding).padding(.vertical, padding - 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardSurface(radius: Radius.tile)
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

/// The page's segmented control: a faint ink track with the chosen option in solid ink. Each option is a button,
/// so it works with the keyboard and VoiceOver.
struct InkSegmented<T: Hashable>: View {
    var label: String
    var options: [T]
    @Binding var selection: T
    var title: (T) -> String
    var fill = true
    var height: CGFloat = 28
    var fontSize: CGFloat = 12.5
    @Namespace private var ns
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { withAnimation(limitMotion ? nil : Motion.snap) { selection = o } } label: {
                    Text(title(o))
                        .font(.system(size: fontSize, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Ink.onInteractive : Ink.dim)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: height)
                        .background {
                            if on { RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.interactive).matchedGeometryEffect(id: "on", in: ns) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(o))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(3)
        .background(Ink.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
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
                Text("A few lines about you and your work. Verbatim uses this to spell names and word titles and summaries. It stays on this Mac.")
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
            SettingsRow("general.aboutMe", detail: aboutMe.isEmpty ? nil : "\(aboutMe.count) of \(YouProfile.aboutMeLimit) characters. Verbatim uses this to spell names and word titles and summaries.") {
                Button(aboutMe.isEmpty ? "Add…" : "Edit…") { editing = true }.buttonStyle(.brandSecondary)
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
