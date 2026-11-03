import SwiftUI

// Your words calendar on iPhone (DESIGN.md §13, Your words calendar; approved mockup "Verbose words calendar", November 1, 2026): You ›
// Your words calendar, or a tap on Your week. Month: the days shaded by the words you dictated, with a dot for a day
// you recorded; your totals, the days you talked, your best day, your longest run, your pace, your rhythm, the month's
// length, and the cards under it. Year: twelve small months, the bookshelf, and month by month. A day opens its own
// page (WordsDayScreen.swift). There's no streak to lose. Counted on this iPhone from your dictations and recordings;
// nothing here leaves it.

extension Notification.Name {
    /// UI tour: a `WordsCalendarTour` step for the words calendar on screen.
    static let verbatimWordsCalendar = Notification.Name("verbatimWordsCalendar")
}

/// The UI tour's steps on the words calendar: a month, a scroll to a section, a day, back from it, or the year.
enum WordsCalendarTour {
    case month(Date), scroll(String), day(Date), back, year
}

struct WordsCalendarScreen: View {
    enum Span: Hashable { case month, year }

    private static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var flow = FlowSettings.shared
    @AppStorage(WordsCalendar.milestoneSeenKey) private var milestoneSeen = 0
    /// You › Show milestones; off by default, so the calendar opens on the month.
    @AppStorage(WordsCalendar.showMilestonesKey) private var showMilestones = false
    @State private var span: Span = .month
    @State private var anchor = Date()
    @State private var now = Date()
    @State private var openDay: Date? = nil
    /// The milestone this visit shows, worked out once on arrival so it stays put until you leave.
    @State private var milestone: (book: WordsCalendar.Book, on: Date)? = nil
    @State private var checkedMilestone = false

    /// How many calendars are on screen, and which span shows, for the self-test.
    static var onScreen = 0
    static var showing: Span = .month

    var body: some View {
        let store = app.store
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RefinedSegmented(label: "Show", options: [(Span.month, "Month"), (Span.year, "Year")], selection: $span)
                    .frame(maxWidth: 240)
                    .id("words.top")
                if span == .month {
                    if showMilestones, let m = milestone {
                        WordsMilestoneCard(book: m.book, on: m.on) { span = .year }
                    }
                    WordsMonthView(month: store.wordsMonth(anchor, now: now), extras: store.wordsExtras(anchor, now: now),
                                   anchor: $anchor, now: now, typingWPM: flow.typingWPM) { openDay = $0 }
                } else {
                    WordsYearView(year: store.wordsYear(anchor, now: now), anchor: $anchor, now: now) { month in anchor = month; span = .month }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimWordsCalendar)) { note in
            guard let step = note.object as? WordsCalendarTour else { return }
            switch step {
            case .month(let d): anchor = d; span = .month; openDay = nil; proxy.scrollTo("words.top", anchor: .top)
            case .scroll(let id): proxy.scrollTo(id, anchor: .top)
            case .day(let d): anchor = d; span = .month; openDay = Calendar.current.startOfDay(for: d)
            case .back: openDay = nil
            case .year: span = .year; proxy.scrollTo("words.top", anchor: .top)
            }
        }
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Your words")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openDay) { d in WordsDayScreen(day: d) }
        .onAppear {
            Self.onScreen += 1
            now = Date()
            // Shown once: marked seen as soon as it's found, and kept on screen for this visit. Only with Show
            // milestones on, so turning it on later still shows the newest one.
            if showMilestones, !checkedMilestone {
                checkedMilestone = true
                milestone = WordsCalendar.milestone(store.wordsEntries, seen: milestoneSeen)
                if let m = milestone { milestoneSeen = max(milestoneSeen, m.book.words) }
            }
        }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
        .onChange(of: span) { _, s in Self.showing = s }
        .onReceive(Self.minute) { now = $0 }
    }
}

// MARK: - Month

struct WordsMonthView: View {
    var month: WordsCalendar.Month
    var extras: WordsExtras
    @Binding var anchor: Date
    var now: Date
    var typingWPM: Int
    var openDay: (Date) -> Void

