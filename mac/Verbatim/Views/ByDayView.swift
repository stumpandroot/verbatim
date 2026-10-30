import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Library › By day (mockup "Thoughts", section 03), on the refined kit (DESIGN.md §13): Thoughts
// and Journal, one page a day. A month calendar marks each day with entries with a dot, a day list sits under it, and
// the selected day's page fills the right side. Thoughts adds New thought, Copy, Send to, Export, and Open as pad;
// Journal's entries show a title, a play button with the length, and the first line. Thoughts are butter and journal
// entries petal (the kinds' colors, §13), on their dots and squares; the selected day takes the persimmon tint with
// accent text, and today a ring. A page is every recording of the kind that started that day (Model/DayPages.swift),
// so nothing here is stored on its own.

struct ByDayView: View {
    @EnvironmentObject var app: AppState
    var kind: RecordingKind
    @State private var selected: Date?
    /// The month the calendar shows once you've moved it; until then, the shown day's month. (Build 219 set it in
    /// `onAppear`, which rendered all of By day a second time right after it appeared: 220 to 790 ms between the
    /// screen's appear and its first frame.)
    @State private var shownMonth: Date?

    /// The day and month you left come back with the screen (ScreenPlaces, App/NavTrail.swift).
    init(kind: RecordingKind) {
        self.kind = kind
        let place = ScreenPlaces.shared.day(kind)
        _selected = State(initialValue: place.day)
        _shownMonth = State(initialValue: place.month)
    }

    private var hour: Int { Thoughts.newPageHour }
    private var isThoughts: Bool { kind != .journal }
    private var name: String { Thoughts.pageName(kind) }

