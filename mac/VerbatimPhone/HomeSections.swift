import SwiftUI

// Home's sections on iPhone beyond the Record card, tiles, This week, and Recent recordings (HomeScreen.swift): Today's
// thoughts and Journal, each Compact (one slim row) or Large (the card under its serif title); the shortcut tiles'
// actions; and the Edit Home button at the end of Home. Drawn with the refined kit (DESIGN.md §13) in both looks.

// MARK: - Spacing

enum HomeSpacing {
    /// Sections with a title of their own get more room above them.
    static func headed(_ item: HomeLayout.Item) -> Bool {
        switch item.section {
        case .recent: return true
        case .thoughts, .journal: return item.size == .large
        default: return false
        }
    }

    /// The gap above a section (the mockup's 14 between cards; 22 above a titled section; 18 under the greeting).
    static func top(_ item: HomeLayout.Item, after previous: HomeLayout.Item?) -> CGFloat {
        guard previous != nil else { return 18 }
        return headed(item) ? 22 : 14
    }

    /// The sections Home draws: the layout's shown ones, in both looks. Native's Record accessory steps aside on Home
    /// while the Record card is drawn (`hidesRecordAccessory`).
    static func drawn(_ layout: HomeLayout) -> [HomeLayout.Item] { layout.shown }

    /// Whether Native's Record accessory (RecordAccessory.swift) stays off on this tab: on Home's own screen, while
    /// its Record card is there and nothing is recording (the accessory carries the live recording on every tab).
    static func hidesRecordAccessory(tab: PhoneState.Tab, homeAtRoot: Bool, recording: Bool, layout: HomeLayout) -> Bool {
        tab == .home && homeAtRoot && !recording && layout.isVisible(.record)
    }
}

// MARK: - Tiles

enum HomeTileAction {
    /// How Home's New thought (the tile and the Today's thoughts section) starts a thought: the recorder opens on one.
    /// The self-test swaps in a simulated thought (no microphone in the simulator).
    @MainActor static var startThought: @MainActor (PhoneState) -> Void = { $0.requestThought() }

    /// What a tile does on iPhone. Import is a menu (HomeTileButton); the Mac's tiles aren't offered here.
    @MainActor static func run(_ tile: HomeTile, _ app: PhoneState) {
        switch tile {
        case .dictate: app.homePath.append(DictationsRoute())
        case .importMedia: app.showImporter = true
        case .whatsPlaying: app.showPlayingSheet = true
        case .captions: app.requestCaptions()
        case .projects: app.go(.projects)
        case .dictations: app.go(.dictations)
        case .dictionary: app.homePath.append(HomeDictionaryRoute())
        case .newThought: startThought(app)
        case .journal: app.go(.journal)
        case .brainDump: app.startRecordChoice(.kind(.brainDump))
        case .appAudio, .thoughtPad: break
        }
    }

    static func hint(_ tile: HomeTile) -> String {
        switch tile {
        case .dictate: return "Opens your dictations and how to use the Verbose keyboard."
        case .importMedia: return "Choose a video from Photos, audio or video files, or paste a link to transcribe."
        case .whatsPlaying: return "Transcribes sound from TikTok or any app."
        case .captions: return "Shows what's said in the room as captions."
        case .dictations: return "Opens every dictation."
        case .dictionary: return "Opens your dictionary."
        case .projects: return "Opens your library, with a chip for each project."
        case .newThought: return "Records a thought for today's page."
        case .journal: return "Opens your journal, by day."
        case .brainDump: return "Records a brain dump. Plan my day sorts it into a plan when it finishes."
        case .appAudio, .thoughtPad: return ""
        }
    }
}

/// Pushes the dictionary from Home's Dictionary tile.
struct HomeDictionaryRoute: Hashable {}

/// A tile's button: Import opens its menu (Photos, files, or a link); every other tile runs its action.
struct HomeTileButton<Face: View>: View {
    @EnvironmentObject var app: PhoneState
    var tile: HomeTile
    @ViewBuilder var label: () -> Face

