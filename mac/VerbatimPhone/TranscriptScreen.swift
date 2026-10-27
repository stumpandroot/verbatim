import SwiftUI
import Combine
import UIKit

/// A transcript, in the website style: the eyebrow (kind · date · length) over the recording's name as the big serif
/// title, the Summary on a butter panel with grain and the strands drawing, the Original / Cleaned switch (plus Review
/// once something was corrected), speaker pills with mono timecodes over the text at a comfortable size, and the dark
/// player at the bottom edge (the tab bar hides while you read). Long-press a line to bookmark it, add a note, copy it, or open the video at
/// that moment. Copy takes the tab you're on.
struct TranscriptScreen: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    var startMode: Mode = .transcript
    /// `result`: the template results tab (TemplatesScreens.swift), once a template ran or is running here.
    enum Mode: Hashable { case transcript, document, review, result }
    @State private var mode: Mode = .transcript
    /// This screen's place in `PhoneState.readingScreens`.
    @State private var readingToken = UUID()
    @State private var showNotes = false
    @State private var shareItems: [Any]? = nil
    @State private var noteFor: Segment? = nil
    @State private var noteText = ""
    @State private var downloading = false
    @State private var didStart = false
    /// "2 filler lines hidden · Show": per screen, starting from Settings › Hide filler lines.
    @State private var showFiller = false
    @AppStorage(Transcript.hideFillerKey) private var hideFillerSetting = true
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false
    /// Why Summarize can't run here (Apple Intelligence unavailable), shown when the action is chosen.
    @State private var summaryUnavailable: String? = nil
    /// Transcribe again with Whisper Turbo's question is showing.
    @State private var askTurbo = false
    /// Original tab: the engine's own words instead of the corrected lines.
    @State private var showEngine = false
    /// Original tab: one selectable text, for selecting across lines.
    @State private var selecting = false
    /// The transcript action whose result sheet is open.
    @State private var runningAction: TranscriptActionSpec? = nil
    /// Scroll to the playing line. Turns off when you scroll yourself; the dock's Follow turns it back on.
    @State private var follow = true
    @State private var followed: UUID? = nil
    /// Opened from a search passage: where the audio starts.
    @State private var pendingSeek: Double? = nil
    /// The scrubber's scroll state (TranscriptScrubber.swift). A plain reference, not observed here, so scrolling
    /// re-renders only the scrubber.
    @State private var scrub = TranscriptScrubModel()
    /// The player dock's height with its bottom margin; the scrubber's track ends above it.
    @State private var dockHeight: CGFloat = 64
    /// The transcript is long enough for the scrubber, which then replaces the system scroll indicator.
    @State private var scrubLong = false
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    /// Native's More menu: Find, Summary, Speakers, and Details open sheets; Delete asks first.
    @State private var showFind = false
    @State private var showSummary = false
    @State private var showSpeakers = false
    @State private var showDetails = false
    @State private var confirmDelete = false
    /// A line Find picked, scrolled to once the sheet has gone.
    @State private var scrollTarget: UUID? = nil

    private static let scrollSpace = "transcript-scroll"

    /// The player dock shows under the Original and Review tabs of a recording with audio.
    private func hasDock(_ t: Transcript) -> Bool { t.audioFileName != nil && t.status == .ready && mode != .document }

    /// The Original tab's lines as shown: filler and background voices left out, the engine's words when chosen.
    private func shownLines(_ t: Transcript) -> [Segment] {
        // Worked out once per transcript change, not on every render (Store+Memo.swift).
        let shown = app.store.displaySegments(t.id, hideFiller: hideFillerSetting && !showFiller, mainOnly: mainSpeakerOnly)
        return showEngine ? t.engineLines(for: shown) : shown
    }

    /// What Copy takes on this tab.
    private var copyVersion: Exporter.CopyVersion { mode == .document ? .cleaned : .original }

    private var t: Transcript? { app.store.transcript(id) }

    var body: some View {
        Group {
            if let t {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(t)
                                if t.status == .ready {
                                    // Native: the summary is in More › Summary, a sheet.
                                    if !look.isNative {
                                    PhoneSummaryPanel(transcript: t,
                                                      onSummarize: { replacing in SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: replacing) },
                                                      onSave: { s in app.store.update(t.id) { $0.summary = s; $0.summaryByModel = false } })
                                        .padding(.top, 16)
                                    }
                                    PhoneSegmented(options: modes(t), selection: $mode)
                                        .padding(.top, 16)
                                        .onChange(of: t.corrections.isEmpty) { _, none in if none, mode == .review { mode = .transcript } }
                                }
                                content(t).padding(.top, 14)
                            }
                            .padding(.horizontal, 20).padding(.top, 4)
                            .padding(.bottom, t.audioFileName != nil && t.status == .ready && mode != .document ? 120 : 32)
                            .scrubContent(scrub, in: Self.scrollSpace)
                        }
                        .coordinateSpace(.named(Self.scrollSpace))
                        .scrubTracking(scrub)
                        .scrollIndicators(scrubLong && t.status == .ready && mode == .transcript && !selecting ? .hidden : .automatic)
                        .onReceive(scrub.$long.removeDuplicates()) { scrubLong = $0 }
                        .scrollDismissesKeyboard(.interactively)
                        .onManualScroll { if app.player.isPlaying, follow { follow = false } }
                        .onAppear {
                            // Opened from a search passage, a note, or a link: land on that line and start the audio there.
                            if let f = app.focusSegment, let s = t.segments.first(where: { $0.id == f }) {
                                app.focusSegment = nil; mode = .transcript
                                pendingSeek = s.start
                                app.player.seek(to: s.start)
                                DispatchQueue.main.async { proxy.scrollTo(f, anchor: .center) }
                            }
                        }
                        .onReceive(app.player.clock.$time) { now in
                            // Follow playback, only when the playing line changes (not on every tick).
                            guard follow, app.player.isPlaying, mode == .transcript, !selecting,
                                  let s = PlaybackSync.line(at: now, in: t.segments), s.id != followed else { return }
                            followed = s.id
                            withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                        }
                        .onChange(of: scrollTarget) { _, id in
                            guard let id else { return }
                            proxy.scrollTo(id, anchor: .center)
                            scrollTarget = nil
                        }
                        .onChange(of: follow) { _, on in
                            // Follow turned back on: go to the playing line now.
                            guard on, let s = PlaybackSync.line(at: app.player.time, in: t.segments) else { return }
                            followed = s.id
                            withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                        }
                        // Long transcripts: hold the right edge and drag to move fast. Original tab only, not in Select text.
                        if t.status == .ready, mode == .transcript, !selecting {
                            TranscriptScrubber(model: scrub,
                                               lines: { shownLines(t) },
                                               end: ScrubMath.scaleEnd(starts: t.segments.map(\.start), ends: t.segments.map(\.end)),
                                               speaker: { s in t.speakers.count >= 2 ? t.speakerName(s.speaker) : nil },
                                               speakerColor: { s in PhoneLines.speakerColor(t, s.speaker) },
                                               jump: { s in
                                                   var tr = Transaction(); tr.disablesAnimations = true
                                                   withTransaction(tr) { proxy.scrollTo(s.id, anchor: .top) }
                                               },
                                               onBegin: { if app.player.isPlaying, follow { follow = false } })
                                .padding(.top, 8)
                                .padding(.bottom, hasDock(t) ? dockHeight + 8 : 8)
                        }
                        if hasDock(t) {
                            PhoneDock(transcript: t, clock: app.player.clock, downloading: downloading, follow: $follow)
                                .padding(.horizontal, 22).padding(.bottom, 10)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                        }
                    }
                    .coordinateSpace(.named(TranscriptScrubber.frameSpace))
                }
                .phoneTopFade()
                .phonePage(plain: true)
                .navigationBarTitleDisplayMode(.inline)
                // Reading: the tab bar goes, and the player sits at the bottom edge instead of floating over it.
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    if look.isNative {
                        // Native: two glass controls beside Back, Share and More (Books' reading menu).
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button { app.exportRequest = PhoneExportRequest(ids: [t.id]) } label: { Image(systemName: "square.and.arrow.up") }   // brand: native
                                .accessibilityLabel("Share")
                                .disabled(t.status != .ready)
                            nativeMore(t)
                        }
                    } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if t.status == .ready, t.audioFileName != nil, t.pendingAppend == nil {
                            Button { app.player.stop(); app.continueRecording(t.id) } label: { toolbarIcon(.capture, "toolbar-continue", "mic.badge.plus") }
                                .accessibilityLabel("Continue recording")
                        }
                        Button { showNotes = true } label: { toolbarIcon(.iconNotes, "toolbar-notes", "note.text") }.accessibilityLabel("Notes")
                        Menu {
                            Section("From the original transcript") {
                                PhoneActionItems { a in
                                    if let why = TranscriptActions.unavailableReason { summaryUnavailable = why } else { runningAction = a }
                                }
                            }
                            // A template's result stays in the transcript, in its own tab (TemplatesScreens.swift).
                            Menu {
                                ForEach(app.store.allTemplates) { tpl in
                                    Button(tpl.name) {
                                        if let why = TemplateCenter.unavailableReason { summaryUnavailable = why }
                                        else { TemplateCenter.shared.run(tpl.id, on: t.id, store: app.store); mode = .result }
                                    }
                                }
                            } label: { Label("Run a template", systemImage: "doc.text") }   // brand: system surface (menu)
                            Button {
                                if let why = SummaryAction.unavailableReason { summaryUnavailable = why }
                                else { SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: false) }
                            } label: { Label(SummaryAction.title(t), systemImage: "text.quote") }   // brand: system surface (menu)
                            .disabled(t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
                            // Whisper Turbo on the original audio, run by your Mac; and back to the words it replaced.
                            Section {
                                Button { askTurbo = true } label: { Label(TurboRerun.title + "…", systemImage: "arrow.counterclockwise") }
                                    .disabled(TurboRerun.unavailableReason(t) != nil)
                                if let other = TurboRerun.switchTitle(t) {
                                    Button { app.switchTranscriptVersion(t.id) } label: { Label(other, systemImage: "arrow.uturn.backward") }
                                }
                            }
                        } label: { toolbarIcon(.refine, "toolbar-actions", "sparkles") }
                        .accessibilityLabel("Actions")
                        .disabled(t.status != .ready)
                        Menu {
                            Button { app.copyText(t, copyVersion) } label: { Label(copyVersion == .cleaned ? "Copy cleaned text" : "Copy text", systemImage: "doc.on.doc") }   // brand: system surface (menu)
                            // The text with a header (title, date, duration, speakers, source, language) for an AI assistant.
                            Button { app.copyForAI(t) } label: { Label("Copy for AI", systemImage: "doc.on.clipboard") }   // brand: system surface
                            Menu {
                                Button { app.copyText(t, copyVersion, timestamps: true) } label: { Label("Copy with timestamps", systemImage: "clock") }   // brand: system surface (menu)
                                Button { app.copyText(t, copyVersion.other) } label: {
                                    Label(copyVersion == .cleaned ? "Copy the original" : "Copy the cleaned text", systemImage: "arrow.left.arrow.right")   // brand: system surface (menu)
                                }
                                Button { app.copyText(t, .engine) } label: { Label("Copy engine words", systemImage: "waveform") }   // brand: system surface (menu)
                                    .disabled(!t.hasEngineWords)
                            } label: { Label("More ways to copy", systemImage: "doc.on.clipboard") }   // brand: system surface (menu)
                            Divider()
                            Button { app.exportRequest = PhoneExportRequest(ids: [t.id]) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                            if let u = app.store.audioURL(for: t) {
                                Button { shareAudio(u) } label: { Label("Share original audio", systemImage: "waveform") }   // brand: system surface (menu)
                            }
                        } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Copy and export")
                        .disabled(t.status != .ready)
                    }
                    }
                }
                .sheet(isPresented: $showFind) {
                    TranscriptFindSheet(transcript: t, lines: shownLines(t)) { s in
                        showFind = false
                        app.player.seek(to: s.start)
                        mode = .transcript
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { scrollTarget = s.id }
                    }
                    .environmentObject(app)
                }
                .sheet(isPresented: $showSummary) { NativeSummarySheet(id: t.id).environmentObject(app) }
                .sheet(isPresented: $showSpeakers) { NativeSpeakersSheet(id: t.id).environmentObject(app) }
                .sheet(isPresented: $showDetails) { NativeTranscriptDetails(id: t.id).environmentObject(app) }
                .confirmationDialog("Move this transcript to Recently Deleted?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Move to Recently Deleted", role: .destructive) { app.delete([t.id]); dismiss() }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("You can restore it for 30 days.") }
                .sheet(item: $runningAction) { a in
                    PhoneActionSheet(action: a, transcript: t).environmentObject(app).presentationDetents([.large])
                }
                .alert("Apple Intelligence is off", isPresented: Binding(get: { summaryUnavailable != nil }, set: { if !$0 { summaryUnavailable = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(summaryUnavailable ?? "") }
                .alert(app.macCanTranscribe ? TurboRerun.title + "?" : "This needs your Mac", isPresented: $askTurbo) {
                    if app.macCanTranscribe {
                        Button("Cancel", role: .cancel) {}
                        Button("Send to Mac") { app.requestTurbo(t.id) }
                    } else {
                        Button("OK", role: .cancel) {}
                    }
                } message: { Text(app.macCanTranscribe ? TurboRerun.message(t, onMac: false, needsDownload: false) : TurboRerun.needsMac) }
                .sheet(isPresented: $showNotes) { NotesSheet(id: id).presentationDetents([.medium, .large]) }
                .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ShareSheet(items: shareItems ?? []) }
                .alert("Add a note", isPresented: Binding(get: { noteFor != nil }, set: { if !$0 { noteFor = nil } })) {
                    TextField("Note", text: $noteText)
                    Button("Cancel", role: .cancel) { noteText = "" }
                    Button("Add") { if let s = noteFor { app.addNote(id, text: noteText, at: s.start, segment: s.id) }; noteText = "" }
                } message: { Text(noteFor.map { "At \($0.start.timecode)" } ?? "") }
                .onAppear {
                    if !didStart {
                        didStart = true; mode = startMode
                        // Show the result first: a transcript with an automatic template result opens on it.
                        if startMode == .transcript, TemplateSettingsModel.shared.settings.showFirst, t.shownTemplateResults.contains(where: { $0.auto }) { mode = .result }
                    }
                    if let u = app.store.audioURL(for: t) {
                        downloading = !Cloud.isDownloaded(u)
                        app.player.loadAsync(u, startAt: pendingSeek)
                        if downloading { Task { _ = await Cloud.ensureDownloaded(u); downloading = false } }
                        // Opened from a recording's play pill (Premium Native): play once the audio is open.
                        if app.autoplay == t.id {
                            app.autoplay = nil
                            Task { @MainActor in
                                for _ in 0..<200 where !app.player.canPlay { try? await Task.sleep(nanoseconds: 50_000_000) }
                                if app.player.canPlay, !app.player.isPlaying { app.player.toggle() }
                            }
                        }
                    }
                }
                .onDisappear { app.player.stop() }
                .skipsSponsors(t, player: app.player)
            } else {
                Text("This transcript was deleted.").foregroundStyle(.lookMute).frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.paper)
            }
        }
        // Reading: Native's Record accessory turns off with the tab bar (RecordAccessory.swift).
        .onAppear { app.readingScreens.insert(readingToken) }
        .onDisappear { app.readingScreens.remove(readingToken) }
    }

    /// A toolbar button's icon: the brand line icon in Verbose style, its SF Symbol in Native.
    private func toolbarIcon(_ art: BrandArt, _ key: String, _ symbol: String) -> Image {
        look.isNative ? Image(systemName: symbol) : Image(uiImage: art.templateImage(size: 22, key: key))   // brand: native
    }

    /// Shares the recording's audio file, after it downloads from iCloud when it lives on the other device.
    private func shareAudio(_ u: URL) {
        Task { @MainActor in
            if !Cloud.isDownloaded(u) { app.say("Downloading the audio…"); _ = await Cloud.ensureDownloaded(u) }
            guard FileManager.default.fileExists(atPath: u.path) else { app.say("The audio isn't on this iPhone yet. Try again in a moment."); return }
            shareItems = [u]
        }
    }

    /// Original and Cleaned; Review joins them once something was corrected.
    private func modes(_ t: Transcript) -> [(Mode, String)] {
        var out: [(Mode, String)] = [(.transcript, "Original"), (.document, "Cleaned")]
        if !t.corrections.isEmpty || mode == .review { out.append((.review, "Review")) }
        // A template's result: a tab named for it ("Meeting notes"), or "Results" with more than one.
        let busy = TemplateCenter.shared.busyTemplate(t.id).flatMap { id in app.store.allTemplates.first { $0.id == id }?.name }
        if let title = PhoneTemplateResults.tabTitle(t, busyName: busy) { out.append((.result, title)) }
        else if mode == .result { out.append((.result, "Template")) }
        return out
    }

    /// "Meeting · Thu Oct 22 · 07:50": the kind (or source), the day, and the length.
    static func eyebrow(_ t: Transcript) -> String {
        var parts = [t.kind?.label ?? HomeRecentStyle(t).source]
        let cal = Calendar.current
        parts.append(Formats.pattern(cal.isDate(t.createdAt, equalTo: Date(), toGranularity: .year) ? "EEE MMM d" : "EEE MMM d, yyyy").string(from: t.createdAt))
        if t.duration > 0 { parts.append(t.duration.timecode) }
        return parts.joined(separator: " · ")
    }

    /// The meta line under the title, before the language: what it is ("Voice note", "Audio file") when the eyebrow
    /// names the kind instead, and "2 speakers". Without a kind the eyebrow already names the source, so it isn't
    /// repeated ("YouTube" over "youtube.com").
    static func metaParts(_ t: Transcript) -> [String] {
        var parts: [String] = []
        if t.kind != nil { parts.append(HomeRecentStyle(t).source) }
        if t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
        return parts
    }

    /// Native's one line under the title: "Meeting · Today, 9:00 AM · 38:12 · 2 speakers".
    static func nativeMeta(_ t: Transcript, now: Date = Date()) -> String {
        var parts = [NativeRows.kind(t)]
        parts.append("\(HomeRecentStyle.day(t.createdAt, now: now)), \(Formats.style(date: .none, time: .short).string(from: t.createdAt))")
        if t.duration > 0 { parts.append(HomeRecentStyle.length(t.duration)) }
        if t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
        return parts.joined(separator: " · ")
    }

    private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Verbose style: the mono eyebrow over the serif title. Native: a bold title, then one meta line.
            if !look.isNative { PhoneEyebrow(text: Self.eyebrow(t)) }
            TextField("Title", text: Binding(get: { t.title }, set: { v in
                guard v != t.title else { return }
                app.store.updateDeferred(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
            }), axis: .vertical)
                .font(look.isNative ? .title.bold() : Ink.serif(titleSize)).tracking(look.isNative ? 0 : -0.6).foregroundStyle(.lookInk).lineLimit(1...4)
                .padding(.top, 2)
                .accessibilityLabel("Title")
            if look.isNative {
                // Native: the kind, day and time, length, and speakers in one line, then the language (Transcribe
                // again in…). Kind, tags, and where it was transcribed are in More › Details.
                HStack(spacing: 6) {
                    Text(Self.nativeMeta(t)).lineLimit(2)
                    if t.status == .ready && t.audioFileName != nil && t.pendingAppend == nil && t.source != .dictation {
                        Text("·")
                        TranscriptLanguageMenu(transcript: t)
                    }
                }
                .font(.subheadline).foregroundStyle(NativeInk.secondary)
            }
            // One meta line: what it is (when the eyebrow shows the kind instead), speakers, and the language. The
            // kind, day, and length are in the eyebrow above.
            let meta = Self.metaParts(t)
            let languageMenu = t.status == .ready && t.audioFileName != nil && t.pendingAppend == nil && t.source != .dictation
            let language = languageMenu ? nil : t.language.map(LanguageDetection.name)
            if !look.isNative, !meta.isEmpty || languageMenu || language != nil {
                HStack(spacing: 6) {
                    ForEach(Array(meta.enumerated()), id: \.offset) { i, part in
                        if i > 0 { Text("·") }
                        Text(part)
                    }
                    // The language it was transcribed in, and Transcribe again in… another one.
                    if languageMenu {
                        if !meta.isEmpty { Text("·") }
                        TranscriptLanguageMenu(transcript: t)
                    } else if let language {
                        if !meta.isEmpty { Text("·") }
                        Text(language)
                    }
                }
                .font(.system(size: 13)).foregroundStyle(.lookMute)
            }
            // Where the data went; tap it for the source file, engine, and exact time (PhoneTrust.swift).
            if t.status == .ready, !look.isNative { PhoneProvenanceLine(transcript: t) }
            if t.titleIsAuto && t.titleByModel { AITitleNote() }
            if t.status == .ready, !look.isNative {
                // Mini chips (28 pt, as mini pills), so the add-a-tag button fits inline after the last tag.
                KindAndTags(transcript: t, compact: true,
                            onPick: { k in app.store.update(t.id) { $0.kind = k; $0.kindIsAuto = false } },
                            onTags: { tags in app.store.update(t.id) { $0.tags = tags } })
                    .padding(.top, 8)
            }
            if t.status == .ready, !t.visibleSpeakerSuggestions.isEmpty {
                SpeakerSuggestionRows(transcript: t,
                                      onUse: { app.useSpeakerSuggestion(t.id, $0) },
                                      onDismiss: { app.dismissSpeakerSuggestion(t.id, $0) })
                    .padding(.top, 8)
            }
            if t.pendingAppend != nil {
                HStack(spacing: 8) {
                    if t.processingDevice != nil { ProgressView().controlSize(.small) } else { LookIcon(art: .capture, symbol: "mic.badge.plus", size: 18, color: Ink.accentText, nativeColor: NativeInk.secondary) }
                    LiveStage(t) { t in Text(t.stageText).font(.system(size: 14)).foregroundStyle(.lookDim).lineLimit(2) }
                    Spacer(minLength: 4)
                    if t.processingDevice == nil {
                        Menu {
                            Button { app.retry(t) } label: { Label("Try again", systemImage: "arrow.counterclockwise") }
                            Button(role: .destructive) { app.discardPendingAppend(t.id) } label: { Label("Discard new recording", systemImage: "trash") }
                        } label: { Text("Retry").font(.system(size: 14, weight: .semibold)) }
                    } else if t.processingDevice == Device.id {
                        Button("Cancel") { app.cancel(t.id) }.font(.system(size: 14))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.lookWash, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .padding(.top, 6)
            } else if t.rerunRequest != nil, t.status == .ready {
                // Transcribe again with Whisper Turbo, waiting for the Mac to pick it up.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    LiveStage(t) { t in Text(t.stageText).font(.system(size: 14)).foregroundStyle(.lookDim).lineLimit(2) }
                    Spacer(minLength: 4)
                    if t.processingDevice == nil { Button("Cancel") { app.cancelTurboRequest(t.id) }.font(.system(size: 14)) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Ink.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .padding(.top, 6)
            } else if t.status == .ready {
                // A progress tick can change the label (StageClock), so it's read live.
                LiveStage(t) { t in
                    if t.stage == "Finding speakers" {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Finding speakers…") }
                            .font(.system(size: 13)).foregroundStyle(.lookMute)
                    }
                }
            }
            if let info = t.linkInfo { PhoneLinkCard(info: info).padding(.top, 8) }
        }
        .task(id: t.id) { SpeakerNameSuggester.openedIfNeeded(t.id, store: app.store) }
    }

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing {
            HStack(spacing: 14) {
                SignalRings(active: t.processingDevice == Device.id).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    LiveStage(t) { t in Text(t.stageText).font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk) }
                    Text(t.processingDevice == Device.id ? "On this iPhone. The first run downloads the model once." : "It appears here when it's done.")
                        .font(.system(size: 14)).foregroundStyle(.lookMute)
                }
            }
            .padding(.top, 20)
        } else if t.status == .failed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) { IconGlyph(art: .iconAttention, size: 20, color: Ink.accentText); Text("Transcription did not finish") }.font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookAccentText)
                Text(t.error ?? "").font(.system(size: 14)).foregroundStyle(.lookMute)
                HStack(spacing: 8) {
                    Button("Retry") { app.retry(t) }.buttonStyle(.phonePrimary)
                    // Local Only refused this transcript's model download (PhoneTrust.swift).
                    PhoneAllowDownloadButton(transcript: t)
                }
            }
            .padding(.top, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                switch mode {
                case .transcript:
                    let background = mainSpeakerOnly ? t.backgroundSegments : []
                    let segs = shownLines(t)
                    VStack(alignment: .leading, spacing: 10) {
                        // Fix all, after Fix a word… (PhoneTrust.swift).
                        PhoneFixAllBanner(transcriptID: t.id)
                        // Native: Words and Select text are in More › Text and display; the bar shows only while one is on.
                        if !look.isNative || selecting || showEngine { originalBar(t) }
                        if selecting {
                            PhoneSelectableText(text: PhoneSelectableText.joined(segs, in: t))
                                .accessibilityIdentifier("original-selectable")
                        } else {
                            PhoneLines(transcript: t, segments: segs,
                                       folds: app.store.sponsorFolds(t.id, hideFiller: hideFillerSetting && !showFiller, mainOnly: mainSpeakerOnly, engine: showEngine),
                                       clock: app.player.clock, scrub: scrub, onNote: { noteFor = $0 })
                        }
                        let fillers = app.store.fillerCount(t.id)
                        if hideFillerSetting, fillers > 0 {
                            FillerToggle(count: fillers, shown: $showFiller).padding(.leading, 6)
                        }
                        if !background.isEmpty {
                            BackgroundVoicesCard(segments: background,
                                                 onPlay: { s in app.player.seek(to: s.start) },
                                                 onMoveBack: { s in if let main = t.mainSpeaker { app.assign(t.id, segment: s.id, to: main) } })
                                .padding(.top, 8)
                        }
                    }
                case .document: PhoneDocument(transcript: t)
                case .review: review(t)
                case .result: PhoneTemplateResults(transcript: t)
                }
            }
        }
    }

    /// Original tab: which words (with corrections, or the engine's) and Select text.
    private func originalBar(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Words", selection: $showEngine) {
                        Text("With corrections").tag(false)
                        Text("Show engine words").tag(true)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(showEngine ? "Engine words" : "With corrections").font(.system(size: 14, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.lookInk)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .modifier(OriginalBarCapsule(native: look.isNative))
                }
                .accessibilityLabel("Words: \(showEngine ? "engine words" : "with corrections")")
                .accessibilityIdentifier("original-words")
                Button { selecting.toggle() } label: {
                    Label(selecting ? "Done selecting" : "Select text", art: .iconSelect, size: 15)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selecting ? (look.isNative ? NativeInk.onAccent : Ink.onInteractive) : (look.isNative ? NativeInk.label : Ink.ink))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .modifier(OriginalBarCapsule(native: look.isNative, selected: selecting))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("original-select")
                Spacer(minLength: 0)
            }
            if showEngine {
                Text(t.hasEngineWords ? "Exactly what the engine heard, before your corrections and Dictionary fixes."
                                      : "This transcript has no separate engine words, so these are the lines as they are.")
                    .font(.system(size: 13)).foregroundStyle(.lookMute)
            }
        }
        .padding(.bottom, 4)
    }

    private func review(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if t.corrections.isEmpty {
                HStack(spacing: 14) {
                    EmptyStateArt(art: .refine, tint: Ink.petalTint)
                    Text("Nothing changed yet. Dictionary fixes and your corrections show here beside the original.").font(.system(size: 14)).foregroundStyle(.lookDim)
                }
            }
            ForEach(t.corrections) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.byDictionary ? "book.closed" : "pencil").foregroundStyle(.lookInk).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { Text(c.from).strikethrough().foregroundStyle(.lookMute); Image(systemName: "arrow.right").font(.system(size: 10)); Text(c.to).fontWeight(.semibold) }
                        if let seg = t.segments.first(where: { $0.id == c.segmentId }) { Text(seg.text).font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(2) }
                    }
                    Spacer()
                    Button("Undo") {
                        app.store.undoCorrection(c, in: t.id)
                    }
                    .buttonStyle(.phoneSecondary)
                }
                .padding(12)
                .cardSurface(radius: Radius.row)
            }
        }
    }
}