    var body: some View {
        let pages = app.store.dayPages(kind, hour: hour)
        let today = DayPages.today(hour: hour)
        let day = selected ?? (pages.first { $0.day == today }?.day ?? pages.first?.day ?? today)
        let items = pages.first { $0.day == day }?.items ?? []
        let month = shownMonth ?? day
        let _ = NavMarks.mark("byday")
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RefinedPageHeader(title: name, count: titleCount(pages, today: today),
                                  lede: isThoughts ? "One page per day. Pick a day to read it." : "One page per day, from your journal recordings.") {
                    if isThoughts { titleControls }
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        DayCalendar(month: Binding(get: { month }, set: { shownMonth = $0 }), selected: day, today: today,
                                    marked: Set(pages.map(\.day)), hue: kind.refinedHue) { d in selected = d }
                        dayList(pages, selected: day, month: month)
                    }
                    .frame(width: 280)
                    // minWidth 0: the page takes what's left and never asks for more, so the window's split view never
                    // squeezes the sidebar off its edge.
                    DayPageCard(kind: kind, day: day, today: today, items: items)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 40)
            .frame(minWidth: 0, maxWidth: 1180, alignment: .leading)
            .scrollPlace(ScreenPlaces.scrollKey(isThoughts ? "byday-thoughts" : "byday-journal"))
            .navMarkWhenLaidOut("byday-laid-out")
        }
        .softScrollEdges(.top)
        .background(Refined.paper)
        .onAppear { NavMarks.mark("byday-appear") }
        .onChange(of: kind) { _, _ in selected = nil }
        .onChange(of: selected) { _, d in ScreenPlaces.shared.setDay(kind, day: d, month: shownMonth) }
        .onChange(of: shownMonth) { _, m in ScreenPlaces.shared.setDay(kind, day: selected, month: m) }
        .uiTarget(isThoughts ? "byday-thoughts" : "byday-journal")
    }

    /// By day | All thoughts (the kit's segmented control; All thoughts opens the Library on Thoughts), and New thought.
    @ViewBuilder private var titleControls: some View {
        RefinedSegmented(label: "View", options: [(0, "By day"), (1, "All thoughts")],
                         selection: Binding(get: { 0 }, set: { v in if v == 1 { showAll() } }))
            .fixedSize()
            .background {
                // The self-test's handles on each half.
                HStack(spacing: 0) {
                    Color.clear.uiTarget("byday-switch-day")
                    Color.clear.uiTarget("byday-switch-all")
                }
                .allowsHitTesting(false)
            }
        NewThoughtPill().uiTarget("byday-new-thought")
    }

    /// Thoughts: today's count ("6 today"), as the sidebar's count. Journal: this week's entries ("3 this week").
    private func titleCount(_ pages: [(day: Date, items: [Transcript])], today: Date) -> String {
        if isThoughts { return "\(pages.first { $0.day == today }?.items.count ?? 0) today" }
        return "\(app.store.journalThisWeek()) this week"
    }

    /// The Library, filtered to Thoughts.
    private func showAll() {
        app.projectFilter = nil
        app.libraryFilter = .all
        app.libraryKind = kind
        app.go(.library)
    }

    /// "This month · 16 days", then each day with entries in the shown month, newest first, in a card.
    @ViewBuilder private func dayList(_ pages: [(day: Date, items: [Transcript])], selected: Date, month: Date) -> some View {
        let cal = Calendar.current
        let inMonth = pages.filter { cal.isDate($0.day, equalTo: month, toGranularity: .month) }
        let thisMonth = cal.isDate(month, equalTo: Date(), toGranularity: .month)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(thisMonth ? "This month" : DayPages.monthTitle(month)) · \(DayPages.count(inMonth.count, "day", "days"))")
                .refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            if inMonth.isEmpty {
                Text(isThoughts ? "No thoughts this month." : "No journal entries this month.")
                    .refinedFont(.body).foregroundStyle(Refined.mute).padding(.vertical, 6).padding(.horizontal, 4)
            } else {
                PaperCard {
                    ForEach(Array(inMonth.enumerated()), id: \.element.day) { i, p in
                        if i > 0 { PaperDivider(leading: 12, trailing: 12) }
                        PaperRowButton(selected: p.day == selected, action: { self.selected = p.day }) {
                            HStack(spacing: 12) {
                                Text(DayPages.listDay(p.day)).refinedFont(.meta).monospacedDigit()
                                    .foregroundStyle(p.day == selected ? Refined.accentText : Refined.mute).frame(width: 56, alignment: .leading)
                                Text(firstLine(p.items)).refinedFont(.rowTitle).foregroundStyle(Refined.ink).lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(p.items.count)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .uiTarget("byday-row-\(DayPages.listDay(p.day))")
                    }
                }
            }
        }
    }

    /// The day's first thought that has words (an empty one never names the day), or Journal's first title.
    private func firstLine(_ items: [Transcript]) -> String {
        guard let first = isThoughts ? ThoughtText.firstWithWords(items) : items.first else { return "" }
        if !isThoughts { return first.title }
        let w = Thoughts.words(first)
        if !w.isEmpty { return w }
        return first.status == .processing ? "Transcribing…" : first.status == .failed ? "Couldn't transcribe it" : "Nothing heard"
    }
}

/// New thought: starts recording in place (Stop while one records). The kit's quiet action with the Thoughts icon and
/// its shortcut, never a second persimmon fill beside Record (DESIGN.md §14.9). By day's title row shares it.
struct NewThoughtPill: View {
    @ObservedObject private var capture = ThoughtCapture.shared

    var body: some View {
        Button { capture.toggle() } label: {
            HStack(spacing: 7) {
                Group {
                    if capture.isRecording {
                        ThoughtMicLevel(live: capture.recorder.live, color: Refined.ink)
                    } else {
                        ThoughtGlyph(color: Refined.ink, lineWidth: 1.4)
                    }
                }
                .frame(width: 14, height: 14)
                Text(capture.isRecording ? "Stop" : "New thought")
                Text(Thoughts.hotkey).refinedFont(.caption).foregroundStyle(Refined.mute).accessibilityHidden(true)
            }
        }
        .buttonStyle(RefinedActionStyle())
        .fixedSize()
        .help("New thought (\(Thoughts.hotkey))")
        .accessibilityLabel(capture.isRecording ? "Stop the thought" : "New thought")
        .accessibilityHint(capture.isRecording ? "Stops the thought and adds it to today's page." : "Records a thought for today's page (\(Keycap.spoken(Thoughts.hotkey))).")
    }
}

