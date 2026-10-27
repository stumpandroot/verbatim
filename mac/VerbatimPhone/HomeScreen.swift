import SwiftUI
import AVFoundation

/// Home, in the website style (mockup "Verbose iPhone, Website Style", October 23, 2026): the only screen with the
/// big two-line serif greeting, then the sections Edit Home lists (HomeLayout.swift), in its order and sizes. By default:
/// the Record panel (record color, grain, the breathing meter, and the rings that swell gently), four short start tiles
/// (Dictate, Import, What's playing, Live captions; Import's menu pastes a link), a one-line This week card, and the two
/// most recent recordings as flat rows. Edit Home's button closes the page. Whatever you record here shows up on your
/// Mac. Sections arrive at once: no entrance animation, and a layout change re-renders them in place.
struct HomeScreen: View {
    /// Ticks `now` once a minute: one timer for every render. Built in `body`, each render made a new timer and
    /// restarted the minute, so under frequent renders (transcribing, playing, dictating) it never fired.
    private static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @EnvironmentObject var app: PhoneState
    @Environment(\.limitMotion) private var limitMotion
    /// Your name for the greeting (the Mac's key); empty means a greeting without a name.
    @AppStorage("profile.name") private var storedName = ""
    @State private var now = Date()
    /// Edit Home's layouts (both looks); Home draws the one for its look.
    @ObservedObject private var layouts = HomeLayoutStore.shared
    /// Edit Home, as a sheet from the button at the end of Home.
    @State private var editingHome = false
    @State private var micName = HomeScreen.currentMic()
    /// Listens to the mic while a finger is on Record, so the meter shows your real level (DESIGN.md §7).
    @StateObject private var monitor = HomeLevelMonitor()
    /// The press on Record (RecordTray.swift): just touched, or held with the Record as tray open.
    @State private var recordPress: RecordPressPhase = .idle
    @ObservedObject private var flow = FlowSettings.shared
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 36
    @ScaledMetric(relativeTo: .title) private var recordSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var recordLine: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 19
    @ScaledMetric(relativeTo: .title2) private var sectionSize: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var small: CGFloat = 12.5
    @Environment(\.look) private var look

    /// Which Home layout is on screen: Verbose style by its Record panel, Native by Premium's This week card (the
    /// self-test checks each look shows only its own).
    static var recordCardsOnScreen = Set<AppLook>()

