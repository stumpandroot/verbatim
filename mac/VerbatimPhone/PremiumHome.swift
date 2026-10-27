// brand: native file
import SwiftUI

/// Home in Premium Native (mockup "premium", section 01), under the large title "Home" and the account button: the
/// date, then the sections Edit Home lists for Native (HomeLayout.swift), in its order and sizes. By default: This week
/// as a persimmon gradient card (the words in big SF Pro Rounded, a seven-day mini chart with today in white, and the
/// time saved and recordings in one line), a row of four soft tiles, and the recent recordings as Voicenotes-style
/// items. The Record section starts hidden; the floating record button stands in for it, and hiding the section never
/// hides the button. Edit Home's button closes the page. Same actions as Verbose style.
struct PremiumHome: View {
    @EnvironmentObject var app: PhoneState
    var now: Date
    var layout: HomeLayout
    var onEdit: () -> Void
    @ObservedObject private var flow = FlowSettings.shared
    @ScaledMetric(relativeTo: .largeTitle) private var bigNumber: CGFloat = 58

    var body: some View {
        let drawn = HomeSpacing.drawn(layout, working: HomeScreen.working(app.store))
        VStack(alignment: .leading, spacing: 0) {
            Text(HomeGreeting.dateLine(now)).font(.system(size: 15)).foregroundStyle(NativeInk.secondary)
                .id("home-top")
                .accessibilityAddTraits(.isHeader)
            WhatsNewBanner(top: 14) { HomeScreen.openWhatsNew(app) }
            ForEach(Array(drawn.enumerated()), id: \.element.section) { i, item in
                section(item)
                    .padding(.top, HomeSpacing.top(item, after: i > 0 ? drawn[i - 1] : nil, native: true))
                    .homeProbe(item)
            }
            EditHomeButton(action: onEdit).padding(.top, 28)
        }
    }

    @ViewBuilder private func section(_ item: HomeLayout.Item) -> some View {
        switch item.section {
        case .week: if item.size == .large { weekCard } else { weekStrip }
        case .record: recordCard(compact: item.size == .compact)
        case .tiles: tiles(layout.tiles, large: item.size == .large)
        case .recent: recent(item.size).id("home-recent")
        case .lastDictation: HomeLastDictationSection(size: item.size, now: now)
        case .projects: HomeProjectsSection(size: item.size)
        case .moments: HomeMomentsSection(size: item.size)
        case .queue: HomeQueueSection(size: item.size)
        case .thoughts: HomeThoughtsSection(size: item.size).id("home-thoughts")
        case .journal: HomeJournalSection(size: item.size, now: now)
        case .stats: EmptyView()
        }
    }

    // MARK: This week

