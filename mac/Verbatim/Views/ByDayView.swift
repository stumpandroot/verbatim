import SwiftUI
import AppKit
import UniformTypeIdentifiers

// brand: web style
//
// Library › By day (mockup "Thoughts", section 03): Thoughts and Journal, one page a day. A month calendar marks each
// day with entries with an ink dot, a day list sits under it, and the selected day's page fills the right side.
// Thoughts adds New thought, Copy, Send to, Export, and Open as the floating pad; Journal's entries show a title, a play
// pill with the length, and the first line. Dots and selection are ink in Verbose style (persimmon stays reserved for
// recording) and the accent in Premium Native. A page is every recording of the kind that started that day
// (Model/DayPages.swift), so nothing here is stored on its own.

struct ByDayView: View {
    @EnvironmentObject var app: AppState
    var kind: RecordingKind
    @State private var selected: Date?
    /// The month the calendar shows once you've moved it; until then, the shown day's month. (Build 219 set it in
    /// `onAppear`, which rendered all of By day a second time right after it appeared: in Native, 220 to 790 ms
    /// between the screen's appear and its first frame.)
    @State private var shownMonth: Date?
    @Environment(\.look) private var look

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
        let _ = LookSwitch.mark("byday")
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: name, count: DayPages.count(pages.count, "day", "days"),
                          lede: isThoughts ? "One page per day. Pick a day to read it." : "One page per day, from your journal recordings.") {
                    if isThoughts { titleControls }
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        DayCalendar(month: Binding(get: { month }, set: { shownMonth = $0 }), selected: day, today: today, marked: Set(pages.map(\.day))) { d in selected = d }
                        dayList(pages, selected: day, month: month)
                    }
                    .frame(width: 320)
                    DayPageCard(kind: kind, day: day, today: today, items: items)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 1180, alignment: .leading)
            .scrollPlace(ScreenPlaces.scrollKey(isThoughts ? "byday-thoughts" : "byday-journal", look: look))
            .navMarkWhenLaidOut("byday-laid-out")
        }
        .background(look == .native ? AnyView(PremiumInk.window) : AnyView(Ink.paper))
        .onAppear { LookSwitch.mark("byday-appear") }
        .onChange(of: kind) { _, _ in selected = nil }
        .onChange(of: selected) { _, d in ScreenPlaces.shared.setDay(kind, day: d, month: shownMonth) }
        .onChange(of: shownMonth) { _, m in ScreenPlaces.shared.setDay(kind, day: selected, month: m) }
        .uiTarget(isThoughts ? "byday-thoughts" : "byday-journal")
    }

    @ViewBuilder private var titleControls: some View {
        HStack(spacing: 8) {
            if look == .native {
                Picker("View", selection: Binding(get: { 0 }, set: { v in if v == 1 { showAll() } })) {
                    Text("By Day").tag(0)
                    Text("All Thoughts").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            } else {
                PillButton(title: "By day", kind: .dark, size: .mini) {}
                PillButton(title: "All thoughts", kind: .line, size: .mini) { showAll() }
            }
            NewThoughtPill()
        }
    }

    /// The Library, filtered to Thoughts.
    private func showAll() {
        app.projectFilter = nil
        app.libraryFilter = .all
        app.libraryKind = kind
        app.go(.library)
    }

    /// "This month · 16 days", then each day with entries in the shown month, newest first.
    @ViewBuilder private func dayList(_ pages: [(day: Date, items: [Transcript])], selected: Date, month: Date) -> some View {
        let cal = Calendar.current
        let inMonth = pages.filter { cal.isDate($0.day, equalTo: month, toGranularity: .month) }
        let thisMonth = cal.isDate(month, equalTo: Date(), toGranularity: .month)
        VStack(alignment: .leading, spacing: 6) {
            DayHeader(text: "\(thisMonth ? "This month" : DayPages.monthTitle(month)) · \(DayPages.count(inMonth.count, "day", "days"))")
            if inMonth.isEmpty {
                Text(isThoughts ? "No thoughts this month." : "No journal entries this month.")
                    .font(.system(size: 13)).foregroundStyle(look == .native ? Color.secondary : Ink.mute).padding(.vertical, 6)
            }
            ForEach(inMonth, id: \.day) { p in
                FlatRowButton(selected: p.day == selected, action: { self.selected = p.day }) { _ in
                    HStack(spacing: 12) {
                        Text(DayPages.listDay(p.day)).font(look == .native ? .system(size: 12.5).monospacedDigit() : Ink.mono(12.5))
                            .foregroundStyle(look == .native ? Color.secondary : Ink.mute).frame(width: 52, alignment: .leading)
                        Text(firstLine(p.items)).font(.system(size: 13.5)).foregroundStyle(look == .native ? Color.primary : Ink.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(p.items.count)").font(look == .native ? .system(size: 12).monospacedDigit() : Ink.mono(12)).foregroundStyle(look == .native ? Color.secondary : Ink.mute)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                }
                .uiTarget("byday-row-\(DayPages.listDay(p.day))")
            }
        }
    }

    private func firstLine(_ items: [Transcript]) -> String {
        guard let first = items.first else { return "" }
        if !isThoughts { return first.title }
        let w = Thoughts.words(first)
        return w.isEmpty ? (first.status == .processing ? "Transcribing…" : first.title) : w
    }
}

/// New thought, from the Library: starts recording without leaving it (Stop while one records).
private struct NewThoughtPill: View {
    @ObservedObject private var capture = ThoughtCapture.shared
    @Environment(\.look) private var look
    var body: some View {
        Group {
            if look == .native {
                Button { capture.toggle() } label: {
                    Label { Text(capture.isRecording ? "Stop" : "New Thought") } icon: { ThoughtGlyph(color: .white, lineWidth: 1.4).frame(width: 14, height: 14) }
                }
                .buttonStyle(.borderedProminent).tint(Ink.nativeAccent)
                .help("New thought (\(Thoughts.hotkey))")
            } else {
                HStack(spacing: 8) {
                    if capture.isRecording {
                        ThoughtMicLevel(live: capture.recorder.live, color: Ink.paper).frame(width: 15, height: 15)
                    } else {
                        ThoughtGlyph(color: Ink.paper, lineWidth: 1.4).frame(width: 15, height: 15)
                    }
                    Text(capture.isRecording ? "Stop" : "New thought").font(.system(size: 13.5, weight: .semibold))
                    Text(Thoughts.hotkey).font(Ink.mono(12)).padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.paper.opacity(0.8), lineWidth: 1))
                }
                .foregroundStyle(Ink.paper)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(Ink.ink))
                .contentShape(Capsule())
                .tapArea { capture.toggle() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(capture.isRecording ? "Stop the thought" : "New thought")
                .accessibilityAddTraits(.isButton)
            }
        }
        .uiTarget("byday-new-thought")
    }
}

// MARK: - Calendar

/// A month calendar: the days with entries carry a dot; the selected day is filled. Click a day to read its page.
struct DayCalendar: View {
    @Binding var month: Date
    var selected: Date
    var today: Date
    var marked: Set<Date>
    var pick: (Date) -> Void
    @Environment(\.look) private var look

    var body: some View {
        let grid = DayPages.monthGrid(month)
        let native = look == .native
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Group {
                    if native {
                        Text(DayPages.monthTitle(month)).font(.system(size: 15, weight: .semibold))
                    } else {
                        WebText.serif(DayPages.monthTitle(month).split(separator: " ").first.map(String.init) ?? "",
                                      italic: DayPages.monthTitle(month).split(separator: " ").dropFirst().joined(separator: " "), size: 20)
                            .foregroundStyle(Ink.ink)
                    }
                }
                .accessibilityAddTraits(.isHeader)
                Spacer()
                arrow(back: true) { month = DayPages.month(month, moved: -1) }
                arrow(back: false) { month = DayPages.month(month, moved: 1) }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(Array(DayPages.weekdayLetters().enumerated()), id: \.offset) { _, l in
                    Text(l).font(native ? .system(size: 11, weight: .medium) : Ink.mono(12)).foregroundStyle(native ? Color.secondary : Ink.mute)
                        .frame(height: 18)
                }
                ForEach(grid, id: \.day) { cell in
                    dayCell(cell.day, inMonth: cell.inMonth, native: native)
                }
            }
        }
        .padding(14)
        .background {
            let shape = RoundedRectangle(cornerRadius: native ? 14 : Radius.tile, style: .continuous)
            if native {
                shape.fill(PremiumInk.card).shadow(color: PremiumInk.shadow.opacity(0.5), radius: 4, y: 1)   // brand: native
            } else {
                shape.fill(Ink.card).overlay(shape.strokeBorder(Ink.ink, lineWidth: 1.5))
            }
        }
        .uiTarget("byday-calendar")
    }

    private func dayCell(_ d: Date, inMonth: Bool, native: Bool) -> some View {
        let isSelected = d == selected
        let isToday = d == today
        let dot = marked.contains(d)
        let accent = native ? Ink.nativeAccent : Ink.ink
        return VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: d))").font(.system(size: 13.5, weight: isSelected ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(isSelected ? (native ? PremiumInk.onAccent : Ink.paper) : (inMonth ? (native ? Color.primary : Ink.ink) : (native ? Color.secondary : Ink.faint)))
            Circle().fill(isSelected ? (native ? PremiumInk.onAccent : Ink.paper) : accent).frame(width: 4, height: 4).opacity(dot ? 1 : 0)
        }
        .frame(maxWidth: .infinity).frame(height: 34)
        .background {
            let shape = RoundedRectangle(cornerRadius: native ? 8 : Radius.button, style: .continuous)
            if isSelected { shape.fill(accent) }
            else if isToday { shape.strokeBorder(accent, lineWidth: native ? 1 : 1.5) }
        }
        .contentShape(Rectangle())
        .tapArea { pick(d); if !inMonth { month = d } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DayPages.dateTitle(d))\(dot ? ", has entries" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .uiTarget(dot && inMonth ? "byday-dot-\(Calendar.current.component(.day, from: d))" : "byday-day-\(Calendar.current.component(.day, from: d))")
    }

    private func arrow(back: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: back ? "chevron.left" : "chevron.right").font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(look == .native ? Color.primary : Ink.ink)
            .frame(width: 26, height: 26)
            .overlay { if look != .native { Circle().strokeBorder(Ink.ink, lineWidth: 1.5) } }
            .contentShape(Circle())
            .tapArea(action)
            .accessibilityLabel(back ? "Month before" : "Month after")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The page

