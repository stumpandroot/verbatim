import SwiftUI
import AVFoundation

/// Home in the refined look (DESIGN.md §6 and §13; mockup "Verbose Refined Look", Main): the date over the large serif
/// greeting, then the sections Edit Home lists (HomeLayout.swift), in its order and sizes. By default: the persimmon
/// Record card (a tap records a voice note; touch and hold opens Record as), the four tiles in the colors of what they
/// do, a slim This week, and Recent recordings in a card; Today's thoughts and Journal when you show them. It's the
/// same Home in both looks until the look switch goes, each look reading its own layout; the tab bar stays each look's
/// (in Native, Record's tab bar accessory steps aside on Home while the card is there). Edit Home's button closes the
/// page. Whatever you record here shows up on your Mac. Sections arrive at once: no entrance animation, and a layout
/// change re-renders them in place.
struct HomeScreen: View {
    /// Ticks `now` once a minute: one timer for every render. Built in `body`, each render made a new timer and
    /// restarted the minute, so under frequent renders (transcribing, playing, dictating) it never fired.
    private static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @EnvironmentObject var app: PhoneState
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look
    /// Your name for the greeting (the Mac's key); empty means a greeting without a name.
    @AppStorage("profile.name") private var storedName = ""
    @State private var now = Date()
    /// Edit Home's layouts (both looks); Home draws the one for its look.
    @ObservedObject private var layouts = HomeLayoutStore.shared
    /// Edit Home, as a sheet from the button at the end of Home.
    @State private var editingHome = false
    /// The Record card's chip at rest ("Ready · AirPods Pro"), named again on every route change.
    @State private var readyText = RecordingRoute.readyText()
    /// The press on Record (RecordTray.swift): just touched, or held with the Record as tray open.
    @State private var recordPress: RecordPressPhase = .idle
    @ObservedObject private var flow = FlowSettings.shared

    /// The looks Home is on screen in (the self-test checks a look draws the refined Home, and only once).
    static var recordCardsOnScreen = Set<AppLook>()

    var body: some View {
        let layout = layouts.layout
        let drawn = HomeSpacing.drawn(layout)
        return scroller {
            VStack(alignment: .leading, spacing: 0) {
                LargeSerifTitle(title: greeting, eyebrow: HomeGreeting.dateLine(now)).id("home-top")
                // After an update: "What's new in build N", once (WhatsNewScreen.swift).
                WhatsNewBanner(top: 14) { Self.openWhatsNew(app) }
                // Only the shown sections, each keeping its identity (its section) when the layout changes.
                ForEach(Array(drawn.enumerated()), id: \.element.section) { i, item in
                    section(item, tiles: layout.tiles)
                        .padding(.top, HomeSpacing.top(item, after: i > 0 ? drawn[i - 1] : nil))
                        .homeProbe(item)
                }
                EditHomeButton { editingHome = true }.padding(.top, 28)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $editingHome) {
            NavigationStack { EditHomeView(onDone: { editingHome = false }) }
                .environmentObject(app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimEditHome)) { note in
            editingHome = (note.object as? Bool) ?? true
        }
        .onAppear { now = Date(); readyText = RecordingRoute.readyText(); Self.recordCardsOnScreen.insert(look) }
        .onDisappear { Self.recordCardsOnScreen.remove(look) }
        .onChange(of: app.recordingActive) { _, _ in readyText = RecordingRoute.readyText() }
        .onReceive(Self.minute) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { readyText = RecordingRoute.readyText() }
        }
    }

    @ViewBuilder private func section(_ item: HomeLayout.Item, tiles picks: [HomeTile]) -> some View {
        switch item.section {
        case .record: recordCard(compact: item.size == .compact)
        case .tiles: tiles(picks, size: item.size)
        case .week: week(item.size).id("home-week")
        case .recent: recent(item.size).id("home-recent")
        case .thoughts: HomeThoughtsSection(size: item.size).id("home-thoughts")
        case .journal: HomeJournalSection(size: item.size, now: now).id("home-journal")
        }
    }