// MARK: - Calendar

/// A month calendar on a card: the days with entries carry a dot in the kind's color; the selected day takes the
/// persimmon tint with accent text, and today a ring. Click a day to read its page.
struct DayCalendar: View {
    @Binding var month: Date
    var selected: Date
    var today: Date
    var marked: Set<Date>
    var hue: RefinedHue = .butter
    var pick: (Date) -> Void

    var body: some View {
        let grid = DayPages.monthGrid(month)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(DayPages.monthTitle(month)).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                arrow(back: true) { month = DayPages.month(month, moved: -1) }
                arrow(back: false) { month = DayPages.month(month, moved: 1) }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(Array(DayPages.weekdayLetters().enumerated()), id: \.offset) { _, l in
                    Text(l).refinedFont(.caption, weight: .medium).foregroundStyle(Refined.mute)
                        .frame(height: 18)
                }
                ForEach(grid, id: \.day) { cell in
                    dayCell(cell.day, inMonth: cell.inMonth)
                }
            }
        }
        .padding(14)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .uiTarget("byday-calendar")
    }

    private func dayCell(_ d: Date, inMonth: Bool) -> some View {
        let isSelected = d == selected
        let isToday = d == today
        let dot = marked.contains(d)
        return VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: d))").refinedFont(.rowTitle, weight: isSelected ? .semibold : .regular).monospacedDigit()
                .foregroundStyle(isSelected ? Refined.accentText : (inMonth ? Refined.ink : Refined.faint))
            Circle().fill(Refined.badge(hue)).frame(width: 5, height: 5).opacity(dot ? 1 : 0)
        }
        .frame(maxWidth: .infinity).frame(height: 34)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if isSelected { shape.fill(Refined.persimmonTint) }
            else if isToday { shape.strokeBorder(Refined.separator, lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
        .tapArea { pick(d); if !inMonth { month = d } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DayPages.dateTitle(d))\(isToday ? ", today" : "")\(dot ? ", has entries" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .uiTarget(dot && inMonth ? "byday-dot-\(Calendar.current.component(.day, from: d))" : "byday-day-\(Calendar.current.component(.day, from: d))")
    }

    private func arrow(back: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: back ? "chevron.left" : "chevron.right").font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(Refined.ink)
            .frame(width: 26, height: 26)
            .background(Refined.neutral, in: Circle())
            .contentShape(Circle())
            .tapArea(action)
            .accessibilityLabel(back ? "Month before" : "Month after")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The page

/// The selected day's page on a card: the day, the serif dated title, what's on it, the day's actions, and its entries.
struct DayPageCard: View {
    @EnvironmentObject var app: AppState
    var kind: RecordingKind
    var day: Date
    var today: Date
    var items: [Transcript]

    private var isThoughts: Bool { kind != .journal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(day == today ? "Today · \(DayPages.eyebrowDay(day))" : DayPages.eyebrowDay(day)).refinedFont(.meta).foregroundStyle(Refined.mute)
                Spacer(minLength: 8)
                if isThoughts {
                    Button { ThoughtPadController.shared.open() } label: {
                        Text("Open as pad").refinedFont(.hint).foregroundStyle(Refined.accentText)
                    }
                    .buttonStyle(.plain)
                    .help("Opens this day as the floating page.")
                    .uiTarget("byday-open-pad")
                }
            }
            Text(DayPages.title(Thoughts.pageName(kind), day: day)).refinedFont(.transcriptTitle).foregroundStyle(Refined.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
            Text(meta).refinedFont(.meta).foregroundStyle(Refined.mute).padding(.top, 4)
            if isThoughts { actions.padding(.top, 14) }
            if items.isEmpty {
                ThoughtEmptyPage(isToday: day == today, play: false).padding(.top, 16).padding(.horizontal, -18)
            } else {
                // Thoughts with nothing heard fold into one row at the foot ("6 empty thoughts · Delete").
                let empties = isThoughts ? items.filter(ThoughtText.isEmpty) : []
                let shown = isThoughts ? items.filter { !ThoughtText.isEmpty($0) } : items
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { PaperDivider(leading: 0) }
                        if isThoughts { ThoughtLine(transcript: t) } else { JournalLine(transcript: t) }
                    }
                    if !empties.isEmpty {
                        if !shown.isEmpty { PaperDivider(leading: 0) }
                        emptyRow(empties)
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(22)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .uiTarget("byday-page")
    }

    /// "6 thoughts from your Mac and iPhone · Updated 11:03 AM", or "3 entries · 13:47 in all".
    private var meta: String {
        if !isThoughts {
            let total = items.reduce(0) { $0 + $1.duration }
            return "\(DayPages.count(items.count, "entry", "entries")) · \(total.timecode) in all"
        }
        let places = Set(items.map(Thoughts.origin)).sorted { $0 == "Mac" && $1 != "Mac" }
        let from = places.isEmpty ? "" : " from your " + places.joined(separator: " and ")
        let updated = items.map(\.createdAt).max().map { " · Updated \(Formats.style(date: .none, time: .short).string(from: $0))" } ?? ""
        return DayPages.count(items.count, "thought", "thoughts") + from + updated
    }

    private var text: String { Thoughts.joined(items.filter { !ThoughtText.isEmpty($0) }) }

    /// "6 empty thoughts · Delete": thoughts where nothing was heard, in one row. Delete moves them to Recently Deleted.
    private func emptyRow(_ empties: [Transcript]) -> some View {
        HStack(spacing: 10) {
            Text(DayPages.count(empties.count, "empty thought", "empty thoughts")).refinedFont(.rowTitle).foregroundStyle(Refined.dim)
            Text("·").foregroundStyle(Refined.mute).accessibilityHidden(true)
            Button("Delete") {
                for t in empties { app.store.moveToTrash(t.id) }
                app.toast = Toast("Moved \(DayPages.count(empties.count, "empty thought", "empty thoughts")) to Recently Deleted")
            }
            .buttonStyle(.plain).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.accentText)
            .accessibilityLabel("Delete \(DayPages.count(empties.count, "empty thought", "empty thoughts"))")
            .uiTarget("byday-empty-delete")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .uiTarget("byday-empty-row")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { Paster.copy(text); app.toast = Toast("Copied the day's thoughts") } label: {
                HStack(spacing: 6) { IconGlyph(art: .iconCopy, size: 14, color: Refined.ink); Text("Copy") }
            }
            .buttonStyle(RefinedActionStyle()).disabled(items.isEmpty)
            .uiTarget("byday-copy")
            ShareLink(item: text) { Text("Send to…") }.buttonStyle(RefinedActionStyle()).disabled(items.isEmpty)
            Button { DayExport.save(items, kind: kind, day: day) } label: {
                HStack(spacing: 6) { IconGlyph(art: .iconExport, size: 14, color: Refined.ink); Text("Export") }
            }
            .buttonStyle(RefinedActionStyle()).disabled(items.isEmpty)
        }
    }
}

/// One thought on a day's page: its time, its words, and where it came from. Click to open it.
private struct ThoughtLine: View {
    @EnvironmentObject var app: AppState
    let transcript: Transcript

    var body: some View {
        let t = transcript
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            PaperRowButton(action: { app.go(.transcript(t.id)) }) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(Thoughts.time(t.createdAt, systemFormat: true)).refinedFont(.meta).monospacedDigit()
                        .foregroundStyle(Refined.mute).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        words(t)
                        Text(Thoughts.origin(t)).refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 12)
            }
            if t.status == .failed {
                Button("Transcribe again") { app.retry(t) }.buttonStyle(RefinedActionStyle()).padding(.trailing, 8)
            }
        }
        .contextMenu {
            Button("Open") { app.go(.transcript(t.id)) }
            Button("Copy") { Paster.copy(Thoughts.words(t)) }
            Divider()
            Button("Delete", role: .destructive) { app.store.moveToTrash(t.id) }
        }
    }

    @ViewBuilder private func words(_ t: Transcript) -> some View {
        switch t.status {
        case .processing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Saved as audio. Transcribing…") }
                .refinedFont(.body).foregroundStyle(Refined.dim)
        case .failed:
            HStack(spacing: 6) {
                BrandGlyph(art: .iconAttention, color: Refined.ink, minLineWidth: 1.2).frame(width: 13, height: 13)
                Text("Couldn't transcribe it. The audio is kept.")
            }
            .refinedFont(.body).foregroundStyle(Refined.ink)
        case .ready:
            let w = Thoughts.words(t)
            Text(w.isEmpty ? "Nothing heard" : w).refinedFont(.body).foregroundStyle(w.isEmpty ? Refined.mute : Refined.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One journal entry on its page: the time, the title, a play button with the length, and the first cleaned line.
private struct JournalLine: View {
    @EnvironmentObject var app: AppState
    let transcript: Transcript

    var body: some View {
        let t = transcript
        let playable = t.audioFileName != nil && t.status == .ready
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            PaperRowButton(action: { app.go(.transcript(t.id)) }) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(Thoughts.time(t.createdAt, systemFormat: true)).refinedFont(.meta).monospacedDigit()
                        .foregroundStyle(Refined.mute).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                        Text(TranscriptPreview.text(t)).refinedFont(.meta).foregroundStyle(Refined.dim).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 12)
            }
            if playable {
                Button { WindowNav.shared.play(t, app: app) } label: {
                    HStack(spacing: 5) {
                        IconGlyph(art: .iconPlay, size: 10, color: Refined.ink)
                        Text(HomeRecentStyle.length(t.duration)).monospacedDigit()
                    }
                }
                .buttonStyle(RefinedActionStyle())
                .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
                .padding(.trailing, 8)
            }
        }
    }
}