/// The selected day's page: its eyebrow, dated title, what's on it, the day's actions, and its entries.
struct DayPageCard: View {
    @EnvironmentObject var app: AppState
    var kind: RecordingKind
    var day: Date
    var today: Date
    var items: [Transcript]
    @Environment(\.look) private var look

    private var isThoughts: Bool { kind != .journal }
    private var native: Bool { look == .native }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayHeader(text: day == today ? "Today · \(DayPages.eyebrowDay(day))" : DayPages.eyebrowDay(day))
            Group {
                if native {
                    Text(DayPages.title(Thoughts.pageName(kind), day: day)).font(.system(size: 24, weight: .bold))
                } else {
                    WebText.serif("\(Thoughts.pageName(kind)) ·", italic: DayPages.dateTitle(day), size: 30).foregroundStyle(Ink.ink)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 10)
            Text(meta).font(.system(size: 12.5)).foregroundStyle(native ? Color.secondary : Ink.dim).padding(.top, 6)
            if isThoughts { actions.padding(.top, 14) }
            if items.isEmpty {
                ThoughtEmptyPage(isToday: day == today, play: false).padding(.top, 16).padding(.horizontal, -18)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { t in
                        if isThoughts { ThoughtLine(transcript: t) } else { JournalLine(transcript: t) }
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(22)
        .background {
            let shape = RoundedRectangle(cornerRadius: native ? 16 : Radius.tile, style: .continuous)
            if native {
                shape.fill(PremiumInk.card).shadow(color: PremiumInk.shadow.opacity(0.5), radius: 5, y: 2)   // brand: native
            } else {
                shape.fill(Ink.card).overlay(shape.strokeBorder(Ink.ink, lineWidth: 1.5))
            }
        }
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

    private var text: String { Thoughts.joined(items) }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if native {
                Button("Copy") { Paster.copy(text); app.toast = Toast("Copied the day's thoughts") }.buttonStyle(.bordered).disabled(items.isEmpty)
                ShareLink(item: text) { Text("Send To…") }.buttonStyle(.bordered).disabled(items.isEmpty)
                Button("Export") { DayExport.save(items, kind: kind, day: day) }.buttonStyle(.bordered).disabled(items.isEmpty)
                Spacer(minLength: 8)
                Button("Open as Floating Pad") { ThoughtPadController.shared.open() }.buttonStyle(.plain).foregroundStyle(Ink.nativeAccent)
            } else {
                PillButton(title: "Copy", kind: .line, size: .mini, icon: .iconCopy, enabled: !items.isEmpty) {
                    Paster.copy(text); app.toast = Toast("Copied the day's thoughts")
                }
                .uiTarget("byday-copy")
                ShareLink(item: text) { PillLabel(title: "Send to…", kind: .line, size: .mini) }.buttonStyle(.plain).disabled(items.isEmpty)
                PillButton(title: "Export", kind: .line, size: .mini, icon: .iconExport, enabled: !items.isEmpty) { DayExport.save(items, kind: kind, day: day) }
                Spacer(minLength: 8)
                Text("Open as the floating pad").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accentText)
                    .tapArea { ThoughtPadController.shared.open() }
                    .accessibilityAddTraits(.isButton)
                    .uiTarget("byday-open-pad")
            }
        }
    }
}