    var body: some View {
        // Each look is its own screen with its own navigation bar setup, so nothing is switched in place.
        Group {
            if look.isNative { nativeScreen } else { verboseScreen }
        }
        .tabEntrance(.home) {}
        .phonePage()
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $editingHome) {
            NavigationStack { EditHomeView(onDone: { editingHome = false }) }
                .environmentObject(app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimEditHome)) { note in
            editingHome = (note.object as? Bool) ?? true
        }
        .onAppear { now = Date(); micName = Self.currentMic() }
        .onDisappear { monitor.stop() }
        .onChange(of: app.recorder.isRecording) { _, on in if on { monitor.stop() } }
        .onReceive(Self.minute) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { micName = Self.currentMic() }
        }
    }

    /// Verbose style draws its own greeting, so the navigation bar stays hidden.
    private var verboseScreen: some View {
        let layout = layouts.layout(.verbose)
        let drawn = HomeSpacing.drawn(layout, working: Self.working(app.store))
        return scroller {
            VStack(alignment: .leading, spacing: 0) {
                header.id("home-top")
                // After an update: "What's new in build N", once (WhatsNewScreen.swift).
                WhatsNewBanner(top: 16) { Self.openWhatsNew(app) }
                // Only the shown sections, each keeping its identity (its section) when the layout changes.
                ForEach(Array(drawn.enumerated()), id: \.element.section) { i, item in
                    verboseSection(item, tiles: layout.tiles)
                        .padding(.top, HomeSpacing.top(item, after: i > 0 ? drawn[i - 1] : nil, native: false))
                        .homeProbe(item)
                }
                EditHomeButton { editingHome = true }.padding(.top, 32)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Whether anything is transcribing (Queue shows only then). One pass, without copying the library.
    static func working(_ store: Store) -> Bool {
        store.transcripts.contains { $0.deletedAt == nil && $0.status == .processing }
    }

    @ViewBuilder private func verboseSection(_ item: HomeLayout.Item, tiles picks: [HomeTile]) -> some View {
        switch item.section {
        case .record: if item.size == .large { recordPanel } else { recordStrip }
        case .tiles: tiles(picks, size: item.size)
        case .week: if item.size == .compact { weekCard } else { weekLarge }
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

    /// Native uses the navigation bar's large title and the account button, with the floating record button over it.
    private var nativeScreen: some View {
        scroller {
            nativeBody
                .padding(.horizontal, 20).padding(.bottom, 104)   // clear of the record button
        }
        .premiumRecordButton(.home)
        .navigationTitle("Home")
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { nativeAccountButton }
        }
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

    /// The input the system would record from, read from the current route (this never opens the microphone).
    static func currentMic() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone Microphone"
    }

    // MARK: Header

    private var firstName: String? { HomeGreeting.firstName(storedName) }

    /// The eyebrow date, then "Good afternoon, Tim." over an italic "What are we keeping?", both in the display serif.
    private var header: some View {
        let line = HomeGreeting.line(name: firstName, hour: Calendar.current.component(.hour, from: now))
        return VStack(alignment: .leading, spacing: 8) {
            PhoneEyebrow(text: HomeGreeting.dateLine(now))
            VStack(alignment: .leading, spacing: 2) {
                Text(line)
                Text("What are we keeping?").italic()
            }
            .lookSerif(displaySize).tracking(-0.8)
            .foregroundStyle(.lookInk)
            .lineSpacing(0)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
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

    /// Ink on the Record fill: 4.7:1, so every line passes at any size. White would be 2.8:1.
    private var onRecord: Color { Ink.inkFixed }

    /// A press on Record: the card presses in (0.98; its hard shadow tightens to (2, 3)), touch down listens (after a
    /// moment, so a quick tap doesn't open the mic), and holding 0.4 s opens the Record as tray, which closes the mic.
    private func recordPressChanged(_ p: RecordPressPhase) {
        recordPress = p
        if p == .pressing, !app.recorder.isRecording { monitor.listen(after: 0.15) } else { monitor.stop() }
    }

    private var recordPressed: Bool { recordPress != .idle }

    private var recordPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        let hard: CGSize = recordPressed ? CGSize(width: 2, height: 3) : CGSize(width: 4, height: 5)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(onRecord).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("Ready · \(micName)").font(.system(size: small, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 11).frame(minHeight: 26)
            .background(Ink.readerFixed.opacity(0.55), in: Capsule())
            // Real level while recording and while a finger rests here; an even breath otherwise.
            Group {
                if app.recorder.isRecording { LiveHomeMeter(live: app.recorder.live, barWidth: 4.5, gap: 7, heights: HomeMeter.phoneHeights, color: onRecord) }
                else if monitor.listening { LiveHomeMeter(live: monitor.live, barWidth: 4.5, gap: 7, heights: HomeMeter.phoneHeights, color: onRecord) }
                else { BreathingHomeMeter(barWidth: 4.5, gap: 7, heights: HomeMeter.phoneHeights, color: onRecord) }
            }
            .frame(maxWidth: 250).frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record").lookSerif(recordSize)
                    Text("a thought, a call, a walk.").lookSerif(recordLine).italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // Room for the record disc, which is drawn with the rings (below) so it stays centered on them.
                Color.clear.frame(width: 70, height: 52)
            }
        }
        .foregroundStyle(onRecord)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .leading)
        .background {
            // The art is an overlay, so its fixed 200-pt box never sizes the fill past the card.
            PhonePanelFill(color: PhoneInk.record, shape: shape)
                .overlay(alignment: .topTrailing) {
                    // The disc sits at the smallest ring's center: x 150, y 210 in the 300-pt design box, scaled
                    // to this 200-pt frame.
                    ZStack(alignment: .topLeading) {
                        PhonePanelArt(kind: .rings)
                        ZStack {
                            Circle().fill(Ink.inkFixed)
                            Circle().fill(PhoneInk.record).frame(width: 18, height: 18)
                        }
                        .frame(width: 52, height: 52)
                        .position(x: 100, y: 140)
                        .accessibilityHidden(true)
                    }
                    .frame(width: 200, height: 200).offset(x: 40, y: 6)
                }
                .clipShape(shape)
        }
        .overlay(shape.strokeBorder(Ink.inkFixed, lineWidth: 1.5))
        .background(shape.fill(PhoneInk.hard).offset(hard))
        .contentShape(shape)
        .scaleEffect(recordPressed && !limitMotion ? 0.98 : 1)
        .animation(limitMotion ? Motion.fade : .easeOut(duration: 0.12), value: recordPressed)
        // Touch and hold: the Record as tray (Voice note, Meeting, Interview, Journal entry, Talk, Thought).
        .recordTrayPress(.card, onPhase: recordPressChanged) {
            monitor.stop()
            RecordTray.shared.tap()
        }
        .recordCardAccessibility(app, value: "Microphone: \(micName)", id: "home.record.verbose") { monitor.stop() }
        .onAppear { Self.recordCardsOnScreen.insert(.verbose) }
        .onDisappear { Self.recordCardsOnScreen.remove(.verbose) }
    }

    /// Record, Compact: one slim strip in the record color with the microphone and the disc.
    private var recordStrip: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        let hard: CGSize = recordPressed ? CGSize(width: 2, height: 3) : CGSize(width: 3, height: 4)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Record").lookSerif(24)
                Text("Ready · \(micName)").font(.system(size: small, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 8)
            ZStack {
                Circle().fill(Ink.inkFixed)
                Circle().fill(PhoneInk.record).frame(width: 14, height: 14)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
        }
        .foregroundStyle(onRecord)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background { PhonePanelFill(color: PhoneInk.record, shape: shape) }
        .overlay(shape.strokeBorder(Ink.inkFixed, lineWidth: 1.5))
        .background(shape.fill(PhoneInk.hard).offset(hard))
        .contentShape(shape)
        .scaleEffect(recordPressed && !limitMotion ? 0.98 : 1)
        .animation(limitMotion ? Motion.fade : .easeOut(duration: 0.12), value: recordPressed)
        .recordTrayPress(.card, onPhase: { recordPress = $0 }) { RecordTray.shared.tap() }
        .recordCardAccessibility(app, value: "Microphone: \(micName)", id: "home.record.verbose.compact")
    }

    // MARK: Tiles

    /// The four tiles you picked. Large: two by two, as tall as a thumb. Compact: one row of four. Fills go by slot
    /// (butter, sage, petal, then paper with an ink outline, so the fourth never outweighs Record).
    @ViewBuilder private func tiles(_ picks: [HomeTile], size: HomeCardSize) -> some View {
        if size == .large {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { tileCells(picks, slots: 0..<2, size: size) }
                GridRow { tileCells(picks, slots: 2..<4, size: size) }
            }
        } else {
            HStack(spacing: 8) { tileCells(picks, slots: 0..<4, size: size) }
        }
    }

    /// One cell per picked tile in `slots`, identified by the tile, so a new pick appears as a new tile.
    private func tileCells(_ picks: [HomeTile], slots: Range<Int>, size: HomeCardSize) -> some View {
        ForEach(HomeTileSlot.slots(picks, slots), id: \.tile) { s in
            HomeTileButton(tile: s.tile) {
                tile(s.tile.title, art: s.tile.art, fill: Self.tileFill(s.slot), compact: size == .compact)
            }
        }
    }

    static func tileFill(_ slot: Int) -> Color? {
        switch slot {
        case 0: return PhoneInk.butter
        case 1: return PhoneInk.sage
        case 2: return PhoneInk.petal
        default: return nil
        }
    }

    /// A start tile: the bare icon top left, the name in the serif at the foot. Color tiles get grain; the fourth is
    /// paper with an ink outline. Compact tiles are shorter, with a smaller name.
    private func tile(_ title: String, art: BrandArt, fill: Color?, compact: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        let on = fill == nil ? Ink.ink : Ink.inkFixed
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            IconGlyph(art: art, size: compact ? 18 : 22, color: on)
            Spacer(minLength: 0)
            Text(title).lookSerif(compact ? 14 : tileSize).foregroundStyle(on)
                .lineLimit(2).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, compact ? 9 : 12).padding(.vertical, compact ? 9 : 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 66 : 76, alignment: .leading)
        .background {
            if let fill { PhonePanelFill(color: fill, shape: shape) } else { shape.fill(Ink.card) }
        }
        .overlay { if fill == nil { shape.strokeBorder(Ink.ink, lineWidth: 1.5) } }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: This week

    /// One line: the week's words in the serif, seven small day bars, and the time saved. Opens the You page.
    private var weekCard: some View {
        let week = app.store.dictationWeek(now: now)
        let saved = Self.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM))
        return Button { Self.openProfile(app) } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This week").lookMono(12).foregroundStyle(.lookMute)
                    (Text(week.words.formatted()) + Text(week.words == 1 ? " word" : " words").italic())
                        .lookSerif(24).foregroundStyle(.lookInk)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 6)
                dayBars(week, height: 34)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(saved).lookSerif(17).foregroundStyle(.lookInk).lineLimit(1)
                    Text("saved").font(.system(size: small)).foregroundStyle(.lookDim)
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .phoneOutlined(radius: Radius.record)
            .contentShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")), \(saved) saved.")
        .accessibilityHint("Opens your You page, with the whole week.")
    }

    /// This week, Large: the words big in the serif beside taller day bars, then the time saved and the recordings.
    private var weekLarge: some View {
        let week = app.store.dictationWeek(now: now)
        let saved = Self.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM))
        let recordings = app.store.memo("recordings-this-week|\(Store.dayKey(now))") { PremiumHome.recordingsThisWeek(app.store.live, now: now) }
        return Button { Self.openProfile(app) } label: {
            VStack(alignment: .leading, spacing: 10) {
                PhoneEyebrow(text: "This week")
                HStack(alignment: .bottom, spacing: 12) {
                    (Text(week.words.formatted()) + Text(week.words == 1 ? " word" : " words").italic())
                        .lookSerif(40).tracking(-0.6).foregroundStyle(.lookInk)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    dayBars(week, height: 52)
                }
                Text("\(saved) saved typing · \(HomeCounts.countLabel(recordings, "recording", "recordings"))")
                    .font(.system(size: 14)).foregroundStyle(.lookDim)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .phoneOutlined(radius: Radius.record)
            .contentShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")), \(saved) saved typing, \(HomeCounts.countLabel(recordings, "recording", "recordings")).")
        .accessibilityHint("Opens your You page, with the whole week.")
    }

    private func dayBars(_ week: HomeWeek, height: CGFloat) -> some View {
        let peak = CGFloat(max(1, week.peak))
        return HStack(alignment: .bottom, spacing: height > 40 ? 7 : 5) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                let empty = day.isFuture || day.words == 0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(day.isToday && !empty ? PhoneInk.record : Ink.ink)
                    .opacity(empty ? 0.3 : 1)
                    .frame(width: height > 40 ? 9 : 7, height: empty ? 2 : max(4, height * CGFloat(day.words) / peak))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }

    /// "42s", "18m", "2h 14m".
    static func savedLabel(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    // MARK: Recent

    /// Large: the two newest recordings as flat rows (a Clean up pill where there are filler words). Compact: the
    /// three newest as one-line rows with their length.
    private func recent(_ size: HomeCardSize) -> some View {
        let items = Array(app.store.live.lazy.filter { !$0.isDictation }.prefix(size == .large ? 2 : 3))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                (Text("Recent ") + Text("recordings").italic())
                    .lookSerif(sectionSize).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Library") { app.go(.library) }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.lookAccentText)
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens your library.")
            }
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record something new.").lookSerif(20).foregroundStyle(.lookInk)
                    Text("Recordings and imports land here, and on your Mac.").font(.system(size: 14)).foregroundStyle(.lookDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
            } else if size == .large {
                ForEach(items) { t in recentRow(t) }
            } else {
                ForEach(items) { t in recentLine(t) }
            }
        }
    }

    /// A Compact recent recording: the title and its length on one line.
    private func recentLine(_ t: Transcript) -> some View {
        Button { app.open(t.id) } label: {
            HStack(spacing: 10) {
                Text(PhoneRowTitle.title(t)).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                Spacer(minLength: 8)
                LiveStage(t) { t in
                    Text(t.status == .ready ? HomeRecentStyle.length(t.duration) : t.stageText).lookMono(12).foregroundStyle(.lookMute).lineLimit(1)
                }
            }
            .frame(minHeight: 46)
            .overlay(alignment: .bottom) { Rectangle().fill(.lookHairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PhoneCardPress())
        .contextMenu { RowActions(transcript: t) }
        .accessibilityHint("Opens the transcript.")
    }

    /// A flat row; a recording with filler words gets a "Clean up" pill that opens its Cleaned text.
    private func recentRow(_ t: Transcript) -> some View {
        let cleanUp = t.status == .ready && !PhoneRowState.cleaned(t) && app.store.fillerCount(t.id) > 0
        return Button { app.open(t.id) } label: {
            // The live progress (StageClock) in the meta line: a tick re-renders the row, not Home.
            LiveStage(t) { t in
                PhoneFlatRow(transcript: t, serif: false, meta: Self.recentMeta(t, now: now)) {
                    // Holds the pill's room; the real pill sits on top so it takes its own taps.
                    if cleanUp { cleanUpPill.hidden() }
                }
            }
        }
        .buttonStyle(PhoneCardPress())
        .overlay(alignment: .trailing) {
            if cleanUp {
                Button { app.focusSegment = nil; app.homePath.append(DocumentRoute(id: t.id)) } label: { cleanUpPill }
                    .buttonStyle(PhoneCardPress())
                    .padding(.trailing, 2)
                    .accessibilityLabel("Clean up \(t.title)")
                    .accessibilityHint("Opens the cleaned text without the filler words.")
            }
        }
        .contextMenu { RowActions(transcript: t) }
        .accessibilityHint("Opens the transcript.")
    }

    /// Native: a tinted `.bordered` capsule.
    private var cleanUpPill: some View {
        Text("Clean up").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(look.isNative ? NativeInk.accent : Ink.onInteractive)
            .padding(.horizontal, 12).frame(minHeight: 30)
            .background(look.isNative ? NativeInk.fill : Ink.interactive, in: Capsule())
    }

    /// "Meeting · Today · 3:39 PM", or where it is while it's being made.
    static func recentMeta(_ t: Transcript, now: Date) -> String {
        let style = HomeRecentStyle(t)
        switch t.status {
        case .processing: return "\(style.chip) · \(t.stageText)"
        case .failed: return "\(style.chip) · Didn't finish"
        case .ready:
            let day = HomeRecentStyle.day(t.createdAt, now: now)
            return "\(style.chip) · \(day) · \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
        }
    }
}

// MARK: - Native look
// brand: native begin

/// Home in Premium Native (PremiumHome.swift), with the account button: your initials on the persimmon gradient.
extension HomeScreen {
    var nativeBody: some View {
        PremiumHome(now: now, layout: layouts.layout(.native), onEdit: { editingHome = true })
    }

    /// Your initials on the persimmon gradient; opens the You page.
    var nativeAccountButton: some View {
        Button { Self.openProfile(app) } label: {
            Text(Self.initials(storedName))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white)
                .frame(width: 34, height: 34)
                .background(PremiumStyle.persimmon, in: Circle())
        }
        .accessibilityLabel("You")
        .accessibilityHint("Opens your You page: your week, your year, and About me.")
    }

    /// "TM" from "Tim Medina"; one letter for one name; a person glyph's stand-in ("?") when there's no name.
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let s = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }
}
// brand: native end


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
        if transcript.status == .ready { Button { app.copyText(transcript) } label: { Label("Copy text", systemImage: "doc.on.doc") } }   // brand: system surface (context menu)
        if transcript.status == .failed { Button { app.retry(transcript) } label: { Label("Retry", systemImage: "arrow.clockwise") } }   // brand: system surface (context menu)
        if transcript.status == .processing, transcript.processingDevice == Device.id { Button { app.cancel(transcript.id) } label: { Label("Cancel transcription", systemImage: "xmark") } }
        Divider()
        Button(role: .destructive) { app.delete([transcript.id]) } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - Recording

