import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import CoreAudio

// brand: web style
//
/// Home in the website style (mockup "The app, in the website's clothes", October 23, 2026; mac/DESIGN.md §6 and §11):
/// a mono date eyebrow over the big two-line greeting, the Record panel (breathing meter, looping rings) beside four
/// start tiles, one slim This week strip, then Recent recordings (two flat rows) beside Last dictation (one card on a
/// butter panel). One 12-column grid: every band splits at the same 7 / 5 edge. Big cards tilt and pick up the ink
/// outline and hard shadow on hover (`HomeCard` + `inkEdge`); rows stay flat. Narrow windows stack the bands.
///
/// Native (NativeHome.swift): plain group boxes under a bold "Good afternoon, Tim", with the same state and actions.
struct HomeView: View {
    /// Ticks `now` once a minute: one timer for every render. Built in `body`, each render made a new timer and
    /// restarted the minute, so under frequent renders (transcribing, playing, dictating) it never fired.
    private static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @EnvironmentObject var app: AppState
    @ObservedObject var log = ActivityLog.shared
    @ObservedObject var sites = SiteLog.shared
    @ObservedObject var captions = LiveCaptions.shared
    @ObservedObject var flow = FlowSettings.shared
    @AppStorage(YouProfile.nameKey) var storedName = ""
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) var look
    /// The microphone's name, looked up off the main thread and kept current by Core Audio's notifications. (Looking
    /// it up here, in a `@State` initial value and on every UserDefaults change, ran a full device scan on the main
    /// thread each time Home's parent re-rendered.)
    @ObservedObject var mics = HomeMic.shared
    /// Moves on each minute, so the greeting and today's numbers follow the clock.
    @State var now = Date()
    @State var importOpen = false
    @State var fileOver = false
    @State private var recordDown = false
    @State private var weekDown = false
    /// Listens to the mic while the pointer is over Record, so the meter shows your real level (DESIGN.md §7).
    @StateObject var monitor = HomeLevelMonitor()

    /// The gutter between columns.
    private static let gap: CGFloat = 16
    /// Side margin around the grid, and the widest the grid gets.
    private static let margin: CGFloat = 40
    private static let maxContent: CGFloat = 1100
    /// The Record panel and the tile block share this height.
    private static let startHeight: CGFloat = 196
    /// The grid's width for a scroll view `available` points wide: the space inside the margins, at most 1100.
    static func contentWidth(_ available: CGFloat) -> CGFloat { min(maxContent, max(280, available - 2 * margin)) }
    private func wide(_ width: CGFloat) -> Bool { width >= 680 }
    /// The 7 / 5 split of a 12-column grid with `gap` gutters: (7 columns + 6 gutters, 5 columns + 4 gutters).
    private func columns(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let column = (total - 11 * Self.gap) / 12
        let left = (7 * column + 6 * Self.gap).rounded(.down)
        return (left, total - Self.gap - left)
    }

    var body: some View {
        Group {
            if look == .native { nativeBody } else { verboseBody }
        }
        .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
        .onChange(of: app.focusLink) { _, _ in importOpen = true }
        .onChange(of: recording) { _, on in if on { monitor.stop() } }
        .onAppear { mics.refresh() }
        .onDisappear { monitor.stop() }
        .onReceive(Self.minute) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in mics.refresh(); now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in monitor.stop() }
    }

    private var verboseBody: some View {
        // A GeometryReader takes exactly the space the window offers and passes it down, so Home's width comes
        // from the window. (Measuring the scroll view or the content was circular: both report the content's
        // own width back, so Home either kept a too-wide layout or grew past the detail area.) The width is worked
        // out in the body, never stored: a stored width laid Home out twice on every visit (900 pt, then the real one).
        GeometryReader { geo in
            let width = Self.contentWidth(geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.staggerIn(0)
                    // After an update: "What's new in build N", once (WhatsNewPane.swift).
                    WhatsNewHomeLine(top: 18) { app.dictation.openSettings(tab: .whatsNew) }
                    if app.recorder.isRecording { RecordPanel().padding(.top, 18) }
                    else if app.capture.isCapturing { CapturePanel().padding(.top, 18) }
                    startRow(width).padding(.top, 20).staggerIn(1)
                    if app.showsHomeWeek { weekStrip.padding(.top, 16).staggerIn(2) }
                    recentRow(width).padding(.top, 30).staggerIn(3)
                }
                .animation(Motion.settle, value: app.recorder.isRecording)
                .animation(Motion.settle, value: app.capture.isCapturing)
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, Self.margin).padding(.top, 30).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Header

    var greeting: String {
        HomeGreeting.line(name: HomeGreeting.firstName(YouProfile.displayName(storedName)), hour: Calendar.current.component(.hour, from: now))
    }
    private static let question = "What are we keeping?"

    /// The mono date eyebrow and the big two-line greeting (Home only; every other screen uses a compact title).
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: HomeGreeting.dateLine(now))
            ViewThatFits(in: .horizontal) {
                headline(52).fixedSize()
                headline(44).fixedSize()
                headline(36).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func headline(_ size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: -size * 0.1) {
            Text(greeting).font(Ink.serif(size))
            Text(Self.question).font(Ink.serif(size).italic())
        }
        .tracking(-size * 0.023)
        .foregroundStyle(Ink.ink)
    }

    // MARK: Record and tiles

    @ViewBuilder private func startRow(_ width: CGFloat) -> some View {
        if wide(width) {
            let cols = columns(width)
            HStack(alignment: .top, spacing: Self.gap) {
                recordPanel(width: cols.0).frame(width: cols.0, height: Self.startHeight)
                tiles.frame(width: cols.1, height: Self.startHeight)
            }
        } else {
            VStack(spacing: 12) {
                recordPanel(width: width).frame(height: Self.startHeight)
                tiles.frame(height: Self.startHeight)
            }
        }
    }

    var recording: Bool { app.recorder.isRecording || app.capture.isCapturing }
    /// Ink on the Record fill: every line passes at its size (status sits on a light wash). White would fail.
    private var onRecord: Color { Ink.inkFixed }
    var micName: String { mics.device?.name ?? "Microphone" }

    var recordStatus: String {
        if app.capture.isCapturing { return "Capturing · \(app.capture.appName)" }
        if app.recorder.isRecording { return app.recorder.isPaused ? "Paused" : "Recording" }
        if app.savingRecording { return "Saving…" }
        return "Ready · \(micName)"
    }

    /// The Record panel: the status, the meter (an even breath at rest, your real level on hover and while
    /// recording), "Record / a thought, a call, a walk.", and a Start recording pill. The rings loop behind.
    private func recordPanel(width panelWidth: CGFloat) -> some View {
        let meterWidth = max(160, (panelWidth - 40) * 0.6)
        return HomeCard(tilt: 2, radius: Radius.record, enabled: !recording, shadow: false, onHover: { h in
            if h {
                if !recording { monitor.listen(after: 0.12) }
            } else {
                monitor.stop(after: 0.4)
            }
        }, onPress: { recordDown = $0 }, action: {
            monitor.stop()
            app.requestRecord()
        }) { hovering in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(onRecord).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(recordStatus).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Ink.readerFixed.opacity(0.55), in: Capsule())
                    Spacer(minLength: 12)
                    Keycap(keys: "⌥⇧R", size: 12)
                }
                Spacer(minLength: 8)
                Group {
                    if app.recorder.isRecording { LiveHomeMeter(live: app.recorder.live, barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                    else if app.capture.isCapturing { LiveHomeMeter(live: app.capture.live, barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                    else if monitor.listening { LiveHomeMeter(live: monitor.live, barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                    else { BreathingHomeMeter(barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                }
                .frame(width: meterWidth, height: 44)
                Spacer(minLength: 8)
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording ? "Recording" : "Record").font(Ink.serif(36)).tracking(-0.6)
                        Text(recording ? "Pause or stop from the bar above." : "a thought, a call, a walk.")
                            .font(Ink.serif(22).italic()).tracking(-0.3)
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    if !recording {
                        PillLabel(title: "Start recording", kind: .dark, trailing: .arrow, fixedInk: true)
                    }
                }
            }
            .foregroundStyle(onRecord)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .colorPanel(Ink.panelRecord, radius: Radius.record) {
                PanelArt(kind: .rings, running: !recording).frame(width: 250, height: 250).offset(x: 50, y: 10)
            }
            .inkEdge(outline: true, shadow: InkEdge.card(hover: hovering, pressed: recordDown, rest: CGSize(width: 6, height: 7)), radius: Radius.record)
        }
        .contextMenu { RecordMenu(onChange: { mics.refresh() }) }
        .help("Recording from \(micName). Right-click to change the microphone.")
        .accessibilityLabel(recording ? "Recording" : "Record")
        .accessibilityValue(recording ? "" : "Microphone: \(micName)")
        .accessibilityHint("Starts a voice note. Shortcut: Option Shift R.")
        .uiTarget("tile-record")
    }

    var dictateOpen: Binding<Bool> {
        Binding(get: { app.captureMode == "dictate" && !recording },
                set: { open in if !open && app.captureMode == "dictate" { app.captureMode = "voice" } })
    }

    /// "hold right ⌘" → ("Talk into any app", "right ⌘"): what it does in sans, and the key as a keycap.
    var dictateKey: (String, String?) {
        guard app.dictation.accessibilityTrusted else { return ("Needs Accessibility", nil) }
        let title = app.dictation.hotkey.shortTitle
        if title.hasPrefix("hold right ") { return ("Talk into any app", "right " + title.dropFirst("hold right ".count)) }
        if title.hasPrefix("hold ") { return ("Talk into any app", String(title.dropFirst("hold ".count))) }
        return (title.prefix(1).uppercased() + title.dropFirst(), nil)
    }

    /// Four start tiles, two by two, as tall together as the Record panel.
    private var tiles: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                WebTile(title: "Dictate", detail: dictateKey.0, keycap: dictateKey.1, fill: Ink.panelButter,
                        hint: "Shows your dictation key and your last dictation.") {
                    app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate"
                } icon: { replay in
                    DrawOnGlyph(art: .iconDictations, color: Ink.inkFixed, lineWidth: 1.5, replay: replay, duration: 0.55)
                }
                .popover(isPresented: dictateOpen, arrowEdge: .bottom) { DictateControls().padding(16).environmentObject(app) }
                .contextMenu { DictateMenu() }
                .uiTarget("mode-dictate")

                WebTile(title: "Import", detail: fileOver ? "Drop to transcribe" : "A file or a link", keycap: "⌘O", fill: Ink.panelSage,
                        outlined: fileOver, hint: "Choose files, or paste a link to transcribe.") {
                    importOpen = true
                } icon: { replay in
                    DrawOnGlyph(art: .iconDownload, color: Ink.inkFixed, lineWidth: 1.5, replay: replay, duration: 0.55)
                }
                .popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }).environmentObject(app) }
                .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                .uiTarget("tile-import")
            }
            HStack(spacing: 10) {
                WebTile(title: "App audio", detail: "Another app's sound", fill: Ink.panelPetal,
                        hint: "Choose an app to record its sound, like a call or a video.") {
                    app.pickApp()
                } icon: { replay in
                    DrawOnGlyph(art: .iconVoice, color: Ink.inkFixed, lineWidth: 1.5, replay: replay, duration: 0.55)
                }
                .contextMenu {
                    Button("Choose an app…") { app.pickApp() }
                    Divider()
                    Button("Screen & System Audio Recording settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                .uiTarget("tile-app")

                // Card white with an ink outline, so it never outweighs Record.
                WebTile(title: "Live captions", detail: captions.isOpen ? "On screen now" : "Words as they're said", keycap: "⌥⌘C",
                        fill: Ink.card, onFill: Ink.ink, outlined: true, grain: false,
                        hint: "Shows captions in a floating panel, from your microphone or an app's sound.") {
                    app.toggleLiveCaptions()
                } icon: { replay in
                    DrawOnGlyph(art: .iconCaptions, color: Ink.ink, lineWidth: 1.5, replay: replay, duration: 0.55)
                }
                .uiTarget("tile-captions")
            }
        }
    }

    // MARK: This week

    /// This week's numbers beyond the words: recordings made, time saved against typing (You's typing speed), and
    /// moments saved this week.
    func weekNumbers(_ week: HomeWeek) -> (recordings: Int, saved: Double, moments: Int) {
        guard let start = week.days.first?.start else { return (0, 0, 0) }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? now
        // One pass over the library, without copying it (`store.live` builds a new array).
        var recordings = 0, moments = 0
        for t in app.store.transcripts where t.deletedAt == nil {
            if !t.isDictation && t.createdAt >= start && t.createdAt < end { recordings += 1 }
            for n in t.notes where n.at != nil && n.createdAt >= start && n.createdAt < end { moments += 1 }
        }
        return (recordings, week.secondsSaved(typingWPM: flow.typingWPM), moments)
    }

    /// One slim strip, and one button: anywhere on it opens You.
    private var weekStrip: some View {
        let week = HomeWeek(log.events.map { HomeWordEntry(date: $0.date, words: $0.words, seconds: $0.seconds) }, now: now)
        let n = weekNumbers(week)
        return HomeCard(tilt: 1, radius: Radius.record, shadow: false, onPress: { weekDown = $0 }, action: { app.go(.activity) }) { hovering in
            WeekStrip(week: week, recordings: n.recordings, saved: WebFormat.compactDuration(n.saved), moments: n.moments)
                .inkEdge(outline: true, shadow: InkEdge.card(hover: hovering, pressed: weekDown), radius: Radius.record)
        }
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")), \(HomeCounts.countLabel(n.recordings, "recording", "recordings")), \(WebFormat.compactDuration(n.saved)) saved typing, \(HomeCounts.countLabel(n.moments, "moment", "moments")).")
        .accessibilityHint("Opens You: your week, cleanup, and where you dictate.")
        .uiTarget("home-week")
    }

    // MARK: Recent

    @ViewBuilder private func recentRow(_ width: CGFloat) -> some View {
        if wide(width) {
            let cols = columns(width)
            HStack(alignment: .top, spacing: Self.gap) {
                recentRecordings.frame(width: cols.0)
                lastDictation.frame(width: cols.1)
            }
        } else {
            VStack(alignment: .leading, spacing: 28) {
                recentRecordings
                lastDictation
            }
        }
    }

    private var recentRecordings: some View {
        let items = Array(app.archive.prefix(2))
        return VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Recent", italic: "recordings", link: "Library", linkHint: "Opens your library.") { app.go(.library) }
                .padding(.bottom, 10)
            if items.isEmpty && app.search.isEmpty {
                EmptyStateCard(art: .iconLibrary, title: "Record something new",
                               message: "Recordings and imports land here, ready to review.",
                               button: "Start recording", action: { app.requestRecord() })
            } else if items.isEmpty {
                EmptyStateCard(art: .search, title: "Nothing found",
                               message: "Nothing matches “\(app.search)”. Search looks at titles and every transcript's text.")
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    let fillers = WebStatus.cachedFillers(t)
                    FlatRowButton(action: { app.go(.transcript(t.id)) }) { _ in
                        RecentRow(transcript: t, fillers: fillers)
                    } accessory: { _ in
                        if fillers > 0 {
                            PillButton(title: "Clean up", kind: .dark, size: .mini, hint: "Opens the transcript's Cleaned tab.") { openCleaned(t) }
                                .padding(.trailing, 14)
                        }
                    }
                    .contextMenu { RowMenu(transcript: t) }
                    .accessibilityHint("Opens the transcript.")
                    .uiTarget("row-\(i)")
                }
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    /// Clean up: the transcript on its Cleaned tab, where Clean up runs (the Original stays).
    func openCleaned(_ t: Transcript) {
        app.go(.transcript(t.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .verbatimShowMode, object: "Document") }
    }

    private var lastDictation: some View {
        let last = app.store.transcripts.lazy.filter { $0.deletedAt == nil && $0.source == .dictation }.max { $0.createdAt < $1.createdAt }
        let key = app.dictation.hotkey.shortTitle
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Last", italic: "dictation", link: "All", linkLabel: "All dictations", linkHint: "Opens every dictation.") { app.go(.dictations) }
                .padding(.bottom, 12)
            VStack(spacing: 0) {
                if let t = last {
                    LastDictationCard(transcript: t, place: sites.hosts[t.id] ?? t.flow?.app, copy: { Paster.copy($0) })
                        .uiTarget("home-dictation-0")
                } else {
                    HStack(spacing: 10) {
                        IconGlyph(art: .iconDictations, size: 18, color: Ink.inkFixed)
                        Text("\(key.prefix(1).uppercased() + String(key.dropFirst())) in any app and speak. What you say shows up here.")
                            .font(.system(size: 13.5)).foregroundStyle(Ink.inkFixed).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 8)
                }
            }
            .padding(12)
            .colorPanel(Ink.panelButter, radius: Radius.record)
            .animation(Motion.settle, value: last?.id)
        }
        .uiTarget("home-dictations")
    }
}