    private var cal: Calendar { .current }

    var body: some View {
        let m = month
        VStack(alignment: .leading, spacing: 20) {
            header(m)
            totals(m)
            grid(m)
            stats(m)
            if let w = m.busiestWeekday { rhythm(m, weekday: w) }
            if let line = WordsCalendar.lengthLine(m.words, monthName: WordsText.monthName(m.start)) { length(line, words: m.words) }
            if !extras.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("More about your words").id("words.more")
                    WordsFunCards(extras: extras, words: m.words, seconds: m.seconds, typingWPM: typingWPM)
                }
            }
        }
    }

    private func header(_ m: WordsCalendar.Month) -> some View {
        // No months after this one: there's nothing in them yet.
        let isCurrent = m.start >= WordsCalendar.monthInterval(now, calendar: cal).start
        return VStack(alignment: .leading, spacing: 4) {
            Text("Your words").refinedFont(.meta).foregroundStyle(Refined.mute)
            HStack(alignment: .center) {
                Text(WordsText.month(m.start)).refinedFont(.largeTitle).foregroundStyle(Refined.ink)
                    .lineLimit(1).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                WordsStepButton(forward: false, label: "Previous month") { step(-1) }
                WordsStepButton(forward: true, label: "Next month") { step(1) }.disabled(isCurrent).opacity(isCurrent ? 0.4 : 1)
            }
        }
    }

    private func step(_ n: Int) { anchor = min(now, cal.date(byAdding: .month, value: n, to: anchor) ?? anchor) }

    private func totals(_ m: WordsCalendar.Month) -> some View {
        let saved = WordsCalendar.typingVersusTalking(words: m.words, seconds: m.seconds, typingWPM: typingWPM).saved
        let line = WordsCalendar.equivalent(m.words).map { "\(m.words == 1 ? "word" : "words") dictated, \($0)" } ?? (m.words == 1 ? "word dictated" : "words dictated")
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.words.formatted()).font(.system(size: 44, weight: .bold)).monospacedDigit().foregroundStyle(Refined.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(line).refinedFont(.hint).foregroundStyle(Refined.dim)
            }
            Spacer(minLength: 8)
            if saved >= 60 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(HomeWeek.savedText(saved)).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.sageText)
                    Text("saved typing").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("words.total")
    }

    private func grid(_ m: WordsCalendar.Month) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(m.weekdayInitials.enumerated()), id: \.offset) { _, d in
                    Text(d).refinedFont(.caption, weight: .semibold).foregroundStyle(Refined.mute).accessibilityHidden(true)
                }
                ForEach(0..<m.leading, id: \.self) { _ in Color.clear.frame(height: 50).accessibilityHidden(true) }
                ForEach(m.days, id: \.start) { day in
                    WordsDayCell(day: day) { openDay(day.start) }
                }
            }
            HStack {
                HStack(spacing: 6) {
                    Text("Fewer")
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Refined.heat[i]).frame(width: 12, height: 12)
                    }
                    Text("More words")
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(Refined.ink).frame(width: 6, height: 6)
                    Text("Recording")
                }
            }
            .refinedFont(.caption).foregroundStyle(Refined.mute)
            .padding(.top, 6)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityIdentifier("words.grid")
    }

    private func stats(_ m: WordsCalendar.Month) -> some View {
        let pace = WordsCalendar.pace(words: m.words, seconds: m.seconds)
        let times = pace.map { Double($0) / Double(max(1, typingWPM)) }
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            WordsStat(label: "Days you talked", value: m.daysTalked.formatted(), unit: "of \(m.daysSoFar)")
            WordsStat(label: "Best day", value: m.best.map { $0.words.formatted() } ?? "–",
                      detail: m.best.map { Formats.pattern("EEEE, MMM d").string(from: $0.start) })
            WordsStat(label: "Longest run", value: m.longestRun.map { $0.days == 1 ? "1 day" : "\($0.days) days" } ?? "–",
                      detail: m.longestRun.map { WordsText.run($0) })
            WordsStat(label: "Your pace", value: pace.map { "\($0)" } ?? "–", unit: pace == nil ? nil : "wpm",
                      detail: times.map { $0 >= 1.05 ? String(format: "%.1f times your typing", $0) : "About your typing speed" })
        }
    }

    private func rhythm(_ m: WordsCalendar.Month, weekday: Int) -> some View {
        let names = Calendar.current.standaloneWeekdaySymbols
        let full = names[(Calendar.current.firstWeekday - 1 + weekday) % 7]
        let top = Double(max(1, m.weekdayAverages.max() ?? 1))
        let hour = m.busiestHour.map { ", around \(WordsText.hour($0))" } ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Your rhythm")
            WordsCard {
                Text("You talk most on \(full)s\(hour).").refinedFont(.body).foregroundStyle(Refined.ink)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(i == weekday ? Refined.persimmon : Refined.heat[2])
                                .frame(maxWidth: 30)
                                .frame(height: max(6, 70 * CGFloat(Double(m.weekdayAverages[i]) / top)))
                            Text(m.weekdayInitials[i]).refinedFont(.caption).foregroundStyle(Refined.mute)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96)
                .accessibilityHidden(true)
                Text("Average words on each weekday this month.").refinedFont(.caption).foregroundStyle(Refined.mute)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func length(_ line: (title: String, detail: String?), words: Int) -> some View {
        HStack(spacing: 14) {
            WordsSpines(filled: WordsCalendar.shelfProgress(words).filled, count: 4, labels: false, scale: 0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                if let d = line.detail { Text(d).refinedFont(.hint).foregroundStyle(Refined.dim) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .refinedSurface(Refined.butterTint, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .combine)
    }
}

/// One day's square: its shade, its number, its short count, a dot when you recorded, and a ring for today. A day you
/// talked opens it.
struct WordsDayCell: View {
    var day: WordsCalendar.Day
    var open: () -> Void

    var body: some View {
        let n = Calendar.current.component(.day, from: day.start)
        let ink = day.level == 4 ? Refined.onFill : Refined.ink
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text("\(n)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Spacer(minLength: 0)
                    if !day.recordings.isEmpty { Circle().fill(ink).frame(width: 6, height: 6).padding(.top, 2) }
                }
                Spacer(minLength: 0)
                Text(WordsCalendar.short(day.words)).font(.system(size: 10)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(day.isFuture ? Refined.faint : ink)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .leading)
            .background { if day.isFuture { shape.strokeBorder(Refined.rail, lineWidth: 1) } else { shape.fill(Refined.heat[day.level]) } }
            .overlay { if day.isToday { shape.strokeBorder(Refined.ink, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(RefinedPress())
        .disabled(!day.talked || day.isFuture)
        .accessibilityLabel(Self.spoken(day))
        .accessibilityHint(day.talked && !day.isFuture ? "Opens the day." : "")
    }

    /// "Friday, October 30, today: 3,120 words, 3 recordings".
    static func spoken(_ d: WordsCalendar.Day) -> String {
        var s = WordsText.day(d.start)
        if d.isToday { s += ", today" }
        if d.isFuture { return s }
        var parts: [String] = [d.words == 0 ? "no words" : WordsText.words(d.words)]
        if !d.recordings.isEmpty { parts.append(d.recordings.count == 1 ? "1 recording" : "\(d.recordings.count) recordings") }
        return s + ": " + parts.joined(separator: ", ")
    }
}

/// The round previous and next buttons beside a month or a year.
struct WordsStepButton: View {
    var forward: Bool
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: forward ? "chevron.right" : "chevron.left").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Refined.ink)
                .frame(width: 36, height: 36)
                .background(Refined.card, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(label)
    }
}

// MARK: - Year

struct WordsYearView: View {
    var year: WordsCalendar.Year
    @Binding var anchor: Date
    var now: Date
    var openMonth: (Date) -> Void

    private var cal: Calendar { .current }

    var body: some View {
        let y = year
        let isCurrent = y.start >= (cal.dateInterval(of: .year, for: now)?.start ?? now)
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your words").refinedFont(.meta).foregroundStyle(Refined.mute)
                HStack {
                    Text(Formats.pattern("yyyy").string(from: y.start)).refinedFont(.largeTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    WordsStepButton(forward: false, label: "Previous year") { anchor = cal.date(byAdding: .year, value: -1, to: anchor) ?? anchor }
                    WordsStepButton(forward: true, label: "Next year") { anchor = min(now, cal.date(byAdding: .year, value: 1, to: anchor) ?? anchor) }
                        .disabled(isCurrent).opacity(isCurrent ? 0.4 : 1)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(y.words.formatted()).font(.system(size: 44, weight: .bold)).monospacedDigit().foregroundStyle(Refined.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text((y.words == 1 ? "word this year" : "words this year") + (WordsCalendar.equivalent(y.words).map { ", \($0)" } ?? ""))
                    .refinedFont(.hint).foregroundStyle(Refined.dim)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("words.year.total")
            months(y)
            shelf(y)
            if let best = y.bestMonth { byMonth(y, best: best) }
        }
    }

    private func months(_ y: WordsCalendar.Year) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(y.months, id: \.start) { m in
                Button { openMonth(m.start) } label: { WordsMiniMonth(month: m) }
                    .buttonStyle(RefinedPress())
                    .accessibilityLabel("\(WordsText.monthName(m.start)): \(WordsText.words(m.words))")
                    .accessibilityHint("Opens the month.")
            }
        }
        .padding(16)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    private func shelf(_ y: WordsCalendar.Year) -> some View {
        let p = WordsCalendar.shelfProgress(y.words)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Your bookshelf")
            WordsCard {
                WordsSpines(filled: p.filled)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Refined.rail).frame(height: 3).offset(y: 3) }
                    .padding(.top, 4).padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.filled == 0 ? "Your first book is on its way." : "This year fills \(p.filled) of the shelf, up to \(WordsCalendar.shelf[p.filled - 1].withArticle).")
                        .refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(p.next.map { "\(p.remaining.formatted()) more words to reach \($0.withArticle)." } ?? "The shelf is full.")
                        .refinedFont(.hint).foregroundStyle(Refined.dim)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("words.shelf")
            Text("Lengths: short story \(7_500.formatted()) words, novella \(20_000.formatted()), novel \(50_000.formatted()), long novel \(100_000.formatted()), epic \(200_000.formatted()), trilogy \(300_000.formatted()).")
                .refinedFont(.caption).foregroundStyle(Refined.mute).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func byMonth(_ y: WordsCalendar.Year, best: Int) -> some View {
        let top = Double(max(1, y.months[best].words))
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Month by month")
            WordsCard {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(Array(y.months.enumerated()), id: \.offset) { i, m in
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(i == best ? Refined.persimmon : Refined.heat[2])
                                .frame(height: m.words == 0 ? 0 : max(4, 84 * CGFloat(Double(m.words) / top)))
                            Text(String(WordsText.monthName(m.start).prefix(1))).refinedFont(.caption).foregroundStyle(Refined.mute)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 110)
                .accessibilityHidden(true)
                (Text("Your biggest month was ") + Text(WordsText.monthName(y.months[best].start)).bold() + Text("."))
                    .refinedFont(.body).foregroundStyle(Refined.ink)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A small month in the year: its name, its words, and a square per day.
struct WordsMiniMonth: View {
    var month: WordsCalendar.Month
    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Formats.pattern("MMM").string(from: month.start)).refinedFont(.caption, weight: .semibold).foregroundStyle(Refined.ink)
                Spacer(minLength: 2)
                Text(month.words == 0 ? "" : WordsCalendar.short(month.words)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Refined.mute)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<month.leading, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                ForEach(month.days, id: \.start) { d in
                    let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
                    Group {
                        if d.isFuture { shape.strokeBorder(Refined.rail, lineWidth: 1) }
                        else { shape.fill(Refined.heat[d.level]) }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { if d.isToday { shape.strokeBorder(Refined.ink, lineWidth: 1.5) } }
                }
            }
        }
        .contentShape(Rectangle())
    }
}
