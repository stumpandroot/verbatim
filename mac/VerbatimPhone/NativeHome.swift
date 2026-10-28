// brand: native file
import SwiftUI

/// Home in the Native look (DESIGN.md §13.3; mockup "Verbose Native Redesign", section 1): an inset grouped list under
/// the large title "Home", with the date as the navigation subtitle and the account button. The sections Edit Home
/// lists for Native (HomeLayout.swift), in its order and sizes. By default: the quick actions as plain rows with blue
/// symbols, the way Mail lists its mailboxes; This week as one stat cell, like Screen Time's; and the recent
/// recordings in Voice Memos' rhythm. Record isn't a section: it's in the tab bar's accessory on every tab
/// (RecordAccessory.swift). Same actions as Verbose style.
struct NativeHome: View {
    @EnvironmentObject var app: PhoneState
    var now: Date
    var layout: HomeLayout
    var onEdit: () -> Void
    @ObservedObject private var flow = FlowSettings.shared
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        let drawn = HomeSpacing.drawn(layout, working: HomeScreen.working(app.store), native: true)
        ScrollViewReader { proxy in
            List {
                // Before iOS 26 there's no navigation subtitle, so the date is the first line.
                if !NativeSubtitle.supported {
                    Text(HomeGreeting.dateLine(now)).font(.subheadline).foregroundStyle(NativeInk.secondary)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                WhatsNewBanner { HomeScreen.openWhatsNew(app) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                ForEach(drawn, id: \.section) { item in section(item) }
                Section {
                    Button(action: onEdit) { Label("Edit Home", systemImage: "square.grid.2x2") }
                        .accessibilityHint("Show, hide, reorder, and resize Home's sections, and choose its four tiles.")
                        .accessibilityIdentifier("home.edit")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .onReceive(NotificationCenter.default.publisher(for: .verbatimHomeScroll)) { note in
                guard var id = note.object as? String else { return }
                // The top is the first section's row.
                if id == "home-top", let first = drawn.first { id = Self.rowID(first.section) }
                withAnimation(limitMotion ? nil : Motion.settle) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        // The list is lazy, so rows below the fold haven't appeared yet: the self-test's probe reads what this list
        // draws from its data instead (HomeProbe; Edit Home's checks compare it with the layout).
        .onAppear { Self.probe(drawn, layout: layout, on: true); HomeScreen.recordCardsOnScreen.insert(.native) }
        .onDisappear { Self.probe(drawn, layout: layout, on: false); HomeScreen.recordCardsOnScreen.remove(.native) }
        .onChange(of: drawn) { old, new in Self.probe(old, layout: layout, on: false); Self.probe(new, layout: layout, on: true) }
        .onChange(of: layout.tiles) { old, new in
            guard drawn.contains(where: { $0.section == .tiles }) else { return }
            old.forEach(HomeProbe.tileDisappeared); new.forEach(HomeProbe.tileAppeared)
        }
    }

    /// The scroll target of a section's first row ("home-recent"; the screenshot tour scrolls to them).
    static func rowID(_ s: HomeSection) -> String {
        switch s {
        case .tiles: return "home-tiles"
        case .week: return "home-week"
        case .recent: return "home-recent"
        case .thoughts: return "home-thoughts"
        case .journal: return "home-journal"
        case .record: return "home-record"
        }
    }

    /// Counts the drawn sections (and the tiles, when their section is drawn) in or out of HomeProbe.
    private static func probe(_ drawn: [HomeLayout.Item], layout: HomeLayout, on: Bool) {
        for item in drawn {
            if on { HomeProbe.appeared(item) } else { HomeProbe.disappeared(item.section) }
        }
        if drawn.contains(where: { $0.section == .tiles }) {
            for t in layout.tiles { if on { HomeProbe.tileAppeared(t) } else { HomeProbe.tileDisappeared(t) } }
        }
    }

    @ViewBuilder private func section(_ item: HomeLayout.Item) -> some View {
        switch item.section {
        case .tiles: tiles(layout.tiles, large: item.size == .large)
        case .week: week(large: item.size == .large)
        case .recent: recent(item.size)
        case .thoughts: embedded("home-thoughts") { HomeThoughtsSection(size: item.size) }
        case .journal: embedded("home-journal") { HomeJournalSection(size: item.size, now: now) }
        // Record retired from Native's Home: it's in the tab bar's accessory.
        case .record: EmptyView()
        }
    }

    /// A section Verbose style shares (HomeSections.swift), which draws its own grouped cell and heading.
    private func embedded<Content: View>(_ id: String, @ViewBuilder _ content: () -> Content) -> some View {
        Section {
            content()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .id(id)
        }
    }

    // MARK: Quick actions

    /// The four tiles you picked, as rows with blue symbols. Large adds a line of what each does.
    private func tiles(_ picks: [HomeTile], large: Bool) -> some View {
        Section {
            ForEach(picks, id: \.self) { t in
                if t == .importMedia {
                    Menu {
                        Button("Choose from Photos") { app.showPhotoPicker = true }
                        Button("Choose files…") { app.showImporter = true }
                        Button("Paste a link") { app.showLinkSheet = true }
                    } label: { tileRow(t, large: large) }
                    .accessibilityAction(named: "Paste a link") { app.showLinkSheet = true }
                    .accessibilityHint(HomeTileAction.hint(t))
                    .homeTileProbe(t)
                    .id(t == picks.first ? "home-tiles" : "home-tile-\(t.rawValue)")
                } else {
                    Button { HomeTileAction.run(t, app) } label: { tileRow(t, large: large) }
                        .accessibilityHint(HomeTileAction.hint(t))
                        .homeTileProbe(t)
                        .id(t == picks.first ? "home-tiles" : "home-tile-\(t.rawValue)")
                }
            }
        }
    }

    private func tileRow(_ t: HomeTile, large: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(t)).foregroundStyle(NativeInk.label)
                if large { Text(t.detail).font(.footnote).foregroundStyle(NativeInk.secondary) }
            }
        } icon: {
            Image(systemName: t.symbol).foregroundStyle(NativeInk.accent)
        }
    }

    /// A quick action's row title: Import says what it takes.
    static func title(_ t: HomeTile) -> String { t == .importMedia ? "Import a file or link" : t.title }

    // MARK: This week

    /// One stat cell, the only number on Home: the words in SF Pro bold with monospaced digits, the recordings and the
    /// time saved under them, and the seven days with today's bar the one blue mark. Large adds "Your week", which
    /// opens You.
    private func week(large: Bool) -> some View {
        let week = app.store.dictationWeek(now: now)
        let saved = HomeScreen.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM))
        let recordings = app.store.memo("recordings-this-week|\(Store.dayKey(now))") { HomeScreen.recordingsThisWeek(app.store.live, now: now) }
        return Section {
            Button { HomeScreen.openProfile(app) } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(week.words.formatted()).font(NativeStyle.number(large ? 32 : 26)).foregroundStyle(NativeInk.label)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(week.words == 1 ? "word" : "words").font(.title3).foregroundStyle(NativeInk.secondary)
                        }
                        Text(NativeRules.weekDetail(recordings: recordings, saved: saved))
                            .font(.subheadline).foregroundStyle(NativeInk.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    NativeWeekChart(week: week, height: large ? 38 : 28, letters: large)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated, \(HomeCounts.countLabel(recordings, "recording", "recordings")), \(saved) saved typing.")
            .accessibilityHint("Opens your You page, with the whole week.")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("home.week.native")
            .id("home-week")
            if large {
                NavigationLinkRow(title: "Your week") { HomeScreen.openProfile(app) }
            }
        } header: {
            NativeListHeader(title: "This week")
        }
    }

