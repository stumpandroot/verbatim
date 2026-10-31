import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import CoreAudio

/// Home in the refined look (DESIGN.md §6 and §13; mockup "Verbose Refined Look", MacHome and MacRecorder): the date
/// over the large serif greeting, then the sections Edit Home lists (HomeLayout.swift), in its order and sizes. By
/// default: the persimmon Record card across the column (a click records a voice note, ⌥⇧R from anywhere;
/// right-click for Record As and the microphone), the four tiles in a row with their shortcuts, then Recent recordings
/// in a card beside This week. While you record, the Record card turns into the recording card (the clock, the live
/// waveform, your words, Mark moment, Pause, and Stop and transcribe). Today's thoughts, Journal, and a kind's newest
/// three (Recent meetings, …) when you show them.
/// One column, at most 860 pt wide; two Large neighbors that can pair share a band (two thirds and one third), and a
/// narrow window stacks them. Edit Home's button closes the page; editing outlines each section and opens the inspector on the right (EditHome.swift). Sections arrive at once and keep their identity when the layout
/// changes.
struct HomeView: View {
    /// Ticks `now` once a minute: one timer for every render. Built in `body`, each render made a new timer and
    /// restarted the minute, so under frequent renders (transcribing, playing, dictating) it never fired.
    private static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @EnvironmentObject var app: AppState
    @ObservedObject var log = ActivityLog.shared
    @ObservedObject var captions = LiveCaptions.shared
    @ObservedObject var flow = FlowSettings.shared
    /// Edit Home's layout and whether Home is being edited.
    @ObservedObject var layouts = HomeLayoutStore.shared
    @ObservedObject var edit = HomeEditSession.shared
    @ObservedObject private var recordAs = RecordAsStore.shared
    @AppStorage(YouProfile.nameKey) var storedName = ""
    /// The microphone's name, looked up off the main thread and kept current by Core Audio's notifications. (Looking
    /// it up here, in a `@State` initial value and on every UserDefaults change, ran a full device scan on the main
    /// thread each time Home's parent re-rendered.)
    @ObservedObject var mics = HomeMic.shared
    /// Moves on each minute, so the greeting and today's numbers follow the clock.
    @State var now = Date()
    @State var importOpen = false
    @State var fileOver = false

    /// The gutter between tiles and between two sections in a band.
    static let gap: CGFloat = 12
    /// The widest Home's column gets (the mockup's 860).
    static let maxContent: CGFloat = 860
    /// Edit Home's inspector beside Home while editing.
    static let inspectorWidth: CGFloat = 320
    /// The side margin: the mockup's 56, narrower in a narrow window.
    static func margin(_ available: CGFloat) -> CGFloat { available < 760 ? 32 : 56 }
    /// The column's width for a scroll view `available` points wide.
    static func contentWidth(_ available: CGFloat) -> CGFloat { min(maxContent, max(280, available - 2 * margin(available))) }
    /// Wide enough for two sections side by side.
    static func wide(_ width: CGFloat) -> Bool { width >= 560 }
    /// A band of two: two thirds and one third of the column, with `gap` between (the mockup's 2fr / 1fr).
    static func columns(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let left = ((total - gap) * 2 / 3).rounded(.down)
        return (left, total - gap - left)
    }

