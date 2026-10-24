import SwiftUI
import AVFoundation

/// Home, in the website style (mockup "Verbose iPhone, Website Style", October 23, 2026): the only screen with the
/// big two-line serif greeting, then the Record panel (record color, grain, the breathing meter, and the rings that
/// swell gently), four short start tiles (Dictate, Import, What's playing, Live captions; Import's touch-and-hold menu pastes a link), a one-line This week card,
/// and the two most recent recordings as flat rows. Whatever you record here shows up on your Mac.
struct HomeScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.limitMotion) private var limitMotion
    /// Your name for the greeting (the Mac's key); empty means a greeting without a name.
    @AppStorage("profile.name") private var storedName = ""
    /// Entrances: the first screenful staggers in on launch and on each switch to Home.
    @State private var seen = SeenRows()
    @State private var entrance = 0
    @State private var now = Date()
    @State private var micName = HomeScreen.currentMic()
    /// Listens to the mic while a finger is on Record, so the meter shows your real level (DESIGN.md §7).
    @StateObject private var monitor = HomeLevelMonitor()
    @ObservedObject private var flow = FlowSettings.shared
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 36
    @ScaledMetric(relativeTo: .title) private var recordSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var recordLine: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 19
    @ScaledMetric(relativeTo: .title2) private var sectionSize: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var small: CGFloat = 12.5

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.id("home-top")
                        .riseIn("header", index: 0, seen: seen, epoch: entrance)
                    recordPanel.padding(.top, 18)
                        .riseIn("record", index: 1, seen: seen, epoch: entrance)
                    tiles.padding(.top, 10)
                        .riseIn("tiles", index: 2, seen: seen, epoch: entrance)
                    weekCard.padding(.top, 12)
                        .riseIn("week", index: 3, seen: seen, epoch: entrance)
                    recent.padding(.top, 24).id("home-recent")
                        .riseIn("recent", index: 4, seen: seen, epoch: entrance)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
            }
            .onReceive(NotificationCenter.default.publisher(for: .verbatimHomeScroll)) { note in
                guard let id = note.object as? String else { return }
                withAnimation(limitMotion ? nil : Motion.settle) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .tabEntrance(.home) { seen.entered(); entrance += 1 }
        .background(Ink.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: DictationsRoute.self) { _ in DictationsListScreen() }
        .onAppear { now = Date(); micName = Self.currentMic() }
        .onDisappear { monitor.stop() }
        .onChange(of: app.recorder.isRecording) { _, on in if on { monitor.stop() } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { micName = Self.currentMic() }
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
            .font(Ink.serif(displaySize)).tracking(-0.8)
            .foregroundStyle(Ink.ink)
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

    /// Puts a dictation's words on the clipboard (a Dictations row). The row itself confirms with a check.
    static func copyDictation(_ text: String) {
        UIPasteboard.general.string = text
    }

    // MARK: Record

    /// Ink on the Record fill: 4.7:1, so every line passes at any size. White would be 2.8:1.
    private var onRecord: Color { Ink.inkFixed }

    private var recordPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        // Touch down listens (after a moment, so a quick tap doesn't open the mic); lifting the finger closes it.
        return Button {
            monitor.stop()
            app.requestRecord()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
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
                        Text("Record").font(Ink.serif(recordSize))
                        Text("a thought, a call, a walk.").font(Ink.serif(recordLine)).italic()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    ZStack {
                        Circle().fill(Ink.inkFixed)
                        Circle().fill(PhoneInk.record).frame(width: 18, height: 18)
                    }
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                }
            }
            .foregroundStyle(onRecord)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 184, alignment: .leading)
            .background {
                // The art is an overlay, so its fixed 200-pt box never sizes the fill past the card.
                PhonePanelFill(color: PhoneInk.record, shape: shape)
                    .overlay(alignment: .topTrailing) {
                        PhonePanelArt(kind: .rings).frame(width: 200, height: 200).offset(x: 40, y: 6)
                    }
                    .clipShape(shape)
            }
            .overlay(shape.strokeBorder(Ink.inkFixed, lineWidth: 1.5))
            .background(shape.fill(PhoneInk.hard).offset(x: 4, y: 5))
            .contentShape(shape)
        }
        .buttonStyle(PhonePressReporting { pressed in
            if pressed, !app.recorder.isRecording { monitor.listen(after: 0.15) } else { monitor.stop() }
        })
        .accessibilityLabel("Record")
        .accessibilityValue("Microphone: \(micName)")
        .accessibilityHint("Starts a voice note. It keeps recording with the screen locked.")
    }

    // MARK: Tiles

    private var tiles: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Button { app.homePath.append(DictationsRoute()) } label: {
                    tile("Dictate", art: .iconDictations, fill: PhoneInk.butter)
                }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Opens your dictations and how to use the Verbose keyboard.")
                // Touch and hold to paste a link instead (the existing link sheet).
                Menu {
                    Button("Choose files…") { app.showImporter = true }
                    Button("Paste a link") { app.showLinkSheet = true }
                } label: {
                    tile("Import", art: .iconDownload, fill: PhoneInk.sage)
                } primaryAction: {
                    app.showImporter = true
                }
                .menuStyle(.button)
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Choose audio or video files to transcribe. Touch and hold to paste a link.")
                .accessibilityAction(named: "Paste a link") { app.showLinkSheet = true }
            }
            GridRow {
                Button { app.showPlayingSheet = true } label: {
                    tile("What's playing", art: .iconVoice, fill: PhoneInk.petal)
                }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Transcribes sound from TikTok or any app.")
                // Paper with an ink outline, so it never outweighs Record.
                Button { app.requestCaptions() } label: {
                    tile("Live captions", art: .iconCaptions, fill: nil)
                }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Shows what's said in the room as captions.")
            }
        }
    }

    /// A start tile: the bare icon top left, the name in the serif at the foot. Color tiles get grain; Live captions
    /// is paper with an ink outline.
    private func tile(_ title: String, art: BrandArt, fill: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        let on = fill == nil ? Ink.ink : Ink.inkFixed
        return VStack(alignment: .leading, spacing: 8) {
            IconGlyph(art: art, size: 22, color: on)
            Spacer(minLength: 0)
            Text(title).font(Ink.serif(tileSize)).foregroundStyle(on)
                .lineLimit(2).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
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
        let week = HomeWeek(HomeCounts.entries(fromDictations: app.store.live), now: now)
        let saved = Self.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM))
        return Button { Self.openProfile(app) } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This week").font(Ink.mono(12)).foregroundStyle(Ink.mute)
                    (Text(week.words.formatted()) + Text(week.words == 1 ? " word" : " words").italic())
                        .font(Ink.serif(24)).foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 6)
                dayBars(week)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(saved).font(Ink.serif(17)).foregroundStyle(Ink.ink).lineLimit(1)
                    Text("saved").font(.system(size: small)).foregroundStyle(Ink.dim)
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

    private func dayBars(_ week: HomeWeek) -> some View {
        let peak = CGFloat(max(1, week.peak))
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                let empty = day.isFuture || day.words == 0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(day.isToday && !empty ? PhoneInk.record : Ink.ink)
                    .opacity(empty ? 0.3 : 1)
                    .frame(width: 7, height: empty ? 2 : max(4, 34 * CGFloat(day.words) / peak))
            }
        }
        .frame(height: 34, alignment: .bottom)
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

    private var recent: some View {
        let items = Array(app.store.live.filter { !$0.isDictation }.prefix(2))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                (Text("Recent ") + Text("recordings").italic())
                    .font(Ink.serif(sectionSize)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Library") { app.tab = .library }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.accentText)
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens your library.")
            }
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record something new.").font(Ink.serif(20)).foregroundStyle(Ink.ink)
                    Text("Recordings and imports land here, and on your Mac.").font(.system(size: 14)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
            } else {
                ForEach(items) { t in recentRow(t) }
            }
        }
    }

    /// A flat row; a recording with filler words gets a "Clean up" pill that opens its Cleaned text.
    private func recentRow(_ t: Transcript) -> some View {
        let cleanUp = t.status == .ready && !PhoneRowState.cleaned(t) && t.fillerCount > 0
        return Button { app.open(t.id) } label: {
            PhoneFlatRow(transcript: t, serif: false, meta: Self.recentMeta(t, now: now)) {
                // Holds the pill's room; the real pill sits on top so it takes its own taps.
                if cleanUp { cleanUpPill.hidden() }
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

    private var cleanUpPill: some View {
        Text("Clean up").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.onInteractive)
            .padding(.horizontal, 12).frame(minHeight: 30)
            .background(Ink.interactive, in: Capsule())
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

/// Card press feedback (`PhoneCardPress`) that also reports the press, so Record can open the mic while a finger
/// rests on it.
struct PhonePressReporting: ButtonStyle {
    var onPress: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        PhoneCardPress().makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}


extension Notification.Name {
    /// Scrolls Home to a section ("home-top", "home-recent", "home-dictations"); the screenshot tour uses it.
    static let verbatimHomeScroll = Notification.Name("verbatimHomeScroll")
    static let verbatimOpenSettingsPage = Notification.Name("verbatimOpenSettingsPage")
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
    private var paused: Bool { app.recorder.isPaused }
    private var adding: Transcript? { app.continuing.flatMap { app.store.transcript($0) } }
    /// The system cover slides up; its content staggers in behind it.
    @State private var seen = SeenRows()
    /// Discard asks first: the recording moves to Recently Deleted.
    @State private var confirmDiscard = false
    @State private var discardLength = ""
    private var saving: Bool { app.savingRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { app.minimizeRecorder() } label: {
                    ChevronDownMark()
                        .stroke(Ink.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 16, height: 16)
                        .frame(width: 36, height: 36)
                        .background(Ink.reader, in: Circle())
                        .overlay(Circle().strokeBorder(Ink.hairline))
                        .contentShape(Circle())
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel("Minimize")
                .accessibilityHint("Keeps recording. Use the bar above the tab bar to come back.")
                Text(adding == nil ? "New recording" : "Continue recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                DottedRule().frame(height: 1)
                Text(adding == nil ? "Voice note" : "Adds to \(HomeRecentStyle.length(adding!.duration))").font(.system(size: 13)).monospacedDigit().foregroundStyle(Ink.mute)
            }
            .padding(.top, 8)
            .riseIn("header", index: 0, seen: seen, epoch: 0, base: 0.2, scrollRise: false)

            Text(headline)
                .font(Ink.serif(30)).foregroundStyle(Ink.ink).lineLimit(2).minimumScaleFactor(0.8)
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
                        Text("Saved as you go").font(.system(size: 13)).foregroundStyle(Ink.mute)
                            .accessibilityLabel("Saved as you go. The recording is written to this iPhone while you talk.")
                    }
                    Spacer(minLength: 8)
                    LiveCaptureMark(live: app.recorder.live, paused: paused).frame(width: 78, height: 100)
                }
                RecordWave(live: app.recorder.live, paused: paused).frame(height: 84).padding(.top, 14)
                Text("Transcribed on this iPhone").font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.top, 10)
            }
            .padding(20)
            .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline))
            .padding(.top, 20)
            .riseIn("meter", index: 2, seen: seen, epoch: 0, base: 0.2, scrollRise: false)

            if paused, let reason = app.autoPauseReason {
                // Paused by an interruption (a call, a microphone change): say so, and offer Resume right here.
                HStack(alignment: .center, spacing: 12) {
                    IconGlyph(art: .iconAttention, size: 20, color: Ink.ink)
                        .accessibilityHidden(true)
                    Text(reason).font(.system(size: 15)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Resume") { app.togglePause() }.buttonStyle(.brandPrimary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .padding(.top, 14)
                .accessibilityElement(children: .combine)
            } else {
                Text("Keeps recording with the screen locked").font(.system(size: 13)).foregroundStyle(Ink.mute)
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
                    Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.dim)
                } action: {
                    discardLength = app.recorder.elapsed.timecode
                    confirmDiscard = true
                }
                .frame(maxWidth: .infinity)
                RoundControl(label: saving ? "Saving…" : adding == nil ? "Stop & transcribe" : "Stop & add", size: 100, primary: true) {
                    if saving { ProgressView().tint(Ink.readerFixed) }
                    else { RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.readerFixed).frame(width: 32, height: 32) }
                } action: { app.stopRecording() }
                .frame(maxWidth: .infinity)
                RoundControl(label: paused ? "Resume" : "Pause", size: 62) {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 20)).foregroundStyle(Ink.ink)
                } action: { app.togglePause() }
                .frame(maxWidth: .infinity)
            }
            .disabled(saving)
            .padding(.bottom, 18)
            .riseIn("controls", index: 4, seen: seen, epoch: 0, base: 0.2, scrollRise: false)
        }
        .padding(.horizontal, 20)
        .background(Ink.paper.ignoresSafeArea())
        .offset(y: pull)
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
                    if !primary { Circle().strokeBorder(Ink.hairline) }
                    icon()
                }
                .frame(width: size, height: size)
                .frame(height: 100)   // labels line up whatever the circle size
                Text(label).font(.system(size: 14, weight: primary ? .semibold : .regular)).foregroundStyle(Ink.ink).lineLimit(1).fixedSize()
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
        TimelineView(.animation(paused: limitMotion || paused)) { timeline in
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
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste a YouTube, Vimeo, or podcast link, or a link to an audio or video file. Verbose downloads the audio and transcribes it on this iPhone.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                HStack(spacing: 8) {
                    IconGlyph(art: .iconLinks, size: 18, color: Ink.mute)
                    TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused)
                }
                .padding(12)
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.hairline))
                PasteButton(payloadType: String.self) { strings in link = strings.first ?? link }
                    .buttonBorderShape(.capsule).labelStyle(.titleAndIcon)
                Spacer()
            }
            .padding(20)
            .background(Ink.paper.ignoresSafeArea())
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