// brand: native begin
extension TranscriptScreen {
    /// Native's More: a standard Liquid Glass menu built like Apple Books' reading menu (iOS 27.2). A row of icon
    /// buttons (Copy, Find, Mark) as a ControlGroup, then the transcript's places and tools, then Rename and Delete,
    /// which the system draws in its destructive red.
    fileprivate func nativeMore(_ t: Transcript) -> some View {
        let moments = t.notes.filter { $0.at != nil }.count
        let ready = t.status == .ready
        let fillers = app.store.fillerCount(t.id)
        return Menu {
            ControlGroup {
                Button { app.copyText(t, copyVersion) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(!ready)
                Button { showFind = true } label: { Label("Find", systemImage: "magnifyingglass") }
                    .disabled(!ready)
                Button { mark(t) } label: { Label("Mark", systemImage: "bookmark") }
                    .disabled(!ready || t.audioFileName == nil)
            }
            Section {
                Button { openSummary(t) } label: { Label("Summary", systemImage: "text.alignleft") }
                    .disabled(!ready)
                Button { showNotes = true } label: {
                    Label("Moments", systemImage: "bookmark")
                    Text(moments == 1 ? "1 saved" : "\(moments) saved")
                }
                Button { showSpeakers = true } label: {
                    Label("Speakers", systemImage: "person.2")
                    Text(t.speakers.count == 1 ? "1 speaker" : "\(t.speakers.count) speakers")
                }
                .disabled(t.speakers.isEmpty)
                Menu {
                    ForEach(app.store.allTemplates) { tpl in
                        Button(tpl.name) {
                            if let why = TemplateCenter.unavailableReason { summaryUnavailable = why }
                            else { TemplateCenter.shared.run(tpl.id, on: t.id, store: app.store); mode = .result }
                        }
                    }
                } label: { Label("Run a template", systemImage: "doc.text") }
                .disabled(!ready)
                Menu {
                    PhoneActionItems { a in
                        if let why = TranscriptActions.unavailableReason { summaryUnavailable = why } else { runningAction = a }
                    }
                    Divider()
                    if t.audioFileName != nil, t.pendingAppend == nil {
                        Button { app.player.stop(); app.continueRecording(t.id) } label: { Label("Continue recording", systemImage: "mic.badge.plus") }
                    }
                    Button { askTurbo = true } label: { Label(TurboRerun.title + "…", systemImage: "arrow.counterclockwise") }
                        .disabled(TurboRerun.unavailableReason(t) != nil)
                    if let other = TurboRerun.switchTitle(t) {
                        Button { app.switchTranscriptVersion(t.id) } label: { Label(other, systemImage: "arrow.uturn.backward") }
                    }
                } label: { Label("Actions", systemImage: "sparkles") }
                .disabled(!ready)
            }
            Section {
                Menu {
                    Button { app.exportRequest = PhoneExportRequest(ids: [t.id]) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    if let u = app.store.audioURL(for: t) {
                        Button { shareAudio(u) } label: { Label("Share original audio", systemImage: "waveform") }
                    }
                    Divider()
                    Button { app.copyForAI(t) } label: { Label("Copy for AI", systemImage: "doc.on.clipboard") }
                    Button { app.copyText(t, copyVersion, timestamps: true) } label: { Label("Copy with timestamps", systemImage: "clock") }
                    Button { app.copyText(t, copyVersion.other) } label: {
                        Label(copyVersion == .cleaned ? "Copy the original" : "Copy the cleaned text", systemImage: "arrow.left.arrow.right")
                    }
                    Button { app.copyText(t, .engine) } label: { Label("Copy engine words", systemImage: "waveform") }
                        .disabled(!t.hasEngineWords)
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(!ready)
                Menu {
                    ForEach(app.store.projects) { p in
                        if t.projectId == p.id {
                            Button { } label: { Label(p.name, systemImage: "checkmark") }.disabled(true)
                        } else {
                            Button(p.name) { app.addToProject([t.id], p.id) }
                        }
                    }
                    if !app.store.projects.isEmpty { Divider() }
                    Button { app.newProjectFor = t.id } label: { Label("New project…", systemImage: "folder.badge.plus") }
                } label: { Label("Add to project", systemImage: "folder.badge.plus") }
                Menu {
                    Picker("Words", selection: $showEngine) {
                        Text("With corrections").tag(false)
                        Text("Engine words").tag(true)
                    }
                    Toggle(isOn: $selecting) { Label("Select text", systemImage: "selection.pin.in.out") }
                    if hideFillerSetting, fillers > 0 {
                        Toggle(isOn: $showFiller) { Label("Show filler lines", systemImage: "text.badge.minus") }
                    }
                } label: { Label("Text and display", systemImage: "textformat.size") }
                .disabled(!ready)
                Button { showDetails = true } label: { Label("Details", systemImage: "info.circle") }
            }
            Section {
                Button { RenameCenter.shared.begin(t) } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("transcript.more")
    }

    /// Mark: a bookmark at the playhead, on the line being said (the same as the player's Bookmark this moment).
    private func mark(_ t: Transcript) {
        let at = app.player.time
        let seg = t.segments.first { at >= $0.start && at < $0.end }
        app.addNote(t.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
        app.say("Marked \(Marks.clock(at))")
    }

    /// Summary: the summary in a sheet, or Summarize first when there isn't one.
    private func openSummary(_ t: Transcript) {
        if t.summary == nil, !SummaryCenter.shared.isRunning(t.id) {
            if let why = SummaryAction.unavailableReason { summaryUnavailable = why; return }
            SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: false)
        }
        showSummary = true
    }
}
// brand: native end

/// A speaker's colored pill on a transcript line (and in the scrubber's bubble): the name in fixed ink on the
/// speaker's color (`PhoneLines.speakerColor`), with a small chevron where it opens a menu.
struct PhoneSpeakerChip: View {
    var name: String
    var color: Color
    var size: CGFloat = 12.5
    var menu = false
    @Environment(\.look) private var look
    var body: some View {
        if look.isNative {
            // Native: the name in semibold, no colored chip. Names carry who's talking.
            HStack(spacing: 3) {
                Text(name).font(.system(size: size + 2, weight: .semibold)).lineLimit(1)
                if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(NativeInk.tertiary) }
            }
            .foregroundStyle(NativeInk.label)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        } else {
            verbose
        }
    }

    private var verbose: some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: size, weight: .bold)).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7) }
        }
        .foregroundStyle(Ink.inkFixed)
        .padding(.horizontal, 10).frame(minHeight: 24)
        .background(color, in: Capsule())
        .contentShape(Capsule())
    }
}