/// One thought on a Library page: its time in mono, its words, and where it came from. Click to open it.
private struct ThoughtLine: View {
    @EnvironmentObject var app: AppState
    let transcript: Transcript
    @Environment(\.look) private var look

    var body: some View {
        let t = transcript, native = look == .native
        FlatRowButton(action: { app.go(.transcript(t.id)) }) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(Thoughts.time(t.createdAt, native: native)).font(native ? .system(size: 12.5).monospacedDigit() : Ink.mono(12.5))
                    .foregroundStyle(native ? Color.secondary : Ink.mute).frame(width: native ? 64 : 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    switch t.status {
                    case .processing:
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Saved as audio. Transcribing…") }
                            .font(.system(size: 14.5)).foregroundStyle(native ? Color.secondary : Ink.dim)
                    case .failed:
                        HStack(spacing: 6) {
                            BrandGlyph(art: .iconAttention, color: native ? NativeInk.danger : Ink.danger, minLineWidth: 1.2).frame(width: 13, height: 13)
                            Text("Couldn't transcribe it. The audio is kept.")
                        }
                        .font(.system(size: 14.5)).foregroundStyle(native ? NativeInk.danger : Ink.danger)
                    case .ready:
                        let w = Thoughts.words(t)
                        Text(w.isEmpty ? "Nothing heard" : w).font(.system(size: 14.5)).foregroundStyle(native ? Color.primary : Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(Thoughts.origin(t)).font(.system(size: 12)).foregroundStyle(native ? Color.secondary : Ink.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
            .padding(.trailing, t.status == .failed ? 130 : 0)
        } accessory: { _ in
            if t.status == .failed {
                PillButton(title: "Transcribe again", kind: .line, size: .mini) { app.retry(t) }.padding(.trailing, 8)
            }
        }
        .contextMenu {
            Button("Open") { app.go(.transcript(t.id)) }
            Button("Copy") { Paster.copy(Thoughts.words(t)) }
            Divider()
            Button("Delete", role: .destructive) { app.store.moveToTrash(t.id) }
        }
    }
}

/// One journal entry on its page: the time, the title, a play pill with the length, and the first cleaned line.
private struct JournalLine: View {
    @EnvironmentObject var app: AppState
    let transcript: Transcript
    @Environment(\.look) private var look

    var body: some View {
        let t = transcript, native = look == .native
        let words = t.title.split(separator: " ")
        FlatRowButton(action: { app.go(.transcript(t.id)) }) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(Thoughts.time(t.createdAt, native: native)).font(native ? .system(size: 12.5).monospacedDigit() : Ink.mono(12.5))
                    .foregroundStyle(native ? Color.secondary : Ink.mute).frame(width: native ? 64 : 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Group {
                        if native || words.count < 2 {
                            Text(t.title).font(native ? .system(size: 15, weight: .semibold) : Ink.serif(19))
                        } else {
                            WebText.serif(words.dropLast().joined(separator: " "), italic: String(words.last ?? ""), size: 19)
                        }
                    }
                    .foregroundStyle(native ? Color.primary : Ink.ink).lineLimit(1)
                    Text(PremiumPreview.text(t)).font(.system(size: 13)).foregroundStyle(native ? Color.secondary : Ink.dim).lineLimit(2)
                    // Room for the play pill, which sits above the row's hit layer.
                    if t.audioFileName != nil && t.status == .ready { Color.clear.frame(width: 60, height: 22) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
        } accessory: { _ in EmptyView() }
        .overlay(alignment: .bottomLeading) {
            if t.audioFileName != nil && t.status == .ready {
                HStack(spacing: 5) {
                    ArtIcon(art: .iconPlay, size: 10, lineWidth: 1.4)
                    Text(HomeRecentStyle.length(t.duration)).font(native ? .system(size: 12).monospacedDigit() : Ink.mono(12))
                }
                .foregroundStyle(native ? Color.primary : Ink.ink)
                .padding(.horizontal, 9).frame(height: 22)
                .overlay(Capsule().strokeBorder(native ? PremiumInk.separator : Ink.ink, lineWidth: native ? 1 : 1.5))
                .contentShape(Capsule())
                .tapArea { NativeNav.shared.play(t, app: app) }
                .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
                .accessibilityAddTraits(.isButton)
                .padding(.leading, 8 + (native ? 64 : 44) + 16).padding(.bottom, 12)
            }
        }
    }
}

/// Export: the day's page as a Markdown file you save where you like.
@MainActor
enum DayExport {
    static func markdown(_ items: [Transcript], kind: RecordingKind, day: Date) -> String {
        var out = "# \(DayPages.title(Thoughts.pageName(kind), day: day))\n"
        for t in items {
            let time = Thoughts.time(t.createdAt, native: true)
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
