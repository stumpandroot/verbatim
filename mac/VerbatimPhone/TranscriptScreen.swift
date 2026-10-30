import SwiftUI
import Combine
import UIKit

/// A transcript in the refined look (DESIGN.md §13; mockup "Verbose Refined Look", PhoneTranscript), one layout in both
/// look settings. Apple draws the chrome: the navigation bar's glass Back, Share, and More (a standard menu built like
/// Books' reading menu), the sheets, and the tab bar, which hides while you read. Verbose draws the content on paper:
/// the title in the serif, a meta line led by the kind's chip (and the project's), the segmented control (Original,
/// Cleaned, Summary, Review once something was corrected, and a template's result), then each turn as the speaker's
/// chip and the time over the serif reading text. The line being played takes the sage `playing` wash; a bookmarked or
/// marked line carries a small accent mark. The glass player bar sits at the bottom edge. Touch and hold a line to
/// bookmark it, add a note, fix a word, copy it, or open the video at that moment. Copy takes the tab you're on.
struct TranscriptScreen: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    var startMode: Mode = .transcript
    /// `result`: the template results tab (TemplatesScreens.swift), once a template ran or is running here.
    enum Mode: Hashable { case transcript, document, summary, review, result }
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
    /// Scroll to the playing line. Turns off when you scroll yourself; Play and the player's menu turn it back on.
    @State private var follow = true
    @State private var followed: UUID? = nil
    /// Opened from a search passage: where the audio starts.
    @State private var pendingSeek: Double? = nil
    /// The scrubber's scroll state (TranscriptScrubber.swift). A plain reference, not observed here, so scrolling
    /// re-renders only the scrubber.
    @State private var scrub = TranscriptScrubModel()
    /// The player bar's height with its bottom margin; the scrubber's track ends above it.
    @State private var dockHeight: CGFloat = 70
    /// The transcript is long enough for the scrubber, which then replaces the system scroll indicator.
    @State private var scrubLong = false
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    /// More's Find, Speakers, and Details open sheets; Delete asks first.
    @State private var showFind = false
    @State private var showSpeakers = false
    @State private var showDetails = false
    @State private var confirmDelete = false
    /// A line Find picked, scrolled to once the sheet has gone.
    @State private var scrollTarget: UUID? = nil

    private static let scrollSpace = "transcript-scroll"

    /// Each transcript screen on view, by its token, and the look it was built in. Keyed by screen rather than look, so
    /// a transcript leaving late can't take a newer one's look with it (build 241).
    private static var shownScreens: [UUID: AppLook] = [:]
    /// The looks a transcript is on screen in (the self-test checks each look draws this one layout, once).
    static var onScreen: Set<AppLook> { Set(shownScreens.values) }

    /// The player bar shows under every tab but Cleaned, for a recording with audio.
    private func hasPlayer(_ t: Transcript) -> Bool { t.audioFileName != nil && t.status == .ready && mode != .document }

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
        // Audio only with no words yet: its own screen (AudioDetailScreen.swift), until Transcribe brings the words.
        if app.store.transcript(id)?.showsAudioDetail == true {
            PhoneAudioDetail(id: id)
        } else {
            transcriptBody
        }
    }

    private var transcriptBody: some View {
        Group {
            if let t {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(t)
                                if t.status == .ready {
                                    RefinedSegmented(options: modes(t), selection: $mode)
                                        .padding(.top, 14)
                                        .onChange(of: t.corrections.isEmpty) { _, none in if none, mode == .review { mode = .transcript } }
                                }
                                content(t).padding(.top, 16)
                            }
                            .padding(.horizontal, 20).padding(.top, 6)
                            .padding(.bottom, hasPlayer(t) ? dockHeight + 24 : 32)
                            .scrubContent(scrub, in: Self.scrollSpace)
                        }
                        .coordinateSpace(.named(Self.scrollSpace))
                        .scrubTracking(scrub)
                        .scrollIndicators(scrubLong && t.status == .ready && mode == .transcript && !selecting ? .hidden : .automatic)
                        .onReceive(scrub.$long.removeDuplicates()) { scrubLong = $0 }
                        .scrollDismissesKeyboard(.interactively)
                        .onManualScroll { if app.player.isPlaying, follow { follow = false } }
                        .onAppear {
                            // Opened from a search passage, a note, a citation, or a link: land on that line and start
                            // the audio there.
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
                            let order = t.speakerOrder
                            TranscriptScrubber(model: scrub,
                                               lines: { shownLines(t) },
                                               end: ScrubMath.scaleEnd(starts: t.segments.map(\.start), ends: t.segments.map(\.end)),
                                               speaker: { s in t.speakers.count >= 2 ? t.speakerName(s.speaker) : nil },
                                               speakerIndex: { s in s.speaker.flatMap { order[$0] } ?? 0 },
                                               jump: { s in
                                                   var tr = Transaction(); tr.disablesAnimations = true
                                                   withTransaction(tr) { proxy.scrollTo(s.id, anchor: .top) }
                                               },
                                               onBegin: { if app.player.isPlaying, follow { follow = false } })
                                .padding(.top, 8)
                                .padding(.bottom, hasPlayer(t) ? dockHeight + 8 : 8)
                        }
                        if hasPlayer(t) {
                            PhonePlayerBar(transcript: t, player: app.player, clock: app.player.clock, downloading: downloading, follow: $follow)
                                .padding(.horizontal, 16).padding(.bottom, 8)
                                .background(alignment: .bottom) { PlayerFade(height: dockHeight + 40) }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                        }
                    }
                    .coordinateSpace(.named(TranscriptScrubber.frameSpace))
                }
                .background(Refined.paper.ignoresSafeArea())
                .modifier(ReadingEdges())
                .navigationBarTitleDisplayMode(.inline)
                // Reading: the tab bar goes, and the player sits at the bottom edge instead of floating over it.
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    // Two glass controls beside Back: Share and More (Books' reading menu).
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { app.exportRequest = PhoneExportRequest(ids: [t.id]) } label: { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share")
                            .accessibilityIdentifier("transcript.share")
                            .disabled(t.status != .ready)
                        more(t)
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
                .sheet(isPresented: $showSpeakers) { TranscriptSpeakersSheet(id: t.id).environmentObject(app) }
                .sheet(isPresented: $showDetails) { TranscriptDetailsSheet(id: t.id).environmentObject(app) }
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
                } message: { Text(noteFor.map { "At \(RefinedRules.time($0.start))" } ?? "") }
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
                        // Opened from a recording's play button: play once the audio is open.
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
                // The self-test's screenshots of the other tabs ("summary", "review", "document", "transcript").
                .onReceive(NotificationCenter.default.publisher(for: .phoneTranscriptMode)) { n in
                    if let raw = n.object as? String, let m = Mode(selfTest: raw) { mode = m }
                }
            } else {
                Text("This transcript was deleted.").refinedFont(.body).foregroundStyle(Refined.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Refined.paper)
            }
        }
        // Reading: Record's accessory turns off with the tab bar (RecordAccessory.swift).
        .onAppear { app.readingScreens.insert(readingToken); Self.shownScreens[readingToken] = look }
        .onDisappear { app.readingScreens.remove(readingToken); Self.shownScreens[readingToken] = nil }
    }

    /// Shares the recording's audio file, after it downloads from iCloud when it lives on the other device.
    private func shareAudio(_ u: URL) {
        Task { @MainActor in
            if !Cloud.isDownloaded(u) { app.say("Downloading the audio…"); _ = await Cloud.ensureDownloaded(u) }
            guard FileManager.default.fileExists(atPath: u.path) else { app.say("The audio isn't on this iPhone yet. Try again in a moment."); return }
            shareItems = [u]
        }
    }

    /// Original, Cleaned, and Summary; Review once something was corrected; and a template's result.
    private func modes(_ t: Transcript) -> [(Mode, String)] {
        Self.modes(t, current: mode, busyName: TemplateCenter.shared.busyTemplate(t.id).flatMap { id in app.store.allTemplates.first { $0.id == id }?.name })
    }

    /// The segmented control's tabs (the self-test reads them): Original, Cleaned, Summary, then Review while there are
    /// corrections (or it's open), then the result's tab, named for its template ("Meeting notes"), or "Results".
    static func modes(_ t: Transcript, current: Mode, busyName: String?) -> [(Mode, String)] {
        var out: [(Mode, String)] = [(.transcript, "Original"), (.document, "Cleaned"), (.summary, "Summary")]
        if !t.corrections.isEmpty || current == .review { out.append((.review, "Review")) }
        if let title = PhoneTemplateResults.tabTitle(t, busyName: busyName) { out.append((.result, title)) }
        else if current == .result { out.append((.result, "Template")) }
        return out
    }

    /// The meta line after the chips: "Today, 8:35 PM · 0:42 · 2 speakers", and the language when there's no menu
    /// for it (a dictation, a link still coming).
    static func meta(_ t: Transcript, languageMenu: Bool, now: Date = Date()) -> String {
        RefinedRules.transcriptMeta(when: RefinedRules.transcriptWhen(t.createdAt, now: now), duration: t.duration,
                                    speakers: t.speakers.count, language: languageMenu ? nil : t.language.map(LanguageDetection.name))
    }

    private func header(_ t: Transcript) -> some View {
        let languageMenu = t.status == .ready && t.audioFileName != nil && t.pendingAppend == nil && t.source != .dictation
        let project = t.projectId.flatMap { p in app.store.projects.first { $0.id == p } }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: Binding(get: { t.title }, set: { v in
                guard v != t.title else { return }
                app.store.updateDeferred(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
            }), axis: .vertical)
                .refinedFont(.transcriptTitle).foregroundStyle(Refined.ink).lineLimit(1...4)
                .accessibilityLabel("Title")
                .accessibilityAddTraits(.isHeader)
            // The kind's chip (tap to change it), the project's, then when, the length, the speakers, and the language.
            FlowRow(spacing: 8, lineSpacing: 2) {
                if t.kind != .dictation, t.status == .ready {
                    KindPickerChip(kind: t.kind, isAuto: t.kindIsAuto) { k in app.pickKind(k, for: t.id) }
                }
                if let project {
                    KindChip(title: project.name, hue: RefinedRules.projectHue(project.colorIndex))
                        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                        .accessibilityLabel("Project: \(project.name)")
                }
                Text(Self.meta(t, languageMenu: languageMenu)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                    .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                if languageMenu {
                    // The language it was transcribed in, and Transcribe again in… another one.
                    TranscriptLanguageMenu(transcript: t).refinedFont(.meta)
                        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                }
            }
            if t.titleIsAuto && t.titleByModel {
                HStack(spacing: 6) {
                    IconGlyph(art: .iconAI, size: 14, color: Refined.mute)
                    Text("Title by Apple Intelligence").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                .accessibilityElement(children: .combine)
            }
            // Filed as a Brain dump afterward: "Now a Brain dump. Run Plan my day?" (PhonePlanViews.swift).
            if t.status == .ready { PhoneKindOffer(transcript: t) { mode = .result } }
            if t.status == .ready, !t.visibleSpeakerSuggestions.isEmpty {
                SpeakerSuggestionRows(transcript: t,
                                      onUse: { app.useSpeakerSuggestion(t.id, $0) },
                                      onDismiss: { app.dismissSpeakerSuggestion(t.id, $0) })
            }
            stageRow(t)
            if let info = t.linkInfo { PhoneLinkCard(info: info) }
        }
        .task(id: t.id) { SpeakerNameSuggester.openedIfNeeded(t.id, store: app.store) }
    }

    /// Continue recording's new part on its way, Transcribe again with Whisper Turbo waiting for the Mac, or speakers
    /// still being found.
    @ViewBuilder private func stageRow(_ t: Transcript) -> some View {
        if t.pendingAppend != nil {
            HStack(spacing: 8) {
                if t.processingDevice != nil { ProgressView().controlSize(.small) } else { IconGlyph(art: .capture, size: 18, color: Refined.accentText) }
                LiveStage(t) { t in Text(t.stageText).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(2) }
                Spacer(minLength: 4)
                if t.processingDevice == nil {
                    Menu {
                        Button { app.retry(t) } label: { Label("Try again", systemImage: "arrow.counterclockwise") }
                        Button(role: .destructive) { app.discardPendingAppend(t.id) } label: { Label("Discard new recording", systemImage: "trash") }
                    } label: { Text("Retry").refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText) }
                        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                } else if t.processingDevice == Device.id {
                    Button("Cancel") { app.cancel(t.id) }.buttonStyle(RefinedActionStyle())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .refinedSurface(Refined.persimmonTint, radius: RefinedPlatform.radius(.card))
        } else if t.rerunRequest != nil, t.status == .ready {
            // Transcribe again with Whisper Turbo, waiting for the Mac to pick it up.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                LiveStage(t) { t in Text(t.stageText).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(2) }
                Spacer(minLength: 4)
                if t.processingDevice == nil { Button("Cancel") { app.cancelTurboRequest(t.id) }.buttonStyle(RefinedActionStyle()) }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        } else if t.status == .ready {
            // A progress tick can change the label (StageClock), so it's read live.
            LiveStage(t) { t in
                if t.stage == "Finding speakers" {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Finding speakers…") }
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                }
            }
        }
    }

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing {
            HStack(spacing: 14) {
                SignalRings(active: t.processingDevice == Device.id).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    LiveStage(t) { t in Text(t.stageText).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink) }
                    Text(t.processingDevice == Device.id ? "On this iPhone. The first run downloads the model once." : "It appears here when it's done.")
                        .refinedFont(.hint).foregroundStyle(Refined.mute)
                }
            }
            .padding(.top, 8)
        } else if t.status == .failed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconGlyph(art: .iconAttention, size: 20, color: Refined.accentText)
                    Text("Transcription did not finish").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                }
                Text(t.error ?? "").refinedFont(.hint).foregroundStyle(Refined.mute)
                HStack(spacing: 8) {
                    Button("Retry") { app.retry(t) }.buttonStyle(RefinedActionStyle(kind: .strong))
                    // Local Only refused this transcript's model download (PhoneTrust.swift).
                    PhoneAllowDownloadButton(transcript: t)
                }
            }
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                switch mode {
                case .transcript:
                    let background = mainSpeakerOnly ? t.backgroundSegments : []
                    let segs = shownLines(t)
                    VStack(alignment: .leading, spacing: 10) {
                        // Fix all, after Fix a word… (PhoneTrust.swift).
                        PhoneFixAllBanner(transcriptID: t.id)
                        // Words and Select text are in More › Text and display; the bar shows only while one is on.
                        if selecting || showEngine { originalBar(t) }
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
                            FillerToggle(count: fillers, shown: $showFiller)
                        }
                        if !background.isEmpty {
                            BackgroundVoicesCard(segments: background,
                                                 onPlay: { s in app.player.seek(to: s.start) },
                                                 onMoveBack: { s in if let main = t.mainSpeaker { app.assign(t.id, segment: s.id, to: main) } })
                                .padding(.top, 8)
                        }
                    }
                case .document: PhoneDocument(transcript: t)
                case .summary:
                    SummaryBlock(transcript: t,
                                 onSummarize: { replacing in summarize(t, replacing: replacing) },
                                 onSave: { s in app.store.update(t.id) { $0.summary = s; $0.summaryByModel = false } })
                case .review: review(t)
                case .result: PhoneTemplateResults(transcript: t, onJump: { at in
                    app.player.play(from: at)
                    mode = .transcript
                    if let s = PlaybackSync.line(at: at, in: t.segments) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { scrollTarget = s.id } }
                })
                }
            }
        }
    }

    /// Runs Summarize, or says why Apple Intelligence can't here.
    private func summarize(_ t: Transcript, replacing: Bool) {
        if let why = SummaryAction.unavailableReason { summaryUnavailable = why; return }
        SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: replacing)
    }

    /// Original tab, while one is on: which words (with corrections, or the engine's) and Select text.
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
                        Text(showEngine ? "Engine words" : "With corrections").refinedFont(.hint, weight: .medium)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Refined.ink)
                    .padding(.horizontal, 14).frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                    .background(Refined.neutral, in: Capsule())
                }
                .accessibilityLabel("Words: \(showEngine ? "engine words" : "with corrections")")
                .accessibilityIdentifier("original-words")
                RefinedChip(title: selecting ? "Done selecting" : "Select text", selected: selecting) { selecting.toggle() }
                    .accessibilityIdentifier("original-select")
                Spacer(minLength: 0)
            }
            if showEngine {
                Text(t.hasEngineWords ? "Exactly what the engine heard, before your corrections and Dictionary fixes."
                                      : "This transcript has no separate engine words, so these are the lines as they are.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
            }
        }
    }

    /// Review: each fix beside what it replaced, in a card, with Undo.
    @ViewBuilder private func review(_ t: Transcript) -> some View {
        if t.corrections.isEmpty {
            Text("Nothing changed yet. Dictionary fixes and your corrections show here beside the original.")
                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        } else {
            PaperList(t.corrections, id: \.id, inset: 46) { c in
                HStack(alignment: .top, spacing: 10) {
                    IconGlyph(art: c.byDictionary ? .iconDictionary : .iconFeedback, size: 18, color: Refined.ink).frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(c.from).strikethrough().foregroundStyle(Refined.mute)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Refined.mute)
                            Text(c.to).fontWeight(.semibold).foregroundStyle(Refined.ink)
                        }
                        .refinedFont(.body)
                        if let seg = t.segments.first(where: { $0.id == c.segmentId }) {
                            Text(seg.text).refinedFont(.meta).foregroundStyle(Refined.dim).lineLimit(2)
                        }
                        Text(c.byDictionary ? "Dictionary" : "Your fix").refinedFont(.caption).foregroundStyle(Refined.mute)
                    }
                    Spacer(minLength: 6)
                    Button("Undo") { app.store.undoCorrection(c, in: t.id) }
                        .buttonStyle(RefinedActionStyle())
                        .accessibilityLabel("Undo \(c.to)")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// More: a standard Liquid Glass menu built like Apple Books' reading menu (iOS 27.2). A row of icon buttons (Copy,
    /// Find, Mark) as a ControlGroup, then the transcript's places and tools, then Rename and Delete, which the system
    /// draws in its destructive red.
    private func more(_ t: Transcript) -> some View {
        let moments = t.notes.filter { $0.at != nil }.count
        let ready = t.status == .ready
        let fillers = app.store.fillerCount(t.id)
        return Menu {
            ControlGroup {
                Button { app.copyText(t, copyVersion) } label: { Label("Copy", systemImage: "doc.on.doc") }   // brand: system surface (menu)
                    .disabled(!ready)
                Button { showFind = true } label: { Label("Find", systemImage: "magnifyingglass") }
                    .disabled(!ready)
                Button { mark(t) } label: { Label("Mark", systemImage: "bookmark") }   // brand: system surface (menu)
                    .disabled(!ready || t.audioFileName == nil)
            }
            Section {
                Button { mode = .summary } label: { Label("Summary", systemImage: "text.alignleft") }   // brand: system surface (menu)
                    .disabled(!ready)
                Button { showNotes = true } label: {
                    Label("Moments", systemImage: "bookmark")   // brand: system surface (menu)
                    Text(moments == 1 ? "1 saved" : "\(moments) saved")
                }
                Button { showSpeakers = true } label: {
                    Label("Speakers", systemImage: "person.2")   // brand: system surface (menu)
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
                } label: { Label("Run a template", systemImage: "doc.text") }   // brand: system surface (menu)
                .disabled(!ready)
                Menu {
                    Section("From the original transcript") {
                        PhoneActionItems { a in
                            if let why = TranscriptActions.unavailableReason { summaryUnavailable = why } else { runningAction = a }
                        }
                    }
                    Button { mode = .summary; summarize(t, replacing: false) } label: { Label(SummaryAction.title(t), systemImage: "text.quote") }   // brand: system surface (menu)
                        .disabled(t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
                    Divider()
                    if t.audioFileName != nil, t.pendingAppend == nil, !t.isAudioOnly {
                        Button { app.player.stop(); app.continueRecording(t.id) } label: { Label("Continue recording", systemImage: "mic.badge.plus") }   // brand: system surface (menu)
                    }
                    // Whisper Turbo on the original audio, run by your Mac; and back to the words it replaced.
                    Button { askTurbo = true } label: { Label(TurboRerun.title + "…", systemImage: "arrow.counterclockwise") }
                        .disabled(TurboRerun.unavailableReason(t) != nil)
                    if let other = TurboRerun.switchTitle(t) {
                        Button { app.switchTranscriptVersion(t.id) } label: { Label(other, systemImage: "arrow.uturn.backward") }
                    }
                } label: { Label("Actions", systemImage: "sparkles") }   // brand: system surface (menu)
                .disabled(!ready)
            }
            Section {
                Menu {
                    Button { app.exportRequest = PhoneExportRequest(ids: [t.id]) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    if let u = app.store.audioURL(for: t) {
                        Button { shareAudio(u) } label: { Label("Share original audio", systemImage: "waveform") }   // brand: system surface (menu)
                    }
                    Divider()
                    // The text with a header (title, date, duration, speakers, source, language) for an AI assistant.
                    Button { app.copyForAI(t) } label: { Label("Copy for AI", systemImage: "doc.on.clipboard") }   // brand: system surface (menu)
                    Button { app.copyText(t, copyVersion, timestamps: true) } label: { Label("Copy with timestamps", systemImage: "clock") }   // brand: system surface (menu)
                    Button { app.copyText(t, copyVersion.other) } label: {
                        Label(copyVersion == .cleaned ? "Copy the original" : "Copy the cleaned text", systemImage: "arrow.left.arrow.right")   // brand: system surface (menu)
                    }
                    Button { app.copyText(t, .engine) } label: { Label("Copy engine words", systemImage: "waveform") }   // brand: system surface (menu)
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
                    Button { app.newProjectFor = t.id } label: { Label("New project…", systemImage: "folder.badge.plus") }   // brand: system surface (menu)
                } label: { Label("Add to project", systemImage: "folder.badge.plus") }   // brand: system surface (menu)
                Menu {
                    Picker("Words", selection: $showEngine) {
                        Text("With corrections").tag(false)
                        Text("Engine words").tag(true)
                    }
                    Toggle(isOn: $selecting) { Label("Select text", systemImage: "selection.pin.in.out") }   // brand: system surface (menu)
                    if hideFillerSetting, fillers > 0 {
                        Toggle(isOn: $showFiller) { Label("Show filler lines", systemImage: "text.badge.minus") }   // brand: system surface (menu)
                    }
                    Toggle(isOn: $follow) { Label("Follow playback", systemImage: "text.line.first.and.arrowtriangle.forward") }   // brand: system surface (menu)
                } label: { Label("Text and display", systemImage: "textformat.size") }   // brand: system surface (menu)
                .disabled(!ready)
                Button { showDetails = true } label: { Label("Details", systemImage: "info.circle") }   // brand: system surface (menu)
            }
            Section {
                Button { RenameCenter.shared.begin(t) } label: { Label("Rename", systemImage: "pencil") }   // brand: system surface (menu)
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("transcript.more")
    }

    /// Mark: a bookmark at the playhead, on the line being said (the same as the player's Mark this moment).
    private func mark(_ t: Transcript) {
        let at = app.player.time
        let seg = t.segments.first { at >= $0.start && at < $0.end }
        app.addNote(t.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
        app.say("Marked \(Marks.clock(at))")
    }
}

extension TranscriptScreen.Mode {
    /// The self-test's names for the tabs.
    init?(selfTest raw: String) {
        switch raw {
        case "transcript": self = .transcript
        case "document": self = .document
        case "summary": self = .summary
        case "review": self = .review
        case "result": self = .result
        default: return nil
        }
    }
}

extension Notification.Name {
    /// The self-test picks a transcript's tab (`TranscriptScreen.Mode(selfTest:)`).
    static let phoneTranscriptMode = Notification.Name("phoneTranscriptMode")
}

/// The reading surface's edges: Apple's soft scroll edge effect under the navigation bar's glass (iOS 26); a fade of
/// paper before that.
private struct ReadingEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

/// Paper fading in under the player bar, so lines scrolling past it fade instead of peeking around it (mockup:
/// transcript). Never takes touches.
private struct PlayerFade: View {
    var height: CGFloat
    var body: some View {
        LinearGradient(stops: [.init(color: Refined.paper.opacity(0), location: 0), .init(color: Refined.paper, location: 0.6)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The reading lines: each turn as the speaker's chip (when the speaker changes) and the time over the serif text. Reads
/// the playhead without observing it: the lines re-render only when the playing passage changes (`playingIDs`), not on
/// every 20 Hz tick, so the playing wash moves without re-rendering the screen. VoiceOver reads a turn as one element:
/// the speaker, the time, and the words, with Play from here as its action and the line's tools as named actions.
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
    /// The passages under the playhead as of the last tick. Only a change here re-renders the lines; the wash itself is
    /// worked out from the clock in `body`.
    @State private var playingIDs: Set<UUID> = []
    /// Sponsor reads opened from their folded row.
    @State private var openSponsors: Set<UUID> = []

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
        let order = transcript.speakerOrder
        let current = Self.playing(segs, at: clock.time, isPlaying: app.player.isPlaying)
        // Sponsor reads fold into one row at their first line; their lines show once the row is opened.
        let folds = self.folds.count == segs.count ? self.folds : SponsorFold.places(segs, in: transcript)
        // "unclear 2:10" chips where speech was heard but no words came through (UnclearRules), between the lines.
        let chips = UnclearStyle.chips(transcript, lines: segs)
        LazyVStack(alignment: .leading, spacing: 4) {
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
                turn(s, showSpeaker: showSpeaker, index: s.speaker.flatMap { order[$0] } ?? 0, playing: playing,
                     marked: saved.contains(s.id) || marked[s.id] != nil, mark: marked[s.id], inFold: fold != nil)
                    .padding(.top, showSpeaker && i > 0 ? 10 : 0)
                    .id(s.id)
                    .scrubRow(scrub, index: i, count: segs.count)
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

    /// One turn: the chip and the time (the chip opens Rename and This line is; the time plays from here), the text,
    /// and a marked moment's chip.
    private func turn(_ s: Segment, showSpeaker: Bool, index: Int, playing: Bool, marked: Bool, mark: Note?, inFold: Bool) -> some View {
        let name = transcript.speakerName(s.speaker)
        let time = RefinedRules.time(s.start)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if showSpeaker, let n = name {
                    // Tap the name to rename the speaker or move this line to someone else.
                    Menu { speakerMenu(s, name: n) } label: {
                        SpeakerChip(name: n, index: index)
                            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                            .contentShape(Rectangle())
                    }
                }
                Button { play(s) } label: {
                    TurnTime(time: time, playing: playing, marked: marked)
                        .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // The 44 pt targets reach into the space around the line, which is empty.
            .padding(.vertical, -10)
            lineText(s, playing: playing).readingStyle()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Tap a line to play from it (Select text, in More, is for selecting).
                .onTapGesture { play(s) }
            if let mark {
                Button { if let at = mark.at { app.player.play(from: at) } else { play(s) } } label: {
                    MomentChip(time: Marks.clock(mark.at ?? s.start), source: Marks.shortSource(mark))
                        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -8)
                .accessibilityLabel(Marks.chip(mark) ?? "Moment")
                .accessibilityHint("Plays from this moment.")
            }
        }
        .readingTurn(playing: playing)
        .contentShape(Rectangle())
        .contextMenu { lineMenu(s, inFold: inFold) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name.map { "\($0)," }, RefinedRules.spokenTime(s.start) + ",", s.text].compactMap { $0 }.joined(separator: " "))
        .accessibilityValue([playing ? "Playing" : nil, marked ? "Marked" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Plays from here.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { play(s) }
        .accessibilityActions {
            Button("Bookmark") { bookmark(s) }
            Button("Add note") { onNote(s) }
            Button("Fix a word") { fixing = s }
            Button("Copy quote") { copyQuote(s) }
            if let sid = s.speaker, let sp = transcript.speakers.first(where: { $0.id == sid }) {
                Button("Rename \(sp.label)") { newName = sp.name; renaming = sp }
            }
            if let mark { Button("Play moment") { app.player.play(from: mark.at ?? s.start) } }
        }
    }

    @ViewBuilder private func speakerMenu(_ s: Segment, name n: String) -> some View {
        if let sid = s.speaker, let sp = transcript.speakers.first(where: { $0.id == sid }) {
            Button { newName = sp.name; renaming = sp } label: { Label("Rename \(n)…", systemImage: "pencil") }   // brand: system surface (menu)
        }
        Section("This line is") {
            ForEach(transcript.speakers) { sp in
                Button { app.assign(transcript.id, segment: s.id, to: sp.id) } label: {
                    Label(sp.label, systemImage: sp.id == s.speaker ? "checkmark" : "person")   // brand: system surface (menu)
                }
            }
            Button { app.assign(transcript.id, segment: s.id, to: nil) } label: { Label("No speaker", systemImage: "person.slash") }   // brand: system surface (menu)
        }
    }

    @ViewBuilder private func lineMenu(_ s: Segment, inFold: Bool) -> some View {
        if app.player.loadedURL != nil {
            Button { play(s) } label: { Label("Play from here", systemImage: "play") }   // brand: system surface (menu)
        }
        Button { bookmark(s) } label: { Label("Bookmark", systemImage: "bookmark") }   // brand: system surface (menu)
        Button { onNote(s) } label: { Label("Add note…", systemImage: "note.text.badge.plus") }   // brand: system surface (menu)
        Button { fixing = s } label: { Label("Fix a word…", systemImage: "pencil") }   // brand: system surface
        Button { copyQuote(s) } label: { Label("Copy quote", systemImage: "quote.opening") }   // brand: system surface (menu)
        if let info = transcript.linkInfo, info.supportsTimestamps, let u = info.url(at: s.start) {
            Button { UIPasteboard.general.string = "“\(s.text)” \(u.absoluteString)"; app.say("Quote and link copied"); Haptics.play(.copied) } label: { Label("Copy quote with link", systemImage: "link") }   // brand: system surface (menu)
            Link(destination: u) { Label("Open video at \(RefinedRules.time(s.start))", systemImage: "play.rectangle") }   // brand: system surface (menu)
        }
        if transcript.offersSponsorMarking, !inFold {
            Button { app.store.update(transcript.id) { $0.markSponsor(segment: s.id) } } label: { Label("Mark as sponsor", systemImage: "tag") }   // brand: system surface (menu)
        }
    }

    private func bookmark(_ s: Segment) {
        app.addNote(transcript.id, text: String(s.text.prefix(60)), at: s.start, segment: s.id, bookmark: true)
    }

    private func copyQuote(_ s: Segment) {
        UIPasteboard.general.string = "“\(s.text)”"; app.say("Quote copied"); Haptics.play(.copied)
    }

    @MainActor private func syncPlaying(at now: Double) {
        let ids = Self.playing(transcript.segments, at: now, isPlaying: app.player.isPlaying)
        if ids != playingIDs { playingIDs = ids }
    }

    /// The chips before a line: tap one to play that spot.
    private func unclearChips(_ spans: [UnclearSpan]) -> some View {
        ForEach(spans, id: \.start) { sp in
            UnclearChip(span: sp, onPlay: { if app.player.canPlay { app.player.play(from: sp.start) } })
                .padding(.vertical, 4)
        }
    }

    /// Seeks to the line and plays, once the audio is open.
    private func play(_ s: Segment) {
        guard app.player.canPlay else { return }
        app.player.play(from: PlaybackSync.seekTime(s, duration: app.player.duration))
    }

    /// The line's text; while it plays with fresh word timings, the playing word takes the playing wash too.
    @ViewBuilder private func lineText(_ s: Segment, playing: Bool) -> some View {
        // Low-confidence words carry a quiet dotted underline (UnclearStyle), as a best guess.
        if playing, PlaybackSync.timingsFresh(s) {
            PlayingWordText(segment: s, base: UnclearStyle.marked(AttributedString(s.text), s), clock: clock, tint: Refined.playing)
        } else {
            Text(UnclearStyle.marked(AttributedString(s.text), s))
        }
    }
}

/// The transcript's player: the kit's glass bar (`GlassPlayerBar`) with this recording's waveform, its moments, and the
/// speed's menu (the speeds, back and forward 5 seconds, Reduce background noise, Mark this moment, and Follow
/// playback). Observes the player and the clock, so playback redraws the bar alone. Play turns Follow back on.
struct PhonePlayerBar: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @ObservedObject var player: Player
    @ObservedObject var clock: PlayerClock
    var downloading: Bool
    @Binding var follow: Bool

    var body: some View {
        let total = max(clock.duration, transcript.duration, 0.1)
        GlassPlayerBar(isPlaying: player.isPlaying, elapsed: min(clock.time, total), duration: total,
                       levels: transcript.waveform.isEmpty ? Self.flat : transcript.waveform,
                       moments: transcript.notes.filter { $0.isBookmark || $0.isMark }.compactMap(\.at),
                       speed: PlaybackSync.speedLabel(player.rate), status: clock.note, loading: downloading,
                       onPlayPause: {
                           if !player.isPlaying { follow = true }
                           player.toggle()
                       },
                       onSeek: { player.seek(to: $0) }) {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(PlaybackSync.speeds, id: \.self) { r in Text(PlaybackSync.speedLabel(r)).tag(r) }
            }
            Button { player.seek(to: max(0, clock.time - 5)) } label: { Label("Back 5 seconds", systemImage: "gobackward.5") }   // brand: system surface (menu)
            Button { player.seek(to: min(total, clock.time + 5)) } label: { Label("Forward 5 seconds", systemImage: "goforward.5") }   // brand: system surface (menu)
            ReduceNoiseToggle(player: player)
            Button {
                let at = clock.time
                let seg = transcript.segments.first { at >= $0.start && at < $0.end }
                app.addNote(transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
            } label: { Label("Mark this moment", systemImage: "bookmark") }   // brand: system surface (menu)
            Toggle(isOn: $follow) { Label("Follow playback", systemImage: "text.line.first.and.arrowtriangle.forward") }   // brand: system surface (menu)
        }
        .accessibilityIdentifier("transcript.player")
    }

    /// A quiet waveform for a recording whose levels aren't measured yet.
    static let flat: [Float] = (0..<46).map { Float(0.25 + 0.5 * abs(sin(Double($0) * 0.7) * cos(Double($0) * 0.23))) }
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

/// A link's video under the header: its thumbnail, the channel and site, and the upload date, on a card. The whole
/// card opens the video.
struct PhoneLinkCard: View {
    var info: LinkInfo
    var body: some View {
        if let u = URL(string: info.url) {
            // One play target: the whole card opens the video.
            Link(destination: u) { card }
                .buttonStyle(RefinedPress())
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
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Refined.neutralSquare)
                if let f = info.thumbnailFile { StillImage(file: f, maxPixel: 240).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
                else { IconGlyph(art: .iconPlay, size: 18, color: Refined.mute) }
            }
            .frame(width: 72, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                Text(info.uploadDisplay ?? URL(string: info.url)?.host ?? "").refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(8)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
    }
}

/// Moments and notes for one transcript, newest first, with an add field: a system sheet with the transcript's
/// paper behind its rows. A bookmark or a marked moment carries the accent mark; tap one to play from it.
struct NotesSheet: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
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
                    .listRowBackground(Refined.card)
                }
                Section {
                    ForEach(app.store.transcript(id)?.notes ?? []) { n in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                if n.isBookmark { MomentMark() }
                                if let at = n.at { Text(RefinedRules.time(at)).refinedFont(.meta).monospacedDigit() }
                                // Marked while recording: where from.
                                if let from = Marks.shortSource(n) { Text("· \(from)").refinedFont(.meta) }
                            }
                            .foregroundStyle(Refined.mute)
                            if let f = n.frameFile { StillImage(file: f).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
                            if let action = n.aiAction {
                                // Saved from an action: stays marked as Apple Intelligence's, not the transcript's.
                                HStack(spacing: 6) {
                                    IconGlyph(art: .iconAI, size: 14, color: Refined.dim)
                                    Text("\(action) · Made by Apple Intelligence").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.dim)
                                }
                            }
                            Text(Marks.words(n, in: app.store.transcript(id)?.segments ?? [])).refinedFont(.body).foregroundStyle(Refined.ink)
                        }
                        .listRowBackground(Refined.card)
                        .contentShape(Rectangle())
                        .onTapGesture { if let at = n.at { app.player.seek(to: at) } }
                    }
                    .onDelete { idx in
                        let notes = app.store.transcript(id)?.notes ?? []
                        for i in idx { app.deleteNote(id, note: notes[i].id) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Refined.paper.ignoresSafeArea())
            .navigationTitle("Moments and notes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
