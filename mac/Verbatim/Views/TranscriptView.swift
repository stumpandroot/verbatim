import SwiftUI
import AppKit

/// Transcript workspace (Listening Desk composition, Soft Instrument playback dock).
/// Calm reading surface; the player and the notes carry the interaction.
struct TranscriptView: View {
    /// True while any text field or text view in the key window is being edited.
    static var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    @EnvironmentObject var app: AppState
    var id: UUID
    @State private var view: Mode = .original
    /// nil = automatic (open when the window is wide). Set once the person toggles it.
    @State private var notesPref: Bool? = nil
    @State private var detailsOpen = false
    @State private var selectedSegment: UUID? = nil
    @State private var followed: UUID? = nil
    @State private var pendingSeek: Double? = nil
    @State private var textSize: CGFloat = 16
    /// True once the mode bar has scrolled under the top edge; a pinned copy shows there instead.
    @State private var barPinned = false
    @State private var runningAction: FlowAction? = nil
    /// Why Summarize can't run here (Apple Intelligence unavailable), shown when the action is chosen.
    @State private var summaryUnavailable: String? = nil
    /// "2 filler lines hidden · Show": per view, starting from Settings › Hide filler lines.
    @State private var showFiller = false
    @AppStorage(Transcript.hideFillerKey) private var hideFillerSetting = true
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false
    /// Original tab: the engine's own words (`original`) instead of the corrected lines.
    @State private var showEngine = false
    /// Original tab: one selectable text, for selecting across lines.
    @State private var selecting = false
    @Namespace private var segNS

    /// Raw values stay stable: UI tests and Home post them in `.verbatimShowMode`.
    enum Mode: String, CaseIterable {
        case original = "Transcript", document = "Document", review = "Review"
        /// The tab's name on screen.
        var title: String {
            switch self { case .original: return "Original"; case .document: return "Cleaned"; case .review: return "Review" }
        }
    }
    /// Clean up and Tone live inside Cleaned.
    static let visibleModes: [Mode] = [.original, .document, .review]

    /// What Copy takes on this tab.
    private var copyVersion: Exporter.CopyVersion { view == .document ? .cleaned : .original }


    private var transcript: Transcript? { app.store.transcript(id) }