    /// Big numbers sit in the card's top third (3:1 is enough for them); every smaller line sits lower, where white
    /// measures 4.5:1 or better (PremiumRules, mac/tools/test-premium-phone.sh). Opens You.
    private var weekCard: some View {
        let week = app.store.dictationWeek(now: now)
        let saved = HomeScreen.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM))
        let recordings = app.store.memo("recordings-this-week|\(Store.dayKey(now))") { Self.recordingsThisWeek(app.store.live, now: now) }
        let foot = "\(saved) saved typing · \(HomeCounts.countLabel(recordings, "recording", "recordings"))"
        return Button { HomeScreen.openProfile(app) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Text(week.words.formatted()).font(PremiumStyle.number(min(bigNumber, 76)))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 8)
                    PremiumWeekChart(week: week)
                }
                Text("words dictated").font(.system(size: 17, weight: .semibold)).padding(.top, 2)
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    Text("This week · \(foot)").font(.system(size: 14, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
            }
            .padding(.leading, 20).padding(.trailing, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
            .premiumCard(.persimmon)
            .onAppear { HomeScreen.recordCardsOnScreen.insert(.native) }
            .onDisappear { HomeScreen.recordCardsOnScreen.remove(.native) }
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated, \(saved) saved typing, \(HomeCounts.countLabel(recordings, "recording", "recordings")).")
        .accessibilityHint("Opens your You page, with the whole week.")
        .accessibilityIdentifier("home.week.premium")
    }

    /// This week, Compact: a slim gradient strip with the words and the seven days.
    private var weekStrip: some View {
        let week = app.store.dictationWeek(now: now)
        return Button { HomeScreen.openProfile(app) } label: {
            HStack(spacing: 12) {
                Text(week.words.formatted()).font(PremiumStyle.number(30)).lineLimit(1).minimumScaleFactor(0.6)
                Text("words this week").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                PremiumWeekChart(week: week, height: 26, letters: false)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .premiumCard(.persimmon, radius: 22)
            .onAppear { HomeScreen.recordCardsOnScreen.insert(.native) }
            .onDisappear { HomeScreen.recordCardsOnScreen.remove(.native) }
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated.")
        .accessibilityHint("Opens your You page, with the whole week.")
        .accessibilityIdentifier("home.week.premium.compact")
    }

    /// Recordings, imports, and links made this calendar week (dictations count on their own).
    static func recordingsThisWeek(_ items: [Transcript], now: Date, calendar: Calendar = .current) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return items.filter { !$0.isDictation && week.contains($0.createdAt) }.count
    }

    // MARK: Record (optional)

    /// The Record section (hidden by default; the floating button stays either way). Compact drops the second line.
    private func recordCard(compact: Bool) -> some View {
        Button { app.requestRecord() } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record").font(compact ? .headline : .title2.bold()).foregroundStyle(NativeInk.label)
                    Text("Ready · \(HomeScreen.currentMic())").font(.subheadline).foregroundStyle(NativeInk.secondary).lineLimit(1)
                    if !compact {
                        Text("Keeps recording with the screen locked").font(.footnote).foregroundStyle(NativeInk.secondary)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                Circle().fill(PremiumStyle.disc).frame(width: compact ? 34 : 48, height: compact ? 34 : 48)
                    .padding(compact ? 3 : 4).background(PremiumStyle.ring, in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, compact ? 10 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumSoftCard(radius: 26)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityLabel("Record")
        .accessibilityHint("Starts a voice note. It keeps recording with the screen locked.")
        .accessibilityIdentifier("home.record.native")
        // Touch and hold: Record a meeting, an interview, a journal entry, a talk, or a note (Templates.swift).
        .contextMenu { PhoneRecordKindItems { app.requestRecord(kind: $0) } }
    }

    // MARK: Tiles

    /// The four tiles you picked. Compact: one row of soft tiles. Large: two by two, each with a line of detail.
    @ViewBuilder private func tiles(_ picks: [HomeTile], large: Bool) -> some View {
        if large {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { tileCells(picks, slots: 0..<2, large: true) }
                GridRow { tileCells(picks, slots: 2..<4, large: true) }
            }
        } else {
            HStack(spacing: 10) { tileCells(picks, slots: 0..<4, large: false) }
        }
    }

    private func tileCells(_ picks: [HomeTile], slots: Range<Int>, large: Bool) -> some View {
        ForEach(HomeTileSlot.slots(picks, slots), id: \.tile) { s in
            HomeTileButton(tile: s.tile) {
                if large { bigTile(s.tile) } else { tile(s.tile.title, symbol: s.tile.symbol) }
            }
        }
    }

    /// A soft white tile: the symbol in a tinted circle over a short name.
    private func tile(_ title: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(NativeInk.accent)
                .frame(width: 38, height: 38)
                .background(PremiumInk.accentSoft, in: Circle())
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(NativeInk.label)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 86)
        .premiumSoftCard(radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    /// A Large tile: the symbol in its circle, the name, and one line of what it does.
    private func bigTile(_ t: HomeTile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: t.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(NativeInk.accent)
                .frame(width: 40, height: 40)
                .background(PremiumInk.accentSoft, in: Circle())
            Spacer(minLength: 10)
            Text(t.title).font(.system(size: 18, weight: .bold)).foregroundStyle(NativeInk.label).lineLimit(1).minimumScaleFactor(0.8)
            Text(t.detail).font(.system(size: 13)).foregroundStyle(NativeInk.secondary).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .premiumSoftCard(radius: 24)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.title)
        .accessibilityValue(t.detail)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Recent recordings

    /// Large: the three newest as Voicenotes-style items. Compact: the three newest as one-line rows with a play mark.
    private func recent(_ size: HomeCardSize) -> some View {
        let items = Array(app.store.live.lazy.filter { !$0.isDictation }.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            PremiumSectionHeader(title: "Recent recordings", action: "Library") { app.go(.library) }
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record something new.").font(.body.weight(.semibold)).foregroundStyle(NativeInk.label)
                    Text("Recordings and imports land here, and on your Mac.").font(.subheadline).foregroundStyle(NativeInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
            } else if size == .large {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    PremiumRecordingItem(transcript: t, now: now, showsDivider: i < items.count - 1)
                }
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    recentLine(t, divider: i < items.count - 1)
                }
            }
        }
    }

    /// A Compact recording: the title, its length, and a play mark; a tap opens it.
    private func recentLine(_ t: Transcript, divider: Bool) -> some View {
        Button { app.open(t.id) } label: {
            HStack(spacing: 12) {
                Text(t.title).font(.system(size: 17, weight: .medium)).foregroundStyle(NativeInk.label).lineLimit(1)
                Spacer(minLength: 8)
                LiveStage(t) { t in
                    Text(t.status == .ready ? HomeRecentStyle.length(t.duration) : t.stageText)
                        .font(.system(size: 15).monospacedDigit()).foregroundStyle(NativeInk.secondary).lineLimit(1)
                }
                Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(NativeInk.label)
                    .frame(width: 30, height: 30).background(NativeInk.fill, in: Circle())
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 52)
            .overlay(alignment: .bottom) { if divider { NativeDivider(leading: 0) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(PhoneCardPress())
        .contextMenu { RowActions(transcript: t) }
        .accessibilityHint("Opens the transcript.")
    }
}

/// Seven small bars for the week, today in white, other days with words in a soft white, and the rest as stubs,
/// over the day letters. Text is solid white (no opacity), so it keeps its contrast.
struct PremiumWeekChart: View {
    var week: HomeWeek
    var height: CGFloat = 50
    /// The day letters under the bars (left off in This week's Compact strip).
    var letters = true

    var body: some View {
        let heights = PremiumRules.barHeights(week.days.map(\.words), future: week.days.map(\.isFuture), maxHeight: Double(height))
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(alignment: .bottom, spacing: letters ? 6 : 4) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { i, day in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(heights[i] == nil ? 0.18 : day.isToday ? 1 : 0.4))
                        .frame(width: letters ? 9 : 7, height: CGFloat(heights[i] ?? 4))
                        .frame(height: height, alignment: .bottom)
                    if letters {
                        Text(symbols[(Calendar.current.component(.weekday, from: day.start) - 1) % symbols.count])
                            .font(.system(size: 10, weight: day.isToday ? .heavy : .semibold))
                            .frame(width: 11)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
