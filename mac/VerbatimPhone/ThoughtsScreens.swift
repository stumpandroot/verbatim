import SwiftUI
import UIKit

// The iPhone's Thoughts and Journal pages (approved mockup "Thoughts", section 07; DESIGN.md §13 and §14), one refined
// design:
//
// - A day's page (`DayPageScreen`): the large serif title with the day and its count over it, the day arrows (the
//   nearest earlier page with something on it, and the nearest later one; Next is off on today), Copy for the whole
//   day, and the calendar (By day) in the navigation bar. The entries sit in one card, each with its time. Tap a
//   thought to edit it; touch and hold to copy, open, or delete it. Today's Thoughts page has a floating New thought
//   button, the record action in persimmon. An empty page shows the empty-day drawing, which plays once the first time
//   a day's page is empty and stays still with Limit animation or Reduce Motion. Journal's entries are recordings: a
//   title, the length, and the first line; tap one to open it.
// - By day (`ByDayScreen`): Library › By day, with a Thoughts and Journal switch, a month calendar on a card with a
//   dot in the kind's color on each day that has something, and the month's days in a card. Tap a day to open its page.

extension Notification.Name {
    /// Moves the day's page on screen to the previous (`"previous"`) or next (`"next"`) page, as the arrows do (the
    /// self-test), or a Thoughts page back to today (`"today"`, when the Thoughts tab opens on today).
    static let verbatimDayPageMove = Notification.Name("verbatimDayPageMove")
}

// MARK: - A day's page

struct DayPageScreen: View {
    @EnvironmentObject var app: PhoneState
    let kind: RecordingKind
    @State private var day: Date
    @State private var editing: Transcript?
    /// The empty-day drawing plays once per day, the first time that day's page is empty.
    @State private var playEmpty = false

    /// For the self-test: the page on screen, its day, and its entries' IDs in order.
    static var shown: (kind: RecordingKind, day: Date, ids: [UUID])?

    init(kind: RecordingKind = .idea, day: Date) {
        self.kind = kind
        _day = State(initialValue: Calendar.current.startOfDay(for: day))
    }

    private var hour: Int { app.newPageHour }
    private var today: Date { app.todayPage }
    private var isToday: Bool { day == today }
    private var thoughts: Bool { kind == .idea }
    private var items: [Transcript] { app.store.page(kind, day: day, hour: hour) }
    private var name: String { kind == .journal ? "Journal" : "Thoughts" }
    private var neighbors: (previous: Date?, next: Date?) {
        ThoughtRules.neighbors(pages: app.store.dayPages(kind, hour: hour).map(\.day), current: day, today: today)
    }