// MARK: - Pieces

/// A start tile: a color panel with grain (Live captions: card white with an ink outline), the bare icon top left,
/// the keycap top right, and the serif name with a one-line detail at the foot. Tilts on hover and picks up the ink
/// outline and hard shadow; the icon draws on again.
private struct WebTile<Icon: View>: View {
    var title: String
    var detail: String
    var keycap: String? = nil
    var fill: Color
    var onFill: Color = Ink.inkFixed
    var outlined = false
    var grain = true
    var hint: String
    var action: () -> Void
    @ViewBuilder var icon: (_ replay: Int) -> Icon
    @State private var replay = 0
    @State private var down = false

    var body: some View {
        HomeCard(tilt: 3, radius: Radius.tile, shadow: false, onHover: { h in if h { replay += 1 } }, onPress: { down = $0 }, action: action) { hovering in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    icon(replay).frame(width: 22, height: 22)
                    Spacer(minLength: 0)
                    if let keycap { Keycap(keys: keycap, size: 12).opacity(0.8) }
                }
                Spacer(minLength: 4)
                Text(title).font(Ink.serif(21)).lineLimit(1).minimumScaleFactor(0.8)
                Text(detail).font(.system(size: 12)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.85).padding(.top, 3)
            }
            .foregroundStyle(onFill)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .colorPanel(fill, radius: Radius.tile, grain: grain)
            .inkEdge(outline: outlined || hovering, shadow: InkEdge.card(hover: hovering, pressed: down), radius: Radius.tile)
        }
        .accessibilityLabel(title)
        .accessibilityValue([detail, keycap.map(Keycap.spoken)].compactMap { $0 }.joined(separator: " "))
        .accessibilityHint(hint)
    }
}

