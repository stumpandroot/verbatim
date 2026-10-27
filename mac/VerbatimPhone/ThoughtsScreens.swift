import SwiftUI
import UIKit

// The iPhone's Thoughts and Journal pages (approved mockup "Thoughts", section 07; DESIGN.md §14), in both looks:
//
// - A day's page (`DayPageScreen`): the dated title, a time on every entry, the day arrows (the nearest earlier page
//   with something on it, and the nearest later one; Next is off on today), Copy for the whole day, and the calendar
//   (By day). Tap a thought to edit it; touch and hold to copy, open, or delete it. Today's Thoughts page has a
//   floating New thought button (Verbose) or the record button (Premium Native). An empty page shows the empty-day
//   drawing, which plays once the first time a day's page is empty and stays still with Limit animation or Reduce
//   Motion. Journal's entries are recordings: a title, the length, and the first line; tap one to open it.
// - By day (`ByDayScreen`): Library › By day, with a Thoughts and Journal switch, a month calendar with a dot on each
//   day that has something, and the month's days. Tap a day to open its page.

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
    @Environment(\.look) private var look

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
        Group {
            if look.isNative { native(items) } else { verbose(items) }
        }
        .phoneTopFade()
        .phonePage()
        .navigationTitle(look.isNative ? name : DayPages.title(name, day: day))
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .toolbar {
            if !look.isNative { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ByDayRoute(kind: kind)) { calendarGlyph }
                    .accessibilityLabel("By day")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { copyPage(items) } label: { copyGlyph }
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

    private func note(_ items: [Transcript]) {
        Self.shown = (kind, day, items.map(\.id))
        if items.isEmpty && !playEmpty { playEmpty = EmptyDayArt.shouldPlay(day: day) }
    }

    private func copyPage(_ items: [Transcript]) {
        UIPasteboard.general.string = ThoughtText.joined(items)
        app.say("Copied \(DayPages.title(name, day: day))")
    }

    private func move(_ to: Date?) {
        guard let to else { return }
        withAnimation(nil) { day = to }
    }

    // MARK: Verbose

    private func verbose(_ items: [Transcript]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Overline(text: thoughts ? ThoughtRules.eyebrow(dayLabel: DayPages.eyebrowDay(day), isToday: isToday, count: items.count)
                                        : "\(isToday ? "Today" : DayPages.eyebrowDay(day)) · \(DayPages.count(items.count, "entry", "entries"))")
                    .padding(.top, 8)
                SerifTitle("\(name) ·", italic: DayPages.dateTitle(day), size: 30)
                    .foregroundStyle(.lookInk)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                dayArrows
                    .padding(.top, 14)
                if items.isEmpty {
                    empty.padding(.top, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { t in
                            entry(t)
                            Rectangle().fill(.lookHairline).frame(height: 1)
                        }
                    }
                    .padding(.top, 10)
                }
                // Room for the New thought button over the last thought.
                Color.clear.frame(height: 96).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
        }
        .overlay(alignment: .bottom) {
            if thoughts && isToday { newThoughtButton.padding(.bottom, 14) }
        }
    }

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
        .buttonStyle(DayPillStyle())
    }

    @ViewBuilder private func entry(_ t: Transcript) -> some View {
        let outlined = t.id == app.lastThought
        Button { tap(t) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(ThoughtText.time(t.createdAt, native: false)).font(Ink.mono(13)).foregroundStyle(.lookMute)
                    .frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    if thoughts { ThoughtWords(transcript: t, native: false) } else { JournalLine(transcript: t, native: false) }
                    Text(thoughts ? ThoughtText.origin(t) : HomeRecentStyle.length(t.duration))
                        .font(.system(size: 12.5)).foregroundStyle(.lookMute)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12).padding(.horizontal, outlined ? 10 : 0)
            .overlay {
                if outlined { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPress())
        .contextMenu { menu(t) }
        .accessibilityHint(thoughts ? "Edits the thought" : "Opens the entry")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            EmptyDayArt(play: playEmpty)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
            Text(thoughts && isToday ? ThoughtRules.emptyToday : ThoughtRules.emptyPage)
                .font(.system(size: 15)).foregroundStyle(.lookDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The floating New thought button: the record action, so it may carry persimmon (§14.1). While a thought
    /// records, it brings the recorder back.
    private var newThoughtButton: some View {
        Button { app.requestThought() } label: {
            HStack(spacing: 8) {
                ThoughtGlyph(level: app.recordingThought ? 0.6 : nil, color: Ink.inkFixed, lineWidth: 1.5).frame(width: 22, height: 22)
                Text(app.recordingThought ? "Recording a thought" : "New thought").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.inkFixed)
            }
            .padding(.horizontal, 20).frame(height: 50)
            .background(Capsule().fill(Ink.persimmonFixed))
            .overlay(Capsule().strokeBorder(Ink.inkFixed, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(app.recordingThought ? "Recording a thought. Open the recorder" : "New thought")
        .accessibilityHint("Starts recording a thought for today's page")
        .accessibilityIdentifier("thoughts.new")
    }

    // MARK: Premium Native
    // brand: native begin

    private func native(_ items: [Transcript]) -> some View {
        let n = neighbors
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(Formats.style(date: .full, time: .none).string(from: day)) · \(DayPages.count(items.count, thoughts ? "thought" : "entry", thoughts ? "thoughts" : "entries"))")
                    .font(.subheadline).foregroundStyle(NativeInk.secondary)
                HStack {
                    Button { move(n.previous) } label: {
                        Label(n.previous.map { DayPages.dateTitle($0) } ?? "Earlier", systemImage: "chevron.left")
                    }
                    .disabled(n.previous == nil)
                    Spacer()
                    Button { move(n.next) } label: {
                        HStack(spacing: 4) {
                            Text(n.next.map { $0 == today ? "Today" : DayPages.dateTitle($0) } ?? "Next")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .disabled(n.next == nil)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NativeInk.accent)
                .buttonStyle(.plain)
                if items.isEmpty {
                    VStack(spacing: 12) {
                        EmptyDayArt(play: playEmpty).frame(height: 200)
                        Text(thoughts && isToday ? "Nothing on today's page yet. Tap the record button and start talking." : ThoughtRules.emptyPage)
                            .font(.subheadline).foregroundStyle(NativeInk.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 20)
                } else {
                    ForEach(items) { t in nativeCard(t) }
                }
                // Room for the record button over the last thought: its 86 pt plus 16 (review P-13).
                Color.clear.frame(height: 104).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
        }
        .overlay(alignment: .bottomTrailing) {
            if thoughts && isToday && !app.recordingActive { ThoughtRecordFAB().padding(.trailing, 18).padding(.bottom, 12) }
        }
    }

    private func nativeCard(_ t: Transcript) -> some View {
        Button { tap(t) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ThoughtText.time(t.createdAt, native: true)) · \(thoughts ? ThoughtText.origin(t) : HomeRecentStyle.length(t.duration))")
                    .font(.footnote).foregroundStyle(NativeInk.secondary)
                if thoughts { ThoughtWords(transcript: t, native: true) } else { JournalLine(transcript: t, native: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .premiumSoftCard(radius: 18)
            .overlay {
                if t.id == app.lastThought { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(NativeInk.accent, lineWidth: 1.5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .contextMenu { menu(t) }
        .accessibilityHint(thoughts ? "Edits the thought" : "Opens the entry")
    }

    private var calendarGlyph: some View {
        Group {
            if look.isNative { Image(systemName: "calendar") } else { IconGlyph(art: .iconCalendar, size: 20, color: Ink.ink) }
        }
    }

    private var copyGlyph: some View {
        Group {
            if look.isNative { Image(systemName: "doc.on.doc") } else { IconGlyph(art: .iconCopy, size: 20, color: Ink.ink) }
        }
    }
    // brand: native end

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
            Button { UIPasteboard.general.string = words; app.say("Copied") } label: { Label("Copy", art: .iconCopy) }
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
    var native: Bool

    var body: some View {
        let t = transcript
        switch t.status {
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ThoughtRules.transcribing).font(.system(size: 15)).foregroundStyle(native ? NativeInk.secondary : Ink.dim)
            }
            .accessibilityElement(children: .combine)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(ThoughtRules.failed).font(.system(size: 15)).foregroundStyle(native ? NativeInk.secondary : Ink.dim)
                Button(ThoughtRules.transcribeAgain) { app.retry(t) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(native ? NativeInk.accent : Ink.accentText)
                    .buttonStyle(.plain)
            }
        default:
            let w = ThoughtText.words(t)
            Text(w.isEmpty ? "No words heard. The audio is saved." : w)
                .font(.system(size: native ? 17 : 16)).foregroundStyle(w.isEmpty ? (native ? NativeInk.secondary : Ink.dim) : (native ? NativeInk.label : Ink.ink))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Journal entry on its page: the title (a serif in Verbose) and the first line.
private struct JournalLine: View {
    var transcript: Transcript
    var native: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(transcript.title).font(native ? .system(size: 17, weight: .semibold) : Ink.serif(18))
                .foregroundStyle(native ? NativeInk.label : Ink.ink).lineLimit(2)
            let first = ThoughtText.words(transcript)
            if !first.isEmpty {
                Text(first).font(.system(size: 14)).foregroundStyle(native ? NativeInk.secondary : Ink.dim).lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

/// The day arrows: outlined pills on the paper (Verbose style).
private struct DayPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(Ink.ink.opacity(configuration.isPressed ? 0.06 : 0)))
                .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.2))
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Capsule())
        }
    }
}

// brand: native begin
/// Today's page in Premium Native: the record button, starting a thought instead of a voice note.
private struct ThoughtRecordFAB: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        Button { app.requestThought() } label: {
            Circle().fill(PremiumStyle.disc)
                .frame(width: 64, height: 64)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1).padding(1).blendMode(.overlay))
                .padding(5)
                .background(PremiumStyle.ring, in: Circle())
                .shadow(color: PremiumStyle.discShadow, radius: 12, y: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New thought")
        .accessibilityHint("Starts recording a thought for today's page")
        .accessibilityIdentifier("thoughts.new")
    }
}
// brand: native end

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
                Text("\(DayPages.title("Thoughts", day: DayPages.pageDay(for: transcript.createdAt, hour: app.newPageHour))) · \(ThoughtText.time(transcript.createdAt, native: true))")
                    .font(.system(size: 13)).foregroundStyle(.lookMute)
                TextEditor(text: $text)
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Thought")
            }
            .padding(20)
            .phonePage()
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
    @Environment(\.look) private var look

    /// For the self-test: the kind on screen and the days with dots in the month shown.
    static var shown: (kind: RecordingKind, dots: Int)?

    init(kind: RecordingKind) { _kind = State(initialValue: kind == .journal ? .journal : .idea) }

    private var hour: Int { app.newPageHour }
    private var pages: [(day: Date, items: [Transcript])] { app.store.dayPages(kind, hour: hour) }
    private var name: String { kind == .journal ? "Journal" : "Thoughts" }

    private func inMonth(_ pages: [(day: Date, items: [Transcript])]) -> [(day: Date, items: [Transcript])] {
        pages.filter { Calendar.current.isDate($0.day, equalTo: month, toGranularity: .month) }
    }

    var body: some View {
        let pages = self.pages
        Group {
            if look.isNative { native(pages) } else { verbose(pages) }
        }
        .phonePage()
        .navigationTitle("By day")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .toolbar { if !look.isNative { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } } }
        .onAppear { note(pages) }
        .onChange(of: kind) { _, _ in note(self.pages) }
        .onChange(of: month) { _, _ in note(self.pages) }
        .onDisappear { if Self.shown?.kind == kind { Self.shown = nil } }
    }

    private func note(_ pages: [(day: Date, items: [Transcript])]) {
        Self.shown = (kind, inMonth(pages).count)
    }

    private func open(_ day: Date) { app.pushHere(DayPageRoute(kind: kind, day: day)) }

    /// "Today, Mon, Oct 26" or "Sat, Oct 24".
    private func dayTitle(_ day: Date) -> (String, String) {
        day == app.todayPage ? ("Today,", DayPages.dateTitle(day)) : (DayPages.listDay(day), "")
    }

    private func preview(_ items: [Transcript]) -> String {
        if kind == .journal { return items.first?.title ?? "" }
        return items.map(ThoughtText.words).first { !$0.isEmpty } ?? (items.isEmpty ? "" : ThoughtRules.transcribing)
    }

    // MARK: Verbose

    private func verbose(_ pages: [(day: Date, items: [Transcript])]) -> some View {
        let days = inMonth(pages)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Overline(text: "By day").padding(.top, 8)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(name).font(Ink.serif(30)).foregroundStyle(.lookInk)
                    Text(DayPages.count(pages.count, "day", "days")).font(Ink.mono(12)).foregroundStyle(.lookMute)
                }
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                kindSwitch.padding(.top, 14)
                VerboseMonthCalendar(month: $month, days: Set(pages.map(\.day)), today: app.todayPage, pick: open)
                    .padding(.top, 16)
                PhoneDayHeader(text: "This month · \(DayPages.count(days.count, "day", "days"))")
                ForEach(days, id: \.day) { p in
                    Button { open(p.day) } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                let title = dayTitle(p.day)
                                SerifTitle(title.0, italic: title.1.isEmpty ? nil : title.1, size: 18).foregroundStyle(.lookInk)
                                Text(preview(p.items)).font(.system(size: 14)).foregroundStyle(.lookDim).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text("\(p.items.count)").font(Ink.mono(13)).foregroundStyle(.lookMute)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRowPress())
                    .accessibilityLabel("\(DayPages.dateTitle(p.day)), \(DayPages.count(p.items.count, kind == .journal ? "entry" : "thought", kind == .journal ? "entries" : "thoughts"))")
                    Rectangle().fill(.lookHairline).frame(height: 1)
                }
                if days.isEmpty {
                    Text(kind == .journal ? "No journal entries this month." : "No thoughts this month.")
                        .font(.system(size: 15)).foregroundStyle(.lookDim).padding(.top, 12)
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 20)
        }
    }

    private var kindSwitch: some View {
        HStack(spacing: 0) {
            ForEach([RecordingKind.idea, .journal], id: \.self) { k in
                let on = k == kind
                Button { kind = k } label: {
                    Text(k == .journal ? "Journal" : "Thoughts")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Ink.paper : Ink.ink)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(Capsule().fill(on ? Ink.ink : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.2))
    }

    // MARK: Premium Native
    // brand: native begin

    private func native(_ pages: [(day: Date, items: [Transcript])]) -> some View {
        let days = inMonth(pages)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(DayPages.count(pages.count, "day", "days")) of \(kind == .journal ? "journal entries" : "thoughts")")
                    .font(.subheadline).foregroundStyle(NativeInk.secondary)
                Picker("Kind", selection: $kind) {
                    Text("Thoughts").tag(RecordingKind.idea)
                    Text("Journal").tag(RecordingKind.journal)
                }
                .pickerStyle(.segmented)
                PremiumMonthCalendar(month: $month, dates: pages.map(\.day), now: Date(), pick: open)
                Text("This month").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.secondary)
                    .padding(.top, 8).accessibilityAddTraits(.isHeader)
                ForEach(days, id: \.day) { p in
                    Button { open(p.day) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(p.day == app.todayPage ? "Today" : Formats.pattern("EEEE").string(from: p.day)) · \(DayPages.count(p.items.count, kind == .journal ? "entry" : "thought", kind == .journal ? "entries" : "thoughts"))")
                                .font(.system(size: 14)).foregroundStyle(NativeInk.secondary)
                            Text(Formats.style(date: .long, time: .none).string(from: p.day))
                                .font(.system(size: 18, weight: .semibold)).foregroundStyle(NativeInk.label)
                            Text(preview(p.items)).font(.system(size: 15)).foregroundStyle(NativeInk.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    NativeDivider(leading: 0)
                }
                if days.isEmpty {
                    Text(kind == .journal ? "No journal entries this month." : "No thoughts this month.")
                        .font(.subheadline).foregroundStyle(NativeInk.secondary)
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 20)
        }
    }
    // brand: native end
}

/// The month calendar in Verbose style: the month in the serif with its year in italic, previous and next, the
/// weekday letters, ink dots on days with something (a day with a dot opens its page), and today outlined.
private struct VerboseMonthCalendar: View {
    @Binding var month: Date
    var days: Set<Date>
    var today: Date
    var pick: (Date) -> Void
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let grid = DayPages.monthGrid(month)
        let title = DayPages.monthTitle(month)
        let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
        let thisMonth = Calendar.current.isDate(month, equalTo: today, toGranularity: .month)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SerifTitle(parts.first ?? title, italic: parts.count > 1 ? parts[1] : nil, size: 20).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { month = DayPages.month(month, moved: -1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel("Previous month")
                Button { month = DayPages.month(month, moved: 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .disabled(thisMonth)
                .opacity(thisMonth ? 0.35 : 1)
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.ink)
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(Array(DayPages.weekdayLetters().enumerated()), id: \.offset) { _, l in
                    Text(l).font(Ink.mono(12)).foregroundStyle(Ink.mute).accessibilityHidden(true)
                }
                ForEach(grid, id: \.day) { cell in dayCell(cell.day, inMonth: cell.inMonth) }
            }
        }
        .padding(14)
        .phoneOutlined(radius: Radius.tile, line: 1.5)
    }

    @ViewBuilder private func dayCell(_ d: Date, inMonth: Bool) -> some View {
        let has = days.contains(d)
        let isToday = d == today
        let cell = VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: d))").font(.system(size: 15, weight: isToday ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(inMonth ? Ink.ink : Ink.faint)
            Circle().fill(Ink.ink).frame(width: 5, height: 5).opacity(has && inMonth ? 1 : 0)
        }
        .frame(maxWidth: .infinity).frame(height: 40)
        .overlay { if isToday { Circle().strokeBorder(Ink.ink, lineWidth: 1.2).frame(width: 36, height: 36) } }
        if has && inMonth {
            Button { pick(d) } label: { cell.contentShape(Rectangle()) }
                .buttonStyle(.plain)
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

/// Serif text with an italic last part ("Thoughts · *Mon, Oct 26*", "Action *button*"); one upright run in Native.
struct SerifTitle: View {
    var plain: String
    var italic: String?
    var size: CGFloat
    @Environment(\.look) private var look

    init(_ plain: String, italic: String? = nil, size: CGFloat) {
        self.plain = plain
        self.italic = italic
        self.size = size
    }

    var body: some View {
        if let italic, !italic.isEmpty {
            let lead = plain.isEmpty ? "" : plain + " "
            if look.isNative {
                Text(lead + italic).lookSerif(size)
            } else {
                (Text(lead) + Text(italic).italic()).lookSerif(size)
            }
        } else {
            Text(plain).lookSerif(size)
        }
    }
}

// MARK: - Library's way in

/// Library's By day card (Verbose style): the calendar glyph, "By day", and today's thought count.
struct ByDayCard: View {
    var todayCount: Int
    var body: some View {
        HStack(spacing: 12) {
            IconGlyph(art: .iconCalendar, size: 20, color: Ink.ink).frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("By day").font(Ink.serif(19)).foregroundStyle(.lookInk)
                Text("Thoughts and Journal, a page a day").font(.system(size: 13)).foregroundStyle(.lookMute)
            }
            Spacer(minLength: 8)
            if todayCount > 0 {
                Text("Today \(todayCount)").font(Ink.mono(12)).foregroundStyle(.lookMute)
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.lookMute)
        }
        .padding(.horizontal, 14).frame(minHeight: 60)
        .phoneOutlined(radius: Radius.row, line: 1)
        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Thoughts and Journal by day")
    }
}