    var body: some View {
        let items = self.items
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeSerifTitle(title: name, eyebrow: eyebrow(items.count))
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                dayArrows
                    .padding(.top, 14)
                // Organize today's thoughts: Plan my day over the page (PhonePlanViews.swift).
                if thoughts, !items.isEmpty {
                    ThoughtsOrganizeRow(day: day, isToday: isToday, thoughts: items).padding(.top, 14)
                }
                if items.isEmpty {
                    empty.padding(.top, 20)
                } else {
                    PaperCard {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { PaperDivider(leading: 16) }
                            entry(t)
                        }
                    }
                    .padding(.top, 14)
                }
                // Room for the New thought button over the last thought.
                Color.clear.frame(height: thoughts && isToday ? 96 : 32).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
        }
        .overlay(alignment: .bottom) {
            if thoughts && isToday { newThoughtButton.padding(.bottom, 14) }
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle(DayPages.title(name, day: day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The serif title sits on the page; the bar keeps only Apple's buttons.
            ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ByDayRoute(kind: kind)) {
                    Image(systemName: "calendar")   // brand: system surface (toolbar)
                }
                .accessibilityLabel("By day")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { copyPage(items) } label: {
                    Image(systemName: "doc.on.doc")   // brand: system surface (toolbar)
                }
                .disabled(ThoughtText.joined(items).isEmpty)
                .accessibilityLabel("Copy the day")
            }
        }
        .sheet(item: $editing) { t in ThoughtEditSheet(transcript: t).environmentObject(app) }
        .onAppear { note(items) }
        .onChange(of: items.map(\.id)) { _, _ in note(self.items) }
        .onChange(of: day) { _, _ in note(self.items) }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimDayPageMove)) { n in
            let what = n.object as? String
            if what == "today" { if thoughts { move(today) }; return }
            let to = neighbors
            move(what == "previous" ? to.previous : to.next)
        }
        .onDisappear {
            if Self.shown?.day == day { Self.shown = nil }
            app.lastThought = nil
        }
    }

    /// "Today · Mon Oct 26 · 3 thoughts", over the title.
    private func eyebrow(_ count: Int) -> String {
        thoughts ? ThoughtRules.eyebrow(dayLabel: DayPages.eyebrowDay(day), isToday: isToday, count: count)
                 : "\(isToday ? "Today" : DayPages.eyebrowDay(day)) · \(DayPages.count(count, "entry", "entries"))"
    }

    private func note(_ items: [Transcript]) {
        Self.shown = (kind, day, items.map(\.id))
        if items.isEmpty && !playEmpty { playEmpty = EmptyDayArt.shouldPlay(day: day) }
    }

    private func copyPage(_ items: [Transcript]) {
        UIPasteboard.general.string = ThoughtText.joined(items)
        app.say("Copied \(DayPages.title(name, day: day))")
        Haptics.play(.copied)
    }

    private func move(_ to: Date?) {
        guard let to else { return }
        withAnimation(nil) { day = to }
    }

    // MARK: Pieces

    /// The day arrows: quiet actions, the earlier page's date on the left and the later one's on the right.
    private var dayArrows: some View {
        let n = neighbors
        return HStack(spacing: 10) {
            Button { move(n.previous) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(n.previous.map { DayPages.dateTitle($0) } ?? "Earlier")
                }
            }
            .disabled(n.previous == nil)
            .accessibilityLabel(n.previous.map { "Previous page, \(DayPages.dateTitle($0))" } ?? "No earlier page")
            Spacer(minLength: 8)
            Button { move(n.next) } label: {
                HStack(spacing: 6) {
                    Text(n.next.map { $0 == today ? "Today" : DayPages.dateTitle($0) } ?? "Next")
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
            }
            .disabled(n.next == nil)
            .accessibilityLabel(n.next.map { "Next page, \(DayPages.dateTitle($0))" } ?? "Next, off on today")
        }
        .buttonStyle(RefinedActionStyle(kind: .quiet))
    }

    /// An entry in the day's card: its time in `mute`, the words (or the Journal entry's title and first line), and
    /// where it came from. The thought you just added takes the persimmon tint.
    private func entry(_ t: Transcript) -> some View {
        let fresh = t.id == app.lastThought
        return PaperRowButton(selected: fresh, action: { tap(t) }) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(ThoughtText.compactTime(t.createdAt)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                    .lineLimit(1).fixedSize().frame(minWidth: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    if thoughts { ThoughtWords(transcript: t) } else { JournalLine(transcript: t) }
                    Text(thoughts ? ThoughtText.origin(t) : HomeRecentStyle.length(t.duration))
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
        }
        .contextMenu { menu(t) }
        .accessibilityHint(thoughts ? "Edits the thought" : "Opens the entry")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            EmptyDayArt(play: playEmpty)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
            Text(thoughts && isToday ? ThoughtRules.emptyToday : ThoughtRules.emptyPage)
                .refinedFont(.body).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The floating New thought button: the record action, so it carries persimmon (§14.1), opaque on the page with
    /// the fixed ink on it. While a thought records, it brings the recorder back.
    private var newThoughtButton: some View {
        Button { app.requestThought() } label: {
            HStack(spacing: 8) {
                ThoughtGlyph(level: app.recordingThought ? 0.6 : nil, color: Refined.onFill, lineWidth: 1.5).frame(width: 22, height: 22)
                Text(app.recordingThought ? "Recording a thought" : "New thought")
                    .refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.onFill)
            }
            .padding(.horizontal, 22).frame(minHeight: 50)
            .background(Capsule().fill(Refined.persimmon))
            .contentShape(Capsule())
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(app.recordingThought ? "Recording a thought. Open the recorder" : "New thought")
        .accessibilityHint("Starts recording a thought for today's page")
        .accessibilityIdentifier("thoughts.new")
    }

    // MARK: Actions

    private func tap(_ t: Transcript) {
        if !thoughts { app.open(t.id); return }
        // A thought still transcribing has nothing to edit yet; a failed one offers Transcribe again in its row.
        guard t.status == .ready else { return }
        editing = t
    }

    @ViewBuilder private func menu(_ t: Transcript) -> some View {
        let words = ThoughtText.words(t)
        if !words.isEmpty {
            Button { UIPasteboard.general.string = words; app.say("Copied"); Haptics.play(.copied) } label: { Label("Copy", art: .iconCopy) }
        }
        if thoughts, t.status == .ready {
            Button { editing = t } label: { Label("Edit", art: .iconNotes) }
        }
        Button { app.open(t.id) } label: { Label(thoughts ? "Open as a transcript" : "Open", art: .iconDetails) }
        Button(role: .destructive) { app.delete([t.id]) } label: { Label("Move to Recently Deleted", art: .iconDeleted) }
    }
}

/// A thought's words, or where it is: "Saved as audio. Transcribing…" until the words are ready, and the failure
/// with Transcribe again (the audio is kept either way).
private struct ThoughtWords: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript

    var body: some View {
        let t = transcript
        switch t.status {
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ThoughtRules.transcribing).refinedFont(.body).foregroundStyle(Refined.dim)
            }
            .accessibilityElement(children: .combine)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(ThoughtRules.failed).refinedFont(.body).foregroundStyle(Refined.dim)
                Button(ThoughtRules.transcribeAgain) { app.retry(t) }
                    .refinedFont(.hint, weight: .semibold)
                    .foregroundStyle(Refined.accentText)
                    .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                    .buttonStyle(.plain)
            }
        default:
            let w = ThoughtText.words(t)
            Text(w.isEmpty ? "No words heard. The audio is saved." : w)
                .refinedFont(.body).foregroundStyle(w.isEmpty ? Refined.dim : Refined.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Journal entry on its page: the title in semibold and the first line.
private struct JournalLine: View {
    var transcript: Transcript
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(transcript.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(2)
            let first = ThoughtText.words(transcript)
            if !first.isEmpty {
                Text(first).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

// MARK: - Editing a thought

/// Tap a thought to edit it: your words go in the edited layer, so what was heard stays (Transcribe again goes back to
/// what's heard). Delete moves it to Recently Deleted.
private struct ThoughtEditSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    let transcript: Transcript
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(DayPages.title("Thoughts", day: DayPages.pageDay(for: transcript.createdAt, hour: app.newPageHour))) · \(ThoughtText.time(transcript.createdAt, systemFormat: true))")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                TextEditor(text: $text)
                    .refinedFont(.reading)
                    .foregroundStyle(Refined.ink)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Thought")
            }
            .padding(20)
            .background(Refined.paper.ignoresSafeArea())
            .navigationTitle("Edit thought")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.editThought(transcript.id, to: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Move to Recently Deleted", role: .destructive) {
                        app.delete([transcript.id])
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            text = ThoughtText.words(transcript)
            focused = true
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - By day

/// Library › By day: Thoughts or Journal, a month calendar with a dot on each day that has something, and that
/// month's days, newest first. Tap a day to open its page.
struct ByDayScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var kind: RecordingKind
    @State private var month = Date()

    /// For the self-test: the kind on screen and the days with dots in the month shown.
    static var shown: (kind: RecordingKind, dots: Int)?

    /// A tab's root for one kind (the Journal tab): no Thoughts and Journal switch, so the tab never turns into the
    /// other kind's view. Reached from Library, By day keeps the switch.
    private let fixed: Bool

    init(kind: RecordingKind, fixed: Bool = false) {
        _kind = State(initialValue: kind == .journal ? .journal : .idea)
        self.fixed = fixed
    }

    private var hour: Int { app.newPageHour }
    private var pages: [(day: Date, items: [Transcript])] { app.store.dayPages(kind, hour: hour) }
    private var name: String { kind == .journal ? "Journal" : "Thoughts" }

    private func inMonth(_ pages: [(day: Date, items: [Transcript])]) -> [(day: Date, items: [Transcript])] {
        pages.filter { Calendar.current.isDate($0.day, equalTo: month, toGranularity: .month) }
    }

    var body: some View {
        let pages = self.pages
        let days = inMonth(pages)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeSerifTitle(title: name, eyebrow: "By day", count: DayPages.count(pages.count, "day", "days"))
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                if !fixed {
                    RefinedSegmented(label: "Kind", options: [(RecordingKind.idea, "Thoughts"), (RecordingKind.journal, "Journal")], selection: $kind)
                        .padding(.top, 14)
                }
                PhoneMonthCalendar(month: $month, days: Set(pages.map(\.day)), today: app.todayPage, hue: kind.refinedHue, pick: open)
                    .padding(.top, 16)
                PaperGroup("This month · \(DayPages.count(days.count, "day", "days"))") {
                    if days.isEmpty {
                        Text(kind == .journal ? "No journal entries this month." : "No thoughts this month.")
                            .refinedFont(.body).foregroundStyle(Refined.dim)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(days.enumerated()), id: \.element.day) { i, p in
                        if i > 0 { PaperDivider(leading: 16) }
                        dayRow(p)
                    }
                }
                .padding(.top, 20)
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 20)
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("By day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .onAppear { note(pages) }
        .onChange(of: kind) { _, _ in note(self.pages) }
        .onChange(of: month) { _, _ in note(self.pages) }
        .onDisappear { if Self.shown?.kind == kind { Self.shown = nil } }
    }

    private func note(_ pages: [(day: Date, items: [Transcript])]) {
        Self.shown = (kind, inMonth(pages).count)
        Self.switchShown = !fixed
    }

    /// For the self-test: whether the screen on view shows the Thoughts and Journal switch.
    static var switchShown: Bool?

    private func open(_ day: Date) { app.pushHere(DayPageRoute(kind: kind, day: day)) }

    private func preview(_ items: [Transcript]) -> String {
        if kind == .journal { return items.first?.title ?? "" }
        return items.map(ThoughtText.words).first { !$0.isEmpty } ?? (items.isEmpty ? "" : ThoughtRules.transcribing)
    }

    /// A day in the month's card: "Today, Mon, Oct 26" or "Sat, Oct 24", the first words, and the count.
    private func dayRow(_ p: (day: Date, items: [Transcript])) -> some View {
        PaperRowButton(action: { open(p.day) }) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.day == app.todayPage ? "Today, \(DayPages.dateTitle(p.day))" : DayPages.dateTitle(p.day))
                        .refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(preview(p.items)).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(p.items.count)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.faint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10).padding(.horizontal, 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DayPages.dateTitle(p.day)), \(DayPages.count(p.items.count, kind == .journal ? "entry" : "thought", kind == .journal ? "entries" : "thoughts"))")
        .accessibilityAddTraits(.isButton)
    }
}

/// The month calendar on a card: the month in the section title's serif, previous and next, the weekday letters, a
/// dot in the kind's color on each day with something (a day with a dot opens its page), and today ringed.
private struct PhoneMonthCalendar: View {
    @Binding var month: Date
    var days: Set<Date>
    var today: Date
    var hue: RefinedHue
    var pick: (Date) -> Void
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let grid = DayPages.monthGrid(month)
        let thisMonth = Calendar.current.isDate(month, equalTo: today, toGranularity: .month)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(DayPages.monthTitle(month)).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                arrow(back: true) { month = DayPages.month(month, moved: -1) }
                arrow(back: false) { month = DayPages.month(month, moved: 1) }
                    .disabled(thisMonth)
                    .opacity(thisMonth ? 0.35 : 1)
            }
            LazyVGrid(columns: Self.columns, spacing: 2) {
                ForEach(Array(DayPages.weekdayLetters().enumerated()), id: \.offset) { _, l in
                    Text(l).refinedFont(.caption, weight: .medium).foregroundStyle(Refined.mute).accessibilityHidden(true)
                }
                ForEach(grid, id: \.day) { cell in dayCell(cell.day, inMonth: cell.inMonth) }
            }
        }
        .padding(14)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    private func arrow(back: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: back ? "chevron.left" : "chevron.right").font(.system(size: 13, weight: .bold))
                .foregroundStyle(Refined.ink)
                .frame(width: 32, height: 32)
                .background(Refined.neutral, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(back ? "Previous month" : "Next month")
    }

    @ViewBuilder private func dayCell(_ d: Date, inMonth: Bool) -> some View {
        let has = days.contains(d)
        let isToday = d == today
        let cell = VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: d))")
                .refinedFont(.rowTitle, weight: isToday ? .semibold : .regular).monospacedDigit()
                .foregroundStyle(isToday ? Refined.accentText : (inMonth ? Refined.ink : Refined.faint))
            Circle().fill(Refined.badge(hue)).frame(width: 6, height: 6).opacity(has && inMonth ? 1 : 0)
        }
        .frame(maxWidth: .infinity).frame(minHeight: 44)
        .background { if isToday { Circle().fill(Refined.persimmonTint).frame(width: 40, height: 40) } }
        if has && inMonth {
            Button { pick(d) } label: { cell.contentShape(Rectangle()) }
                .buttonStyle(RefinedRowPress())
                .accessibilityLabel("\(DayPages.dateTitle(d))\(isToday ? ", today" : ""), has entries")
                .accessibilityHint("Opens that day's page")
        } else {
            cell
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(DayPages.dateTitle(d))\(isToday ? ", today" : "")")
                .accessibilityHidden(!inMonth)
        }
    }
}

// MARK: - Pieces

/// Serif text with an italic last part ("Plan · *Mon, Oct 26*"), in the refined serif, scaled with Dynamic Type.
struct SerifTitle: View {
    var plain: String
    var italic: String?
    var size: CGFloat
    @ScaledMetric private var scale: CGFloat = 1

    init(_ plain: String, italic: String? = nil, size: CGFloat) {
        self.plain = plain
        self.italic = italic
        self.size = size
    }

    var body: some View {
        let font = Font.system(size: size * scale, design: .serif)
        if let italic, !italic.isEmpty {
            let lead = plain.isEmpty ? "" : plain + " "
            (Text(lead) + Text(italic).italic()).font(font)
        } else {
            Text(plain).font(font)
        }
    }
}