    // MARK: Recent recordings

    /// Large: the three newest in Voice Memos' rhythm. Compact: the three newest titles with their lengths.
    private func recent(_ size: HomeCardSize) -> some View {
        let items = Array(HomeScreen.recentRecordings(app.store).prefix(3))
        return Section {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No recordings yet", systemImage: "waveform")
                } description: {
                    Text("Tap Record to start one.")
                }
                .listRowBackground(Color.clear)
                .id("home-recent")
            } else {
                ForEach(items) { t in
                    NavigationLink(value: t.id) {
                        if size == .large {
                            NativeRecentRow(transcript: t, now: now)
                        } else {
                            LiveStage(t) { t in
                                HStack {
                                    Text(PhoneRowTitle.title(t, withTime: false)).foregroundStyle(NativeInk.label).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(t.status == .ready ? HomeRecentStyle.length(t.duration) : t.stageText)
                                        .monospacedDigit().foregroundStyle(NativeInk.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .contextMenu { RowActions(transcript: t) }
                    .accessibilityHint("Opens the transcript.")
                    .id(t.id == items.first?.id ? "home-recent" : t.id.uuidString)
                }
            }
        } header: {
            NativeListHeader(title: "Recent recordings", action: items.isEmpty ? nil : "See all") { app.go(.library) }
        }
    }
}

/// A row that acts like a navigation link (the chevron), for an action that isn't a push on this stack.
struct NavigationLinkRow: View {
    var title: String
    var value: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(NativeInk.label)
                Spacer(minLength: 8)
                if let value { Text(value).foregroundStyle(NativeInk.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(NativeInk.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(NativeInk.label)
    }
}

/// This week's seven days as small bars over the day letters: gray for days with words, a stub for the rest, and
/// today's bar the one blue mark.
struct NativeWeekChart: View {
    var week: HomeWeek
    var height: CGFloat = 38
    var letters = true

    var body: some View {
        let heights = PremiumRules.barHeights(week.days.map(\.words), future: week.days.map(\.isFuture), maxHeight: Double(height))
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { i, day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(day.isToday ? NativeInk.accent : heights[i] == nil ? NativeInk.fillStrong : NativeInk.gray)
                        .frame(width: 8, height: CGFloat(heights[i] ?? 3))
                        .frame(height: height, alignment: .bottom)
                    if letters {
                        Text(symbols[(Calendar.current.component(.weekday, from: day.start) - 1) % symbols.count])
                            .font(.system(size: 10, weight: day.isToday ? .bold : .regular))
                            .foregroundStyle(day.isToday ? NativeInk.label : NativeInk.secondary)
                            .frame(width: 10)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The navigation subtitle (iOS 26), under the large title: Home's date, the Library's count.
enum NativeSubtitle {
    static var supported: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

extension View {
    /// The navigation subtitle on iOS 26; nothing before it (the screen shows the line itself), or with no text.
    @ViewBuilder func nativeSubtitle(_ text: String?) -> some View {
        if let text {
            if #available(iOS 26, *) { navigationSubtitle(text) } else { self }
        } else {
            self
        }
    }
}