    var body: some View {
        Group {
            if tile == .importMedia {
                Menu {
                    Button("Choose from Photos") { app.showPhotoPicker = true }
                    Button("Choose files…") { app.showImporter = true }
                    Button("Paste a link") { app.showLinkSheet = true }
                } label: { label() }
                .menuStyle(.button)
                .buttonStyle(RefinedPress())
                .accessibilityAction(named: "Paste a link") { app.showLinkSheet = true }
            } else {
                Button { HomeTileAction.run(tile, app) } label: { label() }
                    .buttonStyle(RefinedPress())
            }
        }
        .accessibilityLabel(tile.title)
        .accessibilityHint(HomeTileAction.hint(tile))
        .homeTileProbe(tile)
    }
}

// MARK: - Today's thoughts

/// Today's thoughts. Large: "Today's thoughts" with Today's page, the latest four in a card with their times, then New
/// thought. Compact: one slim row with the count and the latest, and New thought beside it. A tap opens today's page
/// (the Thoughts tab, or Library › By day); New thought opens the recorder on a thought. Thoughts are a kind, so the
/// section stays in ink, and New thought is a quiet button, never a second persimmon fill beside Record.
struct HomeThoughtsSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize

    /// For the self-test: how many of today's thoughts the section counted when it last drew.
    static var shownCount: Int?

    var body: some View {
        let page = app.store.todaysThoughts()
        Group {
            if size == .compact { compact(page) } else { large(page) }
        }
        .accessibilityIdentifier("home.thoughts")
        .onAppear { Self.shownCount = page.count }
        .onChange(of: page.count) { _, n in Self.shownCount = n }
    }

    private func words(_ t: Transcript) -> String {
        switch t.status {
        case .processing: return ThoughtRules.transcribing
        case .failed: return ThoughtRules.failed
        case .ready: let w = ThoughtText.words(t); return w.isEmpty ? "No words heard. The audio is saved." : w
        }
    }

    private func compact(_ page: [Transcript]) -> some View {
        HStack(spacing: 10) {
            Button { app.openThoughtPage() } label: {
                HStack(spacing: 12) {
                    IconGlyph(art: .iconThought, size: 20, color: Refined.ink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(HomeThoughts.countLine(page.count)).refinedFont(.rowTitle, weight: .semibold)
                            .foregroundStyle(Refined.ink).lineLimit(1)
                        Text(page.last.map(words) ?? "Tap New thought to start today's page.")
                            .refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
            }
            .buttonStyle(RefinedPress())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens today's Thoughts page.")
            newThought(compact: true)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    private func large(_ page: [Transcript]) -> some View {
        let shown = HomeThoughts.latest(page)
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Today's thoughts", link: "Today's page") { app.openThoughtPage() }
            Button { app.openThoughtPage() } label: {
                PaperCard {
                    if shown.isEmpty {
                        Text("Nothing yet today. A thought is one tap away.").refinedFont(.body).foregroundStyle(Refined.dim)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { PaperDivider(leading: 14) }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(ThoughtText.time(t.createdAt, native: true)).refinedFont(.meta).monospacedDigit()
                                .foregroundStyle(Refined.mute).lineLimit(1).fixedSize()
                                .frame(minWidth: 64, alignment: .leading)
                            Text(words(t)).refinedFont(.body).foregroundStyle(t.status == .ready ? Refined.ink : Refined.dim)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
            .buttonStyle(RefinedPress())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(shown.isEmpty ? "No thoughts yet today" : HomeThoughts.countLine(page.count))
            .accessibilityHint("Opens today's Thoughts page.")
            HStack {
                newThought(compact: false)
                Spacer(minLength: 0)
                if page.count > shown.count {
                    Text("\(page.count) today").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                }
            }
            .padding(.top, 4)
        }
    }

    /// New thought: a quiet button with the bulb. In the compact row it's the bulb alone, so the count beside it never
    /// cuts off (review P-18).
    private func newThought(compact: Bool) -> some View {
        Button { HomeTileAction.startThought(app) } label: {
            HStack(spacing: 7) {
                IconGlyph(art: .iconThought, size: 16, color: Refined.ink)
                if !compact { Text("New thought") }
            }
        }
        .buttonStyle(RefinedActionStyle())
        .accessibilityLabel("New thought")
        .accessibilityHint("Records a thought for today's page.")
        .accessibilityIdentifier("home.thoughts.new")
    }
}

// MARK: - Journal

/// Journal. Large: "Journal" with By day, then a card with the newest entry (the date, its title, the first line, and
/// a play button with the length) over this week's days as dots. Compact: one row with the newest title and the dots.
/// A tap opens Journal By day (the Journal tab, or inside Library); play opens the entry playing.
struct HomeJournalSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    var now: Date

    var body: some View {
        let hour = app.newPageHour
        let pages = app.store.dayPages(.journal, hour: hour)
        let latest = pages.first?.items.last
        let week = HomeJournalWeek.days(entryDays: pages.map(\.day), today: app.todayPage)
        Group {
            if size == .compact { compact(latest, week) } else { large(latest, week) }
        }
        .accessibilityIdentifier("home.journal")
    }

    private func compact(_ latest: Transcript?, _ week: [HomeJournalWeek.Day]) -> some View {
        Button { app.go(.journal) } label: {
            HStack(spacing: 12) {
                IconGlyph(art: .iconNotes, size: 20, color: Refined.ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Journal").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(latest?.title ?? "No entries yet").refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                }
                Spacer(minLength: 8)
                HomeWeekDots(week: week, size: 8)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
        .buttonStyle(RefinedPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journal: \(latest?.title ?? "no entries yet")")
        .accessibilityValue(HomeJournalWeek.countLine(week))
        .accessibilityHint("Opens your journal, by day.")
        .accessibilityAddTraits(.isButton)
    }

    private func large(_ latest: Transcript?, _ week: [HomeJournalWeek.Day]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Journal", link: "By day") { app.go(.journal) }
            VStack(alignment: .leading, spacing: 12) {
                Button { app.go(.journal) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if let t = latest {
                            Text(HomeRecentStyle.day(t.createdAt, now: now)).refinedFont(.meta).foregroundStyle(Refined.mute)
                            Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(2)
                            let first = ThoughtText.words(t)
                            if !first.isEmpty {
                                Text(first).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        } else {
                            Text("Record with the Journal kind, and your newest entry shows here.")
                                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RefinedPress())
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens your journal, by day.")
                HStack(spacing: 12) {
                    if let t = latest, t.status == .ready, t.audioFileName != nil, t.duration > 0 { play(t) }
                    Spacer(minLength: 8)
                    HomeWeekDots(week: week, size: 9, letters: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("This week: \(HomeJournalWeek.countLine(week))")
                }
            }
            .padding(14)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
    }

    /// Play: opens the entry playing.
    private func play(_ t: Transcript) -> some View {
        Button { app.autoplay = t.id; app.open(t.id) } label: {
            HStack(spacing: 7) {
                IconGlyph(art: .iconPlay, size: 12, color: Refined.ink)
                Text(HomeRecentStyle.length(t.duration)).monospacedDigit()
            }
        }
        .buttonStyle(RefinedActionStyle())
        .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
        .accessibilityHint("Opens the entry and plays it.")
    }
}

// MARK: - Edit Home button

/// The last thing on Home: opens Edit Home, a quiet button centered under the sections.
struct EditHomeButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .semibold))
                Text("Edit Home")
            }
        }
        .buttonStyle(RefinedActionStyle())
        .frame(maxWidth: .infinity)
        .accessibilityHint("Show, hide, reorder, and resize Home's sections, and choose its four tiles.")
        .accessibilityIdentifier("home.edit")
    }
}
