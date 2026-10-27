import SwiftUI

// Home's sections that both looks share on iPhone (Edit Home, mockup "premium", section 03): Last dictation, Projects,
// Moments, and Queue, each Compact (one slim row or strip) or Large (the full card); the shortcut tiles' actions; and
// the Edit Home button at the end of Home. Record, the tiles, This week, and Recent recordings are drawn by each
// look's Home (HomeScreen.swift, NativeHome.swift). Every view reads `\.look` and draws the look's clothes; the
// Native branches are stock Apple and marked for the brand check.

// MARK: - Spacing

enum HomeSpacing {
    /// Sections with a heading of their own get more room above them.
    static func headed(_ item: HomeLayout.Item) -> Bool {
        switch item.section {
        case .recent, .lastDictation, .projects, .moments, .queue, .thoughts, .journal: return item.size == .large
        default: return false
        }
    }

    /// The gap above a section, as each look's Home spaced it before Edit Home (Verbose: Record 18, tiles 10 under
    /// Record, This week 12, Recent recordings 24; Native: the first 18, 12 between cards, Recent recordings 28).
    static func top(_ item: HomeLayout.Item, after previous: HomeLayout.Item?, native: Bool) -> CGFloat {
        guard let previous else { return 18 }
        if headed(item) { return native ? 28 : 24 }
        if !native, previous.section == .record, item.section == .tiles { return 10 }
        return 12
    }

    /// The sections Home draws: the layout's shown ones, without Queue while nothing is transcribing. Native draws no
    /// Record section: Record is in the tab bar's accessory there (RecordAccessory.swift).
    static func drawn(_ layout: HomeLayout, working: Bool, native: Bool = false) -> [HomeLayout.Item] {
        layout.shown.filter { ($0.section != .queue || working) && !(native && $0.section == .record) }
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
        case .pasteLink: app.showLinkSheet = true
        case .search: app.go(.library)
        case .projects: app.go(.projects)
        case .moments: app.go(.moments)
        case .queue: app.go(.library, filter: "working")
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
        case .pasteLink: return "Transcribes a YouTube, Vimeo, or podcast link."
        case .search: return "Opens your library, where you can search every transcript."
        case .moments: return "Opens your saved moments."
        case .queue: return "Shows what's still transcribing."
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
                .buttonStyle(PhoneCardPress())
                .accessibilityAction(named: "Paste a link") { app.showLinkSheet = true }
            } else {
                Button { HomeTileAction.run(tile, app) } label: { label() }
                    .buttonStyle(PhoneCardPress())
            }
        }
        .accessibilityHint(HomeTileAction.hint(tile))
        .homeTileProbe(tile)
    }
}

// MARK: - Headings

