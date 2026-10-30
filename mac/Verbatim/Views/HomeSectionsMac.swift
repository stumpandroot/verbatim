import SwiftUI
import AppKit

// Home's Today's thoughts and Journal on the Mac (Edit Home), each Compact (one slim row) or Large (the card under its
// serif title), drawn with the refined kit (DESIGN.md §13) in both looks; and the outline and name badge each section
// wears while Home is being edited.

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

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!editing)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: RefinedPlatform.radius(.record) + 4, style: .continuous)
                        .strokeBorder(Refined.ink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing { badge.offset(x: 14, y: -16).allowsHitTesting(false) }
            }
    }

    private var badge: some View {
        Text("\(item.section.title) · \(item.size.title)").refinedFont(.chip, weight: .semibold)
            .foregroundStyle(Refined.paper)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Refined.ink))
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

/// New thought on Home: a quiet button with the bulb (its wave follows your voice while one records) and ⌃⌥P. It
/// records in place, and a second click stops it onto today's page. Never a second fill beside Record (DESIGN.md §14.9).
struct HomeNewThoughtButton: View {
    @ObservedObject private var capture = ThoughtCapture.shared

    var body: some View {
        Button { capture.toggle() } label: {
            HStack(spacing: 7) {
                Group {
                    if capture.isRecording { ThoughtMicLevel(live: capture.recorder.live, color: Refined.ink) }
                    else { ThoughtGlyph(color: Refined.ink, lineWidth: 1.4) }
                }
                .frame(width: 14, height: 14)
                Text(capture.isRecording ? "Stop" : "New thought")
                Text(Thoughts.hotkey).fontWeight(.regular).foregroundStyle(Refined.mute)
            }
        }
        .buttonStyle(RefinedActionStyle())
        .help("New thought (\(Thoughts.hotkey))")
        .accessibilityLabel(capture.isRecording ? "Stop the thought" : "New thought")
    }
}

/// Today's thoughts. Large: "Today's thoughts" with Today's page, the latest four in a card with their times, and New
/// thought. Compact: one slim row with the count and the latest, and New thought beside it. A click opens today's page.
/// Thoughts are a kind, so the section stays in ink (DESIGN.md §14.1).
struct HomeThoughtsMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize

    var body: some View {
        let page = app.store.todaysThoughts()
        Group {
            if size == .compact { compact(page) } else { large(page) }
        }
        .uiTarget("home-thoughts")
    }

    private func words(_ t: Transcript) -> String {
        switch t.status {
        case .processing: return "Saved as audio. Transcribing…"
        case .failed: return "Couldn't transcribe it. The audio is kept."
        case .ready: let w = Thoughts.words(t); return w.isEmpty ? "Nothing heard" : w
        }
    }

    private func large(_ page: [Transcript]) -> some View {
        let shown = HomeThoughts.latest(page)
        return VStack(alignment: .leading, spacing: 6) {
            SerifSectionTitle("Today's thoughts", link: "Today's page") { HomeDayPages.openToday(app) }
            Button { HomeDayPages.openToday(app) } label: {
                PaperCard {
                    if shown.isEmpty {
                        Text("No thoughts yet today. \(Thoughts.hotkey) starts one from any app.")
                            .refinedFont(.body).foregroundStyle(Refined.dim)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { PaperDivider(leading: 16, trailing: 16) }
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(Thoughts.time(t.createdAt, native: true)).refinedFont(.meta).monospacedDigit()
                                .foregroundStyle(Refined.mute).frame(width: 64, alignment: .leading)
                            Text(words(t)).refinedFont(.body).foregroundStyle(t.status == .ready ? Refined.ink : Refined.dim).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            .buttonStyle(RefinedPress())
            .accessibilityHint("Opens today's Thoughts page.")
            HStack {
                HomeNewThoughtButton().uiTarget("home-thoughts-new")
                Spacer(minLength: 0)
                if page.count > HomeThoughts.largeCount {
                    Text("\(page.count) today").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                }
            }
            .padding(.top, 4)
        }
    }

    private func compact(_ page: [Transcript]) -> some View {
        HStack(spacing: 8) {
            Button { HomeDayPages.openToday(app) } label: {
                HStack(spacing: 12) {
                    IconGlyph(art: .iconThought, size: 18, color: Refined.ink)
                    Text(HomeThoughts.countLine(page.count)).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        .lineLimit(1).fixedSize()
                    if let last = page.last {
                        Text(words(last)).refinedFont(.rowTitle).foregroundStyle(Refined.mute).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(RefinedPress())
            .accessibilityHint("Opens today's Thoughts page.")
            HomeNewThoughtButton().uiTarget("home-thoughts-new")
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }
}

/// Journal. Large: "Journal" with By day, then a card with the newest entry (the date, its title, the first lines, and
/// a play button with the length) over this week's days as dots. Compact: one slim row with the title and the dots.
/// A click opens Journal By day; play plays the entry.
struct HomeJournalMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize

    var body: some View {
        let j = HomeDayPages.journal(app.store)
        Group {
            if size == .compact { compact(j.latest, j.week) } else { large(j.latest, j.week) }
        }
        .uiTarget("home-journal")
    }

    private func compact(_ latest: Transcript?, _ week: [HomeJournalWeek.Day]) -> some View {
        Button { HomeDayPages.openJournal(app) } label: {
            HStack(spacing: 12) {
                IconGlyph(art: .iconNotes, size: 18, color: Refined.ink)
                Text("Journal").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).fixedSize()
                Text(latest?.title ?? "No entries yet").refinedFont(.rowTitle).foregroundStyle(Refined.mute).lineLimit(1)
                Spacer(minLength: 8)
                HomeWeekDots(week: week, size: 8)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
        .buttonStyle(RefinedPress())
        .accessibilityValue(HomeJournalWeek.countLine(week))
        .accessibilityHint("Opens Journal by day.")
    }

    private func large(_ latest: Transcript?, _ week: [HomeJournalWeek.Day]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SerifSectionTitle("Journal", link: "By day") { HomeDayPages.openJournal(app) }
            VStack(alignment: .leading, spacing: 12) {
                Button { HomeDayPages.openJournal(app) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let t = latest {
                            Text(PremiumDateLine.line(t.createdAt)).refinedFont(.meta).foregroundStyle(Refined.mute)
                            Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                            Text(PremiumPreview.text(t)).refinedFont(.meta).foregroundStyle(Refined.dim).lineLimit(2)
                        } else {
                            Text("Record with the Journal kind, and your newest entry shows here.")
                                .refinedFont(.body).foregroundStyle(Refined.dim)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RefinedPress())
                .accessibilityHint("Opens Journal by day.")
                // Play sits beside the entry's button, not inside it (macOS 26 click safety).
                HStack(spacing: 12) {
                    if let t = latest, t.audioFileName != nil, t.status == .ready {
                        Button { WindowNav.shared.play(t, app: app) } label: {
                            HStack(spacing: 6) {
                                IconGlyph(art: .iconPlay, size: 11, color: Refined.ink)
                                Text(HomeRecentStyle.length(t.duration)).monospacedDigit()
                            }
                        }
                        .buttonStyle(RefinedActionStyle())
                        .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
                    }
                    Spacer(minLength: 8)
                    HomeWeekDots(week: week, size: 10, letters: true)
                    Text(HomeJournalWeek.countLine(week)).refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("This week: \(HomeJournalWeek.countLine(week))")
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
    }
}
