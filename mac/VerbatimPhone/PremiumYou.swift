// brand: native file
import SwiftUI

/// The top of the You page in Native, after Journal's Insights, drawn as list sections (mockup "Verbose Native
/// Redesign", section 11: You's gradient cards became list sections): the week (the days you used Verbose, with no
/// streak to keep), the year with month bars (this month in the accent), two stat cells (words dictated and time saved
/// this week), and a month calendar with a dot on each day you recorded or dictated. Grouped cells in system colors,
/// SF Pro bold numbers with monospaced digits. Counted from your transcripts, the same as Home.
struct PremiumYouStats: View {
    /// Whether the cards are on screen, for the self-test.
    static var visible = false
    @EnvironmentObject var app: PhoneState
    var week: HomeWeek
    var now: Date
    @ObservedObject private var flow = FlowSettings.shared
    /// The calendar's month; starts on this month.
    @State private var month: Date? = nil
    @ScaledMetric(relativeTo: .largeTitle) private var daysSize: CGFloat = 60

    var body: some View {
        let live = app.store.live
        let dates = live.map(\.createdAt)
        let year = Calendar.current.component(.year, from: now)
        let recordings = live.filter { !$0.isDictation }.map(\.createdAt)
        let thisYear = PremiumRules.monthCounts(recordings, year: year)
        VStack(alignment: .leading, spacing: 0) {
            label("This week").padding(.top, 6)
            weekCard(PremiumRules.daysUsed(dates, now: now))
            label("Stats")
            yearCard(thisYear)
            HStack(spacing: 12) {
                statCard(value: week.words.formatted(), title: "Dictated", detail: "words this week")
                statCard(value: HomeScreen.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM)), title: "Saved", detail: "typing this week")
            }
            .padding(.top, 12)
            label("Calendar")
            PremiumMonthCalendar(month: Binding(get: { month ?? now }, set: { month = $0 }), dates: dates, now: now)
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    private func label(_ text: String) -> some View {
        NativeListHeader(title: text)
            .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
    }

    /// The days you used Verbose in the last seven, in big rounded type, a calm line, and a dot per day.
    private func weekCard(_ used: [Bool]) -> some View {
        let n = used.filter { $0 }.count
        let letters = PremiumRules.dayLetters(now: now)
        return VStack(spacing: 6) {
            Text(PremiumRules.daysLabel(n)).font(NativeStyle.number(min(daysSize, 56)))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(PremiumRules.daysSentence(n)).font(.system(size: 15)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(Array(zip(letters.indices, letters)), id: \.0) { i, letter in
                    Text(letter).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(used[i] ? NativeInk.onAccent : NativeInk.secondary)
                        .frame(width: 22, height: 22)
                        .background(used[i] ? NativeInk.accent : NativeInk.fill, in: Circle())
                }
            }
            .padding(.top, 6)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .foregroundStyle(NativeInk.label).nativeCell()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PremiumRules.daysSentence(n))
        .accessibilityIdentifier("you.week.premium")
    }

    /// This year's recordings: the count, then a bar per month with the current month in white.
    private func yearCard(_ months: [Int]) -> some View {
        let total = months.reduce(0, +)
        let current = Calendar.current.component(.month, from: now) - 1
        let heights = PremiumRules.barHeights(months, future: months.indices.map { $0 > current }, maxHeight: 46, minHeight: 4)
        let letters = Calendar.current.veryShortStandaloneMonthSymbols
        return HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(total.formatted()).font(NativeStyle.number(34)).lineLimit(1).minimumScaleFactor(0.6)
                Text("Transcripts").font(.headline)
                Text("This year").font(.subheadline).foregroundStyle(NativeInk.secondary)
            }
            Spacer(minLength: 6)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<12, id: \.self) { i in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(heights[i] == nil ? NativeInk.fill : i == current ? NativeInk.accent : NativeInk.gray)
                            .frame(width: 7, height: CGFloat(heights[i] ?? 4))
                            .frame(height: 46, alignment: .bottom)
                        Text(letters[i % letters.count]).font(.system(size: 10.5, weight: i == current ? .heavy : .semibold))
                            .frame(width: 9)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .foregroundStyle(NativeInk.label).nativeCell()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(HomeCounts.countLabel(total, "transcript", "transcripts")) this year")
    }

    /// A stat card: the number up top (big numbers need 3:1), its name and detail lower, where small text keeps 4.5:1.
    private func statCard(value: String, title: String, detail: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(NativeStyle.number(28)).lineLimit(1).minimumScaleFactor(0.5)
            Text(title).font(.subheadline.weight(.semibold)).padding(.top, 2)
            Text(detail).font(.footnote).foregroundStyle(NativeInk.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100)
        .foregroundStyle(NativeInk.label).nativeCell()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value), \(detail)")
    }
}

/// A month on a soft card: the month and year with previous and next, the weekday names, and the days, with a dot
/// under each day you recorded or dictated and today in the accent. No streaks, no goals.
struct PremiumMonthCalendar: View {
    @Binding var month: Date
    var dates: [Date]
    var now: Date
    /// By day (ByDayScreen): a day with a dot opens its page. Nil on You, where the days only show.
    var pick: ((Date) -> Void)? = nil
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let grid = PremiumRules.month(month, recorded: dates, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(Formats.pattern("MMMM yyyy").string(from: grid.start)).font(.system(size: 19, weight: .bold)).foregroundStyle(NativeInk.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { month = PremiumRules.shiftMonth(month, by: -1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Previous month")
                Button { month = PremiumRules.shiftMonth(month, by: 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Next month")
                .disabled(grid.today != nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NativeInk.accent)
            .padding(.horizontal, 6)
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(PremiumRules.weekdayHeaders(), id: \.self) { h in
                    Text(h).font(.system(size: 12, weight: .semibold)).foregroundStyle(NativeInk.secondary)
                        .padding(.bottom, 4).accessibilityHidden(true)
                }
                ForEach(0..<grid.leadingBlanks, id: \.self) { i in Color.clear.frame(height: 40).id("blank-\(i)") }
                ForEach(1...max(1, grid.days), id: \.self) { d in dayCell(d, grid: grid) }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 10)
        .nativeCell(radius: 26)
    }

    @ViewBuilder private func dayCell(_ d: Int, grid: PremiumRules.MonthGrid) -> some View {
        if let pick, grid.recorded.contains(d), let date = Calendar.current.date(byAdding: .day, value: d - 1, to: grid.start) {
            Button { pick(date) } label: { dayLabel(d, grid: grid) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens that day's page")
        } else {
            dayLabel(d, grid: grid)
        }
    }

    private func dayLabel(_ d: Int, grid: PremiumRules.MonthGrid) -> some View {
        let today = grid.today == d
        let recorded = grid.recorded.contains(d)
        return VStack(spacing: 2) {
            Text("\(d)").font(.system(size: 17, weight: today ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(today ? NativeInk.onAccent : NativeInk.label)
            Circle().fill(today ? NativeInk.onAccent : NativeInk.accent).frame(width: 5, height: 5)
                .opacity(recorded ? 1 : 0)
        }
        .frame(maxWidth: .infinity).frame(height: 40)
        .background { if today { Circle().fill(NativeInk.accent).frame(width: 38, height: 38) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(d)\(today ? ", today" : "")\(recorded ? ", recorded" : "")")
    }
}
