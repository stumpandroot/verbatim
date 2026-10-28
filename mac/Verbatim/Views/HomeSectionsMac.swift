import SwiftUI
import AppKit

// brand: web style
//
// Home's newer sections on the Mac (Edit Home, mockup "premium", section 03): Today's thoughts and Journal in the
// website style, each Compact (one strip) or Large (the card under its heading); Native draws its own
// (NativeHomeSections.swift). Also the outline and name badge each section wears while Home is being edited. Projects,
// Moments, and Queue left Home in the consolidation (October 28, 2026), with the Search tile.

// MARK: - Editing frame

extension View {
    /// While Home is being edited: a dashed outline and a "This week · Large" badge, and the section's own controls
    /// rest (no clicks reach them). Nothing changes identity, so leaving edit mode costs nothing.
    func homeEditFrame(_ item: HomeLayout.Item, editing: Bool) -> some View {
        modifier(HomeEditFrame(item: item, editing: editing))
    }
}

private struct HomeEditFrame: ViewModifier {
    var item: HomeLayout.Item
    var editing: Bool
    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!editing)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: look == .native ? 14 : Radius.record + 4, style: .continuous)
                        .strokeBorder(look == .native ? NativeInk.accent.opacity(0.55) : Ink.ink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing { badge.offset(x: 14, y: -16).allowsHitTesting(false) }
            }
    }

    @ViewBuilder private var badge: some View {
        let text = "\(item.section.title) · \(item.size.title)"
        if look == .native {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)   // brand: native
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(NativeInk.content))   // brand: native
                .overlay(Capsule().strokeBorder(NativeInk.separator, lineWidth: 0.5))   // brand: native
        } else {
            HStack(spacing: 6) {
                ArtIcon(art: .iconNameAndSort, size: 12, lineWidth: 1.4)
                Text(text).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Ink.paper)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Ink.ink))
        }
    }
}

// MARK: - Today's thoughts and Journal

/// Where Home's Thoughts and Journal open on the Mac: today's page in Library › By day › Thoughts (the day set to
/// today, not the one you left), and Journal's By day.
@MainActor
enum HomeDayPages {
    static func openToday(_ app: AppState) {
        ScreenPlaces.shared.setDay(.idea, day: DayPages.today(hour: Thoughts.newPageHour), month: nil)
        app.go(.byDay(.idea))
    }

    static func openJournal(_ app: AppState) { app.go(.byDay(.journal)) }

    /// Journal's newest entry and this week's days with an entry.
    static func journal(_ store: Store) -> (latest: Transcript?, week: [HomeJournalWeek.Day]) {
        let hour = Thoughts.newPageHour
        let pages = store.dayPages(.journal, hour: hour)
        let week = HomeJournalWeek.days(entryDays: pages.map(\.day), today: DayPages.today(hour: hour))
        return (pages.first?.items.last, week)
    }
}

