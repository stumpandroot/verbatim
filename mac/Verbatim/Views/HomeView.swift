import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Home (approved mockup Home D, October 22, 2026, with the card feel Tim chose that day; mac/DESIGN.md §6): a
/// greeting under a sans date line, the Record panel, four start tiles (Dictate, Import, App audio, Live captions),
/// This week (the only stats), three Method cards, Recent recordings, and Recent dictations. One 12-column grid: every
/// band splits at the same 7 / 5 edge. Every icon is a bare brand icon (HomeKit.swift); surfaces are opaque. Every
/// card tilts, lifts, and catches the light on hover (`HomeCard`). Narrow windows stack the bands.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var sites = SiteLog.shared
    @ObservedObject private var captions = LiveCaptions.shared
    @AppStorage(YouProfile.nameKey) private var storedName = ""
    @Environment(\.limitMotion) private var limitMotion
    @State private var width: CGFloat = 900
    /// Moves on each minute, so the greeting and today's numbers follow the clock.
    @State private var now = Date()
    @State private var mic: AudioDevices.Device? = AudioDevices.current()
    @State private var importOpen = false
    @State private var fileOver = false
    @State private var recordReplay = 0
    /// Listens to the mic while the pointer is over Record, so the meter shows your real level (DESIGN.md §7).
    @StateObject private var monitor = HomeLevelMonitor()

    /// The gutter between columns and between bands.
    private static let gap: CGFloat = 16
    /// Side margin around the grid, and the widest the grid gets.
    private static let margin: CGFloat = 40
    private static let maxContent: CGFloat = 1100
    /// The grid's width for a scroll view `available` points wide: the space inside the margins, at most 1100.
    static func contentWidth(_ available: CGFloat) -> CGFloat { min(maxContent, max(280, available - 2 * margin)) }
    private var wide: Bool { width >= 680 }
    /// Tiles tighten (smaller icon and padding) when their column is narrow, as in the 1000-pt screenshot window.
    private var tileMetrics: HomeTileMetrics { wide && columns(width).1 < 380 ? .macCompact : .mac }
    /// The 7 / 5 split of a 12-column grid with `gap` gutters: (7 columns + 6 gutters, 5 columns + 4 gutters).
    private func columns(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let column = (total - 11 * Self.gap) / 12
        let left = (7 * column + 6 * Self.gap).rounded(.down)
        return (left, total - Self.gap - left)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.gap) {
                header.staggerIn(0)
                Group {
                    if app.recorder.isRecording { RecordPanel() }
                    else if app.capture.isCapturing { CapturePanel() }
                }
                .animation(Motion.settle, value: app.recorder.isRecording)
                .animation(Motion.settle, value: app.capture.isCapturing)
                startRow.staggerIn(1)
                if app.showsWelcomeCard { method.padding(.top, 4).staggerIn(2) }
                recentRow.padding(.top, 10).staggerIn(3)
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, Self.margin).padding(.top, 36).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        // The space Home has to work with comes from the scroll view, which always takes the window's full width.
        // Measuring the content instead was circular: its bands are sized from `width`, so a window narrower than
        // the starting guess kept the wide layout and slid under the sidebar.
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = Self.contentWidth(g.size.width) }
                .onChange(of: g.size.width) { _, w in width = Self.contentWidth(w) }
        })
        .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
        .onChange(of: app.focusLink) { _, _ in importOpen = true }
        .onChange(of: recording) { _, on in if on { monitor.stop() } }
        .onDisappear { monitor.stop() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in mic = AudioDevices.current(); now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in monitor.stop() }
        // UserDefaults posts on whichever thread wrote the setting (the speaker models mark themselves ready from a
        // background actor); Home state changes only on the main thread.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in let m = AudioDevices.current(); if m != mic { mic = m } }
    }

    // MARK: Header

    private var greeting: String {
        HomeGreeting.line(name: HomeGreeting.firstName(YouProfile.displayName(storedName)), hour: Calendar.current.component(.hour, from: now))
    }

    /// The date in sentence-case sans and the greeting in the serif. No stats here: they live in This week.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HomeGreeting.dateLine(now)).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.mute)
            ViewThatFits(in: .horizontal) {
                Text(greeting).font(Ink.serif(46)).fixedSize()
                Text(greeting).font(Ink.serif(38)).fixedSize()
                Text(greeting).font(Ink.serif(34)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Ink.ink)
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, 8)
    }

    // MARK: Record, tiles, This week

    @ViewBuilder private var startRow: some View {
        if wide {
            let cols = columns(width)
            HStack(alignment: .top, spacing: Self.gap) {
                recordPanel.frame(width: cols.0).frame(maxHeight: .infinity)
                VStack(spacing: 12) { tiles; weekCard.frame(minHeight: 100) }.frame(width: cols.1)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 12) {
                recordPanel.frame(minHeight: 230)
                tiles
                weekCard
            }
        }
    }

    private var recording: Bool { app.recorder.isRecording || app.capture.isCapturing }
    /// Ink on the Record fill (#FB7350): 4.7:1, so every line passes at any size. White would be 2.8:1.
    private var onRecord: Color { Ink.inkFixed }
    private var micName: String { mic?.name ?? "Microphone" }

    private var recordStatus: String {
        if app.capture.isCapturing { return "Capturing · \(app.capture.appName)" }
        if app.recorder.isRecording { return app.recorder.isPaused ? "Paused" : "Recording" }
        if app.savingRecording { return "Saving…" }
        return "Ready · \(micName)"
    }

    private var recordPanel: some View {
        HomeCard(tilt: 2, radius: Radius.record, enabled: !recording, onHover: { h in
            if h {
                recordReplay += 1
                if !recording { monitor.listen(after: 0.12) }
            } else {
                monitor.stop(after: 0.4)
            }
        }, action: {
            monitor.stop()
            app.requestRecord()
        }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(onRecord).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(recordStatus).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 12)
                    Keycap(keys: "⌥⇧R")
                }
                Spacer(minLength: 16)
                // Real level while recording and while the pointer rests here; an even breath otherwise.
                Group {
                    if app.recorder.isRecording { LiveHomeMeter(live: app.recorder.live, barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                    else if app.capture.isCapturing { LiveHomeMeter(live: app.capture.live, barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                    else if monitor.listening { LiveHomeMeter(live: monitor.live, barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                    else { BreathingHomeMeter(barWidth: 7, gap: 7, heights: HomeMeter.macHeights, color: onRecord) }
                }
                .frame(height: 72)
                Spacer(minLength: 16)
                HStack(alignment: .bottom, spacing: 14) {
                    // Bare: no disc behind the mic.
                    DrawOnGlyph(art: .capture, color: onRecord, lineWidth: 2, replay: recordReplay, duration: 0.55)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recording ? "Recording" : "Record").font(Ink.serif(34))
                        Text(recording ? "Pause or stop from the bar above." : "A voice note, a meeting, or a thought.")
                            .font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .foregroundStyle(onRecord)
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 296)
            .background(Ink.recordFill, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
        .contextMenu { RecordMenu(onChange: { mic = AudioDevices.current() }) }
        .help("Recording from \(micName). Right-click to change the microphone.")
        .accessibilityLabel(recording ? "Recording" : "Record")
        .accessibilityValue(recording ? "" : "Microphone: \(micName)")
        .accessibilityHint("Starts a voice note. Shortcut: Option Shift R.")
        .uiTarget("tile-record")
    }

    private var dictateOpen: Binding<Bool> {
        Binding(get: { app.captureMode == "dictate" && !recording },
                set: { open in if !open && app.captureMode == "dictate" { app.captureMode = "voice" } })
    }

    /// "hold right ⌘" → ("Hold to talk in any app", "right ⌘"): what it does in sans, and the key as a keycap.
    private var dictateKey: (String, String?) {
        guard app.dictation.accessibilityTrusted else { return ("Needs Accessibility", nil) }
        let title = app.dictation.hotkey.shortTitle
        if title.hasPrefix("hold right ") { return ("Hold to talk in any app", "right " + title.dropFirst("hold right ".count)) }
        if title.hasPrefix("hold ") { return ("Hold to talk in any app", String(title.dropFirst("hold ".count))) }
        return (title.prefix(1).uppercased() + title.dropFirst(), nil)
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 12) {
            Group {
                HomeTile(title: "Dictate", detail: dictateKey.0, keycap: dictateKey.1,
                         fill: Ink.butter, metrics: tileMetrics, hint: "Shows your dictation key and your last dictation.") {
                    app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate"
                } icon: { replay in
                    DrawOnGlyph(art: .iconDictations, color: Ink.inkFixed, lineWidth: 1.5, replay: replay, duration: 0.55)
                }
                .popover(isPresented: dictateOpen, arrowEdge: .bottom) { DictateControls().padding(16).environmentObject(app) }
                .contextMenu { DictateMenu() }
                .uiTarget("mode-dictate")

                HomeTile(title: "Import", detail: fileOver ? "Drop to transcribe" : "A file or a link", keycap: "⌘O",
                         fill: Ink.sage, edge: fileOver ? Ink.inkFixed : .clear, edgeWidth: 1.5, metrics: tileMetrics, hint: "Choose files, or paste a link to transcribe.") {
                    importOpen = true
                } icon: { replay in
                    DrawOnGlyph(art: .document, color: Ink.inkFixed, lineWidth: 1.5, replay: replay, duration: 0.55)
                }
                .popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }).environmentObject(app) }
                .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                .uiTarget("tile-import")
            }
            Group {
                HomeTile(title: "App audio", detail: "Another app", fill: Ink.petal, metrics: tileMetrics,
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

                // Paper with an ink outline, so it never outweighs Record.
                HomeTile(title: "Live captions", detail: captions.isOpen ? "On screen now" : "Words as they're said", keycap: "⌥⌘C",
                         fill: Ink.card, onFill: Ink.ink, edge: Ink.ink, edgeWidth: 1.5,
                         metrics: tileMetrics, hint: "Shows captions in a floating panel, from your microphone or an app's sound.") {
                    app.toggleLiveCaptions()
                } icon: { replay in
                    DrawOnGlyph(art: .iconCaptions, color: Ink.ink, lineWidth: 1.5, replay: replay, duration: 0.55)
                }
                .uiTarget("tile-captions")
            }
        }
    }

    /// This week is one button: anywhere on it opens You. "You →" stays as a visual cue inside it.
    private var weekCard: some View {
        let week = HomeWeek(log.events.map { HomeWordEntry(date: $0.date, words: $0.words, seconds: $0.seconds) }, now: now)
        let today = HomeCounts.recordingsToday(app.store.live, now: now)
        return HomeCard(tilt: 3, radius: Radius.tile, action: { app.go(.activity) }) { _ in
            HomeWeekCard(week: week, recordingsToday: today, compact: false) {
                Text("·").foregroundStyle(Ink.mute)
                Text("You →").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ink)
            }
        }
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")). Today: \(HomeCounts.countLabel(today, "recording", "recordings")).")
        .accessibilityHint("Opens You: your week, cleanup, and where you dictate.")
        .uiTarget("home-week")
    }

    // MARK: Method

    /// Three full-color cards across all 12 columns (DESIGN.md §6.4), each with its looping diagram.
    private var method: some View {
        let live = app.store.live
        let latest = HomeCounts.latestRefinable(live)
        return HStack(alignment: .top, spacing: Self.gap) {
            MethodCard(feature: .capture, line: "Record, dictate, or import.",
                       meta: HomeCounts.countLabel(live.filter { !$0.isDictation }.count, "transcript", "transcripts"),
                       hint: "Starts a voice note.") { app.requestRecord() }
                .uiTarget("card-capture")
            MethodCard(feature: .refine, line: "Clean up. The original stays.",
                       meta: latest.map { "Latest: \($0.title)" } ?? "Nothing to refine yet", enabled: latest != nil,
                       hint: "Opens your latest transcript as a document.") {
                guard let t = latest else { return }
                app.go(.transcript(t.id))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .verbatimShowMode, object: "Document") }
            }
            MethodCard(feature: .understand, line: "Search and summaries.",
                       meta: HomeCounts.countLabel(HomeCounts.momentsSaved(live), "moment saved", "moments saved"),
                       hint: "Opens your saved moments.") { app.go(.moments) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Method")
        .uiTarget("home-method")
    }

    // MARK: Recent

    @ViewBuilder private var recentRow: some View {
        if wide {
            let cols = columns(width)
            HStack(alignment: .top, spacing: Self.gap) {
                recentRecordings.frame(width: cols.0)
                recentDictations.frame(width: cols.1)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                recentRecordings
                recentDictations
            }
        }
    }

    private var recentRecordings: some View {
        let items = Array(app.archive.prefix(4))
        return VStack(alignment: .leading, spacing: 8) {
            HomeSectionTitle(title: "Recent recordings", link: "Library", linkHint: "Opens your library.") { app.go(.library) }
            if items.isEmpty {
                emptyRecordings
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    HomeCard(tilt: 2, radius: Radius.row, action: { app.go(.transcript(t.id)) }) { hovering in
                        HomeRecentRow(transcript: t, compact: false, hovering: hovering)
                    }
                        .contextMenu { RowMenu(transcript: t) }
                        .accessibilityHint("Opens the transcript.")
                        .uiTarget("row-\(i)")
                }
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    private var emptyRecordings: some View {
        HStack(spacing: 14) {
            EmptyStateArt(art: app.search.isEmpty ? .capture : .search, tint: app.search.isEmpty ? Ink.persimmonTint : Ink.neutralChip)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.search.isEmpty ? "Record something new." : "Nothing found for “\(app.search)”").font(Ink.serif(20)).foregroundStyle(Ink.ink)
                Text(app.search.isEmpty ? "Recordings and imports land here, ready to review." : "Search looks at titles and every transcript's text.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.row)
    }

    private var recentDictations: some View {
        let items = Array(app.store.live.filter { $0.source == .dictation }.sorted { $0.createdAt > $1.createdAt }.prefix(4))
        let key = app.dictation.hotkey.shortTitle
        return VStack(alignment: .leading, spacing: 8) {
            HomeSectionTitle(title: "Recent dictations", link: "All dictations", linkHint: "Opens every dictation.") { app.go(.dictations) }
            HomeDictationsPanel(items: items, compact: false,
                                place: { t in sites.hosts[t.id] ?? t.flow?.app },
                                copy: { Paster.copy($0) },
                                empty: "\(key.prefix(1).uppercased() + String(key.dropFirst())) in any app and speak. What you say shows up here.")
        }
        .uiTarget("home-dictations")
        .animation(Motion.settle, value: items.map(\.id))
    }
}