/// This week as one slim strip: the eyebrow, the words in the serif, seven small bars (today in the Record color,
/// days to come as faint dashes), and the stats on the right. Two lines when the window is narrow.
private struct WeekStrip: View {
    var week: HomeWeek
    var recordings: Int
    var saved: String
    var moments: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 28) {
                lead
                Spacer(minLength: 12)
                stats
            }
            .padding(.horizontal, 22)
            .frame(height: 72)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) { lead; Spacer(minLength: 0) }
                HStack(spacing: 22) { stats; Spacer(minLength: 0) }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
    }

    private var lead: some View {
        HStack(spacing: 28) {
            Eyebrow(text: "This week")
            Text("\(Text(week.words.formatted()).font(Ink.serif(28))) \(Text(week.words == 1 ? "word" : "words").font(Ink.serif(28).italic()))")
                .tracking(-0.4).foregroundStyle(Ink.ink).lineLimit(1).fixedSize()
            bars
        }
    }

    private var stats: some View {
        HStack(spacing: 28) {
            stat("\(recordings.formatted())", recordings == 1 ? "recording" : "recordings")
            stat(saved, "saved typing")
            stat("\(moments.formatted())", moments == 1 ? "moment" : "moments")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(Ink.serif(20)).foregroundStyle(Ink.ink)
            Text(label).font(.system(size: 13)).foregroundStyle(Ink.dim)
        }
        .lineLimit(1).fixedSize()
    }

    private var bars: some View {
        let peak = max(1, week.peak)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                let empty = day.isFuture || day.words == 0
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(day.isToday ? Ink.panelRecord : Ink.ink)
                        .opacity(day.isFuture ? 0.3 : 1)
                        .frame(width: 8, height: empty ? 2 : max(3, 24 * CGFloat(day.words) / CGFloat(peak)))
                    Text(Formats.pattern("EEEEE").string(from: day.start))
                        .font(Ink.mono(12, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? Ink.ink : Ink.mute)
                }
                .frame(width: 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Formats.pattern("EEEE").string(from: day.start))
                .accessibilityValue(day.isFuture ? "Still to come" : HomeCounts.countLabel(day.words, "word", "words"))
            }
        }
        .frame(height: 44, alignment: .bottom)
    }
}

