import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Home (approved mockup "HomeC", October 2026): a greeting with today's numbers, a persimmon Record panel, four
/// start tiles (Dictate, Import, App audio, Live captions), This week, the compact Method cards, Recent recordings,
/// and Recent dictations. Every icon is a brand icon (HomeKit.swift); surfaces are opaque paper.
/// Wide windows set the panel and tiles side by side (1.15 : 1); narrow windows stack them.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var sites = SiteLog.shared
    @ObservedObject private var flow = FlowSettings.shared
    @ObservedObject private var captions = LiveCaptions.shared
    @AppStorage(YouProfile.nameKey) private var storedName = ""
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var width: CGFloat = 900
    /// Moves on each minute, so the greeting and today's numbers follow the clock.
    @State private var now = Date()
    @State private var mic: AudioDevices.Device? = AudioDevices.current()
    @State private var importOpen = false
    @State private var fileOver = false
    @State private var recordHover = false
    @State private var recordReplay = 0

    private static let gap: CGFloat = 14
    private var wide: Bool { width >= 680 }
    /// Tiles tighten (smaller disc and padding) when their column is narrow, as in the 1000-pt screenshot window.
    private var tileMetrics: HomeTileMetrics { wide && columns(width).1 < 380 ? .macCompact : .mac }
    private func columns(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let left = ((total - Self.gap) * 1.15 / 2.15).rounded(.down)
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
                if app.showsWelcomeCard { method.padding(.top, 6).staggerIn(2) }
                recentRow.padding(.top, 6).staggerIn(3)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { _, w in width = w }
            })
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
        .onChange(of: app.focusLink) { _, _ in importOpen = true }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in mic = AudioDevices.current(); now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in let m = AudioDevices.current(); if m != mic { mic = m } }
    }

    // MARK: Header

    private var greeting: String {
        HomeGreeting.line(name: HomeGreeting.firstName(YouProfile.displayName(storedName)), hour: Calendar.current.component(.hour, from: now))
    }
    private var wordsToday: Int {
        log.events.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }.reduce(0) { $0 + $1.words }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(HomeGreeting.dateLine(now)).font(Ink.mono(11)).tracking(2).foregroundStyle(Ink.mute)
                ViewThatFits(in: .horizontal) {
                    Text(greeting).font(Ink.serif(46)).fixedSize()
                    Text(greeting).font(Ink.serif(38)).fixedSize()
                    Text(greeting).font(Ink.serif(34)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Ink.ink)
                .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 24) {
                stat(wordsToday.formatted(), wordsToday == 1 ? "word dictated today" : "words dictated today")
                let n = HomeCounts.recordingsToday(app.store.live, now: now)
                stat("\(n)", n == 1 ? "recording today" : "recordings today")
            }
        }
        .padding(.bottom, 6)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(Ink.serif(28)).foregroundStyle(Ink.ink)
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.mute)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    // MARK: Record, tiles, This week

    @ViewBuilder private var startRow: some View {
        if wide {
            let cols = columns(width)
            HStack(alignment: .top, spacing: Self.gap) {
                recordPanel.frame(width: cols.0).frame(maxHeight: .infinity)
                VStack(spacing: 12) { tiles; weekCard }.frame(width: cols.1)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 12) {
                recordPanel.frame(minHeight: 210)
                tiles
                weekCard
            }
        }
    }

    private var recording: Bool { app.recorder.isRecording || app.capture.isCapturing }
    /// Reader white on persimmon, as approved; ink under Increase Contrast (white on persimmon is 2.8:1).
    private var onPersimmon: Color { contrast == .increased ? Ink.inkFixed : Ink.readerFixed }
    private var micName: String { mic?.name ?? "Microphone" }

    private var recordOverline: String {
        if app.capture.isCapturing { return "Capturing · \(app.capture.appName)" }
        if app.recorder.isRecording { return app.recorder.isPaused ? "Paused" : "Recording" }
        return "Ready · \(micName)"
    }

    private var recordPanel: some View {
        Button { app.requestRecord() } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(recordOverline.uppercased()).font(Ink.mono(11)).tracking(1.8).lineLimit(1)
                    Spacer(minLength: 12)
                    Text("⌥⇧R").font(Ink.mono(11)).tracking(1.2)
                }
                Spacer(minLength: 16)
                Group {
                    if app.recorder.isRecording { LiveHomeMeter(live: app.recorder.live, bars: 28, barWidth: 6, gap: 8) }
                    else if app.capture.isCapturing { LiveHomeMeter(live: app.capture.live, bars: 28, barWidth: 6, gap: 8) }
                    else { HomeMeter(bars: 28, barWidth: 6, gap: 8, heights: HomeMeter.macHeights, color: onPersimmon) }
                }
                .frame(height: 64)
                Spacer(minLength: 16)
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Ink.readerFixed)
                        DrawOnGlyph(art: .capture, color: Color(hex: Ink.persimmonHex), lineWidth: 1.6, replay: recordReplay).frame(width: 30, height: 30)
                    }
                    .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recording ? "Recording" : "Record").font(Ink.serif(34))
                        Text(recording ? "Pause or stop from the bar above." : "A voice note, a meeting, or a thought.")
                            .font(.system(size: 13)).opacity(0.9).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .foregroundStyle(onPersimmon)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 250)
            .background(Ink.persimmon, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
        .disabled(recording)
        .offset(y: recordHover && !limitMotion && !recording ? -2 : 0)
        .onHover { h in recordHover = h; if h { recordReplay += 1 } }
        .animation(HomeMotion.lift, value: recordHover)
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

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 12) {
            Group {
                HomeTile(title: "Dictate",
                         detail: app.dictation.accessibilityTrusted ? app.dictation.hotkey.shortTitle : "Needs Accessibility",
                         fill: Ink.butter, metrics: tileMetrics, hint: "Shows your dictation key and your last dictation.") {
                    app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate"
                } icon: { replay in
                    DrawOnGlyph(art: .iconDictations, color: Ink.inkFixed, lineWidth: 1.8, replay: replay)
                }
                .popover(isPresented: dictateOpen, arrowEdge: .bottom) { DictateControls().padding(16).environmentObject(app) }
                .contextMenu { DictateMenu() }
                .uiTarget("mode-dictate")

                HomeTile(title: "Import", detail: fileOver ? "Drop to transcribe" : "File or link",
                         fill: Ink.sage, edge: fileOver ? Ink.inkFixed : .clear, metrics: tileMetrics, hint: "Choose files, or paste a link to transcribe.") {
                    importOpen = true
                } icon: { replay in
                    DrawOnGlyph(art: .document, color: Ink.inkFixed, lineWidth: 1.6, replay: replay)
                }
                .popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }).environmentObject(app) }
                .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                .uiTarget("tile-import")
            }
            Group {
                HomeTile(title: "App audio", detail: "Record another app", fill: Ink.petal, metrics: tileMetrics,
                         hint: "Choose an app to record its sound, like a call or a video.") {
                    app.pickApp()
                } icon: { _ in
                    PulsingRingsGlyph(color: Ink.inkFixed, lineWidth: 1.8)
                }
                .contextMenu {
                    Button("Choose an app…") { app.pickApp() }
                    Divider()
                    Button("Screen & System Audio Recording settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                .uiTarget("tile-app")

                HomeTile(title: "Live captions", detail: captions.isOpen ? "On screen now" : "⌥⌘C",
                         fill: Ink.inkFixed, onFill: Color(hex: Ink.paperHex), disc: Ink.readerFixed.opacity(0.14), edge: Ink.hairline,
                         metrics: tileMetrics, hint: "Shows captions in a floating panel, from your microphone or an app's sound.") {
                    app.toggleLiveCaptions()
                } icon: { replay in
                    TwinkleRefineGlyph(color: Color(hex: Ink.paperHex), lineWidth: 1.6, replay: replay)
                }
                .uiTarget("tile-captions")
            }
        }
    }

    private var weekCard: some View {
        let week = HomeWeek(log.events.map { HomeWordEntry(date: $0.date, words: $0.words, seconds: $0.seconds) }, now: now)
        let start = week.days.first?.start ?? now
        let end = week.days.last.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0.start) } ?? now
        // Time saved counts the same way as You (talking and processing time come off).
        let saved = ActivityStats(log.events.filter { $0.date >= start && $0.date < end }, since: nil).secondsSaved(typingWPM: flow.typingWPM)
        return HomeWeekCard(week: week, saved: saved, compact: false) {
            Text("·").foregroundStyle(Ink.mute)
            Button { app.go(.activity) } label: {
                Text("You →").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ink).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("You")
            .accessibilityHint("Opens your week, cleanup, and where you dictate.")
        }
        .uiTarget("home-week")
    }

    // MARK: Method

    private var method: some View {
        let live = app.store.live
        let latest = HomeCounts.latestRefinable(live)
        let animated = HomeMotion.enabled
        return VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader(index: "01", label: "Method")
            HStack(alignment: .top, spacing: 12) {
                CompactMethodCard(feature: .capture, line: "Record, dictate, or import a file or link.",
                                  meta: HomeCounts.countLabel(live.filter { !$0.isDictation }.count, "transcript", "transcripts"),
                                  animated: animated, hint: "Starts a voice note.") { app.requestRecord() }
                    .uiTarget("card-capture")
                CompactMethodCard(feature: .refine, line: "Clean up a transcript. The original stays.",
                                  meta: latest.map { "Latest: \($0.title)" } ?? "Nothing to refine yet", enabled: latest != nil,
                                  animated: animated, hint: "Opens your latest transcript as a document.") {
                    guard let t = latest else { return }
                    app.go(.transcript(t.id))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .verbatimShowMode, object: "Document") }
                }
                CompactMethodCard(feature: .understand, line: "Search, moments, and summaries.",
                                  meta: HomeCounts.countLabel(HomeCounts.momentsSaved(live), "moment saved", "moments saved"),
                                  animated: animated, hint: "Opens your saved moments.") { app.go(.moments) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
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
                    Button { app.go(.transcript(t.id)) } label: { HomeRecentRow(transcript: t, compact: false) }
                        .buttonStyle(HomePressStyle())
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
            EmptyStateArt(art: app.search.isEmpty ? .capture : .search, tint: app.search.isEmpty ? Ink.persimmonTint : Ink.butterTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.search.isEmpty ? "Record something new." : "Nothing found for “\(app.search)”").font(Ink.serif(20)).foregroundStyle(Ink.ink)
                Text(app.search.isEmpty ? "Recordings and imports land here, ready to review." : "Search looks at titles and every transcript's text.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 14)
    }

    private var recentDictations: some View {
        let items = Array(app.store.live.filter { $0.source == .dictation }.sorted { $0.createdAt > $1.createdAt }.prefix(3))
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