/// The full-screen recorder. The chevron (top left), a swipe down, or VoiceOver's escape minimizes it to the bar
/// above the tab bar without stopping anything (MiniRecorder.swift); Stop and Discard end the recording.
struct RecordScreen: View {
    @EnvironmentObject var app: PhoneState
    /// The namespace the bar shares, for the zoom between them.
    var zoom: Namespace.ID
    @Environment(\.limitMotion) private var limitMotion
    /// How far a swipe down has pulled the screen (iOS 17, or with motion limited; otherwise the system's zoom
    /// transition handles the swipe).
    @State private var pull: CGFloat = 0
    /// Started from the Record as tray: the next recorder opens with no system transition and slides up 12 pt over
    /// 150 ms, opaque from its first frame (PhoneState.presentRecorder sets it; never under Limit animation).
    static var slideInNext = false
    @State private var arrive: CGFloat = RecordScreen.slideInNext ? 12 : 0
    @ObservedObject private var auto = TemplateSettingsModel.shared
    private var paused: Bool { app.recorder.isPaused }
    private var adding: Transcript? { app.continuing.flatMap { app.store.transcript($0) } }
    /// The system cover slides up; its content staggers in behind it.
    @State private var seen = SeenRows()
    /// Discard asks first: the recording moves to Recently Deleted.
    @State private var confirmDiscard = false
    @State private var discardLength = ""
    private var saving: Bool { app.savingRecording }
    @Environment(\.look) private var look

