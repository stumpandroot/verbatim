import SwiftUI
import AppKit

// brand: web style
//
// Home's newer sections on the Mac (Edit Home, mockup "premium", section 03): Projects, Moments, and Queue in the
// website style, each Compact (one strip) or Large (the card under its heading); Native draws its own
// (NativeHomeSections.swift). Also the outline and name badge each section wears while Home is being edited, and the
// Search tile's action.

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

// MARK: - Search tile

enum HomeTileSearch {
    /// Opens the Library and puts the cursor in the toolbar's search field.
    @MainActor static func open(_ app: AppState) {
        app.projectFilter = nil
        app.go(.library)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            for item in w.toolbar?.items ?? [] {
                if let field = (item as? NSSearchToolbarItem)?.searchField ?? (item.view as? NSSearchField) {
                    w.makeFirstResponder(field)
                    return
                }
            }
        }
    }
}

// MARK: - Projects

/// Each project and how many recordings it holds. Compact: a row of pills. Large: the first six as flat rows under
/// "Projects". A click opens the Library on the project.
struct HomeProjectsMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @Environment(\.look) private var look

    var body: some View {
        let counts = Self.counts(app.store)
        if look == .native {
            NativeHomeProjects(size: size, counts: counts)
        } else if size == .compact {
            compact(counts)
        } else {
            large(counts)
        }
    }

    /// Recordings per project, in one pass over the library.
    static func counts(_ store: Store) -> [UUID: Int] {
        var c: [UUID: Int] = [:]
        for t in store.transcripts where t.deletedAt == nil && !t.isDictation { if let p = t.projectId { c[p, default: 0] += 1 } }
        return c
    }

    private func open(_ p: Project) { app.projectFilter = p.id; app.go(.library) }

    private func compact(_ counts: [UUID: Int]) -> some View {
        Group {
            if app.store.projects.isEmpty {
                Text("Projects group recordings. Make one from the sidebar or a recording's menu.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                    .inkEdge(outline: true, radius: Radius.record)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(app.store.projects) { p in
                            PillButton(title: "\(p.name)  \((counts[p.id] ?? 0).formatted())", kind: .line, size: .regular, icon: .iconProject,
                                       hint: "Opens the project in your library.") { open(p) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func large(_ counts: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "", italic: "Projects", link: "Library", linkHint: "Opens your library.") { app.projectFilter = nil; app.go(.library) }
                .padding(.bottom, 8)
            if app.store.projects.isEmpty {
                EmptyStateCard(art: .iconProject, title: "No projects yet", message: "Projects group recordings. Make one from the sidebar or a recording's menu.")
            }
            ForEach(Array(app.store.projects.prefix(6))) { p in
                FlatRowButton(action: { open(p) }) { _ in
                    HStack(spacing: 12) {
                        IconGlyph(art: .iconProject, size: 18, color: Ink.ink)
                        Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        StatusText(text: HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings"))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                } accessory: { _ in EmptyView() }
                .accessibilityHint("Opens the project in your library.")
            }
        }
    }
}

// MARK: - Moments

/// The newest saved moment and where it came from. A click opens the transcript at that line.
@MainActor
enum HomeMomentPick {
    static func latest(_ store: Store) -> (t: Transcript, n: Note)? {
        var best: (t: Transcript, n: Note)?
        for t in store.transcripts where t.deletedAt == nil {
            for n in t.notes where n.at != nil && (best == nil || n.createdAt > best!.n.createdAt) { best = (t, n) }
        }
        return best
    }

    /// The note's words, or the passage it points at for a bookmark without words.
    static func text(_ t: Transcript, _ n: Note) -> String {
        if !n.text.isEmpty { return n.isBookmark ? "“\(n.text)”" : n.text }
        let at = n.at ?? 0
        let seg = t.segments.first { $0.id == n.segmentId } ?? t.segments.last { $0.start <= at }
        return seg.map { "“\($0.text.trimmingCharacters(in: .whitespaces))”" } ?? "Bookmark"
    }

    static func open(_ app: AppState, _ t: Transcript, _ n: Note) {
        app.focusSegment = n.segmentId ?? t.segments.last { $0.start <= (n.at ?? 0) }?.id
        app.go(.transcript(t.id))
    }
}

/// Large: the moment as a quote on a butter panel under "Saved moments". Compact: one strip with the quote.
struct HomeMomentsMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @Environment(\.look) private var look
    @State private var down = false

    var body: some View {
        let latest = HomeMomentPick.latest(app.store)
        if look == .native {
            NativeHomeMoments(size: size, latest: latest)
        } else if size == .compact {
            strip(latest)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Saved", italic: "moments", link: "All", linkLabel: "All moments", linkHint: "Opens Moments.") { app.go(.moments) }
                    .padding(.bottom, 12)
                card(latest)
            }
        }
    }

    private func card(_ latest: (t: Transcript, n: Note)?) -> some View {
        HomeCard(tilt: 1.5, radius: Radius.record, shadow: false, onPress: { down = $0 }, action: {
            if let latest { HomeMomentPick.open(app, latest.t, latest.n) } else { app.go(.moments) }
        }) { hovering in
            VStack(alignment: .leading, spacing: 10) {
                if let latest {
                    HStack(spacing: 8) {
                        IconGlyph(art: latest.n.isBookmark ? .iconPin : .iconNotes, size: 15, color: Ink.inkFixed)
                        Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(Ink.mono(12)).foregroundStyle(Ink.inkFixed).lineLimit(1)
                    }
                    Text(HomeMomentPick.text(latest.t, latest.n))
                        .font(latest.n.isBookmark ? Ink.serif(22).italic() : .system(size: 15)).foregroundStyle(Ink.inkFixed)
                        .lineSpacing(2).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Bookmark a moment while a transcript plays, and the newest shows here.")
                        .font(.system(size: 14)).foregroundStyle(Ink.inkFixed).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .colorPanel(Ink.panelButter, radius: Radius.record)
            .inkEdge(outline: true, shadow: InkEdge.card(hover: hovering, pressed: down), radius: Radius.record, color: Ink.inkFixed)
        }
        .accessibilityLabel(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "No moments yet")
        .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
    }

    private func strip(_ latest: (t: Transcript, n: Note)?) -> some View {
        FlatRowButton(action: { if let latest { HomeMomentPick.open(app, latest.t, latest.n) } else { app.go(.moments) } }) { _ in
            HStack(spacing: 12) {
                IconGlyph(art: .iconMoments, size: 18, color: Ink.ink)
                Text(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "Bookmark a moment while a transcript plays.")
                    .font(Ink.serif(18)).foregroundStyle(Ink.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let latest {
                    Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .inkEdge(outline: true, radius: Radius.record)
        } accessory: { _ in EmptyView() }
        .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
    }
}

// MARK: - Queue

/// What's transcribing (Home draws Queue only while something is). Compact: the first, with how many wait behind it.
/// Large: up to three under "Queue". A click opens the Queue.
struct HomeQueueMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @Environment(\.look) private var look

    static func working(_ store: Store) -> [Transcript] {
        store.transcripts.filter { $0.deletedAt == nil && $0.status == .processing }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let items = Self.working(app.store)
        if look == .native {
            NativeHomeQueue(size: size, items: items)
        } else if size == .compact {
            if let first = items.first { row(first, more: items.count - 1, boxed: true) }
        } else if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title: "", italic: "Queue", link: "Queue", linkLabel: "Open the Queue", linkHint: "Opens the Queue.") { app.go(.queue) }
                    .padding(.bottom, 8)
                ForEach(items.prefix(3)) { t in row(t, more: 0, boxed: false) }
            }
        }
    }

    private func row(_ t: Transcript, more: Int, boxed: Bool) -> some View {
        FlatRowButton(action: { app.go(.queue) }) { _ in
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    LiveStage(t) { t in
                        Text(more > 0 ? "\(t.stageText) · \(more.formatted()) more" : t.stageText).font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: boxed ? 60 : 52)
            .background(boxed ? Ink.card : Color.clear, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .inkEdge(outline: boxed, radius: Radius.record)
        } accessory: { _ in EmptyView() }
        .accessibilityHint("Opens the Queue.")
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