/// A section's heading: Verbose style's serif with an italic word ("Last *dictation*"), Native's bold title; an
/// optional link on the right.
struct HomeSectionHeading: View {
    var title: String
    var italic: String? = nil
    var link: String? = nil
    var onLink: () -> Void = {}
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 22
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            NativeListHeader(title: nativeTitle, action: link, onAction: onLink)
        } else {
            HStack(alignment: .firstTextBaseline) {
                (Text(title.isEmpty ? "" : title + " ") + Text(italic ?? "").italic())
                    .lookSerif(size).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let link {
                    Button(link, action: onLink)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.lookAccentText)
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

extension HomeSectionHeading {
    /// One upright title in Native: "Last dictation", "Projects".
    fileprivate var nativeTitle: String {
        guard let italic else { return title }
        if title.isEmpty { return italic.prefix(1).uppercased() + String(italic.dropFirst()) }
        return title + " " + italic
    }
}

/// A slim card for a Compact section: Verbose style's paper with an ink outline, Native's soft card.
private struct HomeStrip: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.isNative {
            content.padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nativeCell(radius: 20)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content.padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .phoneOutlined(radius: Radius.record)
                .contentShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
    }
}

extension View {
    fileprivate func homeStrip() -> some View { modifier(HomeStrip()) }
}

// MARK: - Last dictation

/// The newest dictation with a Copy button. Compact: one row with where it went and its length. Large: the words too,
/// on a butter panel (Verbose style) or a soft card (Native). A tap anywhere copies; the button turns into "Copied".
struct HomeLastDictationSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    var now: Date
    @Environment(\.look) private var look
    @Environment(\.limitMotion) private var limitMotion
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        let last = app.store.memo("phone.last-dictation") { app.store.live.filter(\.isDictation).max { $0.createdAt < $1.createdAt } }
        Group {
            if size == .compact { compact(last) } else { large(last) }
        }
        .accessibilityIdentifier("home.lastDictation")
    }

    private func head(_ t: Transcript) -> String {
        let words = HomeCounts.countLabel(HomeCounts.words(t), "word", "words")
        let when = Calendar.current.isDate(t.createdAt, inSameDayAs: now)
            ? Formats.style(date: .none, time: .short).string(from: t.createdAt) : HomeRecentStyle.day(t.createdAt, now: now)
        if let place = t.flow?.app, !place.isEmpty { return "\(words) in \(place) · \(when)" }
        return "\(words) · \(when)"
    }

    private func compact(_ last: Transcript?) -> some View {
        Button { if let last { copy(last) } else { app.homePath.append(DictationsRoute()) } } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last dictation").lookSerif(look.isNative ? 17 : 19, weight: look.isNative ? .semibold : .regular).foregroundStyle(.lookInk)
                    Text(last.map(head) ?? "Dictate in any app with the Verbose keyboard.")
                        .font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                if last != nil { copyPill }
            }
            .homeStrip()
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(last.map { "Last dictation: \(HomeDictationText.body($0))" } ?? "Last dictation: none yet")
        .accessibilityValue(copied ? "Copied" : last.map(head) ?? "")
        .accessibilityHint(last == nil ? "Opens your dictations." : "Copies the dictation.")
    }

    private func large(_ last: Transcript?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeading(title: "Last", italic: "dictation", link: "All") { app.homePath.append(DictationsRoute()) }
            Button { if let last { copy(last) } else { app.homePath.append(DictationsRoute()) } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if let last {
                        Text(head(last)).lookMono(12).foregroundStyle(look.isNative ? AnyShapeStyle(NativeInk.secondary) : AnyShapeStyle(Ink.inkFixed)).lineLimit(1)
                        Text(HomeDictationText.body(last)).font(.system(size: 16)).lineSpacing(3)
                            .foregroundStyle(look.isNative ? AnyShapeStyle(NativeInk.label) : AnyShapeStyle(Ink.inkFixed))
                            .lineLimit(3).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack { Spacer(minLength: 0); copyPill }
                    } else {
                        Text("Dictate in any app with the Verbose keyboard. What you say shows up here.")
                            .font(.system(size: 15)).foregroundStyle(look.isNative ? AnyShapeStyle(NativeInk.secondary) : AnyShapeStyle(Ink.inkFixed))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { panel }
                .contentShape(RoundedRectangle(cornerRadius: look.isNative ? 22 : Radius.record, style: .continuous))
            }
            .buttonStyle(PhoneCardPress())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(last.map { HomeDictationText.body($0) } ?? "No dictations yet")
            .accessibilityValue(copied ? "Copied" : last.map(head) ?? "")
            .accessibilityHint(last == nil ? "Opens your dictations." : "Copies the dictation.")
        }
    }

    @ViewBuilder private var panel: some View {
        if look.isNative {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(NativeInk.card)
        } else {
            let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
            PhonePanelFill(color: PhoneInk.butter, shape: shape).overlay(shape.strokeBorder(Ink.inkFixed, lineWidth: 1.5))
        }
    }

    /// "Copy", then "Copied" for 1.6 s.
    private var copyPill: some View {
        Text(copied ? "Copied" : "Copy")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(look.isNative ? NativeInk.accent : Ink.inkFixed)
            .padding(.horizontal, 14).frame(minHeight: 32)
            .background {
                if look.isNative { Capsule().fill(NativeInk.fill) }
                else { Capsule().fill(Ink.readerFixed.opacity(0.7)).overlay(Capsule().strokeBorder(Ink.inkFixed, lineWidth: 1.2)) }
            }
            .contentTransition(.opacity)
            .accessibilityHidden(true)
    }

    private func copy(_ t: Transcript) {
        HomeScreen.copyDictation(HomeDictationText.pasted(t))
        Haptics.play(.copied)
        copies += 1
        let token = copies
        withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = true }
        HomeAnnounce.say("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copies == token else { return }
            withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = false }
        }
    }
}

