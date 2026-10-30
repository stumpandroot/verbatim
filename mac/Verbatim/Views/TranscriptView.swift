import SwiftUI
import AppKit

/// A transcript in the refined look (DESIGN.md §13; mockup "Verbose Refined Look", MacTranscript), one layout in both
/// look settings: a centered 640 pt reading column on paper with the title in the serif, a meta line led by the kind's
/// chip (and the project's), then each turn as the speaker's chip and the time over the serif reading text, and the
/// glass player bar floating at the foot of the column. The window's toolbar holds Back and Forward, the centered
/// segmented control (Original, Cleaned, Summary, Review once something was corrected, and a template's result), Share,
/// and More, and the side column (Moments, Speakers, Export, Details) is the window's inspector (MacChrome.swift). Keys: Space plays, ← and → move 5 seconds, B marks a moment, ⇧⌘C copies the tab, ⌥⇧⌘C copies for AI, and
/// ⌘+ and ⌘− change the text size.
struct TranscriptView: View {
    /// True while any text field or text view in the key window is being edited.
    static var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    @EnvironmentObject var app: AppState
    var id: UUID
    @State private var selectedSegment: UUID? = nil
    @State private var followed: UUID? = nil
    @State private var pendingSeek: Double? = nil
    /// A passage to bring into view (opened from search, a link, a note, or an Ask citation).
    @State private var scrollTarget: UUID? = nil
    /// "2 filler lines hidden · Show": per view, starting from Settings › Hide filler lines.
    @State private var showFiller = false
    @AppStorage(Transcript.hideFillerKey) private var hideFillerSetting = true
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false
    /// Renaming the title in place (click it).
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @Environment(\.look) private var look
    /// The tab, text size, Follow, engine words, Select text, the selected passage, and the running action, shared
    /// with the window's toolbar and inspector (MacChrome.swift).
    @EnvironmentObject private var nav: WindowNav

    /// Raw values stay stable: UI tests, Home, and Fix all post them in `.verbatimShowMode`.
    enum Mode: String, CaseIterable {
        case original = "Transcript", document = "Document", summary = "Summary", review = "Review", result = "Result"
        /// The tab's name on screen (a result's tab is named for its template, `TranscriptView.tabs`).
        var title: String {
            switch self {
            case .original: return "Original"
            case .document: return "Cleaned"
            case .summary: return "Summary"
            case .review: return "Review"
            case .result: return "Template"
            }
        }
    }

    /// The looks a transcript is on screen in (the self-test checks each look draws this one layout, once).
    static var onScreen = Set<AppLook>()

    /// The reading column's width (the mockup's 640 pt), and the player bar's.
    static let column: CGFloat = 640
    static let playerWidth: CGFloat = 600

    /// The segmented control's tabs: Original, Cleaned, and Summary, then Review while there are corrections (or it's
    /// open), then a template's result, named for its template ("Meeting notes"), or "Results" with more than one.
    @MainActor static func tabs(_ t: Transcript, current: Mode, templates: [TranscriptTemplate]) -> [(Mode, String)] {
        var out: [(Mode, String)] = [(.original, Mode.original.title), (.document, Mode.document.title), (.summary, Mode.summary.title)]
        if !t.corrections.isEmpty || current == .review { out.append((.review, Mode.review.title)) }
        let busy = TemplateCenter.shared.busyTemplate(t.id).flatMap { b in templates.first { $0.id == b }?.name }
        if let title = t.resultTabTitle(busyName: busy) { out.append((.result, title)) }
        else if current == .result { out.append((.result, Mode.result.title)) }
        return out
    }

    /// What Copy takes on this tab.
    private var copyVersion: Exporter.CopyVersion { nav.copyVersion }
    private var view: Mode { nav.mode }

    private var transcript: Transcript? { app.store.transcript(id) }