/// The first lines of what was said, filler left out, remembered per transcript until its words change (lists ask on
/// every render): Journal's entries on Home and By day.
@MainActor
enum TranscriptPreview {
    private struct Key: Hashable { var id: UUID; var segments: Int; var chars: Int; var cleaned: Bool }
    private static var cache: [Key: String] = [:]

    static func text(_ t: Transcript) -> String {
        guard t.status == .ready else { return "" }
        let key = Key(id: t.id, segments: t.segments.count, chars: t.segments.reduce(0) { $0 + $1.text.utf8.count }, cleaned: t.document != nil)
        if let hit = cache[key] { return hit }
        let text = JournalDays.preview(t)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = text
        return text
    }
}

/// Export: the day's page as a Markdown file you save where you like.
@MainActor
enum DayExport {
    static func markdown(_ items: [Transcript], kind: RecordingKind, day: Date) -> String {
        var out = "# \(DayPages.title(Thoughts.pageName(kind), day: day))\n"
        for t in items {
            let time = Thoughts.time(t.createdAt, systemFormat: true)
            if kind == .journal {
                out += "\n## \(time) · \(t.title)\n\n\(Thoughts.words(t))\n"
            } else {
                out += "\n**\(time)** \(Thoughts.words(t))\n"
            }
        }
        return out
    }

    static func save(_ items: [Transcript], kind: RecordingKind, day: Date) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DayPages.title(Thoughts.pageName(kind), day: day).replacingOccurrences(of: ",", with: "") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(items, kind: kind, day: day).write(to: url, atomically: true, encoding: .utf8)
    }
}