/// Today's thoughts. Large: the latest four under "Today's thoughts", each with its time in mono, and New thought.
/// Compact: one strip with the count and the latest. A click opens today's page; New thought records in place, as
/// ⌃⌥P does. Thoughts are a kind, so everything here is ink (DESIGN.md §14.1).
struct HomeThoughtsMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @ObservedObject private var capture = ThoughtCapture.shared
    @Environment(\.look) private var look

    var body: some View {
        let page = app.store.todaysThoughts()
        if look == .native {
            NativeHomeThoughts(size: size, page: page)
        } else if size == .compact {
            strip(page)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title: "Today's", italic: "thoughts", link: "Today's page", linkHint: "Opens today's Thoughts page.") { HomeDayPages.openToday(app) }
                    .padding(.bottom, 8)
                if page.isEmpty {
                    FlatRowButton(action: { HomeDayPages.openToday(app) }) { _ in
                        Text("No thoughts yet today. \(Thoughts.hotkey) starts one from any app.")
                            .font(.system(size: 14)).foregroundStyle(Ink.dim)
                            .padding(.horizontal, 14).frame(height: 52, alignment: .leading)
                    } accessory: { _ in EmptyView() }
                    .accessibilityHint("Opens today's Thoughts page.")
                }
                ForEach(HomeThoughts.latest(page)) { t in line(t) }
                HStack {
                    newThought
                    Spacer(minLength: 0)
                    if page.count > HomeThoughts.largeCount {
                        Text("\(page.count) today").font(Ink.mono(12)).foregroundStyle(Ink.mute)
                    }
                }
                .padding(.top, 10)
            }
            .uiTarget("home-thoughts")
        }
    }

    private func line(_ t: Transcript) -> some View {
        FlatRowButton(action: { HomeDayPages.openToday(app) }) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Thoughts.time(t.createdAt, native: false)).font(Ink.mono(12.5)).foregroundStyle(Ink.mute).frame(width: 44, alignment: .leading)
                Text(words(t)).font(.system(size: 14)).foregroundStyle(t.status == .ready ? Ink.ink : Ink.dim).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 11)
        } accessory: { _ in EmptyView() }
        .accessibilityHint("Opens today's Thoughts page.")
    }

    private func words(_ t: Transcript) -> String {
        switch t.status {
        case .processing: return "Saved as audio. Transcribing…"
        case .failed: return "Couldn't transcribe it. The audio is kept."
        case .ready: let w = Thoughts.words(t); return w.isEmpty ? "Nothing heard" : w
        }
    }

    /// A line pill with its keycap, never a second fill beside Record (DESIGN.md §14.9; `NewThoughtPill`, ByDayView.swift).
    private var newThought: some View {
        NewThoughtPill(size: .mini).uiTarget("home-thoughts-new")
    }

    private func strip(_ page: [Transcript]) -> some View {
        FlatRowButton(action: { HomeDayPages.openToday(app) }) { _ in
            HStack(spacing: 12) {
                IconGlyph(art: .iconThought, size: 18, color: Ink.ink)
                Text(HomeThoughts.countLine(page.count)).font(Ink.serif(18)).foregroundStyle(Ink.ink).lineLimit(1).fixedSize()
                if let last = page.last {
                    Text(words(last)).font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Color.clear.frame(width: 176, height: 1)   // room for New thought and its keycap
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .inkEdge(outline: true, radius: Radius.record)
        } accessory: { _ in newThought.padding(.trailing, 14) }
        .accessibilityHint("Opens today's Thoughts page.")
        .uiTarget("home-thoughts")
    }
}

/// Journal. Large: the newest entry under "Journal" (its title in the serif with an italic last word, the first
/// line, and a play pill with the length) over this week's days as ink dots. Compact: one strip with the title and the
/// dots. A click opens Journal By day; the play pill plays the entry.
struct HomeJournalMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @Environment(\.look) private var look

    var body: some View {
        let j = HomeDayPages.journal(app.store)
        if look == .native {
            NativeHomeJournal(size: size, latest: j.latest, week: j.week)
        } else if size == .compact {
            FlatRowButton(action: { HomeDayPages.openJournal(app) }) { _ in
                HStack(spacing: 12) {
                    IconGlyph(art: .iconNotes, size: 18, color: Ink.ink)
                    Text("Journal").font(Ink.serif(18)).foregroundStyle(Ink.ink).fixedSize()
                    Text(j.latest?.title ?? "No entries yet").font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineLimit(1)
                    Spacer(minLength: 8)
                    HomeWeekDots(week: j.week, size: 8)
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                .inkEdge(outline: true, radius: Radius.record)
            } accessory: { _ in EmptyView() }
            .accessibilityValue(HomeJournalWeek.countLine(j.week))
            .accessibilityHint("Opens Journal by day.")
            .uiTarget("home-journal")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title: "", italic: "Journal", link: "By day", linkHint: "Opens Journal by day.") { HomeDayPages.openJournal(app) }
                    .padding(.bottom, 8)
                entry(j.latest)
                HStack(spacing: 12) {
                    HomeWeekDots(week: j.week, size: 10, letters: true)
                    Spacer(minLength: 8)
                    Text(HomeJournalWeek.countLine(j.week)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                }
                .padding(.horizontal, 10).padding(.top, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("This week: \(HomeJournalWeek.countLine(j.week))")
            }
            .uiTarget("home-journal")
        }
    }

    @ViewBuilder private func entry(_ t: Transcript?) -> some View {
        if let t {
            let words = t.title.split(separator: " ")
            let playable = t.audioFileName != nil && t.status == .ready
            FlatRowButton(action: { HomeDayPages.openJournal(app) }) { _ in
                VStack(alignment: .leading, spacing: 5) {
                    Text(PremiumDateLine.line(t.createdAt)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                    Group {
                        if words.count < 2 { Text(t.title).font(Ink.serif(21)) }
                        else { WebText.serif(words.dropLast().joined(separator: " "), italic: String(words.last ?? ""), size: 21) }
                    }
                    .foregroundStyle(Ink.ink).lineLimit(1)
                    Text(PremiumPreview.text(t)).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2)
                    if playable { Color.clear.frame(width: 60, height: 24) }
                }
                .padding(.horizontal, 10).padding(.vertical, 12)
            } accessory: { _ in EmptyView() }
            .accessibilityHint("Opens Journal by day.")
            .overlay(alignment: .bottomLeading) {
                if playable {
                    HStack(spacing: 5) {
                        ArtIcon(art: .iconPlay, size: 10, lineWidth: 1.4)
                        Text(HomeRecentStyle.length(t.duration)).font(Ink.mono(12))
                    }
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, 9).frame(height: 24)
                    .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5))
                    .contentShape(Capsule())
                    .tapArea { NativeNav.shared.play(t, app: app) }
                    .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
                    .accessibilityAddTraits(.isButton)
                    .padding(.leading, 10).padding(.bottom, 12)
                }
            }
        } else {
            FlatRowButton(action: { HomeDayPages.openJournal(app) }) { _ in
                Text("Record with the Journal kind, and your newest entry shows here.")
                    .font(.system(size: 14)).foregroundStyle(Ink.dim)
                    .padding(.horizontal, 14).frame(height: 52, alignment: .leading)
            } accessory: { _ in EmptyView() }
            .accessibilityHint("Opens Journal by day.")
        }
    }
}

/// This week's seven days as dots: filled where there's an entry, today outlined, ink in Verbose style and the accent
/// in Native (DESIGN.md §14.6). Optional weekday letters under them.
struct HomeWeekDots: View {
    var week: [HomeJournalWeek.Day]
    var size: CGFloat
    var letters = false
    @Environment(\.look) private var look

    var body: some View {
        let native = look == .native
        let color = native ? NativeInk.accent : Ink.ink
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(spacing: size * 0.9) {
            ForEach(week, id: \.start) { d in
                VStack(spacing: 4) {
                    Circle().fill(d.hasEntry ? color : Color.clear)
                        .overlay(Circle().strokeBorder(color.opacity(d.hasEntry ? 1 : (d.isFuture ? 0.25 : 0.5)), lineWidth: d.isToday ? 1.6 : 1))
                        .frame(width: size, height: size)
                    if letters {
                        Text(symbols[(Calendar.current.component(.weekday, from: d.start) - 1) % symbols.count])
                            .font(native ? .system(size: 10, weight: d.isToday ? .bold : .regular) : Ink.mono(12))   // brand: native
                            .foregroundStyle(native ? Color.secondary : Ink.mute)   // brand: native
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
