// brand: native file
import SwiftUI

// The month calendar Journal's By day draws in Native (ThoughtsScreens.swift). The You page's Native stat cards that
// lived here moved to the refined look (YouScreen.swift).

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