    var body: some View {
        // Premium Native has its own recorder (PremiumRecord.swift); both minimize, zoom, and discard the same way.
        Group {
            if look.isNative {
                PremiumRecorder(confirmDiscard: $confirmDiscard, discardLength: $discardLength)
            } else {
                verbose
            }
        }
        .offset(y: pull + arrive)
        .onAppear {
            guard Self.slideInNext else { return }
            Self.slideInNext = false
            withAnimation(.easeOut(duration: 0.15)) { arrive = 0 }
        }
        // Swipe down to minimize where the system's zoom transition doesn't provide it. Never stops the recording.
        .gesture(swipeDown, including: RecorderZoomDestination.systemSwipe(limitMotion: limitMotion) ? .subviews : .all)
        .modifier(RecorderZoomDestination(zoom: zoom))
        .sensoryFeedback(.impact(weight: .light), trigger: paused)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { app.minimizeRecorder() }
        .confirmationDialog("Move this recording to Recently Deleted?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { app.discardRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("\(discardLength) recorded. You can restore it for 30 days.")
        }
    }

    /// The line under the meter: the template that runs when you stop (with Run automatically's glyph), or what the
    /// kind does, then "Screen can lock". Wraps to two lines at larger text sizes.
    private var recordMeta: some View {
        let choice = app.recordingChoice
        let all = app.store.allTemplates
        let runs = choice.template(settings: auto.settings, templates: all) != nil
        let line = HStack(spacing: 5) {
            if runs { IconGlyph(art: .iconRecent, size: 13, color: Ink.mute).accessibilityHidden(true) }
            Text(choice.recorderLine(settings: auto.settings, templates: all)).fixedSize(horizontal: false, vertical: true)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                line
                Spacer(minLength: 8)
                Text("Screen can lock")
            }
            VStack(alignment: .leading, spacing: 4) {
                line
                Text("Keeps recording with the screen locked")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13)).foregroundStyle(.lookMute)
        .accessibilityElement(children: .combine)
    }

    /// Beside Mark: "Marked 4:12 · 3 moments" for two seconds, then how many are marked.
    private var markLine: String {
        if let c = app.lastMark { return Marks.confirmation(c) }
        let n = app.recordingMoments.count
        return n > 0 ? "\(Marks.count(n)) marked" : "Keep this moment as a bookmark"
    }

    private var verbose: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { app.minimizeRecorder() } label: {
                    ChevronDownMark()
                        .stroke(Ink.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 16, height: 16)
                        .frame(width: 36, height: 36)
                        .background(.lookReader, in: Circle())
                        .overlay(Circle().strokeBorder(.lookHairline))
                        .contentShape(Circle())
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel("Minimize")
                .accessibilityHint("Keeps recording. Use the bar above the tab bar to come back.")
                Text(adding != nil ? "Continue recording" : app.recordingThought ? ThoughtRules.activityTitle : "New recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(.lookDim)
                DottedRule().frame(height: 1)
                // A kind picked in the Record as tray shows as its neutral chip; a plain Record stays "Voice note".
                if adding == nil, !app.recordingThought, let k = app.recordKind {
                    RecordKindChip(choice: .kind(k))
                } else {
                    Text(adding != nil ? "Adds to \(HomeRecentStyle.length(adding!.duration))" : app.recordingThought ? PhoneState.thoughtPageTitle(app.todayPage) : "Voice note").font(.system(size: 13)).monospacedDigit().foregroundStyle(.lookMute)
                }
            }
            .padding(.top, 8)
            .riseIn("header", index: 0, seen: seen, epoch: 0, base: 0.2, scrollRise: false)

            Text(headline)
                .lookSerif(30).foregroundStyle(.lookInk).lineLimit(2).minimumScaleFactor(0.8)
                .padding(.top, 14)
                .contentTransition(.opacity)
                .animation(Motion.settle, value: paused)
                .riseIn("headline", index: 1, seen: seen, epoch: 0, base: 0.2, scrollRise: false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Circle().fill(paused ? Ink.mute : Ink.persimmon).frame(width: 8, height: 8)
                            Overline(text: paused ? "Paused" : "Recording", color: paused ? Ink.mute : Ink.accentText)
                        }
                        ElapsedLabel(live: app.recorder.live, size: 54)
                        // The recording is written to disk as it goes, in 5-minute parts.
                        Text("Saved as you go").font(.system(size: 13)).foregroundStyle(.lookMute)
                            .accessibilityLabel("Saved as you go. The recording is written to this iPhone while you talk.")
                    }
                    Spacer(minLength: 8)
                    LiveCaptureMark(live: app.recorder.live, paused: paused).frame(width: 78, height: 100)
                }
                RecordWave(live: app.recorder.live, paused: paused).frame(height: 84).padding(.top, 14)
                Text("Transcribed on this iPhone").font(.system(size: 13)).foregroundStyle(.lookMute).padding(.top, 10)
            }
            .padding(20)
            .background(.lookReader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(.lookHairline))
            .padding(.top, 20)
            .riseIn("meter", index: 2, seen: seen, epoch: 0, base: 0.2, scrollRise: false)

            // Mark a moment (Model/Marks.swift): a bookmark at this time, on the line being said once transcribed.
            HStack(spacing: 12) {
                Button { app.markMoment() } label: {
                    HStack(spacing: 7) {
                        IconGlyph(art: .iconMark, size: 17, color: Ink.ink)
                        Text("Mark")
                    }
                }
                .buttonStyle(.phoneSecondary)
                .disabled(saving)
                .accessibilityLabel("Mark a moment")
                .accessibilityHint("Saves this point in the recording as a moment.")
                Text(markLine).font(.system(size: 13)).foregroundStyle(app.lastMark != nil ? Ink.butterText : Ink.mute)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)

            if paused, let reason = app.autoPauseReason {
                // Paused by an interruption (a call, a microphone change): say so, and offer Resume right here.
                HStack(alignment: .center, spacing: 12) {
                    IconGlyph(art: .iconAttention, size: 20, color: Ink.ink)
                        .accessibilityHidden(true)
                    Text(reason).font(.system(size: 15)).foregroundStyle(.lookInk).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Resume") { app.togglePause() }.buttonStyle(.phonePrimary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .padding(.top, 14)
                .accessibilityElement(children: .combine)
            } else if adding == nil {
                // What happens when you stop: the template Run automatically will run, or what the kind does.
                recordMeta
                    .padding(.top, 14)
                    .riseIn("locked", index: 3, seen: seen, epoch: 0, base: 0.2, scrollRise: false)
            } else {
                Text("Keeps recording with the screen locked").font(.system(size: 13)).foregroundStyle(.lookMute)
                    .frame(maxWidth: .infinity).padding(.top, 14)
                    .riseIn("locked", index: 3, seen: seen, epoch: 0, base: 0.2, scrollRise: false)
            }

            // Show words while you record: the newest three lines, a preview only.
            RecordLiveText(text: app.recordingWords)
                .padding(.top, 16)
                .padding(.horizontal, 4)

            Spacer(minLength: 20)

            // Centered: the Record button you tapped is now Stop, with Discard and Pause on either side.
            HStack(alignment: .top, spacing: 0) {
                RoundControl(label: "Discard", size: 62) {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(.lookDim)
                } action: {
                    discardLength = app.recorder.elapsed.timecode
                    confirmDiscard = true
                }
                .frame(maxWidth: .infinity)
                RoundControl(label: saving ? "Saving…" : (adding == nil && !app.recordingThought) ? "Stop & transcribe" : "Stop & add", size: 100, primary: true) {
                    if saving { ProgressView().tint(Ink.readerFixed) }
                    else { RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.readerFixed).frame(width: 32, height: 32) }
                } action: { app.stopRecording() }
                .frame(maxWidth: .infinity)
                RoundControl(label: paused ? "Resume" : "Pause", size: 62) {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 20)).foregroundStyle(.lookInk)
                } action: { app.togglePause() }
                .frame(maxWidth: .infinity)
            }
            .disabled(saving)
            .padding(.bottom, 18)
            .riseIn("controls", index: 4, seen: seen, epoch: 0, base: 0.2, scrollRise: false)
        }
        .padding(.horizontal, 20)
        .phonePage()
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { v in
                guard v.translation.height > 0, abs(v.translation.height) > abs(v.translation.width) else { return }
                pull = v.translation.height
            }
            .onEnded { v in
                let minimize = v.translation.height > 120 || v.predictedEndTranslation.height > 320
                if minimize { app.minimizeRecorder() }
                withAnimation(limitMotion ? nil : .spring(duration: 0.35, bounce: 0)) { pull = 0 }
            }
    }

    private var headline: String {
        if saving { return "Saving your recording…" }
        if paused, app.autoPauseReason != nil { return "Paused. What you said is saved." }
        if paused { return "Paused. Pick up when you're ready." }
        if let t = adding { return "Keep going. This adds to “\(t.title)”." }
        return "Go ahead, I'm listening."
    }
}