/// The reading lines. Reads the playhead without observing it: the lines re-render only when the playing
/// passage changes (`playingIDs`), not on every 20 Hz tick, so the playing tint moves without re-rendering the screen.
struct PhoneLines: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    /// The lines to show (filler and background voices already left out by the screen).
    var segments: [Segment]
    /// Where sponsor reads fold, one entry per line in `segments` (`Store.sponsorFolds`, worked out once per change).
    var folds: [SponsorFold.Place?]
    var clock: PlayerClock
    /// The scrubber's model: each line tells it when it reaches the top of the screen.
    var scrub: TranscriptScrubModel? = nil
    var onNote: (Segment) -> Void
    @State private var renaming: Speaker? = nil
    @State private var newName = ""
    /// Fix a word… on a line (PhoneTrust.swift).
    @State private var fixing: Segment? = nil
    /// The passages under the playhead as of the last tick. Only a change here re-renders the lines; the tint
    /// itself is worked out from the clock in `body`.
    @State private var playingIDs: Set<UUID> = []
    /// Sponsor reads opened from their folded row.
    @State private var openSponsors: Set<UUID> = []
    /// Reading text at a comfortable size and line height (the website's 16.5 / 1.6), scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 16.5
    @ScaledMetric(relativeTo: .caption) private var pillSize: CGFloat = 12.5
    @Environment(\.look) private var look

    /// A speaker's pill color, by their place in the list: record, petal, sage, butter, then around again.
    static func speakerColor(_ t: Transcript, _ id: String?) -> Color {
        let colors = [PhoneInk.record, PhoneInk.petal, PhoneInk.sage, PhoneInk.butter]
        guard let id, let i = t.speakers.firstIndex(where: { $0.id == id }) else { return PhoneInk.wash }
        return colors[i % colors.count]
    }

    /// The playing rule: under the playhead, and either playing or moved off the start.
    static func playing(_ segments: [Segment], at now: Double, isPlaying: Bool) -> Set<UUID> {
        guard isPlaying || now > 0 else { return [] }
        var out = Set<UUID>()
        for s in segments where now >= s.start && now < s.end { out.insert(s.id) }
        return out
    }

    var body: some View {
        let _ = playingIDs
        let saved = Set(transcript.notes.filter(\.isBookmark).compactMap(\.segmentId))
        // Moments marked while recording, by line, for their chips (the first on a line).
        let marked = Dictionary(transcript.notes.filter(\.isMark).compactMap { n in n.segmentId.map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
        let segs = segments
        let current = Self.playing(segs, at: clock.time, isPlaying: app.player.isPlaying)
        // Sponsor reads fold into one row at their first line; their lines show once the row is opened.
        let folds = self.folds.count == segs.count ? self.folds : SponsorFold.places(segs, in: transcript)
        // "unclear 2:10" chips where speech was heard but no words came through (UnclearRules), between the lines.
        let chips = UnclearStyle.chips(transcript, lines: segs)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segs.enumerated()), id: \.element.id) { i, s in
                // After a folded read, name the speaker again: the line above on screen is someone else's.
                let afterFold = i > 0 && folds[i - 1].map { !openSponsors.contains($0.span.id) } == true
                let showSpeaker = transcript.speakers.count >= 2 && s.speaker != nil && (i == 0 || afterFold || segs[i - 1].speaker != s.speaker)
                let playing = current.contains(s.id)
                let fold = folds[i]
                if let spans = chips[i] { unclearChips(spans) }
                if let fold, fold.first {
                    SponsorFoldRow(span: fold.span, open: openSponsors.contains(fold.span.id), compact: false,
                                   onToggle: { if openSponsors.remove(fold.span.id) == nil { openSponsors.insert(fold.span.id) } },
                                   onPlay: app.player.canPlay ? { app.player.play(from: fold.span.start) } : nil,
                                   onNotSponsor: { app.store.update(transcript.id) { $0.dismissSponsor(fold.span.id) } })
                        .padding(.top, i == 0 ? 2 : 10).padding(.bottom, 4)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if showSpeaker, let n = transcript.speakerName(s.speaker) {
                            // Tap the name to rename the speaker or move this line to someone else.
                            Menu {
                                if let sid = s.speaker, let sp = transcript.speakers.first(where: { $0.id == sid }) {
                                    Button { newName = sp.name; renaming = sp } label: { Label("Rename \(n)…", systemImage: "pencil") }   // brand: system surface (menu)
                                }
                                Section("This line is") {
                                    ForEach(transcript.speakers) { sp in
                                        Button { app.assign(transcript.id, segment: s.id, to: sp.id) } label: {
                                            Label(sp.label, systemImage: sp.id == s.speaker ? "checkmark" : "person")
                                        }
                                    }
                                    Button { app.assign(transcript.id, segment: s.id, to: nil) } label: { Label("No speaker", systemImage: "person.slash") }   // brand: system surface (menu)
                                }
                            } label: {
                                PhoneSpeakerChip(name: n, color: Self.speakerColor(transcript, s.speaker), size: pillSize, menu: true)
                            }
                            .accessibilityLabel("Speaker: \(n). Rename or reassign")
                        }
                        Text(s.start.timecode).lookMono(12).foregroundStyle(.lookMute)
                            .onTapGesture { play(s) }
                            .accessibilityLabel("Play from \(s.start.timecode)").accessibilityAddTraits(.isButton)
                    }
                    lineText(s, playing: playing).font(.system(size: textSize)).foregroundStyle(.lookInk).lineSpacing(textSize * 0.38)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        // Tap a line to play from it (Select text, above, is for selecting).
                        .onTapGesture { play(s) }
                        .accessibilityAction(named: "Play from here") { play(s) }
                    if let mark = marked[s.id] {
                        PhoneMarkChip(note: mark) { if let at = mark.at { app.player.play(from: at) } else { play(s) } }
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 6)
                .background(look.isNative ? (playing ? NativeInk.fill : .clear) : playing ? Ink.playing : saved.contains(s.id) ? Ink.saved : .clear,
                            in: RoundedRectangle(cornerRadius: look.isNative ? 12 : Radius.button, style: .continuous))
                .padding(.top, showSpeaker && i > 0 ? 12 : 2)
                .id(s.id)
                .scrubRow(scrub, index: i, count: segs.count)
                .contentShape(Rectangle())
                .contextMenu {
                    if app.player.loadedURL != nil {
                        Button { play(s) } label: { Label("Play from here", systemImage: "play") }   // brand: system surface (menu)
                    }
                    Button { app.addNote(transcript.id, text: String(s.text.prefix(60)), at: s.start, segment: s.id, bookmark: true) } label: { Label("Bookmark", systemImage: "bookmark") }   // brand: system surface (menu)
                    Button { onNote(s) } label: { Label("Add note…", systemImage: "note.text.badge.plus") }   // brand: system surface (menu)
                    Button { fixing = s } label: { Label("Fix a word…", systemImage: "pencil") }   // brand: system surface
                    Button { UIPasteboard.general.string = "“\(s.text)”"; app.say("Quote copied"); Haptics.play(.copied) } label: { Label("Copy quote", systemImage: "quote.opening") }   // brand: system surface (menu)
                    if let info = transcript.linkInfo, info.supportsTimestamps, let u = info.url(at: s.start) {
                        Button { UIPasteboard.general.string = "“\(s.text)” \(u.absoluteString)"; app.say("Quote and link copied"); Haptics.play(.copied) } label: { Label("Copy quote with link", systemImage: "link") }   // brand: system surface (menu)
                        Link(destination: u) { Label("Open video at \(s.start.timecode)", systemImage: "play.rectangle") }   // brand: system surface (menu)
                    }
                    if transcript.offersSponsorMarking, fold == nil {
                        Button { app.store.update(transcript.id) { $0.markSponsor(segment: s.id) } } label: { Label("Mark as sponsor", systemImage: "tag") }   // brand: system surface (menu)
                    }
                }
                .foldedAway(fold.map { !openSponsors.contains($0.span.id) } ?? false)
            }
            if let spans = chips[segs.count] { unclearChips(spans) }
        }
        .alert("Name this speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("First and last name", text: $newName).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { if let sp = renaming { app.renameSpeaker(transcript.id, speaker: sp.id, to: newName) }; renaming = nil }
        } message: { Text("Changes every line from this speaker, on this iPhone and your Mac.") }
        .phoneFixWord($fixing, transcriptID: transcript.id)
        .onReceive(clock.$time) { now in syncPlaying(at: now) }
        .onChange(of: app.player.isPlaying) { _, _ in syncPlaying(at: clock.time) }
        // The lines' ids and times, not the whole lines (words included): only those decide what's playing.
        .onChange(of: transcript.segments.timingKey) { _, _ in syncPlaying(at: clock.time) }
    }

    @MainActor private func syncPlaying(at now: Double) {
        let ids = Self.playing(transcript.segments, at: now, isPlaying: app.player.isPlaying)
        if ids != playingIDs { playingIDs = ids }
    }

    /// The chips before a line: tap one to play that spot.
    private func unclearChips(_ spans: [UnclearSpan]) -> some View {
        ForEach(spans, id: \.start) { sp in
            UnclearChip(span: sp, onPlay: { if app.player.canPlay { app.player.play(from: sp.start) } })
                .padding(.leading, 6).padding(.vertical, 6)
        }
    }

    /// Seeks to the line and plays, once the audio is open.
    private func play(_ s: Segment) {
        guard app.player.canPlay else { return }
        app.player.play(from: PlaybackSync.seekTime(s, duration: app.player.duration))
    }

    /// The line's text; while it plays with fresh word timings, the playing word is tinted too.
    @ViewBuilder private func lineText(_ s: Segment, playing: Bool) -> some View {
        // Low-confidence words carry a quiet dotted underline (UnclearStyle), as a best guess.
        if playing, PlaybackSync.timingsFresh(s) {
            PlayingWordText(segment: s, base: UnclearStyle.marked(AttributedString(s.text), s), clock: clock, tint: look.isNative ? NativeInk.fillStrong : Ink.accentText.opacity(0.18))
        } else {
            Text(UnclearStyle.marked(AttributedString(s.text), s))
        }
    }
}