/// A recent recording as a flat row, 66 pt: the kind dot, the title and a sentence-case meta line, and plain status
/// text on the right ("14 filler words" with room for the Clean up pill, or "1 moment").
private struct RecentRow: View {
    var transcript: Transcript
    var fillers: Int

    var body: some View {
        let style = HomeRecentStyle(transcript)
        let moments = WebStatus.moments(transcript)
        HStack(spacing: 12) {
            KindDot(transcript: transcript, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                metaText(style).font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.mute).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if fillers > 0 {
                StatusText(text: HomeCounts.countLabel(fillers, "filler word", "filler words"))
                // Room for the Clean up pill, which sits above the row's click layer.
                PillLabel(title: "Clean up", kind: .dark, size: .mini).hidden()
            } else if moments > 0 {
                StatusText(text: HomeCounts.countLabel(moments, "moment", "moments"), icon: .iconMoments)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
    }

    private func metaText(_ style: HomeRecentStyle) -> Text {
        let parts = HomeRecentStyle.metaParts(transcript, style: style, compact: false)
        var out = Text(verbatim: "")
        for (i, part) in parts.enumerated() {
            let piece = part.failed ? Text(part.text).foregroundStyle(Ink.danger).fontWeight(.semibold) : Text(part.text)
            out = Text("\(out)\(i > 0 ? " · " : "")\(piece)")
        }
        return out
    }
}

/// Home's last dictation: one white card with an ink outline on the butter panel. The app and time and the word count
/// in mono, the words (two lines at most), what cleanup did as plain status, and a Copy pill. A click anywhere on
/// the card copies; the pill turns into "✓ Copied" for 1.6 s. VoiceOver hears "Copied".
private struct LastDictationCard: View {
    var transcript: Transcript
    var place: String?
    var copy: (String) -> Void
    @Environment(\.limitMotion) private var limitMotion
    @State private var copied = false
    @State private var copies = 0
    @State private var down = false

    var body: some View {
        let failed = transcript.status == .failed
        let text = HomeDictationText.pasted(transcript)
        let canCopy = !failed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HomeCard(tilt: 1.5, radius: Radius.tile, enabled: canCopy, shadow: false, onPress: { down = $0 }, action: { copyNow(text) }) { hovering in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        AppIconView(bundleID: transcript.flow?.bundleID).frame(width: 16, height: 16)
                        Text(head).font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(HomeCounts.countLabel(HomeCounts.words(transcript), "word", "words")).font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1)
                }
                Text(HomeDictationText.body(transcript)).font(.system(size: 15.5)).lineSpacing(4)
                    .foregroundStyle(failed ? Ink.danger : Ink.ink)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let status = WebStatus.dictationCleanup(transcript) { StatusText(text: status, check: true) }
                    Spacer(minLength: 8)
                    if canCopy { copyPill }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .inkEdge(outline: true, shadow: InkEdge.card(hover: hovering, pressed: down), radius: Radius.tile, color: Ink.inkFixed)
        }
        .accessibilityLabel(HomeDictationText.body(transcript))
        .accessibilityValue(copied ? "Copied" : head)
        .accessibilityHint(canCopy ? "Copies the dictation." : "")
    }

    /// "Mail · 10:16 AM": where it went, then when.
    private var head: String {
        let d = transcript.createdAt
        let when = Calendar.current.isDateInToday(d) ? Formats.style(date: .none, time: .short).string(from: d) : HomeRecentStyle.day(d)
        guard let place, !place.isEmpty else { return when }
        return "\(place) · \(when)"
    }

    private var copyPill: some View {
        ZStack(alignment: .trailing) {
            PillLabel(title: "Copy", kind: .line, size: .mini, icon: .iconCopy)
                .opacity(copied ? 0 : 1)
                .offset(y: copied && !limitMotion ? -4 : 0)
            PillLabel(title: "Copied", kind: .dark, size: .mini, icon: .homeCheck)
                .opacity(copied ? 1 : 0)
                .offset(y: copied || limitMotion ? 0 : 4)
        }
        .accessibilityHidden(true)
    }

    private func copyNow(_ text: String) {
        copy(text)
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