/// A round control with its label underneath. Small ones sit on the card color; the primary one is persimmon.
struct RoundControl<Icon: View>: View {
    var label: String
    var size: CGFloat
    var primary = false
    @ViewBuilder var icon: () -> Icon
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(primary ? Ink.persimmon : Ink.reader)
                    if !primary { Circle().strokeBorder(.lookHairline) }
                    icon()
                }
                .frame(width: size, height: size)
                .frame(height: 100)   // labels line up whatever the circle size
                Text(label).font(.system(size: 14, weight: primary ? .semibold : .regular)).foregroundStyle(.lookInk).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Press: scale 0.97 over 320 ms (a brief dim when motion is limited).
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SoftPress().makeBody(configuration: configuration) }
}

/// Three voice bands from the recorder's one level, each on its own spring, for the four rings (outer to
/// inner): the outer ring follows slow voice energy (soft spring, gain .10), the middle rings follow the level
/// (gains .13, .16), and the inner ring follows onsets, the crisp sounds (stiff spring, gain .22).
final class LiveBands {
    let springs = SpringBank([(30, 7, 0.10), (45, 8, 0.13), (60, 9, 0.16), (120, 12, 0.22)])
    private var slow = 0.0

    func advance(_ now: Date, level: Double) {
        let dt = springs.tick(now)
        slow += (level - slow) * min(1, dt * 3)
        let crisp = max(0, level - slow)
        springs.step(dt, targets: [min(1, slow * 1.2), min(1, level * 0.9), min(1, level), min(1, level * 0.4 + crisp * 2)])
    }
}