/// The dark player at the foot of a transcript (an opaque ink capsule, never glass): play on a sage disc (sage means
/// playback; persimmon stays on Record), the time in mono, the waveform (drag or tap it to move through the recording;
/// the played part is sage), Follow, and a menu with speed, skip 5 seconds, and Bookmark this moment.
struct PhoneDock: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock
    var downloading: Bool
    @Binding var follow: Bool
    @Environment(\.look) private var look

    /// Native repaints the dock in system colors on glass; Verbose style keeps the opaque ink capsule.
    private var onDock: Color { look.isNative ? NativeInk.label : Ink.paperFixed }

    var body: some View {
        let total = max(app.player.duration, transcript.duration, 0.1)
        if look.isNative { nativeDock(total) } else { verboseDock(total) }
    }

    private func verboseDock(_ total: Double) -> some View {
        let dock = HStack(spacing: 10) {
            Button { app.player.toggle() } label: {
                ZStack {
                    Circle().fill(look.isNative ? NativeInk.accent : PhoneInk.sage)
                    if downloading { ProgressView().tint(look.isNative ? Color.white : Ink.inkFixed) }
                    else if look.isNative {
                        Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white)   // brand: native
                    }
                    else { ArtIcon(art: app.player.isPlaying ? .iconPause : .iconPlay, size: 15, lineWidth: 2).foregroundStyle(Ink.inkFixed) }
                }
                .frame(width: 38, height: 38)
                .contentShape(Circle())
            }
            .buttonStyle(PhoneCardPress())
            .disabled(downloading)
            .accessibilityLabel(downloading ? "Downloading audio" : app.player.isPlaying ? "Pause" : "Play")
            if let note = clock.note {
                SkippedSponsorNote(text: note)
            } else {
                Text(clock.time.timecode).lookMono(12).foregroundStyle(onDock)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            PhoneDockWave(levels: transcript.waveform, progress: min(1, clock.time / total),
                          played: look.isNative ? NativeInk.accent : Ink.sage,
                          rest: look.isNative ? NativeInk.gray : Ink.paperFixed.opacity(0.35)) { f in
                app.player.seek(to: f * total)
            }
            .frame(height: 26)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(clock.time.timecode) of \(total.timecode)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: app.player.seek(to: min(total, clock.time + 5))
                case .decrement: app.player.seek(to: max(0, clock.time - 5))
                @unknown default: break
                }
            }
            Button { follow.toggle() } label: {
                Text("Follow").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(look.isNative ? (follow ? Color.white : NativeInk.accent) : follow ? Ink.inkFixed : Ink.paperFixed)
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .background { if follow { Capsule().fill(look.isNative ? NativeInk.accent : Ink.paperFixed) } }
                    .overlay { if !follow { Capsule().strokeBorder(look.isNative ? NativeInk.accent.opacity(0.6) : Ink.paperFixed.opacity(0.6), lineWidth: 1.2) } }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Follow playback")
            .accessibilityValue(follow ? "On" : "Off")
            .accessibilityHint("Scrolls to the line that's playing. Scrolling yourself turns it off.")
            Menu {
                Picker("Speed", selection: Binding(get: { app.player.rate }, set: { app.player.setRate($0) })) {
                    ForEach(PlaybackSync.speeds, id: \.self) { r in Text(PlaybackSync.speedLabel(r)).tag(r) }
                }
                Button("Back 5 seconds") { app.player.seek(to: max(0, clock.time - 5)) }
                Button("Forward 5 seconds") { app.player.seek(to: min(total, clock.time + 5)) }
                ReduceNoiseToggle(player: app.player)
                Button {
                    let at = clock.time
                    let seg = transcript.segments.first { at >= $0.start && at < $0.end }
                    app.addNote(transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
                } label: { Label("Bookmark this moment", systemImage: "bookmark") }   // brand: system surface (menu)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(onDock)
                    .frame(width: 32, height: 38).contentShape(Rectangle())
            }
            .accessibilityLabel("Playback options, \(PlaybackSync.speedLabel(app.player.rate))")
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(minHeight: 54)
        return dock
            .background(Ink.inkFixed, in: Capsule())
            .shadow(color: Ink.inkFixed.opacity(0.2), radius: 12, y: 8)
    }
}