// MARK: - Projects

/// Each project with how many recordings it holds. Compact: a row of chips. Large: a card with a row per project
/// (the first five). A tap opens the Library on that project.
struct HomeProjectsSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    @Environment(\.look) private var look

    var body: some View {
        let counts = app.store.memo("phone.project-counts") { () -> [UUID: Int] in
            var counts: [UUID: Int] = [:]
            for t in app.store.live where !t.isDictation { if let p = t.projectId { counts[p, default: 0] += 1 } }
            return counts
        }
        let projects = app.store.projects
        return Group {
            if size == .compact { compact(projects, counts) } else { large(projects, counts) }
        }
    }

    private func open(_ p: Project) { app.go(.library, filter: "project:\(p.id.uuidString)") }

    private func compact(_ projects: [Project], _ counts: [UUID: Int]) -> some View {
        Group {
            if projects.isEmpty {
                Button { app.go(.library) } label: {
                    Text("Projects group recordings. Make one in the Library.").font(.system(size: 14)).foregroundStyle(.lookDim).homeStrip()
                }
                .buttonStyle(PhoneCardPress())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(projects) { p in
                            Button { open(p) } label: { chip(p.name, counts[p.id] ?? 0) }
                                .buttonStyle(PhoneCardPress())
                                .accessibilityLabel("\(p.name), \(HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings"))")
                                .accessibilityHint("Opens the project in your library.")
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private func chip(_ name: String, _ n: Int) -> some View {
        HStack(spacing: 7) {
            if !look.isNative { IconGlyph(art: .iconProject, size: 15, color: Ink.ink) }
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
            Text(n.formatted()).lookMono(12).foregroundStyle(.lookMute)
        }
        .padding(.horizontal, 14).frame(minHeight: 40)
        .background {
            if look.isNative { Capsule().fill(NativeInk.fill) }
            else { Capsule().fill(Ink.card).overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5)) }
        }
    }

    private func large(_ projects: [Project], _ counts: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeading(title: "", italic: "Projects", link: "Library") { app.go(.library) }
            VStack(spacing: 0) {
                if projects.isEmpty {
                    Text("Projects group recordings. Make one in the Library.").font(.system(size: 15)).foregroundStyle(.lookDim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                ForEach(Array(projects.prefix(5).enumerated()), id: \.element.id) { i, p in
                    Button { open(p) } label: {
                        HStack(spacing: 12) {
                            if !look.isNative { IconGlyph(art: .iconProject, size: 18, color: Ink.ink) }
                            Text(p.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings")).font(.system(size: 14)).foregroundStyle(.lookMute)
                        }
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityHint("Opens the project in your library.")
                    if i < min(projects.count, 5) - 1 { Rectangle().fill(.lookHairline).frame(height: look.isNative ? 0.5 : 1) }
                }
            }
            .homeStrip()
        }
    }
}

// MARK: - Moments

/// The newest saved moment. Large: the moment card from Moments. Compact: one line of it with its recording and time.
/// A tap opens the transcript at that line.
struct HomeMomentsSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    @Environment(\.look) private var look

    var body: some View {
        let latest = app.store.memo("phone.latest-moment") { () -> (t: Transcript, n: Note)? in
            var latest: (t: Transcript, n: Note)?
            for t in app.store.live {
                for n in t.notes where n.at != nil && (latest == nil || n.createdAt > latest!.n.createdAt) { latest = (t, n) }
            }
            return latest
        }
        return Group {
            if size == .compact { compact(latest) } else { large(latest) }
        }
    }

    private func open(_ t: Transcript, _ n: Note) {
        app.open(t.id, segment: n.segmentId ?? t.segments.last { $0.start <= (n.at ?? 0) }?.id)
    }

    private func compact(_ latest: (t: Transcript, n: Note)?) -> some View {
        Button { if let latest { open(latest.t, latest.n) } else { app.go(.moments) } } label: {
            HStack(spacing: 12) {
                if !look.isNative { IconGlyph(art: .iconMoments, size: 20, color: Ink.ink) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(latest.map { $0.n.isBookmark ? "“\(Marks.words($0.n, in: $0.t.segments))”" : $0.n.text } ?? "Bookmark a moment while a transcript plays.")
                        .lookSerif(look.isNative ? 16 : 18, weight: look.isNative ? .semibold : .regular)
                        .italic(!look.isNative && latest?.n.isBookmark == true)
                        .foregroundStyle(.lookInk).lineLimit(1)
                    if let latest {
                        Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .homeStrip()
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
    }

    private func large(_ latest: (t: Transcript, n: Note)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeading(title: "Saved", italic: "moments", link: "All") { app.go(.moments) }
            if let latest {
                Button { open(latest.t, latest.n) } label: { PhoneMomentCard(transcript: latest.t, note: latest.n) }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityHint("Opens the transcript at this moment.")
            } else {
                Text("Bookmark a moment while a transcript plays, or touch and hold a line.")
                    .font(.system(size: 15)).foregroundStyle(.lookDim).homeStrip()
            }
        }
    }
}

// MARK: - Today's thoughts

/// Today's thoughts. Large: the latest four under "Today's thoughts", each with its time in mono, then New thought.
/// Compact: one row with the count and the latest, and New thought beside it. A tap opens today's page (the Thoughts
/// tab, or Library › By day); New thought opens the recorder on a thought. Thoughts are a kind, so the section is ink in
/// Verbose style, and New thought is a line pill, never a second persimmon fill beside Record (DESIGN.md §1.3, §14.1).
struct HomeThoughtsSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    @Environment(\.look) private var look

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
                    if !look.isNative { IconGlyph(art: .iconThought, size: 20, color: Ink.ink) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HomeThoughts.countLine(page.count)).lookSerif(look.isNative ? 17 : 19, weight: look.isNative ? .semibold : .regular)
                            .foregroundStyle(.lookInk).lineLimit(1)
                        Text(page.last.map(words) ?? "Tap New thought to start today's page.")
                            .font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PhoneCardPress())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens today's Thoughts page.")
            newThought(compact: true)
        }
        .homeStrip()
    }

    private func large(_ page: [Transcript]) -> some View {
        let shown = HomeThoughts.latest(page)
        return VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeading(title: "Today's", italic: "thoughts", link: "Today's page") { app.openThoughtPage() }
            Button { app.openThoughtPage() } label: {
                VStack(spacing: 0) {
                    if shown.isEmpty {
                        Text("Nothing yet today. A thought is one tap away.").font(.system(size: 15)).foregroundStyle(.lookDim)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(look.isNative ? ThoughtText.time(t.createdAt, native: true) : ThoughtText.compactTime(t.createdAt))
                                .font(look.isNative ? .system(size: 14).monospacedDigit() : Ink.mono(12))
                                .foregroundStyle(.lookMute)
                                .lineLimit(1).fixedSize()
                                .frame(minWidth: look.isNative ? 70 : 52, alignment: .leading)
                            Text(words(t)).font(.system(size: 15)).foregroundStyle(t.status == .ready ? LookStyle.lookInk : LookStyle.lookDim)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        if i < shown.count - 1 { Rectangle().fill(.lookHairline).frame(height: look.isNative ? 0.5 : 1) }
                    }
                }
                .homeStrip()
            }
            .buttonStyle(PhoneCardPress())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(shown.isEmpty ? "No thoughts yet today" : HomeThoughts.countLine(page.count))
            .accessibilityHint("Opens today's Thoughts page.")
            HStack {
                newThought(compact: false)
                Spacer(minLength: 0)
                if page.count > shown.count {
                    Text("\(page.count) today").font(look.isNative ? .system(size: 14).monospacedDigit() : Ink.mono(12)).foregroundStyle(.lookMute)
                }
            }
        }
    }

    /// New thought: a line pill with the bulb in Verbose style; the accent's soft capsule in Native. In the compact row
    /// it's the bulb alone in a 34 pt circle in both looks, so the count beside it never cuts off (review P-18).
    private func newThought(compact: Bool) -> some View {
        Button { HomeTileAction.startThought(app) } label: {
            HStack(spacing: 7) {
                if look.isNative {
                    Image(systemName: "lightbulb").font(.system(size: 14, weight: .semibold))   // brand: native
                } else {
                    IconGlyph(art: .iconThought, size: 16, color: Ink.ink)
                }
                if !compact { Text("New thought").font(.system(size: 14, weight: .semibold)) }
            }
            .foregroundStyle(look.isNative ? NativeInk.accent : Ink.ink)
            .padding(.horizontal, compact ? 0 : 14).frame(minWidth: 34, minHeight: 34)
            .background {
                if look.isNative { Capsule().fill(NativeInk.fill) }
                else { Capsule().fill(Ink.card).overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityLabel("New thought")
        .accessibilityHint("Records a thought for today's page.")
        .accessibilityIdentifier("home.thoughts.new")
    }
}

// MARK: - Journal

/// Journal. Large: the newest entry under "Journal" (the date, its title, the first line, and a play pill with the
/// length) over this week's days as dots. Compact: one row with the newest title and the dots. A tap opens Journal By
/// day (the Journal tab, or inside Library); the play pill opens the entry playing.
struct HomeJournalSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    var now: Date
    @Environment(\.look) private var look

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
                if !look.isNative { IconGlyph(art: .iconNotes, size: 20, color: Ink.ink) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Journal").lookSerif(look.isNative ? 17 : 19, weight: look.isNative ? .semibold : .regular).foregroundStyle(.lookInk)
                    Text(latest?.title ?? "No entries yet").font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                HomeJournalDots(week: week, size: 8)
            }
            .homeStrip()
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journal: \(latest?.title ?? "no entries yet")")
        .accessibilityValue(HomeJournalWeek.countLine(week))
        .accessibilityHint("Opens your journal, by day.")
    }

    private func large(_ latest: Transcript?, _ week: [HomeJournalWeek.Day]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeading(title: "", italic: "Journal", link: "By day") { app.go(.journal) }
            VStack(alignment: .leading, spacing: 12) {
                Button { app.go(.journal) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let t = latest {
                            Text(HomeRecentStyle.day(t.createdAt, now: now)).font(look.isNative ? .system(size: 14) : Ink.mono(12)).foregroundStyle(.lookMute)
                            title(t)
                            let first = ThoughtText.words(t)
                            if !first.isEmpty {
                                Text(first).font(.system(size: 14)).foregroundStyle(.lookDim).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        } else {
                            Text("Record with the Journal kind, and your newest entry shows here.")
                                .font(.system(size: 15)).foregroundStyle(.lookDim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PhoneCardPress())
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens your journal, by day.")
                HStack(spacing: 12) {
                    if let t = latest, t.status == .ready, t.audioFileName != nil, t.duration > 0 { play(t) }
                    Spacer(minLength: 8)
                    HomeJournalDots(week: week, size: 9, letters: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("This week: \(HomeJournalWeek.countLine(week))")
                }
            }
            .homeStrip()
        }
    }

    @ViewBuilder private func title(_ t: Transcript) -> some View {
        let words = t.title.split(separator: " ")
        if look.isNative || words.count < 2 {
            Text(t.title).lookSerif(look.isNative ? 17 : 20, weight: look.isNative ? .semibold : .regular).foregroundStyle(.lookInk).lineLimit(2)
        } else {
            (Text(words.dropLast().joined(separator: " ") + " ") + Text(String(words.last ?? "")).italic())
                .lookSerif(20).foregroundStyle(.lookInk).lineLimit(2)
        }
    }

    /// The play pill: opens the entry playing.
    private func play(_ t: Transcript) -> some View {
        Button { app.autoplay = t.id; app.open(t.id) } label: {
            HStack(spacing: 7) {
                if look.isNative {
                    Image(systemName: "play.fill").font(.system(size: 12))   // brand: native
                } else {
                    ArtIcon(art: .iconPlay, size: 11, lineWidth: 1.4)
                }
                Text(HomeRecentStyle.length(t.duration)).font(look.isNative ? .system(size: 15, weight: .semibold).monospacedDigit() : Ink.mono(12))
            }
            .foregroundStyle(.lookInk)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background {
                if look.isNative { Capsule().fill(NativeInk.fill) }
                else { Capsule().strokeBorder(Ink.ink, lineWidth: 1.5) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
        .accessibilityHint("Opens the entry and plays it.")
    }
}

/// This week's seven days as dots: filled where there's a journal entry, today ringed. Ink in Verbose style, the
/// accent in Native (DESIGN.md §14.6). Optional weekday letters under them.
struct HomeJournalDots: View {
    var week: [HomeJournalWeek.Day]
    var size: CGFloat
    var letters = false
    @Environment(\.look) private var look

    var body: some View {
        let color = look.isNative ? NativeInk.accent : Ink.ink
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(spacing: size * 0.8) {
            ForEach(week, id: \.start) { d in
                VStack(spacing: 4) {
                    Circle().fill(d.hasEntry ? color : Color.clear)
                        .overlay(Circle().strokeBorder(color.opacity(d.hasEntry ? 1 : (d.isFuture ? 0.25 : 0.5)), lineWidth: d.isToday ? 1.6 : 1))
                        .frame(width: size, height: size)
                    if letters {
                        Text(symbols[(Calendar.current.component(.weekday, from: d.start) - 1) % symbols.count])
                            .font(look.isNative ? .system(size: 11, weight: d.isToday ? .bold : .regular) : Ink.mono(12))
                            .foregroundStyle(.lookMute)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Queue

/// What's transcribing (Home draws Queue only while something is). Compact: the first one, and how many more.
/// Large: up to three, each with where it is. A tap opens the transcript.
struct HomeQueueSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    @Environment(\.look) private var look

    static func working(_ app: PhoneState) -> [Transcript] {
        app.store.memo("phone.working") { app.store.live.filter { $0.status == .processing }.sorted { $0.createdAt < $1.createdAt } }
    }

    var body: some View {
        let items = Self.working(app)
        return Group {
            if size == .compact, let first = items.first {
                Button { app.open(first.id) } label: {
                    row(first, more: items.count - 1).homeStrip()
                }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Opens the transcript.")
            } else if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HomeSectionHeading(title: "", italic: "Queue", link: items.count > 3 ? "All" : nil) {
                        app.go(.library, filter: "working")
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { i, t in
                            Button { app.open(t.id) } label: { row(t, more: 0).frame(minHeight: 48).contentShape(Rectangle()) }
                                .buttonStyle(PhoneCardPress())
                                .accessibilityHint("Opens the transcript.")
                            if i < min(items.count, 3) - 1 { Rectangle().fill(.lookHairline).frame(height: look.isNative ? 0.5 : 1) }
                        }
                    }
                    .homeStrip()
                }
            }
        }
    }

    private func row(_ t: Transcript, more: Int) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(look.isNative ? NativeInk.accent : Ink.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                LiveStage(t) { t in
                    Text(more > 0 ? "\(t.stageText) · \(more.formatted()) more" : t.stageText).font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Edit Home button

/// The last thing on Home: opens Edit Home. Verbose style: an outlined capsule; Native: a gray capsule with the grid.
struct EditHomeButton: View {
    var action: () -> Void
    @Environment(\.look) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if look.isNative {
                    Image(systemName: "square.grid.2x2").font(.system(size: 15, weight: .medium))   // brand: native
                } else {
                    Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .semibold))
                }
                Text("Edit Home").font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.lookInk)
            .padding(.horizontal, 20).frame(minHeight: 44)
            .background {
                if look.isNative { Capsule().fill(NativeInk.fill) }
                else { Capsule().strokeBorder(Ink.ink, lineWidth: 1.5) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PhoneCardPress())
        .frame(maxWidth: .infinity)
        .accessibilityHint("Show, hide, reorder, and resize Home's sections, and choose its four tiles.")
        .accessibilityIdentifier("home.edit")
    }
}