    var body: some View {
        LookSwitch.mark("transcript")
        // Actions run from the window's toolbar, which shows their sheet and Summarize's alert (MacChrome.swift).
        return screenBody
            // Transcribe again with Whisper Turbo, from More (either look): what it does, the download when the model
            // isn't here, and that your edits stay with the words you can switch back to.
            .alert(TurboRerun.title + "?", isPresented: Binding(get: { app.turboAsk == id }, set: { if !$0, app.turboAsk == id { app.turboAsk = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button(TurboRerun.confirm(needsDownload: !app.turboDownloaded)) { app.transcribeAgainWithTurbo(id) }
            } message: { Text(transcript.map { TurboRerun.message($0, onMac: true, needsDownload: !app.turboDownloaded) } ?? "") }
    }

    @ViewBuilder private var screenBody: some View {
        if let t = transcript {
            // The side column (Moments, Speakers, Export, Details) is the window's inspector (MacChrome.swift).
            column(t)
            .background(Refined.paper)
            .background {
                // Shortcuts live here once.
                ZStack {
                    Button("") { ExportMenu.copy(t, copyVersion, app: app) }.keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("") { CopyForAI.copy(t, app: app) }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
                    Button("") { nav.textSize = WindowNav.textSizes.clamp(nav.textSize + 1) }.keyboardShortcut("=", modifiers: .command)
                    Button("") { nav.textSize = WindowNav.textSizes.clamp(nav.textSize - 1) }.keyboardShortcut("-", modifiers: .command)
                }
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onAppear {
                if UITest.enabled { Log.note("UITEST nav appear ms=\(Int(Date().timeIntervalSince(app.navStartedAt) * 1000)) segments=\(t.segments.count)") }
                Self.onScreen.insert(look)
                // Opened from search, a link, a note, or an Ask citation: land on that passage, on Original.
                let focus = app.focusSegment.flatMap { f in t.segments.first { $0.id == f } }
                nav.opened(t, focus: focus != nil)
                if nav.selectedSegment != focus?.id { nav.selectedSegment = focus?.id }
                selectedSegment = focus?.id
                if let s = focus { pendingSeek = s.start; scrollTarget = s.id; app.focusSegment = nil }
                app.player.screenAppeared(t.id)
                if let u = app.store.audioURL(for: t) {
                    app.player.loadAsync(u, startAt: pendingSeek, autoplay: nav.takeAutoplay(t.id))
                } else {
                    app.player.stop()   // nothing of another transcript's keeps playing here
                }
                if UITest.enabled { DispatchQueue.main.async { Log.note("UITEST nav settled ms=\(Int(Date().timeIntervalSince(app.navStartedAt) * 1000))") } }
            }
            // Stops only when the last screen for this transcript goes and no other transcript took playback: a look
            // switch builds the new screen before the old one leaves, and that used to stop the audio.
            .onDisappear {
                Self.onScreen.remove(look)
                if app.player.screenLeft(id) { app.player.stop() }
            }
            .skipsSponsors(t, player: app.player)
            // Playback keys never steal typing: when a text field (renaming a speaker, a note, a correction) has
            // focus, the key goes to the field.
            .onKeyPress(.space) { if Self.typing { return .ignored }; app.player.toggle(); return .handled }
            .onKeyPress(.leftArrow) { if Self.typing { return .ignored }; app.player.seek(to: app.player.time - 5); return .handled }
            .onKeyPress(.rightArrow) { if Self.typing { return .ignored }; app.player.seek(to: app.player.time + 5); return .handled }
            .onKeyPress("b") { if Self.typing { return .ignored }; nav.bookmark(t, app: app); return .handled }
            .onReceive(NotificationCenter.default.publisher(for: .verbatimShowMode)) { n in
                if let raw = n.object as? String, let m = Mode(rawValue: raw) { nav.mode = m }
            }
            .onChange(of: selectedSegment) { _, v in if nav.selectedSegment != v { nav.selectedSegment = v } }
            .onChange(of: t.corrections.isEmpty) { _, none in if none, nav.mode == .review { nav.mode = .original } }
        } else {
            Text("This transcript was deleted.").refinedFont(.body).foregroundStyle(Refined.mute)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Refined.paper)
        }
    }

    // MARK: The reading column

    private func column(_ t: Transcript) -> some View {
        let hasPlayer = t.audioFileName != nil && t.status == .ready && view != .document
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(t)
                    content(t).padding(.top, 18)
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 14)
                .padding(.bottom, hasPlayer ? 104 : 40)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Lines fade under the toolbar's glass and the player's, instead of colliding with them (review M-29).
            .softScrollEdges([.top, .bottom])
            .onReceive(app.player.clock.$time) { now in
                // Follow playback (while Follow is on), only when the playing passage changes, not on every tick.
                if nav.follow, app.player.isPlaying, view == .original, !nav.selecting,
                   let s = t.segments.first(where: { now >= $0.start && now < $0.end }), s.id != followed {
                    followed = s.id
                    withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                }
            }
            .onChange(of: scrollTarget, initial: true) { _, target in
                guard let target else { return }
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
        .overlay(alignment: .bottom) {
            if hasPlayer {
                // The glass bar over the reading column's foot; the scroll edge effect keeps lines legible under it.
                MacPlayerBar(transcript: t, player: app.player, clock: app.player.clock, nav: nav)
                    .frame(maxWidth: Self.playerWidth)
                    .padding(.horizontal, 32).padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    /// The title (click it to rename), the meta line with the kind's and the project's chips and the tags, and what
    /// needs you: the title's Apple Intelligence note, the kind-change offer, suggested speakers, a recording being
    /// added, the link's video, and the latest fixes with Undo.
    private func header(_ t: Transcript) -> some View {
        let project = t.projectId.flatMap { p in app.store.projectsByID[p] }
        return VStack(alignment: .leading, spacing: 10) {
            title(t)
            FlowRow(spacing: 8, lineSpacing: 6) {
                if t.kind != .dictation, t.status == .ready {
                    KindPickerChip(kind: t.kind, isAuto: t.kindIsAuto) { k in app.pickKind(k, for: t.id) }
                }
                if let project {
                    KindColorChip(title: project.name, hue: RefinedRules.projectHue(project.colorIndex))
                        .accessibilityLabel("Project: \(project.name)")
                }
                Text(Self.meta(t)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                if t.status == .ready {
                    RefinedTagChips(tags: t.tags,
                                    onAdd: { tag in if !t.tags.contains(tag) { app.store.update(t.id) { $0.tags = t.tags + [tag] } } },
                                    onRemove: { tag in app.store.update(t.id) { $0.tags = t.tags.filter { $0 != tag } } })
                }
            }
            if t.titleIsAuto && t.titleByModel {
                HStack(spacing: 6) {
                    IconGlyph(art: .iconAI, size: 14, color: Refined.mute)
                    Text("Title by Apple Intelligence").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                .accessibilityElement(children: .combine)
            }
            if t.status == .ready { KindOfferRow(transcript: t) { nav.mode = .result } }
            if t.status == .ready, !t.visibleSpeakerSuggestions.isEmpty {
                SpeakerSuggestionRows(transcript: t,
                                      onUse: { app.useSpeakerSuggestion(transcript: t.id, $0) },
                                      onDismiss: { app.dismissSpeakerSuggestion(transcript: t.id, $0) })
            }
            if t.pendingAppend != nil { appendRow(t) }
            if let info = t.linkInfo { LinkCard(info: info, transcript: t) }
            if view == .original, !t.corrections.isEmpty { correctionChips(t) }
        }
        .task(id: t.id) { SpeakerNameSuggester.openedIfNeeded(t.id, store: app.store) }
    }

    /// "Tuesday, Oct 27, 8:35 PM · 0:42 · 2 speakers · English" after the chips. A dictation's text has no length.
    static func meta(_ t: Transcript, now: Date = Date()) -> String {
        RefinedRules.transcriptMeta(when: RefinedRules.transcriptWhen(t.createdAt, now: now),
                                    duration: WebStatus.isTextOnly(t) ? 0 : t.duration,
                                    speakers: t.speakers.count, language: t.language.map(LanguageDetection.name))
    }

    /// What the recording is when it has no kind: "Voice note" for a voice note (its stored label says "Voice memo"
    /// in older libraries; review M-14), else the stored label.
    static func sourceName(_ t: Transcript) -> String {
        if t.source == .voiceMemo { return "Voice note" }
        return t.sourceLabel.isEmpty ? "Recording" : t.sourceLabel
    }

    /// The title in the serif (32 pt). Click it to rename in place; Return or clicking away saves, Escape cancels.
    @ViewBuilder private func title(_ t: Transcript) -> some View {
        if editingTitle {
            TextField("Title", text: $titleDraft, axis: .vertical)
                .textFieldStyle(.plain).refinedFont(.transcriptTitle).foregroundStyle(Refined.ink).lineLimit(1...3)
                .focused($titleFocused)
                .onSubmit { commitTitle(t) }
                .onChange(of: titleFocused) { _, f in if !f { commitTitle(t) } }
                .onExitCommand { editingTitle = false }
        } else {
            Text(t.title).refinedFont(.transcriptTitle).foregroundStyle(Refined.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { beginRename(t) }
                .help("Click to rename")
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: "Rename") { beginRename(t) }
        }
    }

    private func beginRename(_ t: Transcript) {
        titleDraft = t.title
        editingTitle = true
        DispatchQueue.main.async { titleFocused = true }
    }

    private func commitTitle(_ t: Transcript) {
        guard editingTitle else { return }
        editingTitle = false
        let v = titleDraft.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != t.title else { return }
        app.store.update(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
    }

    /// Continue recording's new part: its stage, and Retry and Discard (or Cancel while it transcribes).
    private func appendRow(_ t: Transcript) -> some View {
        HStack(spacing: 8) {
            if t.processingDevice != nil { ProgressView().controlSize(.small) } else { IconGlyph(art: .capture, size: 16, color: Refined.accentText) }
            LiveStage(t) { t in Text(t.stageText).refinedFont(.body).foregroundStyle(Refined.dim) }
            Spacer(minLength: 8)
            if t.processingDevice == nil {
                Button("Retry") { app.retry(t) }.buttonStyle(RefinedActionStyle())
                Button("Discard") { app.discardPendingAppend(t.id) }.buttonStyle(RefinedActionStyle())
            } else {
                Button("Cancel") { app.cancel(t.id) }.buttonStyle(RefinedActionStyle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .refinedSurface(Refined.persimmonTint, radius: RefinedPlatform.radius(.card))
    }

    /// The latest fixes (yours and the Dictionary's) with Undo; the rest are in Review.
    private func correctionChips(_ t: Transcript) -> some View {
        let recent = Array(t.corrections.suffix(3).reversed())
        let more = t.corrections.count - recent.count
        return FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(recent) { c in
                HStack(spacing: 8) {
                    Text("\u{201C}\(c.from)\u{201D} \u{2192} \(c.to)").refinedFont(.meta).foregroundStyle(Refined.ink)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
                    Button("Undo") { app.store.undoCorrection(c, in: t.id) }
                        .buttonStyle(.plain).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.accentText)
                        .accessibilityLabel("Undo \(c.from) to \(c.to)")
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(Refined.neutral, in: Capsule())
            }
            if more > 0 {
                RefinedLink(title: more == 1 ? "1 more in Review" : "\(more) more in Review") { nav.mode = .review }
            }
        }
    }

    // MARK: Content per tab

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing { processing(t) }
        else if t.status == .failed { failed(t) }
        else {
            switch view {
            case .original: original(t)
            case .document: DocumentView(transcript: t)
            case .summary:
                VStack(alignment: .leading, spacing: 24) {
                    SummaryBlock(transcript: t,
                                 onSummarize: { replacing in
                                     if let why = SummaryAction.unavailableReason { nav.summaryUnavailable = why; return }
                                     SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: replacing)
                                 },
                                 onSave: { s in app.store.update(t.id) { $0.summary = s; $0.summaryByModel = false } })
                    // Make notes, a plan, or a draft from it; the result gets a tab of its own.
                    if t.shownTemplateResults.isEmpty, TemplateCenter.shared.busyTemplate(t.id) == nil {
                        RunTemplateMenu(transcript: t, title: "Run a template", templates: app.store.allTemplates)
                            .uiTarget("transcript-run-template")
                    }
                }
            case .review: review(t)
            case .result: TemplateResultsSection(transcript: t, inline: true, runRow: true, showsOffers: false)
            }
        }
    }

    /// The reading lines, then the quiet filler toggle and, with Main speaker only on, the Background voices card.
    private func original(_ t: Transcript) -> some View {
        let hide = hideFillerSetting && !showFiller
        let background = mainSpeakerOnly ? t.backgroundSegments : []
        // Worked out once per transcript change, not on every render (Store+Memo.swift).
        let shown = app.store.displaySegments(t.id, hideFiller: hide, mainOnly: mainSpeakerOnly)
        let folds = app.store.sponsorFolds(t.id, hideFiller: hide, mainOnly: mainSpeakerOnly, engine: nav.showEngine)
        let fillers = app.store.fillerCount(t.id)
        // Engine words: the same passages as the engine wrote them, read-only (corrections apply to the corrected lines).
        let segs = nav.showEngine ? t.engineLines(for: shown) : shown
        return VStack(alignment: .leading, spacing: 12) {
            wordsRow(t)
            // Fix all, after a correction (Views/TrustViews.swift).
            FixAllBanner(transcriptID: t.id)
            if nav.selecting {
                SelectableLines(clock: app.player.clock, isPlaying: app.player.isPlaying, transcript: t, segments: segs, textSize: nav.textSize)
            } else {
                TranscriptLines(clock: app.player.clock, isPlaying: app.player.isPlaying, transcript: t, segments: segs, folds: folds,
                                editable: !nav.showEngine, textSize: nav.textSize, selected: $selectedSegment)
            }
            if hideFillerSetting, fillers > 0 {
                FillerToggle(count: fillers, shown: $showFiller)
            }
            if !background.isEmpty {
                BackgroundVoicesCard(segments: background, compact: true,
                                     onPlay: { s in app.player.seek(to: s.start) },
                                     onMoveBack: { s in if let main = t.mainSpeaker { app.assign(transcript: t.id, segment: s.id, to: main) } })
                    .padding(.top, 6)
            }
        }
    }

    /// Above the lines: which words to show (with corrections, or the engine's) and Select text, quietly.
    private func wordsRow(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Menu {
                    Picker("Words", selection: $nav.showEngine) {
                        Text("With corrections").tag(false)
                        Text("Show engine words").tag(true)
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(nav.showEngine ? "Engine words" : "With corrections").refinedFont(.meta, weight: .medium).foregroundStyle(Refined.dim)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("With corrections shows your fixes and Dictionary fixes. Engine words shows exactly what the engine heard.")
                .accessibilityIdentifier("original-words")
                Button { nav.selecting.toggle() } label: {
                    Text(nav.selecting ? "Done selecting" : "Select text").refinedFont(.meta, weight: .medium)
                        .foregroundStyle(nav.selecting ? Refined.accentText : Refined.dim)
                }
                .buttonStyle(.plain)
                .help(nav.selecting ? "Back to lines (corrections, notes, Copy quote)" : "Select across lines and copy with ⌘C")
                .accessibilityIdentifier("original-select")
            }
            if nav.showEngine {
                Text(t.hasEngineWords ? "Engine words: exactly what the engine heard, before your corrections and Dictionary fixes."
                                      : "This transcript has no separate engine words, so these are the lines as they are.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
            }
        }
    }

    /// Review: each fix beside what it replaced, in a card, with Undo; its time plays from there.
    @ViewBuilder private func review(_ t: Transcript) -> some View {
        if t.corrections.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing changed yet").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                Text("Corrections you make, and Dictionary fixes, show here side by side with the original so you can accept or undo them.")
                    .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            PaperList(t.corrections, id: \.id, inset: 16, trailingInset: 16) { c in
                HStack(alignment: .top, spacing: 12) {
                    IconGlyph(art: c.byDictionary ? .iconDictionary : .iconFeedback, size: 15, color: Refined.ink).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(c.from).strikethrough().foregroundStyle(Refined.mute)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Refined.mute)
                            Text(c.to).fontWeight(.semibold).foregroundStyle(Refined.ink)
                        }
                        .refinedFont(.body)
                        if let seg = t.segments.first(where: { $0.id == c.segmentId }) {
                            Text(seg.text).refinedFont(.meta).foregroundStyle(Refined.dim).lineLimit(2)
                            Text(RefinedRules.time(seg.start)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.accentText)
                                .tapArea { app.player.seek(to: seg.start) }
                                .help("Play from here").accessibilityAddTraits(.isButton)
                        }
                    }
                    Spacer()
                    Text(c.byDictionary ? "Dictionary" : "Your fix").refinedFont(.meta).foregroundStyle(Refined.mute)
                    Button("Undo") { app.store.undoCorrection(c, in: t.id) }.buttonStyle(RefinedActionStyle())
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    private func processing(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SignalRings().frame(width: 40, height: 40).padding(6)
                VStack(alignment: .leading, spacing: 2) {
                    LiveStage(t) { t in Text(t.stageText).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink) }
                    Text("On this Mac. The first run of a model downloads it once; after that it starts in seconds.").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
            }
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(Refined.neutral).frame(width: CGFloat([480, 420, 500, 300][i]), height: 14).padding(.vertical, 6)
            }
        }
    }

    private func failed(_ t: Transcript) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconGlyph(art: .iconAttention, size: 28, color: Refined.accentText).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription did not finish").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(t.error ?? "").refinedFont(.meta).foregroundStyle(Refined.mute)
                HStack(spacing: 8) {
                    Button("Retry") { app.retry(t) }.buttonStyle(RefinedActionStyle(kind: .strong))
                    AllowDownloadButton(transcript: t)
                }
            }
        }
    }
}

extension Notification.Name { static let verbatimFocusNote = Notification.Name("verbatimFocusNote") }
extension Notification.Name { static let verbatimShowMode = Notification.Name("verbatimShowMode") }

/// An action run on a transcript (Actions menu): the transcript actions read the Original text with corrections,
/// never the Cleaned text; the result can be kept as a note.
struct TranscriptActionSheet: View {
    @EnvironmentObject var app: AppState
    var action: FlowAction
    var transcript: Transcript

    var body: some View {
        let t = transcript
        let onOriginal = TranscriptActions.isBuiltIn(action.id)
        ActionSheet(action: action, source: onOriginal ? TranscriptActions.source(t, timestamps: false) : t.documentText,
                    sourceLabel: onOriginal ? "the original transcript" : "“\(t.title)”",
                    transcript: onOriginal ? t : nil, aiLabel: TranscriptActions.madeByLabel) { text in
            app.store.addNote(Note(text: text, aiAction: action.name), to: t.id)
        }
    }
}