// brand: native begin
extension PhoneDock {
    /// Native: the player as a glass bar at the bottom edge (the tab bar hides while you read), like Apple's own
    /// players: play, the time, the waveform as the scrubber (label color played, tertiary after), the time left, the
    /// speed (its menu has skip, Reduce background noise, and Bookmark this moment), and Follow.
    @ViewBuilder fileprivate func nativeDock(_ total: Double) -> some View {
        let dock = HStack(spacing: 8) {
            Button { app.player.toggle() } label: {
                Group {
                    if downloading { ProgressView() }
                    else { Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                }
                .foregroundStyle(NativeInk.label)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(downloading)
            .accessibilityLabel(downloading ? "Downloading audio" : app.player.isPlaying ? "Pause" : "Play")
            if let note = clock.note {
                SkippedSponsorNote(text: note)
            } else {
                Text(clock.time.timecode).font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(NativeInk.label)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            PhoneDockWave(levels: transcript.waveform, progress: min(1, clock.time / total),
                          played: NativeInk.label, rest: NativeInk.tertiary) { f in
                app.player.seek(to: f * total)
            }
            .frame(height: 26)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(clock.time.timecode) of \(total.timecode)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: app.player.seek(to: min(total, clock.time + 5))
                case .decrement: app.player.seek(to: max(0, clock.time - 5))
                @unknown default: break
                }
            }
            Text("−" + max(0, total - clock.time).timecode).font(.footnote).monospacedDigit().foregroundStyle(NativeInk.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            Menu {
                Picker("Speed", selection: Binding(get: { app.player.rate }, set: { app.player.setRate($0) })) {
                    ForEach(PlaybackSync.speeds, id: \.self) { r in Text(PlaybackSync.speedLabel(r)).tag(r) }
                }
                Button { app.player.seek(to: max(0, clock.time - 5)) } label: { Label("Back 5 seconds", systemImage: "gobackward.5") }
                Button { app.player.seek(to: min(total, clock.time + 5)) } label: { Label("Forward 5 seconds", systemImage: "goforward.5") }
                ReduceNoiseToggle(player: app.player)
                Button {
                    let at = clock.time
                    let seg = transcript.segments.first { at >= $0.start && at < $0.end }
                    app.addNote(transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
                } label: { Label("Bookmark this moment", systemImage: "bookmark") }
            } label: {
                Text(PlaybackSync.speedLabel(app.player.rate)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(NativeInk.label)
                    .frame(minWidth: 30, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Playback options, \(PlaybackSync.speedLabel(app.player.rate))")
            Button { follow.toggle() } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.body.weight(.medium))
                    .foregroundStyle(follow ? NativeInk.accent : NativeInk.secondary)
                    .frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Follow playback")
            .accessibilityValue(follow ? "On" : "Off")
            .accessibilityHint("Scrolls to the line that's playing. Scrolling yourself turns it off.")
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(minHeight: 52)
        NativeDockSurface(content: dock)
    }
}
// brand: native end

// brand: native begin
/// The player in the Native look: Liquid Glass like Music's bar above the tab bar (a material before iOS 26). Native
/// follows Apple in putting text on glass here; keep the scroll edge effect on.
private struct NativeDockSurface<Content: View>: View {
    var content: Content
    var body: some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.bar, in: Capsule())
                .overlay(Capsule().strokeBorder(NativeInk.separator, lineWidth: 0.5))
        }
    }
}
// brand: native end

/// The player's waveform: the recording's levels as thin bars, butter up to the playhead and faint paper after it.
/// Tap or drag to move the playhead.
struct PhoneDockWave: View {
    var levels: [Float]
    var progress: Double
    var played: Color = Ink.butter
    var rest: Color = Ink.paperFixed.opacity(0.35)
    var seek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let n = 46
                let gap: CGFloat = 2
                let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                for i in 0..<n {
                    let v: CGFloat
                    if levels.isEmpty {
                        v = 0.2 + 0.7 * CGFloat(abs(sin(Double(i) * 0.7) * cos(Double(i) * 0.23)))
                    } else {
                        let idx = min(levels.count - 1, i * levels.count / n)
                        v = max(0.2, min(1, CGFloat(levels[idx]) * 1.4))
                    }
                    let h = v * size.height
                    let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                    let isPlayed = Double(i) / Double(n) < progress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, w / 2)),
                             with: .color(isPlayed ? played : rest))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                seek(max(0, min(1, Double(v.location.x / max(1, g.size.width)))))
            })
        }
    }
}