    var body: some View {
        // One sheet for the screen: the tools row can exist twice (scrolled and pinned).
        screenBody.sheet(item: $runningAction) { a in
            if let t = transcript {
                ActionSheet(action: a, source: t.documentText, sourceLabel: "“\(t.title)”") { text in
                    app.store.addNote(Note(text: "\(a.name):\n\(text)"), to: t.id)
                }
                .environmentObject(app)
            }
        }
        .alert("Summaries need Apple Intelligence", isPresented: Binding(get: { summaryUnavailable != nil }, set: { if !$0 { summaryUnavailable = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(summaryUnavailable ?? "") }
    }

    /// The Summarize action: runs it, or says why it can't run on this Mac.
    private func summarize(_ t: Transcript) {
        if let why = SummaryAction.unavailableReason { summaryUnavailable = why; return }
        // An edited summary is replaced only from the Summary block's Regenerate, which asks first.
        SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: false)
    }

    @ViewBuilder private var screenBody: some View {
        if let t = transcript {
            GeometryReader { g in
            // Decided from the geometry in the same pass, so the screen lays out once (no open-then-close).
            let narrow = g.size.width < 900
            let notesOpen = notesPref ?? !narrow
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(t).staggerIn(0)
                                modeBar(t, notesOpen: notesOpen, narrow: narrow)
                                    .opacity(barPinned ? 0 : 1).allowsHitTesting(!barPinned)
                                    .background(GeometryReader { b in Color.clear.preference(key: BarOffsetKey.self, value: b.frame(in: .named("tscroll")).minY) })
                                    .staggerIn(1).padding(.bottom, 8)
                                content(t)
                            }
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, t.audioFileName != nil && view != .document ? 124 : 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .coordinateSpace(name: "tscroll")
                        .onPreferenceChange(BarOffsetKey.self) { y in
                            let pinned = y < 6
                            if pinned != barPinned { barPinned = pinned }
                        }
                        .overlay(alignment: .top) {
                            // The mode bar and tools stay reachable while reading: pinned under the top edge.
                            if barPinned {
                                VStack(spacing: 0) {
                                    modeBar(t, notesOpen: notesOpen, narrow: narrow)
                                        .frame(maxWidth: 720, alignment: .leading)
                                        .padding(.horizontal, 40).padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Ink.paper)
                                    Rectangle().fill(Ink.hairline).frame(height: 1)
                                }
                                .transition(.opacity)
                            }
                        }
                        .onReceive(app.player.clock.$time) { now in
                            // Follow playback, but only when the playing passage changes (not on every tick).
                            if app.player.isPlaying, let s = t.segments.first(where: { now >= $0.start && now < $0.end }), s.id != followed {
                                followed = s.id
                                withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                            }
                        }
                        .onAppear {
                            // Opened from search, a link, or a note: land on that passage.
                            if let f = app.focusSegment, t.segments.contains(where: { $0.id == f }) {
                                app.focusSegment = nil
                                view = .original
                                selectedSegment = f
                                DispatchQueue.main.async { proxy.scrollTo(f, anchor: .center) }
                                if let s = t.segments.first(where: { $0.id == f }) { pendingSeek = s.start }
                            }
                        }
                    }
                    if t.audioFileName != nil, t.status == .ready, view != .document { PlayerDock(transcript: t, clock: app.player.clock).padding(.horizontal, 24).padding(.bottom, 18).staggerIn(3) }
                }
                .frame(maxWidth: .infinity)
                if notesOpen && !narrow {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.nav) { notesPref = false } })
                        .frame(width: 300)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .identity))
                }
            }
            .overlay(alignment: .trailing) {
                // Narrow window: Notes becomes a drawer over the text instead of squeezing it.
                if notesOpen && narrow {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.nav) { notesPref = false } })
                        .frame(width: 300)
                        .shadow(color: .black.opacity(0.12), radius: 24, x: -6)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .identity))
                }
            }

            }
            .background {
                // Shortcuts live here once, not on the mode bar (which can exist twice while pinned).
                ZStack {
                    Button("") { ExportMenu.copy(t, copyVersion, app: app) }.keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("") { textSize = min(22, textSize + 1) }.keyboardShortcut("=", modifiers: .command)
                    Button("") { textSize = max(13, textSize - 1) }.keyboardShortcut("-", modifiers: .command)
                }
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onAppear {
                if UITest.enabled { Log.note("UITEST nav appear ms=\(Int(Date().timeIntervalSince(app.navStartedAt) * 1000)) segments=\(t.segments.count)") }
                if let u = app.store.audioURL(for: t) { app.player.loadAsync(u, startAt: pendingSeek) }
                if UITest.enabled { DispatchQueue.main.async { Log.note("UITEST nav settled ms=\(Int(Date().timeIntervalSince(app.navStartedAt) * 1000))") } }
            }
            .onDisappear { app.player.stop() }
            // Playback keys never steal typing: when a text field (renaming a speaker, a note, a correction) has
            // focus, the key goes to the field.
            .onKeyPress(.space) { if Self.typing { return .ignored }; app.player.toggle(); return .handled }
            .onKeyPress(.leftArrow) { if Self.typing { return .ignored }; app.player.seek(to: app.player.time - 5); return .handled }
            .onKeyPress(.rightArrow) { if Self.typing { return .ignored }; app.player.seek(to: app.player.time + 5); return .handled }
            .onKeyPress("b") { if Self.typing { return .ignored }; bookmark(t); return .handled }
            .onReceive(NotificationCenter.default.publisher(for: .verbatimShowMode)) { n in
                if let raw = n.object as? String, let m = Mode(rawValue: raw) { withAnimation(Motion.snap) { view = m } }
            }
        } else {
            Text("This transcript was deleted.").foregroundStyle(Ink.mute)
        }
    }

    private func bookmark(_ t: Transcript) {
        let at = app.player.time
        let seg = t.segments.first(where: { at >= $0.start && at < $0.end })
        app.addNote(transcript: t.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
    }

    // MARK: Header and mode bar

    private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Deferred save: typing a title doesn't re-encode the whole transcript on every keystroke.
            TextField("Title", text: Binding(get: { t.title }, set: { v in
                guard v != t.title else { return }
                app.store.update(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
            }))
                .textFieldStyle(.plain).font(Ink.serif(32)).foregroundStyle(Ink.ink).lineLimit(2)
            HStack(spacing: 8) {
                Text(t.sourceLabel); Text("·"); Text(t.duration.timecode)
                if t.speakers.count >= 2 { Text("·"); Text("\(t.speakers.count) speakers") }
                if let k = t.kind { Text("·"); Text(k.label) }
            }
            .font(.system(size: 14)).foregroundStyle(Ink.mute)
            if t.titleIsAuto && t.titleByModel { AITitleNote().padding(.top, 2) }
            if t.status == .ready {
                KindAndTags(transcript: t, compact: true,
                            onPick: { k in app.store.update(t.id) { $0.kind = k; $0.kindIsAuto = false } },
                            onTags: { tags in app.store.update(t.id) { $0.tags = tags } })
                    .padding(.top, 10)
            }
            if t.pendingAppend != nil {
                HStack(spacing: 8) {
                    if t.processingDevice != nil { ProgressView().controlSize(.small) } else { Image(systemName: "waveform.badge.plus").foregroundStyle(Ink.accentText) }
                    Text(t.stageText).font(.system(size: 13.5)).foregroundStyle(Ink.dim)
                    if t.processingDevice == nil {
                        Button("Retry") { app.retry(t) }.buttonStyle(.link)
                        Button("Discard") { app.discardPendingAppend(t.id) }.buttonStyle(.link)
                    } else {
                        Button("Cancel") { app.cancel(t.id) }.buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Ink.persimmonTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 8)
            }
            if let info = t.linkInfo { LinkCard(info: info, transcript: t).padding(.top, 10) }
        }
        .padding(.bottom, 14)
    }

    private func modeBar(_ t: Transcript, notesOpen: Bool, narrow: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Self.visibleModes, id: \.self) { m in
                    Text(m.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        .background { if view == m { Capsule().fill(Ink.iris).matchedGeometryEffect(id: "mode", in: segNS) } }
                        .foregroundStyle(view == m ? Ink.onInteractive : Ink.ink)
                        .tapArea { withAnimation(Motion.snap) { view = m } }
                        .accessibilityLabel(m.title).accessibilityAddTraits(view == m ? .isSelected : [])
                }
            }
            .padding(3).background(Ink.track, in: Capsule()).fixedSize()
            Divider().frame(height: 18)
            versionControl(t).layoutPriority(-1)
            Spacer(minLength: 8)
            tools(t, notesOpen: notesOpen, compact: narrow)
        }
    }

    /// Beside the tabs. Original: which words to show (with corrections, or the engine's) and Select text. Cleaned
    /// and Review: a way to the engine's words, which are stored untouched.
    @ViewBuilder private func versionControl(_ t: Transcript) -> some View {
        if view == .original {
            HStack(spacing: 6) {
                Menu {
                    Picker("Words", selection: $showEngine) {
                        Text("With corrections").tag(false)
                        Text("Show engine words").tag(true)
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(showEngine ? "Engine words" : "With corrections").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.dim).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("With corrections shows your fixes and Dictionary fixes. Engine words shows exactly what the engine heard.")
                .accessibilityIdentifier("original-words")
                Button { selecting.toggle() } label: { ToolLabel(title: "Select text", symbol: "character.cursor.ibeam", compact: false, on: selecting) }
                    .buttonStyle(.plain)
                    .help(selecting ? "Back to lines (corrections, notes, Copy quote)" : "Select across lines and copy with ⌘C")
                    .accessibilityIdentifier("original-select")
            }
        } else {
            Button { withAnimation(Motion.snap) { view = .original; showEngine = true } } label: {
                Text("Engine words kept · Show").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("The engine's words are stored untouched. Open them in Original.")
        }
    }

    /// Copy, Export, Notes, and text size, beside the modes they act on.
    private func tools(_ t: Transcript, notesOpen: Bool, compact: Bool) -> some View {
        HStack(spacing: 2) {
            ExportMenu(transcript: t, compact: compact, version: copyVersion)
            Button { app.continueRecording(t.id) } label: { ToolLabel(title: "Continue", symbol: "record.circle", compact: compact) }
                .buttonStyle(.plain)
                .disabled(t.status != .ready || t.audioFileName == nil || t.pendingAppend != nil || app.recorder.isRecording)
                .help("Record more and add it to the end of this transcript")
            Menu {
                ActionsMenuItems { runningAction = $0 }
                Divider()
                Button(SummaryAction.title(t)) { summarize(t) }
                    .disabled(t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
            } label: { ToolLabel(title: "Actions", symbol: "wand.and.stars", compact: compact) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(t.status != .ready)
                .help("Run a saved action on this transcript: decisions and next steps, a brief, an email")
            Button { withAnimation(Motion.nav) { notesPref = !notesOpen } } label: { ToolLabel(title: "Notes", symbol: "note.text", compact: compact, on: notesOpen) }
                .buttonStyle(.plain).help(notesOpen ? "Hide notes" : "Show notes")
            Menu {
                Button("Larger text") { textSize = min(22, textSize + 1) }
                Button("Smaller text") { textSize = max(13, textSize - 1) }
                Button("Default size") { textSize = 16 }
            } label: { ToolLabel(title: "Text", symbol: "textformat.size", compact: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Text size (⌘+ and ⌘−)")
        }
        .fixedSize()
    }

    // MARK: Content per mode

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing { processing(t) }
        else if t.status == .failed { failed(t) }
        else {
            VStack(alignment: .leading, spacing: 0) {
                if view != .review {
                    SummaryBlock(transcript: t,
                                 onSummarize: { replacing in SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: replacing) },
                                 onSave: { s in app.store.update(t.id) { $0.summary = s; $0.summaryByModel = false } })
                }
                switch view {
                case .original: original(t)
                case .document: DocumentView(transcript: t)
                case .review: review(t)
                }
            }
        }
    }

    /// The reading lines, then the quiet filler toggle and, with Main speaker only on, the Background voices card.
    private func original(_ t: Transcript) -> some View {
        let hide = hideFillerSetting && !showFiller
        let background = mainSpeakerOnly ? t.backgroundSegments : []
        let shown = t.displaySegments(hideFiller: hide, mainOnly: mainSpeakerOnly)
        // Engine words: the same passages as the engine wrote them, read-only (corrections apply to the corrected lines).
        let segs = showEngine ? t.engineLines(for: shown) : shown
        return VStack(alignment: .leading, spacing: 12) {
            if showEngine {
                Text(t.hasEngineWords ? "Engine words: exactly what the engine heard, before your corrections and Dictionary fixes."
                                      : "This transcript has no separate engine words, so these are the lines as they are.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute).padding(.leading, 62)
            }
            if selecting {
                SelectableLines(clock: app.player.clock, isPlaying: app.player.isPlaying, transcript: t, segments: segs, textSize: textSize)
            } else {
                lines(t, segments: segs, editable: !showEngine)
            }
            if hideFillerSetting, t.fillerCount > 0 {
                FillerToggle(count: t.fillerCount, shown: $showFiller).padding(.leading, 60)
            }
            if !background.isEmpty {
                BackgroundVoicesCard(segments: background, compact: true,
                                     onPlay: { s in app.player.seek(to: s.start) },
                                     onMoveBack: { s in if let main = t.mainSpeaker { app.assign(transcript: t.id, segment: s.id, to: main) } })
                    .padding(.top, 6)
            }
        }
    }

    private func lines(_ t: Transcript, segments: [Segment], editable: Bool) -> some View {
        TranscriptLines(clock: app.player.clock, isPlaying: app.player.isPlaying, transcript: t, segments: segments, editable: editable, textSize: textSize, selected: $selectedSegment)
    }

    private func review(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if t.corrections.isEmpty {
                placeholder("Nothing changed yet", "Corrections you make, and Dictionary fixes, show here side by side with the original so you can accept or undo them.")
            } else {
                ForEach(t.corrections) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: c.byDictionary ? "book.closed.fill" : "pencil").foregroundStyle(Ink.iris).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) { Text(c.from).strikethrough().foregroundStyle(Ink.mute); Image(systemName: "arrow.right").font(.system(size: 10)); Text(c.to).fontWeight(.semibold) }
                            if let seg = t.segments.first(where: { $0.id == c.segmentId }) {
                                Text(seg.text).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2)
                                Button(seg.start.timecode) { app.player.seek(to: seg.start) }.buttonStyle(.link).font(.system(size: 11, design: .monospaced))
                            }
                        }
                        Spacer()
                        Button("Undo") { undo(t, c) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(12).cardSurface(radius: 12)
                }
            }
        }
    }

    private func undo(_ t: Transcript, _ c: Correction) {
        app.store.undoCorrection(c, in: t.id)
    }

    private func placeholder(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            EmptyStateArt(art: .refine, tint: Ink.petalTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(body).font(.system(size: 13.5)).foregroundStyle(Ink.mute)
            }
        }
        .padding(16).background(Ink.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }


    private func processing(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SignalRings().frame(width: 40, height: 40).padding(6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.stageText).font(.system(size: 15, weight: .semibold))
                    Text("On this Mac. The first run of a model downloads it once; after that it starts in seconds.").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
            }
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(Ink.ink.opacity(0.07)).frame(width: CGFloat([480, 420, 500, 300][i]), height: 14).padding(.vertical, 6)
            }
        }
    }

    private func failed(_ t: Transcript) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconGlyph(art: .iconAttention, size: 28, color: Ink.accentText).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription did not finish").font(.system(size: 14, weight: .semibold))
                Text(t.error ?? "").font(.system(size: 13)).foregroundStyle(Ink.mute)
                Button("Retry") { app.retry(t) }.buttonStyle(.brandPrimary)
            }
        }
    }
}

extension Notification.Name { static let verbatimFocusNote = Notification.Name("verbatimFocusNote") }

struct BarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

extension Notification.Name { static let verbatimShowMode = Notification.Name("verbatimShowMode") }