/// The brand's Capture diagram, listening: each ring swells on its own band of your voice, scaling from the
/// shared bottom point; the dot is the recording light. Still when motion is limited.
struct LiveCaptureMark: View {
    @ObservedObject var live: LiveMeter
    var paused: Bool
    @Environment(\.limitMotion) private var limitMotion
    @State private var bands = LiveBands()
    var body: some View {
        // 60 fps at most: the springs advance by the clock, so they move the same, without redrawing at ProMotion's 120 Hz
        // for the whole recording.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: limitMotion || paused)) { timeline in
            Canvas { ctx, size in
                bands.advance(timeline.date, level: paused || limitMotion ? 0 : Double(live.level))
                // Diagram space: circles touch at the bottom, an axis runs through them (diagram_capture).
                let sp = ArtSpace(box: BrandArt.diagramCapture.box, size: size)
                func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: sp.dx + x * sp.s, y: sp.dy + y * sp.s) }
                let base: CGFloat = 383   // where the circles meet
                let radii: [CGFloat] = [124, 102, 80, 58]
                for (i, r0) in radii.enumerated() {
                    let r = r0 * (limitMotion ? 1 : bands.springs.scale(i))
                    ctx.stroke(sp.circle(300, base - r, r), with: .color(Ink.ink.opacity([0.22, 0.42, 0.7, 1][i])), lineWidth: 1.6)
                }
                var axis = Path(); axis.move(to: pt(300, 96)); axis.addLine(to: pt(300, 421))
                axis.move(to: pt(280, 93)); axis.addLine(to: pt(320, 93)); axis.move(to: pt(282, 425)); axis.addLine(to: pt(318, 425))
                ctx.stroke(axis, with: .color(Ink.ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                let pulse = limitMotion ? 0 : CGFloat(min(1, max(0, bands.springs.value(2))))
                let d = 15 * sp.s * (1 + pulse * 0.4)
                let dc = pt(300, base)
                ctx.fill(Path(ellipseIn: CGRect(x: dc.x - d, y: dc.y - d, width: 2 * d, height: 2 * d)), with: .color(paused ? Ink.mute : Ink.persimmon))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The live waveform: newest on the right, the latest few bars in persimmon.
struct RecordWave: View {
    @ObservedObject var live: LiveMeter
    var paused: Bool
    var body: some View {
        GeometryReader { g in
            let n = live.levels.count
            let gap: CGFloat = 3
            let w = max(2, (g.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(live.levels.enumerated()), id: \.offset) { i, v in
                    Capsule()
                        .fill(paused ? Ink.track : (i >= n - 4 ? Ink.persimmon : Ink.ink))
                        .frame(width: w, height: max(4, CGFloat(v) * g.size.height))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeOut(duration: 0.12), value: live.levels)
        .accessibilityHidden(true)
    }
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