/// Calls `action` when the person drags the scroll view themselves (not when code scrolls it), for turning off
/// Follow. iOS 18 reads the scroll phase; iOS 17 watches for a drag alongside the scroll.
private struct ManualScroll: ViewModifier {
    var action: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in if phase == .interacting { action() } }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in action() })
        }
    }
}

extension View {
    func onManualScroll(_ action: @escaping () -> Void) -> some View { modifier(ManualScroll(action: action)) }
}

struct PhoneLinkCard: View {
    var info: LinkInfo
    var body: some View {
        if let u = URL(string: info.url) {
            // One play target: the whole card opens the video.
            Link(destination: u) { card }
                .buttonStyle(PhoneCardPress())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Open video, \(title)")
        } else {
            card
        }
    }

    private var title: String { [info.channel, info.site].compactMap { $0 }.joined(separator: " · ") }

    private var card: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.track)
                if let f = info.thumbnailFile { StillImage(file: f, maxPixel: 240).clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)) }
                else { IconGlyph(art: .iconPlay, size: 18, color: Ink.mute) }
            }
            .frame(width: 72, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.lookInk).lineLimit(1)
                Text(info.uploadDisplay ?? URL(string: info.url)?.host ?? "").font(.system(size: 12.5)).foregroundStyle(.lookMute).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(8)
        .cardSurface(radius: Radius.row)
        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}