    /// Recordings, imports, and links made this calendar week (dictations count on their own).
    static func recordingsThisWeek(_ items: [Transcript], now: Date, calendar: Calendar = .current) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return items.filter { !$0.isDictation && week.contains($0.createdAt) }.count
    }

    /// Recordings (not dictations), newest first by when they were made, as the Library sorts them. The store keeps
    /// the order things were added, so a synced or imported older recording would otherwise show as recent (review
    /// P-15). Worked out once per library change.
    static func recentRecordings(_ store: Store) -> [Transcript] {
        store.memo("phone.home.recent") { store.live.filter { !$0.isDictation }.sorted { $0.createdAt > $1.createdAt } }
    }

    /// Whether anything is transcribing. One pass, without copying the library.
    static func working(_ store: Store) -> Bool {
        store.transcripts.contains { $0.deletedAt == nil && $0.status == .processing }
    }

    /// The scroll view, which the screenshot tour scrolls to a section ("home-top", "home-recent").
    private func scroller<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let content = content()
        return ScrollViewReader { proxy in
            ScrollView { content }
                .onReceive(NotificationCenter.default.publisher(for: .verbatimHomeScroll)) { note in
                    guard let id = note.object as? String else { return }
                    withAnimation(limitMotion ? nil : Motion.settle) { proxy.scrollTo(id, anchor: .top) }
                }
        }
    }

    /// The input a recording hears or will hear, by name ("AirPods Pro", "iPhone microphone"). It never opens the
    /// microphone or changes the session (RecordingRoute).
    static func currentMic() -> String { RecordingRoute.currentName() }

    // MARK: Header

    /// "Good evening, Tim." (the date sits above it, in `LargeSerifTitle`).
    private var greeting: String {
        HomeGreeting.line(name: HomeGreeting.firstName(storedName), hour: Calendar.current.component(.hour, from: now))
    }

    /// Your profile, the You page in Settings (YouScreen.swift): This week opens it.
    static func openProfile(_ app: PhoneState) {
        SettingsPage.open("you")
        app.tab = .settings
    }

    /// Home's note after an update opens Settings › What's new.
    static func openWhatsNew(_ app: PhoneState) {
        SettingsPage.open("whatsNew")
        app.tab = .settings
    }

    /// Puts a dictation's words on the clipboard (a Dictations row). The row itself confirms with a check.
    static func copyDictation(_ text: String) {
        UIPasteboard.general.string = text
    }

    // MARK: Record

    /// "Ready · AirPods Pro" (the input a recording will use: RecordingInputRules picks AirPods over the iPhone's
    /// microphone, and the route alone can't say before the first recording), or the recording's state while one
    /// runs (a tap brings the recorder back).
    private var recordStatus: String {
        if app.savingRecording { return "Saving…" }
        if app.recordingActive { return app.recorder.isPaused ? "Paused" : "Recording" }
        return readyText
    }

    /// The Record card (the kit's `RecordCardFace`) under Record's own press: a tap records a voice note (or brings back
    /// the recording that's running), and touch and hold opens the Record as tray. It presses in (0.98), or dims under
    /// Limit animation. VoiceOver reads one button with each way to record as an action.
    private func recordCard(compact: Bool) -> some View {
        let pressed = recordPress != .idle
        let hint = app.recordingActive ? "Tap to open the recorder" : "Tap for a voice note, hold for more"
        return RecordCardFace(status: recordStatus, hint: hint, compact: compact)
            .scaleEffect(pressed && !limitMotion ? 0.98 : 1)
            .opacity(pressed && limitMotion ? 0.8 : 1)
            .animation(limitMotion ? Motion.fade : Motion.press, value: pressed)
            // Touch and hold: the Record as tray (Voice note, Meeting, Thought, Brain dump, Audio only, and the rows you add).
            .recordTrayPress(.card, onPhase: { recordPress = $0 }) { RecordTray.shared.tap() }
            .recordCardAccessibility(app, value: recordStatus, id: compact ? "home.record.compact" : "home.record",
                                     hint: app.recordingActive ? "Opens the recorder." : "Records a voice note. Touch and hold for more ways to record.")
    }

    // MARK: Tiles

    /// The four tiles you picked. Large: two by two. Compact: one row of four. Colors go by what a tile does
    /// (`HomeTile.refinedHues`): Dictate butter, Import sage, What's playing petal, everything else the card, and never
    /// more than three colored.
    @ViewBuilder private func tiles(_ picks: [HomeTile], size: HomeCardSize) -> some View {
        if size == .large {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { tileCells(picks, slots: 0..<2, compact: false) }
                GridRow { tileCells(picks, slots: 2..<4, compact: false) }
            }
        } else {
            HStack(spacing: 8) { tileCells(picks, slots: 0..<4, compact: true) }
        }
    }

    /// One cell per picked tile in `slots`, identified by the tile, so a new pick appears as a new tile.
    private func tileCells(_ picks: [HomeTile], slots: Range<Int>, compact: Bool) -> some View {
        let hues = HomeTile.refinedHues(picks)
        return ForEach(HomeTileSlot.slots(picks, slots), id: \.tile) { s in
            HomeTileButton(tile: s.tile) {
                ColorTileFace(title: s.tile.title, art: s.tile.art, hue: hues[s.slot],
                              pattern: RefinedRules.tilePattern(forTile: s.tile.rawValue), compact: compact)
            }
        }
    }

    /// A picked tile's fill in Verbose style's Edit Home (its capture mode's panel color, or nil for paper with an ink
    /// outline; review P-14). Home itself uses `HomeTile.refinedHues`.
    static func tileFill(_ tile: HomeTile, in picks: [HomeTile]) -> Color? {
        guard let i = picks.firstIndex(of: tile) else { return nil }
        switch HomeTile.hues(picks)[i] {
        case .butter?: return PhoneInk.butter
        case .sage?: return PhoneInk.sage
        case .petal?: return PhoneInk.petal
        case nil: return nil
        }
    }

    // MARK: This week

    /// This week as one button that opens the You page: the words, the recordings, the time saved, and seven bars.
    /// Compact is one line; Large the card.
    private func week(_ size: HomeCardSize) -> some View {
        let week = app.store.dictationWeek(now: now)
        let saved = HomeWeek.savedText(week.secondsSaved(typingWPM: flow.typingWPM))
        let recordings = app.store.memo("recordings-this-week|\(Store.dayKey(now))") { Self.recordingsThisWeek(app.store.live, now: now) }
        let recordingsText = HomeCounts.countLabel(recordings, "recording", "recordings")
        return Button { Self.openProfile(app) } label: {
            WeekCard(words: week.words, detail: "\(week.words == 1 ? "word" : "words"), \(recordingsText)",
                     saved: "\(saved) saved", days: week.cardDays, large: size == .large)
        }
        .buttonStyle(RefinedPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")), \(recordingsText), \(saved) saved typing.")
        .accessibilityHint("Opens your You page, with the whole week.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home.week")
    }

    /// "42s", "18m", "2h 14m" (the You page's numbers).
    static func savedLabel(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    // MARK: Recent

    /// The serif "Recent" with See all, then the three newest in a card. Large: each with its kind's badge and a meta
    /// line; Compact: one line each with the kind's dot. A recording with filler words gets Clean up, which opens its
    /// Cleaned text.
    private func recent(_ size: HomeCardSize) -> some View {
        let items = Array(Self.recentRecordings(app.store).prefix(3))
        let large = size == .large
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Recent", link: "See all") { app.go(.library) }
            if items.isEmpty {
                PaperCard {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Record something new.").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        Text("Recordings and imports land here, and on your Mac.").refinedFont(.meta).foregroundStyle(Refined.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                }
            } else {
                PaperList(items, id: \.id, inset: large ? 60 : 34) { t in recentRow(t, large: large) }
            }
        }
    }

    private func recentRow(_ t: Transcript, large: Bool) -> some View {
        let cleanUp = t.status == .ready && !PhoneRowState.cleaned(t) && app.store.fillerCount(t.id) > 0
        return Button { app.open(t.id) } label: {
            // The live progress (StageClock) in the meta line: a tick re-renders the row, not Home.
            LiveStage(t) { t in
                if large {
                    PaperRow(kind: t.refinedKind, title: PhoneRowTitle.title(t, withTime: false), meta: Self.recentMeta(t, now: now)) {
                        trailing(t, cleanUp: cleanUp)
                    }
                } else {
                    HStack(spacing: 12) {
                        KindBadge(kind: t.refinedKind, size: 8)
                        Text(PhoneRowTitle.title(t, withTime: false)).refinedFont(.rowTitle, weight: .semibold)
                            .foregroundStyle(Refined.ink).lineLimit(1)
                            .alignmentGuide(.rowTitle) { d in d[VerticalAlignment.center] }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        trailing(t, cleanUp: cleanUp)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(RefinedPress())
        // The real Clean up sits on top of the row's button, so it takes its own taps: a compact accent text action
        // at the trailing edge, level with the title, with a 44 pt hit area (RefinedTextActionStyle).
        .overlay(alignment: Alignment(horizontal: .trailing, vertical: .rowTitle)) {
            if cleanUp {
                Button("Clean up") { app.focusSegment = nil; app.homePath.append(DocumentRoute(id: t.id)) }
                    .buttonStyle(RefinedTextActionStyle())
                    .padding(.trailing, 6)
                    .accessibilityLabel("Clean up \(t.title)")
                    .accessibilityHint("Opens the cleaned text without the filler words.")
                    .accessibilityIdentifier("home.recent.cleanup")
            }
        }
        .contextMenu { RowActions(transcript: t) }
        .accessibilityHint("Opens the transcript.")
    }

    /// The length on the right, or where it is while it's being made; room for Clean up when it shows.
    @ViewBuilder private func trailing(_ t: Transcript, cleanUp: Bool) -> some View {
        if cleanUp {
            Text("Clean up").modifier(RefinedTextActionFont()).hidden()
        } else if t.status == .ready {
            if t.duration > 0 { RowLength(text: HomeRecentStyle.length(t.duration)) }
        } else {
            RowLength(text: t.status == .failed ? "Didn't finish" : t.stageText)
        }
    }

    /// "Meeting · Today, 3:39 PM", or where it is while it's being made.
    static func recentMeta(_ t: Transcript, now: Date) -> String {
        let style = HomeRecentStyle(t)
        switch t.status {
        case .processing: return "\(style.chip) · \(t.stageText)"
        case .failed: return "\(style.chip) · Didn't finish"
        case .ready:
            let day = HomeRecentStyle.day(t.createdAt, now: now)
            return "\(style.chip) · \(day), \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
        }
    }
}

extension Notification.Name {
    /// Scrolls Home to a section ("home-top", "home-recent", "home-dictations"); the screenshot tour uses it.
    static let verbatimHomeScroll = Notification.Name("verbatimHomeScroll")
    static let verbatimOpenSettingsPage = Notification.Name("verbatimOpenSettingsPage")
    /// Opens (true) or closes (false) Edit Home over Home; the self-test uses it.
    static let verbatimEditHome = Notification.Name("verbatimEditHome")
}

/// Opens a page inside Settings from elsewhere (Home's This week opens the You page; the keyboard row opens Keyboard).
/// Kept until Settings reads it, because the Settings tab may not exist yet when Home asks.
enum SettingsPage {
    static var pending: String?
    /// The latest page asked for, kept after Settings opens it (for the self-test).
    static var lastRequested: String?
    static func open(_ page: String) {
        pending = page
        lastRequested = page
        NotificationCenter.default.post(name: .verbatimOpenSettingsPage, object: page)
    }
    static func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

/// Opens a transcript straight into its Document view.
struct DocumentRoute: Hashable { let id: UUID }

/// Long-press actions shared by every list.
struct RowActions: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var body: some View {
        Button { app.togglePin(transcript.id) } label: { Label(transcript.pinned ? "Unpin" : "Pin", systemImage: transcript.pinned ? "pin.slash" : "pin") }
        Button { RenameCenter.shared.begin(transcript) } label: { Label("Rename…", systemImage: "pencil") }   // brand: system surface (context menu)
        Menu {
            // One project at a time: choosing another moves it there (the current one has a checkmark).
            ForEach(app.store.projects) { p in
                if transcript.projectId == p.id {
                    Button { } label: { Label(p.name, systemImage: "checkmark") }.disabled(true)
                } else {
                    Button(p.name) { app.addToProject([transcript.id], p.id) }
                }
            }
            if let current = transcript.projectId, let name = app.store.projects.first(where: { $0.id == current })?.name {
                Divider()
                Button { app.move(transcript.id, to: nil); app.say("Removed from \(name)") } label: { Label("Remove from \(name)", systemImage: "folder.badge.minus") }   // brand: system surface (context menu)
            }
            if !app.store.projects.isEmpty { Divider() }
            Button { app.newProjectFor = transcript.id } label: { Label("New project…", systemImage: "folder.badge.plus") }   // brand: system surface (context menu)
        } label: { Label("Add to project", systemImage: "folder.badge.plus") }   // brand: system surface (context menu)
        if AudioOnlyRules.canTranscribe(transcript) {
            // Audio only: Transcribe, or Transcribe as each kind, like Record as (AudioOnly.swift).
            Button { app.transcribeLater(transcript.id) } label: { Label("Transcribe", systemImage: "text.bubble") }   // brand: system surface (context menu)
            Menu {
                ForEach(AudioOnlyRules.transcribeChoices, id: \.self) { k in
                    Button(AudioOnlyRules.choiceName(k)) { app.transcribeLater(transcript.id, as: k) }
                }
            } label: { Label("Transcribe as", systemImage: "text.bubble") }   // brand: system surface (context menu)
        } else if transcript.status == .ready, !transcript.showsAudioDetail { Button { app.copyText(transcript) } label: { Label("Copy text", systemImage: "doc.on.doc") } }   // brand: system surface (context menu)
        if transcript.status == .failed { Button { app.retry(transcript) } label: { Label("Retry", systemImage: "arrow.clockwise") } }   // brand: system surface (context menu)
        if transcript.status == .processing, transcript.processingDevice == Device.id { Button { app.cancel(transcript.id) } label: { Label("Cancel transcription", systemImage: "xmark") } }
        Divider()
        Button(role: .destructive) { app.delete([transcript.id]) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Press: scale 0.97 over 320 ms (a brief dim when motion is limited).
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SoftPress().makeBody(configuration: configuration) }
}

struct LinkSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @FocusState private var focused: Bool
    /// A show or feed link: its episodes, pushed in this sheet.
    @State private var pickFrom: URL?
    @State private var detent: PresentationDetent = .medium
    var body: some View {
        NavigationStack {
            // A scroll view with the field first and the description under it as a footnote: with the keyboard up at
            // the medium detent, nothing slides under the toolbar.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        IconGlyph(art: .iconLinks, size: 18, color: Ink.mute)
                        TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused)
                    }
                    .padding(12)
                    .background(.lookReader, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(.lookHairline))
                    Text("Paste a YouTube, Vimeo, or podcast link, or a link to an audio or video file. Verbose downloads the audio and transcribes it on this iPhone.")
                        .font(.system(size: 13.5)).foregroundStyle(.lookDim)
                        .fixedSize(horizontal: false, vertical: true)
                    PasteButton(payloadType: String.self) { strings in link = strings.first ?? link }
                        .buttonBorderShape(.capsule).labelStyle(.titleAndIcon)
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .phonePage()
            .navigationTitle("Add a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
            .navigationDestination(item: $pickFrom) { u in
                EpisodePicker(link: u, show: nil,
                              onPick: { ep in app.addLink(ep.link); dismiss() },
                              onNotAShow: { app.addLink(u.absoluteString); dismiss() })
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    /// A podcast show or feed opens its episode list; anything else is added as is.
    private func add() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // With Local Only on, the episode list isn't fetched: the link is added and refused like any other.
        if let u = URL(string: trimmed), PhoneLinkFetcher.isShowLink(u), NetworkGate.permits(.linkDownload) {
            focused = false
            detent = .large
            pickFrom = u
        } else {
            app.addLink(link); dismiss()
        }
    }
}