    var body: some View {
        NavMarks.mark("home")
        return HStack(spacing: 0) {
            column.frame(maxWidth: .infinity)
            if edit.editing {
                EditHomeView(onDone: { edit.editing = false })
                    .frame(width: Self.inspectorWidth)
                    .padding(.vertical, 16).padding(.trailing, 16)
            }
        }
        .background(Refined.paper)
        .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
        .onChange(of: app.focusLink) { _, _ in importOpen = true }
        .onAppear { NavMarks.mark("home-appear"); mics.refresh() }
        // Only when editing: a write publishes even when nothing changes, so it re-rendered Home (and Settings' Edit
        // Home list) again.
        .onDisappear { if edit.editing { edit.editing = false } }
        .onReceive(Self.minute) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in mics.refresh(); now = Date() }
    }

    private var column: some View {
        // A GeometryReader takes exactly the space the window offers and passes it down, so Home's width comes
        // from the window. (Measuring the scroll view or the content was circular: both report the content's
        // own width back, so Home either kept a too-wide layout or grew past the detail area.) The width is worked
        // out in the body, never stored: a stored width laid Home out twice on every visit (900 pt, then the real one).
        GeometryReader { geo in
            let _ = NavMarks.mark("home-grid")
            let width = Self.contentWidth(geo.size.width)
            let layout = layouts.layout
            let rows = HomeRows.rows(layout.shown, wide: Self.wide(width))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LargeSerifTitle(title: greeting, eyebrow: HomeGreeting.dateLine(now))
                        .background { popoverAnchors(layout) }
                    // After an update: "What's new in build N", once (WhatsNewPane.swift).
                    WhatsNewHomeLine(top: 16) { app.dictation.openSettings(tab: .whatsNew) }
                    // Recording with the Record card hidden: the recording card leads Home all the same.
                    if recording && !layout.isVisible(.record) { HomeRecordingCard().padding(.top, 18) }
                    // Only the shown sections, each band identified by its first section.
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        band(row, width: width, layout: layout)
                            .padding(.top, Self.rowGap(row, after: i > 0 ? rows[i - 1] : nil))
                    }
                    editHomeButton.padding(.top, 32)
                }
                .navMarkWhenLaidOut("home-laid-out")
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, Self.margin(geo.size.width)).padding(.top, 18).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Back and Forward bring Home back where you left it; the sidebar opens it at the top (App/NavTrail.swift).
                .scrollPlace(ScreenPlaces.scrollKey("home"), restore: NavTrail.shared.movingThroughHistory)
            }
            // The greeting fades under the toolbar's glass instead of running into it (review M-05).
            .softScrollEdges(.top)
        }
    }

    // MARK: Layout

    /// The gap above a band: 20 under the greeting, the mockup's 16 between cards, 22 above a titled section.
    static func rowGap(_ row: HomeRow, after previous: HomeRow?) -> CGFloat {
        guard previous != nil else { return 20 }
        return row.items.contains(where: \.headed) ? 22 : 16
    }

    /// A band: one section across the column, or two side by side at the same height.
    @ViewBuilder private func band(_ row: HomeRow, width: CGFloat, layout: HomeLayout) -> some View {
        if row.items.count == 2 {
            let cols = Self.columns(width)
            HStack(alignment: .top, spacing: Self.gap) {
                section(row.items[0], layout: layout).frame(width: cols.0).frame(maxHeight: .infinity, alignment: .top)
                section(row.items[1], layout: layout).frame(width: cols.1).frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            section(row.items[0], layout: layout)
        }
    }

    private func section(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        content(item, layout: layout)
            .homeEditFrame(item, editing: edit.editing)
            .homeProbe(item)
    }

    @ViewBuilder private func content(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        switch item.section {
        case .record: if recording { HomeRecordingCard() } else { recordCard(compact: item.size == .compact) }
        case .tiles: tiles(layout.tiles, compact: item.size == .compact)
        case .week: weekCard(large: item.size == .large)
        case .recent: recentCard(item.size)
        case .thoughts: HomeThoughtsMac(size: item.size)
        case .journal: HomeJournalMac(size: item.size)
        case .meetings, .interviews, .talks, .brainDumps, .audioOnly: kindCard(item)
        }
    }

    /// The last thing on Home: Edit Home, which outlines the sections and opens the inspector. While the inspector is
    /// open its Done is the one way to stop editing, so this button steps aside (keeping its place, so Home doesn't move).
    var editHomeButton: some View {
        HStack {
            Spacer(minLength: 0)
            Button { edit.editing = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold))
                    Text("Edit Home")
                }
            }
            .buttonStyle(RefinedActionStyle())
            .help("Show, hide, reorder, and resize Home's sections, and choose its four tiles.")
            .uiTarget("home-edit")
            .opacity(edit.editing ? 0 : 1)
            .allowsHitTesting(!edit.editing)
            .accessibilityHidden(edit.editing)
            Spacer(minLength: 0)
        }
    }

    /// Where the Dictate and Import panels open when their tiles aren't on Home (File › Import… and New Transcript, and
    /// Dictate, still open them): an anchor under the greeting. With the tile on Home, the tile is the anchor.
    @ViewBuilder func popoverAnchors(_ layout: HomeLayout) -> some View {
        let shown = layout.isVisible(.tiles) ? layout.tiles : []
        Color.clear
            .popover(isPresented: shown.contains(.dictate) ? .constant(false) : dictateOpen, arrowEdge: .bottom) {
                DictateControls().padding(16).environmentObject(app)
            }
            .background {
                Color.clear
                    .popover(isPresented: shown.contains(.importMedia) ? .constant(false) : $importOpen, arrowEdge: .bottom) {
                        ImportPanel(done: { importOpen = false }).environmentObject(app)
                    }
            }
    }

    // MARK: Header

    var greeting: String {
        HomeGreeting.line(name: HomeGreeting.firstName(YouProfile.displayName(storedName)), hour: Calendar.current.component(.hour, from: now))
    }

    // MARK: Record

    var recording: Bool { app.recorder.isRecording || app.capture.isCapturing }
    var micName: String { mics.device?.name ?? "Microphone" }

    var recordStatus: String {
        if app.savingRecording { return "Saving…" }
        return "Ready · \(micName)"
    }

    /// The Record card: a click records a voice note; right-click has Record As's ways and the microphone. VoiceOver
    /// reads one button with each way to record as an action.
    private func recordCard(compact: Bool) -> some View {
        RecordCard(status: recordStatus, hint: "Click for a voice note, right-click for a meeting, a thought, and more · ⌥⇧R",
                   accessibilityHint: "Starts a voice note. Shortcut: Option Shift R. Right-click for more ways to record.",
                   compact: compact,
                   actions: recordAs.visible.map { c in RecordCardAction(name: c.actionName) { app.startRecordChoice(c) } }) {
            app.requestRecord()
        }
        .contextMenu { RecordMenu(onChange: { mics.refresh() }) }
        .help("Recording from \(micName). Right-click for more ways to record, or to change the microphone.")
        .uiTarget("tile-record")
    }

    // MARK: Tiles

    var dictateOpen: Binding<Bool> {
        Binding(get: { app.captureMode == "dictate" && !recording },
                set: { open in if !open && app.captureMode == "dictate" { app.captureMode = "voice" } })
    }

    /// "hold right ⌘" → ("Talk into any app", "right ⌘"): what it does, and the key.
    var dictateKey: (String, String?) {
        guard app.dictation.accessibilityTrusted else { return ("Needs Accessibility", nil) }
        let title = app.dictation.hotkey.shortTitle
        if title.hasPrefix("hold right ") { return ("Talk into any app", "right " + title.dropFirst("hold right ".count)) }
        if title.hasPrefix("hold ") { return ("Talk into any app", String(title.dropFirst("hold ".count))) }
        return (title.prefix(1).uppercased() + title.dropFirst(), nil)
    }

    /// What a tile does on the Mac.
    func runTile(_ t: HomeTile) {
        switch t {
        case .dictate: app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate"
        case .importMedia: importOpen = true
        case .appAudio: app.pickApp()
        case .captions: app.toggleLiveCaptions()
        case .thoughtPad: ThoughtPadController.shared.toggle()
        case .dictations: app.go(.dictations)
        case .dictionary: app.go(.dictionary)
        case .projects: app.projectFilter = nil; app.go(.library)
        case .newThought: ThoughtCapture.shared.toggle()
        case .journal: HomeDayPages.openJournal(app)
        case .brainDump: DayNote.open()
        // A kind's tile starts that kind, as File › Record As does (Meeting is the meeting capture, consent sheet first).
        case .meeting, .interview, .talk, .audioOnly:
            if let k = t.kindRaw.flatMap(RecordingKind.init(rawValue:)) { app.startRecordChoice(.kind(k)) }
        case .whatsPlaying: break
        }
    }

    /// The tile's second line, live where it can be (Dictate's key, a file over Import, captions on screen): read by
    /// VoiceOver as the tile's value.
    func tileDetail(_ t: HomeTile) -> String {
        switch t {
        case .dictate: return dictateKey.0
        case .importMedia: return fileOver ? "Drop to transcribe" : t.detail
        case .captions: return captions.isOpen ? "On screen now" : t.detail
        default: return t.detail
        }
    }

    /// What sits with a tile's name: its shortcut, or a state ("Needs Accessibility", "Drop to transcribe", "On screen
    /// now"), which takes its own line under the name and speaks as a state (`RefinedRules.TileTrailing`).
    func tileTrailing(_ t: HomeTile) -> RefinedRules.TileTrailing? {
        switch t {
        case .dictate:
            guard app.dictation.accessibilityTrusted else {
                return .state("Needs Accessibility", spoken: "Needs Accessibility access. Opens the setup.")
            }
            return dictateKey.1.map { .shortcut("\($0) hold") }
        case .importMedia:
            return fileOver ? .state("Drop to transcribe", spoken: "Drop the file to transcribe it.") : .shortcut("⌘O")
        case .captions:
            return captions.isOpen ? .state("On screen now", spoken: "Live captions are on screen.") : .shortcut("⌥⌘C")
        case .newThought: return .shortcut(Thoughts.hotkey)
        default: return nil
        }
    }

    /// The tile's VoiceOver hint: what a state means while there is one ("Needs Accessibility access. Opens the
    /// setup."), else what the tile does.
    static func tileHint(_ t: HomeTile, _ trailing: RefinedRules.TileTrailing?) -> String {
        if case .state(_, let spoken)? = trailing { return spoken }
        return tileHint(t)
    }

    static func tileHint(_ t: HomeTile) -> String {
        switch t {
        case .dictate: return "Shows your dictation key and your last dictation."
        case .importMedia: return "Choose files, or paste a link to transcribe."
        case .appAudio: return "Choose an app to record its sound, like a call or a video."
        case .captions: return "Shows captions in a floating panel, from your microphone or an app's sound."
        case .thoughtPad: return "Opens today's Thoughts page as the floating page, for thoughts you speak or type."
        case .dictations: return "Opens every dictation."
        case .dictionary: return "Opens your dictionary."
        case .projects: return "Opens the Library, with your projects in the sidebar."
        case .newThought: return "Records a thought for today's page without leaving Home. Click again to stop."
        case .journal: return "Opens Journal by day."
        case .brainDump: return "Opens today's note. Hold your dictation keys and talk, then plan your day."
        case .meeting: return "Records a meeting, filed as a Meeting. The consent sheet comes first."
        case .interview: return "Records an interview, with every voice kept."
        case .talk: return "Records a talk, with every voice kept."
        case .audioOnly: return "Records the sound only, with no transcript."
        case .whatsPlaying: return ""
        }
    }

    /// The self-test's click target for a tile (the four from before Edit Home keep their names).
    static func tileTarget(_ t: HomeTile) -> String {
        switch t {
        case .dictate: return "mode-dictate"
        case .importMedia: return "tile-import"
        case .appAudio: return "tile-app"
        case .captions: return "tile-captions"
        default: return "tile-\(t.rawValue)"
        }
    }

    /// The four tiles you picked, in one row: Large 84 pt with the glyph, Compact 58 pt with the name alone.
    private func tiles(_ picks: [HomeTile], compact: Bool) -> some View {
        let hues = HomeTile.refinedHues(picks)
        return HStack(alignment: .top, spacing: Self.gap) {
            ForEach(HomeTileSlot.slots(picks, 0..<HomeLayout.tileCount), id: \.tile) { s in
                tile(s.tile, hue: hues[s.slot], compact: compact, importAnchor: picks.contains(.importMedia) && s.tile == .importMedia)
            }
        }
    }

    @ViewBuilder private func tile(_ t: HomeTile, hue: RefinedHue, compact: Bool, importAnchor: Bool) -> some View {
        let trailing = tileTrailing(t)
        let base = Button { runTile(t) } label: {
            ColorTileFace(title: t.title, art: t.art, hue: hue, pattern: RefinedRules.tilePattern(forTile: t.rawValue), trailing: trailing, compact: compact)
                .overlay {
                    // A file held over Import: the tile says so, with the accent's edge.
                    if t == .importMedia && fileOver {
                        RoundedRectangle(cornerRadius: RefinedPlatform.radius(.tile), style: .continuous)
                            .strokeBorder(Refined.accentText, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(t.title)
        // The detail, then a shortcut's keys; a state is said once, and its hint says what it means.
        .accessibilityValue(trailing?.value(detail: tileDetail(t), spokenKeys: Keycap.spoken) ?? tileDetail(t))
        .accessibilityHint(Self.tileHint(t, trailing))
        switch t {
        case .dictate:
            base.popover(isPresented: dictateOpen, arrowEdge: .bottom) { DictateControls().padding(16).environmentObject(app) }
                .contextMenu { DictateMenu() }
                .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
        case .appAudio:
            base.contextMenu {
                Button("Choose an app…") { app.pickApp() }
                Divider()
                Button("Screen & System Audio Recording settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
        case .importMedia:
            if importAnchor {
                base.popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }).environmentObject(app) }
                    .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                    .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
            } else {
                base.contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                    .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
            }
        default:
            base.uiTarget(Self.tileTarget(t)).homeTileProbe(t)
        }
    }

    // MARK: This week

    /// This week's numbers beyond the words: recordings made, time saved against typing (You's typing speed), and
    /// moments saved this week.
    func weekNumbers(_ week: HomeWeek) -> (recordings: Int, saved: Double, moments: Int) {
        guard let start = week.days.first?.start else { return (0, 0, 0) }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? now
        // One pass over the library, once per library change and week (Store+Memo.swift), not on every render.
        let store = app.store
        let (recordings, moments) = store.memo("week-counts|\(Int(start.timeIntervalSinceReferenceDate))") { () -> (Int, Int) in
            var recordings = 0, moments = 0
            for t in store.transcripts where t.deletedAt == nil {
                if !t.isDictation && t.createdAt >= start && t.createdAt < end { recordings += 1 }
                for n in t.notes where n.at != nil && n.createdAt >= start && n.createdAt < end { moments += 1 }
            }
            return (recordings, moments)
        }
        return (recordings, week.secondsSaved(typingWPM: flow.typingWPM), moments)
    }

    /// This week as one button: a click anywhere opens You. Large is the card (beside Recent recordings by default);
    /// Compact a strip across the column.
    private func weekCard(large: Bool) -> some View {
        let week = log.week(now: now)
        let n = weekNumbers(week)
        let saved = HomeWeek.savedText(n.saved)
        let recordings = HomeCounts.countLabel(n.recordings, "recording", "recordings")
        let savedLine = n.moments > 0 ? "\(saved) saved · \(HomeCounts.countLabel(n.moments, "moment", "moments"))" : "\(saved) saved"
        return Button { app.go(.activity) } label: {
            WeekCard(words: week.words, detail: "\(week.words == 1 ? "word" : "words"), \(recordings)", saved: savedLine,
                     days: week.cardDays, large: large)
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(RefinedPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")), \(recordings), \(saved) saved typing, \(HomeCounts.countLabel(n.moments, "moment", "moments")).")
        .accessibilityHint("Opens You: your week, cleanup, and where you dictate.")
        .accessibilityAddTraits(.isButton)
        .uiTarget("home-week")
    }

    // MARK: Recent

    /// The serif "Recent" with Library, then the newest recordings in a card, one line each: the kind's dot, the
    /// title, the kind and day, and the length. Large lists four, Compact two. A recording with filler words gets Clean
    /// up, which opens its Cleaned tab.
    private func recentCard(_ size: HomeCardSize) -> some View {
        let items = Array(app.archive.prefix(size == .large ? 4 : 2))
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Recent", link: "Library") { app.go(.library) }
                .padding(.horizontal, 16).padding(.top, 2)
            if items.isEmpty && app.search.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Record something new").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text("Recordings and imports land here, ready to review.").refinedFont(.meta).foregroundStyle(Refined.mute)
                    Button("Start recording") { app.requestRecord() }.buttonStyle(RefinedActionStyle()).padding(.top, 6)
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            } else if items.isEmpty {
                Text("Nothing matches “\(app.search)”. Search looks at titles and every transcript's text.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { PaperDivider(leading: 16, trailing: 16) }
                    recentRow(t).uiTarget("row-\(i)")
                }
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .animation(Motion.settle, value: items.map(\.id))
    }

    /// A kind's section (Recent meetings, Recent interviews, Recent talks, Recent brain dumps, Audio only), drawn like
    /// Recent: the serif title with See all, which opens the Library on the kind, then the kind's three newest with
    /// Recent's rows, or one line when there are none yet.
    private func kindCard(_ item: HomeLayout.Item) -> some View {
        let raw = item.section.kindRaw ?? ""
        let store = app.store
        let items = store.memo("home.kind|\(raw)") { () -> [Transcript] in
            Array(store.live.filter { !$0.isDictation && $0.kind?.rawValue == raw }.sorted { $0.createdAt > $1.createdAt }.prefix(3))
        }
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(item.section.title, link: "See all") {
                app.projectFilter = nil
                app.libraryFilter = .all
                app.libraryKind = RecordingKind(rawValue: raw)
                app.go(.library)
            }
            .padding(.horizontal, 16).padding(.top, 2)
            if items.isEmpty {
                Text(item.section.emptyLine).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { PaperDivider(leading: 16, trailing: 16) }
                    recentRow(t)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .uiTarget("home-\(item.section.rawValue)")
    }

    /// A recent recording: the row is the button that opens it; Clean up sits beside it, never inside it (macOS 26
    /// click safety).
    private func recentRow(_ t: Transcript) -> some View {
        let fillers = RowStatus.cachedFillers(t)
        return HStack(spacing: 0) {
            Button { app.go(.transcript(t.id)) } label: {
                // The live progress (StageClock) while it transcribes: only this row re-renders on a tick.
                LiveStage(t) { t in
                    PaperRow(kind: t.refinedKind, title: t.title, meta: Self.recentMeta(t)) {
                        if t.status != .ready { RowLength(text: t.status == .failed ? "Didn't finish" : t.stageText) }
                        else if !RowStatus.isTextOnly(t), t.duration > 0 { RowLength(text: HomeRecentStyle.length(t.duration)) }
                    }
                }
            }
            .buttonStyle(RefinedPress())
            .accessibilityHint("Opens the transcript.")
            if fillers > 0 {
                // A compact accent text action beside the row (RefinedTextActionStyle), never inside its button.
                Button("Clean up") { openCleaned(t) }
                    .buttonStyle(RefinedTextActionStyle())
                    .help("\(HomeCounts.countLabel(fillers, "filler word", "filler words")). Opens the transcript's Cleaned tab.")
                    .accessibilityLabel("Clean up \(t.title)")
                    .padding(.trailing, 12)
            }
        }
        .contextMenu { RowMenu(transcript: t) }
    }

    /// "Meeting · Today", or where it is while it's being made.
    static func recentMeta(_ t: Transcript) -> String {
        let chip = HomeRecentStyle(t).chip
        switch t.status {
        case .processing: return chip
        case .failed: return chip
        case .ready: return "\(chip) · \(HomeRecentStyle.day(t.createdAt))"
        }
    }

    /// Clean up: the transcript on its Cleaned tab, where Clean up runs (the Original stays).
    func openCleaned(_ t: Transcript) {
        app.go(.transcript(t.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .verbatimShowMode, object: "Document") }
    }
}

// MARK: - Recording

/// The Record card while you record or capture an app's audio (mockup: MacRecorder): the persimmon recording card
/// with what's recording and from where, the clock, the live waveform, your words as they're heard, and Mark moment
/// (with its shortcut), Pause, the moments so far, and Stop and transcribe. Starting, the stop button cancels; a muted
/// microphone says so on the card.
struct HomeRecordingCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var marks = MarkCenter.shared
    @ObservedObject private var mics = HomeMic.shared
    @CurrentPalette private var palette: AppPalette

    var body: some View {
        let capturing = app.capture.isCapturing && !app.recorder.isRecording
        let starting = app.recorder.isStarting
        let paused = app.recorder.isPaused && !capturing
        let ink = Refined.onFill(.persimmon, palette)
        RecordingCard(title: title(capturing: capturing, starting: starting, paused: paused), detail: detail(capturing: capturing),
                      live: capturing ? app.capture.live : app.recorder.live, paused: paused) {
            if !capturing {
                if let w = app.recorder.micWarning, !starting, !paused {
                    Text("\(w.title). \(w.detail).").refinedFont(.body, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RecordingCardWords(words: app.recordingWords, ink: ink)
            }
        } controls: {
            if !capturing {
                Button { marks.mark(.macApp) } label: {
                    HStack(spacing: 6) {
                        IconGlyph(art: .iconMark, size: 14, color: ink)
                        Text("Mark moment")
                        Text(MarkHotkeyStore.current().title).fontWeight(.regular)
                    }
                }
                .buttonStyle(RefinedActionStyle(ink: ink, wash: Refined.readyChip(palette)))
                .disabled(starting)
                .help("Mark this moment (\(MarkHotkeyStore.current().title) from any app while you record)")
                .accessibilityLabel("Mark a moment")
                .uiTarget("record-panel-mark")
                Button { app.togglePause() } label: {
                    HStack(spacing: 6) {
                        IconGlyph(art: paused ? .iconPlay : .iconPause, size: 12, color: ink)
                        Text(paused ? "Resume" : "Pause")
                    }
                }
                .buttonStyle(RefinedActionStyle(ink: ink, wash: Refined.readyChip(palette)))
                .disabled(starting)
                if let c = marks.confirmation, !starting {
                    Text(Marks.confirmation(c)).refinedFont(.body).monospacedDigit().lineLimit(1)
                        .uiTarget("record-panel-marked")
                } else if marks.count(.voiceNote) > 0 {
                    Text(Marks.count(marks.count(.voiceNote))).refinedFont(.body).monospacedDigit().lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                if capturing { app.stopCapture() } else { app.stopRecording() }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Refined.recordRed).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(starting ? "Cancel" : capturing ? "Stop" : "Stop and transcribe")
                }
            }
            .buttonStyle(RefinedActionStyle(kind: .strong, ink: ink, light: palette == .full ? Refined.lift : Refined.paper))
            // While the mic is starting, Stop cancels the start.
            .keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .accessibilityLabel(starting ? "Starting the microphone" : paused ? "Recording paused" : capturing ? "Capturing \(app.capture.appName)" : "Recording")
        .uiTarget("home-recording")
    }

    /// "Recording a voice note", "Recording a meeting", "Paused", "Starting…", or "Capturing Zoom".
    private func title(capturing: Bool, starting: Bool, paused: Bool) -> String {
        if capturing { return "Capturing \(app.capture.appName)" }
        if starting { return "Starting…" }
        if paused { return "Paused" }
        return "Recording " + Self.noun(app.recordKind)
    }

    /// "a voice note", "a meeting", "an interview", "a journal entry", "audio only".
    static func noun(_ kind: RecordingKind?) -> String {
        switch kind {
        case nil, .note?: return "a voice note"
        case .interview?: return "an interview"
        case .journal?: return "a journal entry"
        case .idea?: return "a thought"
        case .audio?: return "audio only"
        case let k?: return "a " + k.label.lowercased()
        }
    }

    /// "MacBook Pro microphone · Saved as you go", or the transcript a recording adds to.
    private func detail(capturing: Bool) -> String {
        if capturing { return "Saved as you go" }
        if let id = app.continuing, let t = app.store.transcript(id) { return "Adding to “\(t.title)”" }
        return "\(mics.device?.name ?? "Microphone") · Saved as you go"
    }
}

/// Your words on the recording card as they're heard: the newest two lines in the serif, in the card's ink. Words
/// still changing are in italic rather than lighter, since a lighter ink on the fill falls under 4.5:1. Nothing at all
/// when Show words while you record is off or nothing has been heard.
private struct RecordingCardWords: View {
    @ObservedObject var words: RecordingWords
    var ink: Color
    @AppStorage(RecordingWords.enabledKey) private var showWords = true

    var body: some View {
        let w = words.shown.tail(220)
        if showWords && !w.isEmpty {
            let gap = w.settled.isEmpty || w.volatile.isEmpty ? "" : " "
            (Text(w.settled) + Text(gap) + Text(w.volatile).italic())
                .readingStyle(ink)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Live text")
                .accessibilityValue(w.text)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Microphone name

/// The microphone Home's Record panel names ("Ready · Shure MV7+"). Scanning Core Audio's devices takes a few
/// round trips to the audio server, so it runs on its own queue: once at launch, when the default input or the device
/// list changes (Core Audio's notifications), when the chosen input changes in Settings, and when the app comes back.
@MainActor
final class HomeMic: ObservableObject {
    static let shared = HomeMic()
    @Published private(set) var device: AudioDevices.Device?
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.home-mic", qos: .userInitiated)
    private var running = false
    private var again = false
    private var lastUID: String?
    private var observer: NSObjectProtocol?

    private init() {
        lastUID = AudioDevices.selectedUID
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
        // UserDefaults posts on whichever thread wrote; the main queue delivers it here. Only a changed input choice
        // (one string read) starts a scan.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionMayHaveChanged() }
        }
        refresh()
    }

    /// Looks the device up again off the main thread; publishes only when it changed.
    func refresh() {
        if running { again = true; return }
        running = true
        queue.async { [weak self] in
            let found = AudioDevices.current()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.running = false
                    if self.device != found { self.device = found }
                    if self.again { self.again = false; self.refresh() }
                }
            }
        }
    }

    private func selectionMayHaveChanged() {
        let uid = AudioDevices.selectedUID
        guard uid != lastUID else { return }
        lastUID = uid
        refresh()
    }
}