/// A marked line's chip (mockup "Library features", section 3c): the Marked icon, "Moment 4:12", and where it came from
/// ("· from the Lock Screen"), on butter in ink. Premium Native: the accent's symbol on a neutral capsule. Tap to play.
struct PhoneMarkChip: View {
    @Environment(\.look) private var look
    var note: Note
    var play: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 13

    var body: some View {
        let native = look.isNative
        Button(action: play) {
            HStack(spacing: 6) {
                if native {
                    Image(systemName: "bookmark.fill").font(.system(size: size - 1, weight: .semibold)).foregroundStyle(NativeInk.accent)   // brand: native
                } else {
                    IconGlyph(art: .iconMarked, size: size + 1, color: Ink.inkFixed)
                }
                Text("Moment").font(.system(size: size, weight: .semibold))
                Text(Marks.clock(note.at ?? 0)).font(native ? .system(size: size, weight: .medium).monospacedDigit() : Ink.mono(max(12, size - 0.5)))
                // The short form, as the Moments screen says it ("Lock Screen", "Mac · ⌃⌥B"; DESIGN.md §18.3); VoiceOver
                // hears the sentence (Marks.chip).
                if let from = Marks.shortSource(note) { Text("· \(from)").font(.system(size: size)).opacity(0.78) }
            }
            .foregroundStyle(native ? NativeInk.label : Ink.inkFixed)
            .lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(native ? NativeInk.label.opacity(0.07) : Ink.panelButter, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Marks.chip(note) ?? "Moment")
        .accessibilityHint("Plays from this moment.")
    }
}

/// Notes and bookmarks for one transcript, newest first, with an add field.
struct NotesSheet: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    @Environment(\.look) private var look
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a note…", text: $draft, axis: .vertical).focused($focused)
                        Button("Add") {
                            let at = app.player.loadedURL != nil && app.player.time > 0 ? app.player.time : nil
                            app.addNote(id, text: draft, at: at, segment: nil); draft = ""
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(app.store.transcript(id)?.notes ?? []) { n in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                if n.isBookmark { ArtIcon(art: n.isMark ? .iconMarked : .bookmark, size: 13) }
                                if let at = n.at { Text(at.timecode).lookMono(12) }
                                // Marked while recording: where from.
                                if let from = Marks.shortSource(n) { Text("· \(from)").font(.system(size: 13)) }
                            }
                            .foregroundStyle(look.isNative ? (n.isBookmark ? NativeInk.accent : NativeInk.secondary) : (n.isBookmark ? Ink.butterText : Ink.dim))
                            if let f = n.frameFile { StillImage(file: f).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: Radius.button)) }
                            if let action = n.aiAction {
                                // Saved from an action: stays marked as Apple Intelligence's, not the transcript's.
                                Label("\(action) · Made by Apple Intelligence", art: .iconAI, size: 14)
                                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.lookDim)
                            }
                            Text(Marks.words(n, in: app.store.transcript(id)?.segments ?? [])).font(.system(size: 15)).foregroundStyle(.lookInk)
                        }
                        .listRowBackground(look.isNative ? NativeInk.card : (n.isBookmark ? Ink.butterTint : Ink.card))
                        .onTapGesture { if let at = n.at { app.player.seek(to: at) } }
                    }
                    .onDelete { idx in
                        let notes = app.store.transcript(id)?.notes ?? []
                        for i in idx { app.deleteNote(id, note: notes[i].id) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background((look.isNative ? NativeInk.paper : Ink.paper).ignoresSafeArea())
            .navigationTitle(look.isNative ? "Moments and notes" : "Notes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The Summary on a butter panel with grain and the strands drawing (the screen's one moving drawing): the eyebrow,
/// the overview's first sentence as a serif headline and the rest under it, the key points, the Apple Intelligence
/// note, and Edit and Regenerate. Ink text in both modes. Hidden while there's nothing to show and Apple
/// Intelligence can't run here (`SummaryBlock.shows`); the Summarize action says why.
struct PhoneSummaryPanel: View {
    var transcript: Transcript
    /// Runs the summary; `true` replaces a summary the person edited.
    var onSummarize: (_ replacingEdits: Bool) -> Void
    /// Saves the person's edit; nil removes the summary.
    var onSave: (TranscriptSummary?) -> Void

    @ObservedObject private var center = SummaryCenter.shared
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmReplace = false
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .title2) private var headSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 14.5
    @Environment(\.look) private var look

    private var running: Bool { center.isRunning(transcript.id) }
    private var animation: Animation { limitMotion ? Motion.fade : Motion.settle }

    var body: some View {
        if SummaryBlock.shows(transcript, center: center) {
            Group {
                if look.isNative { nativeCard } else { verboseCard }
            }
            .confirmationDialog("Replace your edited summary?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { onSummarize(true) }
                Button("Keep mine", role: .cancel) {}
            } message: {
                Text("Apple Intelligence writes a new summary, and your edits are gone.")
            }
        }
    }

    private var verboseCard: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            PhoneEyebrow(text: "Summary", color: Ink.inkFixed)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .foregroundStyle(.lookOnPanel)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PhonePanelFill(color: PhoneInk.butter, shape: shape)
                .overlay(alignment: .topTrailing) {
                    if !editing { PhonePanelArt(kind: .strands).frame(width: 160, height: 107).offset(x: 4, y: -16) }
                }
                .clipShape(shape)
        }
    }

    // brand: native begin
    /// Native: an inset grouped cell with label text, the sparkles symbol, Apple Intelligence's mark, and the moment
    /// and speaker counts.
    private var nativeCard: some View {
        let moments = transcript.notes.filter { $0.at != nil }.count
        let speakers = transcript.speakers.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Summary", systemImage: "sparkles").font(.subheadline.weight(.semibold)).foregroundStyle(NativeInk.secondary)
                Spacer(minLength: 6)
                if transcript.summaryByModel { Text("Apple Intelligence").font(.caption).foregroundStyle(NativeInk.secondary) }
            }
            .accessibilityAddTraits(.isHeader)
            content
            if !editing, moments > 0 || speakers >= 2 {
                HStack(spacing: 8) {
                    if moments > 0 { nativeCount("bookmark", moments == 1 ? "1 moment" : "\(moments) moments") }
                    if speakers >= 2 { nativeCount("person.2", "\(speakers) speakers") }
                }
                .padding(.top, 4)
            }
        }
        .foregroundStyle(NativeInk.label)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeCell()
    }

    private func nativeCount(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.footnote)
            Text(text).font(.footnote).monospacedDigit()
        }
        .foregroundStyle(NativeInk.secondary)
        .padding(.horizontal, 10).frame(minHeight: 26)
        .background(NativeInk.fill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
    // brand: native end

    @ViewBuilder private var content: some View {
        if editing {
            editor
        } else if let s = transcript.summary {
            let parts = Self.split(s.overview)
            let head = parts.0, rest = parts.1
            VStack(alignment: .leading, spacing: 10) {
                if !head.isEmpty {
                    Text(head).lookSerif(headSize).lineSpacing(1)
                        .padding(.trailing, 64)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !rest.isEmpty {
                    Text(rest).font(.system(size: bodySize)).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !s.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Circle().fill(look.isNative ? NativeInk.label : Ink.inkFixed).frame(width: 4.5, height: 4.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                Text(p).font(.system(size: bodySize)).lineSpacing(2)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Key points")
                }
                if transcript.summaryByModel {
                    Label { Text(AIGeneratedNote.summary) } icon: { ArtIcon(art: .iconAI, size: 13) }
                        .font(.system(size: 12)).opacity(0.8)
                        .accessibilityElement(children: .combine)
                }
                if running { progressRow } else if let why = center.failures[transcript.id] { Text(why).font(.system(size: 13)).opacity(0.8) }
                HStack(spacing: 18) {
                    Button("Edit") { draft = s.plainText; withAnimation(animation) { editing = true } }
                    if Summarizer.available, !running {
                        Button("Regenerate") {
                            if transcript.summaryIsEdited { confirmReplace = true } else { onSummarize(false) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .underline(!look.isNative)
                .foregroundStyle(look.isNative ? NativeInk.accent : Ink.inkFixed)
            }
        } else if running {
            progressRow
        } else if let why = center.failures[transcript.id] {
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                if Summarizer.available {
                    Button("Try again") { onSummarize(false) }.buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold)).underline()
                }
            }
        }
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(look.isNative ? NativeInk.secondary : Ink.inkFixed)
            Text(progressText).font(.system(size: 14))
        }
    }

    private var progressText: String {
        if let p = center.progress[transcript.id], p > 0 { return "Writing a summary… \(Int(p * 100))%" }
        return "Writing a summary…"
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An overview, then one key point per line starting with “- ”.").font(.system(size: 13.5))
            TextEditor(text: $draft)
                .font(.system(size: bodySize)).lineSpacing(3)
                .foregroundStyle(Ink.inkFixed)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(8)
                .background(Ink.readerFixed, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .environment(\.colorScheme, .light)
            HStack(spacing: 18) {
                Button("Save") {
                    let parsed = TranscriptSummary.parse(draft)
                    onSave(parsed.isEmpty ? nil : parsed)
                    withAnimation(animation) { editing = false }
                }
                Button("Cancel") { withAnimation(animation) { editing = false } }
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
        }
    }

    /// The overview's first sentence (the headline) and the rest.
    static func split(_ overview: String) -> (String, String) {
        let text = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression) else { return (text, "") }
        let head = String(text[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A long first sentence reads as body text, not a headline.
        return head.count <= 90 ? (head, rest) : ("", text)
    }
}

/// The Original tab's two capsules (the words menu and Select text): card white with a hairline in Verbose style
/// (ink when selecting); a gray system fill in Native (the accent when selecting).
private struct OriginalBarCapsule: ViewModifier {
    var native: Bool
    var selected = false
    func body(content: Content) -> some View {
        if native {
            content.background(selected ? NativeInk.accent : NativeInk.fill, in: Capsule())
        } else {
            content
                .background(selected ? Ink.interactive : Ink.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Ink.hairline))
        }
    }
}
