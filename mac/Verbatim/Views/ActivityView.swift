import SwiftUI

/// What you've dictated: totals, pace, time saved, where it went, and a calendar of the days you used it.
/// No streaks and no goals: a quiet week is just a quiet week. Counted on this Mac; nothing here leaves it.
struct ActivityView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var settings = FlowSettings.shared
    @State private var period: Period = .month
    @State private var confirmReset = false

    enum Period: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", year = "This year", all = "All time"
        var id: String { rawValue }
        var since: Date? {
            let cal = Calendar.current, now = Date()
            switch self {
            case .week: return cal.date(byAdding: .day, value: -7, to: now)
            case .month: return cal.date(byAdding: .day, value: -30, to: now)
            case .year: return cal.date(from: cal.dateComponents([.year], from: now))
            case .all: return nil
            }
        }
    }

    var body: some View {
        let stats = ActivityStats(log.events, since: period.since)
        let words = WordStats(app.store.live, since: period.since)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Activity").font(Ink.serif(30)).foregroundStyle(Ink.ink)
                    Spacer()
                    HStack(spacing: 6) { ForEach(Period.allCases) { p in SiteChip(label: p.rawValue, on: period == p) { period = p } } }
                }
                Text("Counted on this Mac from your dictations. Nothing here leaves it.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.top, 4)

                if stats.dictations == 0 {
                    empty.padding(.top, 20)
                } else {
                    totals(stats).padding(.top, 20)
                    HStack(alignment: .top, spacing: 14) {
                        whereCard(stats).frame(maxWidth: .infinity)
                        calendarCard.frame(maxWidth: .infinity)
                    }
                    .padding(.top, 14)
                    wordsRow(stats, words).padding(.top, 14)
                    detailCard(stats).padding(.top, 14)
                }
                footer.padding(.top, 22)
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .onAppear { log.seedIfNeeded(from: app.store.live) }
        .confirmationDialog("Reset activity?", isPresented: $confirmReset) {
            Button("Reset Activity", role: .destructive) { log.reset() }
        } message: {
            Text("Clears these numbers and starts counting again. Your dictations and transcripts aren't touched.")
        }
    }

    // MARK: Totals

    private func totals(_ s: ActivityStats) -> some View {
        HStack(alignment: .top, spacing: 14) {
            card {
                big(s.words.formatted())
                label("Words dictated")
                rule
                line("\(s.dictations.formatted()) dictations · \(Self.duration(s.seconds)) of talking")
                if s.words >= 500 { line("About \(max(1, s.words / 275).formatted()) \(s.words / 275 == 1 ? "page" : "pages") of writing") }
            }
            card {
                big(s.pace.map { "\($0)" } ?? "–")
                label("Words per minute")
                rule
                line(s.pace == nil ? "Shows after a few dictations." : "Counted over your whole recordings, pauses included.")
            }
            card {
                big(Self.duration(s.secondsSaved(typingWPM: settings.typingWPM)))
                label("Time saved, about")
                rule
                HStack(spacing: 6) {
                    Text("Compared with typing at").font(.system(size: 13)).foregroundStyle(Ink.dim)
                    Picker("Typing speed", selection: $settings.typingWPM) {
                        ForEach([20, 30, 40, 50, 60, 70, 80, 100, 120], id: \.self) { Text("\($0) wpm").tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                line("Talking and processing time are taken off; editing time isn't counted.")
            }
        }
    }

    // MARK: Where and when

    private func whereCard(_ s: ActivityStats) -> some View {
        let total = max(1, s.words)
        let cats = AppCategory.allCases.map { ($0, s.byCategory[$0] ?? 0) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let apps = s.byApp.sorted { $0.value > $1.value }.prefix(5)
        return card {
            HStack(alignment: .firstTextBaseline) {
                Text("Where you dictate").font(Ink.serif(21)).foregroundStyle(Ink.ink)
                Spacer()
                Text("\(s.byApp.count) \(s.byApp.count == 1 ? "APP" : "APPS")").font(Ink.mono(11)).tracking(0.8).foregroundStyle(Ink.mute)
            }
            .padding(.bottom, 6)
            ForEach(cats, id: \.0) { c, n in
                let share = Double(n) / Double(total)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(c)).font(.system(size: 12.5)).foregroundStyle(Ink.dim).frame(width: 18)
                        Text(c.title).font(.system(size: 12.5)).foregroundStyle(Ink.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(Int((share * 100).rounded()))%").font(Ink.mono(11.5)).foregroundStyle(Ink.dim)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Ink.track)
                            Capsule().fill(Ink.sage).frame(width: max(6, g.size.width * share))
                        }
                    }
                    .frame(height: 6)
                    .padding(.leading, 26)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.title): \(Int((share * 100).rounded())) percent")
            }
            rule
            Text("TOP APPS").font(Ink.mono(10.5)).tracking(0.8).foregroundStyle(Ink.mute)
            ForEach(Array(apps), id: \.key) { name, n in
                HStack {
                    Text(name).font(.system(size: 13)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(n.formatted()) words").font(Ink.mono(11.5)).foregroundStyle(Ink.mute)
                }
            }
        }
    }

    private var calendarCard: some View {
        // Always the last 26 weeks, whatever the period: the calendar is for seeing your rhythm.
        let all = ActivityStats(log.events, since: nil)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
        let first = cal.date(byAdding: .weekOfYear, value: -25, to: weekStart) ?? weekStart
        let maxWords = max(1, all.byDay.values.max() ?? 1)
        let monthFmt = DateFormatter(); monthFmt.dateFormat = "MMM"
        let dayFmt = DateFormatter(); dayFmt.dateStyle = .medium
        return card {
            HStack(alignment: .firstTextBaseline) {
                Text("Your days").font(Ink.serif(21)).foregroundStyle(Ink.ink)
                Spacer()
                Text("LAST 6 MONTHS").font(Ink.mono(11)).tracking(0.8).foregroundStyle(Ink.mute)
            }
            .padding(.bottom, 6)
            HStack(alignment: .top, spacing: 3) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(" ").font(.system(size: 9.5))
                    ForEach(0..<7, id: \.self) { r in
                        Text(r % 2 == 1 ? cal.veryShortWeekdaySymbols[(r + cal.firstWeekday - 1) % 7] : " ")
                            .font(.system(size: 9.5)).foregroundStyle(Ink.mute).frame(height: 13)
                    }
                }
                ForEach(0..<26, id: \.self) { w in
                    let colStart = cal.date(byAdding: .weekOfYear, value: w, to: first) ?? first
                    VStack(spacing: 3) {
                        let showMonth = cal.component(.day, from: colStart) <= 7
                        Text(showMonth ? monthFmt.string(from: colStart) : " ").font(.system(size: 9.5)).foregroundStyle(Ink.mute).fixedSize().frame(width: 13, alignment: .leading)
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: d, to: colStart) ?? colStart
                            let n = all.byDay[day] ?? 0
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(day > today ? Color.clear : Self.shade(n, max: maxWords))
                                .overlay { if day == today { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Ink.ink.opacity(0.55), lineWidth: 1) } }
                                .frame(width: 13, height: 13)
                                .help(day > today ? "" : "\(dayFmt.string(from: day)): \(n == 0 ? "no dictation" : "\(n.formatted()) words")")
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calendar of the last six months. Dictated on \(all.byDay.filter { $0.key >= first && $0.value > 0 }.count) days.")
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 11)).foregroundStyle(Ink.mute)
                ForEach([0, 1, 2, 3, 4], id: \.self) { l in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.level(l)).frame(width: 11, height: 11)
                }
                Text("More").font(.system(size: 11)).foregroundStyle(Ink.mute)
            }
            .padding(.top, 8)
        }
    }

    // MARK: Words

    private func wordsRow(_ s: ActivityStats, _ w: WordStats) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let m = w.mostUsed {
                quoteCard("“\(m.0)”", "Most-used word", "\(m.1.formatted()) times, leaving out everyday words like “the” and “just.”")
            }
            if let m = w.mostFixed {
                quoteCard("“\(m.0)”", "Most-fixed word", "Your Dictionary corrected it \(m.1.formatted()) \(m.1 == 1 ? "time" : "times").")
            }
            if let m = w.catchphrase {
                quoteCard("“\(m.0)”", "Catchphrase", "In \(m.1) dictations.")
            }
            if let p = s.peak {
                quoteCard(Self.peakTitle(p), "Busiest time", "When you dictate the most words.")
            }
        }
    }

    private func quoteCard(_ title: String, _ label: String, _ note: String) -> some View {
        card {
            Text(title).font(Ink.serif(24).italic()).foregroundStyle(Ink.ink).lineLimit(2).minimumScaleFactor(0.7)
            self.label(label)
            Text(note).font(.system(size: 12.5)).foregroundStyle(Ink.mute).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Details

    private func detailCard(_ s: ActivityStats) -> some View {
        card {
            Text("Cleanup and speed").font(Ink.serif(21)).foregroundStyle(Ink.ink).padding(.bottom, 4)
            HStack(alignment: .top, spacing: 28) {
                stat(s.fillers.formatted(), "filler words removed")
                stat(s.changed.formatted(), "words changed by cleanup")
                stat(s.vocabularyFixes.formatted(), "Dictionary fixes")
                stat(s.medianProcessing.map { String(format: "%.1f s", $0) } ?? "–", "typical wait after you stop")
                if let slow = s.slowProcessing { stat(String(format: "%.1f s", slow), "slowest 1 in 10") }
            }
            Text("Changes are edits, not mistakes fixed: removing an “um” counts the same as fixing a name.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.top, 6)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Ink.mono(20)).foregroundStyle(Ink.ink)
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.dim)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer and empty

    private var footer: some View {
        let files = app.store.live.filter { $0.source != .dictation && $0.status == .ready }
        let hours = files.reduce(0) { $0 + $1.duration }
        return HStack(alignment: .firstTextBaseline) {
            if !files.isEmpty {
                Text("You've also transcribed \(Self.duration(hours)) across \(files.count) \(files.count == 1 ? "recording" : "recordings and links").")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
            Spacer()
            if !log.events.isEmpty {
                Button("Reset Activity…") { confirmReset = true }.buttonStyle(.link).font(.system(size: 12.5))
            }
        }
    }

    private var empty: some View {
        HStack(spacing: 16) {
            EmptyStateArt(art: .capture, tint: Ink.sageTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(log.events.isEmpty ? "Nothing counted yet" : "Nothing in this period").font(Ink.serif(20))
                Text("Dictate into any app with \(app.dictation.hotkey.shortTitle) or the floating button. Your totals show up here.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
            }
            Spacer()
        }
        .padding(20).background(NoteCardBackground(hover: false))
    }

    // MARK: Pieces

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(NoteCardBackground(hover: false))
    }
    private func big(_ s: String) -> some View { Text(s).font(Ink.serif(34)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.6) }
    private func label(_ s: String) -> some View { Text(s.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(Ink.dim) }
    private func line(_ s: String) -> some View { Text(s).font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
    private var rule: some View { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.vertical, 6) }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        if s < 60 { return "\(Int(s.rounded())) s" }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    private static func symbol(_ c: AppCategory) -> String {
        switch c {
        case .email: return "envelope"
        case .work: return "bubble.left.and.text.bubble.right"
        case .personal: return "message"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc.text"
        }
    }

    private static func level(_ l: Int) -> Color {
        switch l {
        case 0: return Ink.track
        case 1: return Ink.sageTint
        case 2: return Ink.sage.opacity(0.55)
        case 3: return Ink.sage
        default: return Ink.sageText
        }
    }

    private static func shade(_ n: Int, max: Int) -> Color {
        guard n > 0 else { return level(0) }
        let f = Double(n) / Double(max)
        return level(f > 0.66 ? 4 : f > 0.33 ? 3 : f > 0.1 ? 2 : 1)
    }

    private static func peakTitle(_ p: (weekday: Int, hour: Int)) -> String {
        let day = Calendar.current.weekdaySymbols[(p.weekday - 1) % 7]
        let hour: String
        switch p.hour {
        case 0: hour = "midnight"
        case 12: hour = "noon"
        default: hour = p.hour < 12 ? "\(p.hour) a.m." : "\(p.hour - 12) p.m."
        }
        return "\(day)s around \(hour)"
    }
}
