import SwiftUI
import AppKit

// brand: web style

/// Transcript workspace in the website style (mac/DESIGN.md §11): the recording's name as a large two-line serif
/// title under a mono eyebrow, the Original / Cleaned / Review toggle, the lines on a paper sheet with an ink outline,
/// the side column (Summary on butter, Moments, Export), and the dark player dock.
///
/// Native (`nativeScreen`): a bold title over plain text on the window background, Original and Cleaned as a segmented
/// control in the toolbar with the tools beside it, the side column as an inspector, and a standard player bar.
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
    /// True once the header's Original / Cleaned / Review toggle reaches the top of the screen's content area (it
    /// would sit under the toolbar); a copy floats at the top, right where it was, until the whole bar pins.
    @State private var togglePinned = false
    /// The top of the screen's content area (below the toolbar), in window coordinates.
    @State private var contentTop: CGFloat = 0
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
    /// Renaming the title in place (click it).
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @Namespace private var segNS
    @Environment(\.look) private var look
    /// Native's toolbar and inspector share the tab, text size, and selected passage (NativeChrome.swift).
    @EnvironmentObject private var nav: NativeNav

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

    /// The reading text's size: this screen's own in Verbose style; Native's toolbar sets it (`NativeNav`).
    private var fontSize: CGFloat { look == .native ? nav.textSize : textSize }

    /// What Copy takes on this tab.
    private var copyVersion: Exporter.CopyVersion { view == .document ? .cleaned : .original }


    private var transcript: Transcript? { app.store.transcript(id) }

    var body: some View {
        LookSwitch.mark("transcript")
        // One sheet for the screen: the tools row can exist twice (scrolled and pinned). Native runs actions from the
        // window's toolbar, which shows the same sheet (NativeChrome.swift).
        return screenBody.sheet(item: $runningAction) { a in
            if let t = transcript {
                TranscriptActionSheet(action: a, transcript: t).environmentObject(app)
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
            Group {
            if look == .native {
                nativeScreen(t)
            } else {
            GeometryReader { g in
            // Decided from the geometry in the same pass, so the screen lays out once (no open-then-close).
            let narrow = g.size.width < 900
            let notesOpen = notesPref ?? !narrow
            let sideInline = notesOpen && !narrow
            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(t).staggerIn(0)
                                modeBar(t, notesOpen: notesOpen, narrow: narrow, withToggle: false)
                                    .opacity(barPinned ? 0 : 1).allowsHitTesting(!barPinned)
                                    .background(GeometryReader { b in Color.clear.preference(key: BarOffsetKey.self, value: b.frame(in: .named("tscroll")).minY) })
                                    .staggerIn(1).padding(.bottom, 12)
                                // The side column is closed: the Summary card sits above the text instead.
                                if !notesOpen, view != .review {
                                    TranscriptSummaryCard(transcript: t).padding(.bottom, 14)
                                }
                                content(t)
                            }
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(.leading, 40).padding(.trailing, sideInline ? 22 : 40)
                            .padding(.top, 28).padding(.bottom, t.audioFileName != nil && view != .document ? 124 : 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .coordinateSpace(name: "tscroll")
                        .onPreferenceChange(BarOffsetKey.self) { y in
                            let pinned = y < 6
                            if pinned != barPinned { barPinned = pinned }
                        }
                        .onPreferenceChange(ToggleOffsetKey.self) { y in
                            let pinned = y < contentTop + 4
                            if pinned != togglePinned { togglePinned = pinned }
                        }
                        .overlay(alignment: .top) {
                            // The mode bar and tools stay reachable while reading: pinned under the top edge.
                            if barPinned {
                                VStack(spacing: 0) {
                                    modeBar(t, notesOpen: notesOpen, narrow: narrow, withToggle: true)
                                        .frame(maxWidth: 760, alignment: .leading)
                                        .padding(.leading, 40).padding(.trailing, sideInline ? 22 : 40).padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Ink.paper)
                                    Rectangle().fill(Ink.hairline).frame(height: 1)
                                }
                                .transition(.opacity)
                            } else if togglePinned {
                                // Only the header has scrolled up: the toggle stays put, inside the content area.
                                HStack(spacing: 0) { Spacer(minLength: 0); modeToggle }
                                    .frame(maxWidth: 760, alignment: .trailing)
                                    .padding(.leading, 40).padding(.trailing, sideInline ? 22 : 40).padding(.top, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    if t.audioFileName != nil, t.status == .ready, view != .document {
                        PlayerDock(transcript: t, clock: app.player.clock)
                            .padding(.leading, 40).padding(.trailing, sideInline ? 22 : 40).padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .staggerIn(3)
                    }
                }
                .frame(maxWidth: .infinity)
                if sideInline {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.nav) { notesPref = false } })
                        .frame(width: 300).padding(.trailing, 32).padding(.top, 28)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .identity))
                }
            }
            .overlay(alignment: .trailing) {
                // Narrow window: Notes becomes a drawer over the text instead of squeezing it.
                if notesOpen && narrow {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.nav) { notesPref = false } }, drawer: true)
                        .frame(width: 320)
                        .shadow(color: .black.opacity(0.12), radius: 24, x: -6)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .identity))
                }
            }
            .background {
                // Shortcuts live here once, not on the mode bar (which can exist twice while pinned).
                ZStack {
                    Button("") { ExportMenu.copy(t, copyVersion, app: app) }.keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("") { CopyForAI.copy(t, app: app) }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
                    Button("") { textSize = min(22, textSize + 1) }.keyboardShortcut("=", modifiers: .command)
                    Button("") { textSize = max(13, textSize - 1) }.keyboardShortcut("-", modifiers: .command)
                }
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onChange(of: g.frame(in: .global).minY, initial: true) { _, y in contentTop = y }
            }
            }
            }
            .onAppear {
                if UITest.enabled { Log.note("UITEST nav appear ms=\(Int(Date().timeIntervalSince(app.navStartedAt) * 1000)) segments=\(t.segments.count)") }
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
            .onDisappear { if app.player.screenLeft(id) { app.player.stop() } }
            .skipsSponsors(t, player: app.player)
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

    // MARK: Native

    /// The transcript in Premium Native: a reading column on the warm window with times in a fixed column, and a
    /// floating player bar. The tabs and tools live in the window's toolbar and the side column in its inspector
    /// (NativeChrome.swift), so opening a transcript adds nothing to the window.
    private func nativeScreen(_ t: Transcript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(t)
                    if view == .original, t.status == .ready { versionControl(t).padding(.bottom, 12) }
                    content(t)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 8)
                .padding(.bottom, t.audioFileName != nil && view != .document ? 110 : 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onReceive(app.player.clock.$time) { now in
                // Follow playback (while Follow is on), only when the playing passage changes, not on every tick.
                if nav.follow, app.player.isPlaying, let s = t.segments.first(where: { now >= $0.start && now < $0.end }), s.id != followed {
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
        .overlay(alignment: .bottom) {
            if t.audioFileName != nil, t.status == .ready, view != .document {
                NativePlayerBar(transcript: t, clock: app.player.clock, nav: nav)
                    .padding(.horizontal, 40).padding(.bottom, 22)
            }
        }
        .background {
            ZStack {
                Button("") { ExportMenu.copy(t, copyVersion, app: app) }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("") { CopyForAI.copy(t, app: app) }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
                Button("") { nav.textSize = min(22, nav.textSize + 1) }.keyboardShortcut("=", modifiers: .command)
                Button("") { nav.textSize = max(13, nav.textSize - 1) }.keyboardShortcut("-", modifiers: .command)
            }
            .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
        // The toolbar's tabs and text size and the inspector's note field share this screen's state.
        // Written only when they differ, so opening a transcript doesn't re-render the toolbar for nothing.
        .onAppear { if nav.mode != view { nav.mode = view }; if nav.selectedSegment != selectedSegment { nav.selectedSegment = selectedSegment } }
        .onChange(of: nav.mode) { _, m in if view != m { withAnimation(Motion.snap) { view = m } } }
        .onChange(of: view) { _, m in if nav.mode != m { nav.mode = m } }
        .onChange(of: selectedSegment) { _, v in if nav.selectedSegment != v { nav.selectedSegment = v } }
    }

    /// "Podcast · Thursday, October 22 · 1:04:12 · 2 speakers · English".
    private func nativeMeta(_ t: Transcript) -> String {
        var parts = [t.kind?.label ?? (t.sourceLabel.isEmpty ? "Recording" : t.sourceLabel)]
        parts.append(Formats.pattern("EEEE, MMMM d").string(from: t.createdAt))
        parts.append(NativeLibraryView.length(t.duration))
        if t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
        if let lang = t.language { parts.append(LanguageDetection.name(lang)) }
        return parts.joined(separator: " · ")
    }

    private func bookmark(_ t: Transcript) {
        let at = app.player.time
        let seg = t.segments.first(where: { at >= $0.start && at < $0.end })
        app.addNote(transcript: t.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
    }

    // MARK: Header and mode bar

    /// "◇ Meeting · Thu Oct 22 · 15:39": the kind (or the source), the day, and the length.
    private func eyebrow(_ t: Transcript) -> String {
        var parts = [t.kind?.label ?? (t.sourceLabel.isEmpty ? "Recording" : t.sourceLabel)]
        parts.append(Formats.pattern("EEE MMM d").string(from: t.createdAt))
        parts.append(WebFormat.clock(t.duration))
        if t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
        return parts.joined(separator: " · ")
    }

    private func projectName(_ t: Transcript) -> String? {
        t.projectId.flatMap { id in app.store.projects.first { $0.id == id }?.name }
    }

    /// The recording's name on two lines, the second in italic: after the project's name when it starts with it
    /// ("Lapp Wagons / *catalog call*"), otherwise split near the middle at a word. One word stays on one line.
    static func twoLine(_ title: String, project: String?) -> (String, String?) {
        let split = WebText.split(title, after: project)
        if split.1 != nil { return split }
        let words = title.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return (title, nil) }
        var best = 1, bestDiff = Int.max
        for k in 1..<words.count {
            let a = words[..<k].joined(separator: " ").count, b = words[k...].joined(separator: " ").count
            // Ties go to a longer first line.
            let diff = abs(a - b) * 2 + (a < b ? 1 : 0)
            if diff < bestDiff { bestDiff = diff; best = k }
        }
        return (words[..<best].joined(separator: " "), words[best...].joined(separator: " "))
    }

    private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if look == .native {
                // Native: a big bold title (SF Pro, never the serif) and one secondary line; the tabs live in the toolbar.
                title(t)
                Text(nativeMeta(t)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).padding(.top, 6)
            } else {
            // Back, named for where you came from (App/NavTrail.swift); Native's is in the toolbar.
            TranscriptBackPill().padding(.bottom, 16)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: eyebrow(t))
                    title(t)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Top-aligned with the eyebrow, inside the content area (the mockup's .tr-head). When it reaches the
                // top edge, a floating copy takes its place (togglePinned), so it never sits under the toolbar.
                modeToggle
                    .background(GeometryReader { b in Color.clear.preference(key: ToggleOffsetKey.self, value: b.frame(in: .global).minY) })
                    .opacity(togglePinned ? 0 : 1).allowsHitTesting(!togglePinned)
            }
            }
            if t.titleIsAuto && t.titleByModel { AITitleNote().padding(.top, 8) }
            if t.status == .ready {
                KindAndTags(transcript: t, compact: true,
                            onPick: { k in app.store.update(t.id) { $0.kind = k; $0.kindIsAuto = false } },
                            onTags: { tags in app.store.update(t.id) { $0.tags = tags } })
                    .padding(.top, 12)
            }
            if t.status == .ready, !t.visibleSpeakerSuggestions.isEmpty {
                SpeakerSuggestionRows(transcript: t,
                                      onUse: { app.useSpeakerSuggestion(transcript: t.id, $0) },
                                      onDismiss: { app.dismissSpeakerSuggestion(transcript: t.id, $0) })
                    .padding(.top, 12)
            }
            if t.pendingAppend != nil {
                HStack(spacing: 8) {
                    if t.processingDevice != nil { ProgressView().controlSize(.small) } else { ArtIcon(art: .capture, size: 16).foregroundStyle(Ink.accentText) }
                    LiveStage(t) { t in Text(t.stageText).font(.system(size: 13.5)).foregroundStyle(Ink.dim) }
                    if t.processingDevice == nil {
                        Button("Retry") { app.retry(t) }.buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                        Button("Discard") { app.discardPendingAppend(t.id) }.buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                    } else {
                        Button("Cancel") { app.cancel(t.id) }.buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Ink.persimmonTint, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .padding(.top, 10)
            }
            if let info = t.linkInfo { LinkCard(info: info, transcript: t).padding(.top, 12) }
            if view == .original, !t.corrections.isEmpty { correctionChips(t).padding(.top, 16) }
        }
        .padding(.bottom, 14)
        .task(id: t.id) { SpeakerNameSuggester.openedIfNeeded(t.id, store: app.store) }
    }

    /// The title: content, not a page label, so it stays large (serif 44). Click it to rename in place; Return or
    /// clicking away saves, Escape cancels.
    @ViewBuilder private func title(_ t: Transcript) -> some View {
        if editingTitle {
            TextField("Title", text: $titleDraft, axis: .vertical)
                .textFieldStyle(.plain).font(look == .native ? .system(size: 30, weight: .bold) : Ink.serif(44))
                .tracking(look == .native ? 0 : -1).foregroundStyle(Ink.ink).lineLimit(1...3)
                .focused($titleFocused)
                .onSubmit { commitTitle(t) }
                .onChange(of: titleFocused) { _, f in if !f { commitTitle(t) } }
                .onExitCommand { editingTitle = false }
        } else if look == .native {
            Text(t.title).font(.system(size: 30, weight: .bold)).tracking(-0.4).foregroundStyle(.primary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { beginRename(t) }
                .help("Click to rename")
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: "Rename") { beginRename(t) }
        } else {
            let lines = Self.twoLine(t.title, project: projectName(t))
            VStack(alignment: .leading, spacing: 0) {
                Text(lines.0).font(Ink.serif(44))
                if let second = lines.1 { Text(second).font(Ink.serif(44).italic()) }
            }
            .tracking(-1).foregroundStyle(Ink.ink)
            .lineLimit(2).minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { beginRename(t) }
            .help("Click to rename")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(t.title)
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

    /// Original / Cleaned / Review: a soft track with the chosen one in ink.
    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach(Self.visibleModes, id: \.self) { m in
                Text(m.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background { if view == m { Capsule().fill(Ink.ink).matchedGeometryEffect(id: "mode", in: segNS) } }
                    .foregroundStyle(view == m ? Ink.paper : Ink.ink)
                    .contentShape(Capsule())
                    .tapArea { withAnimation(Motion.snap) { view = m } }
                    .accessibilityLabel(m.title).accessibilityAddTraits(view == m ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4).background(Ink.chip, in: Capsule()).fixedSize()
    }

    /// The latest fixes (yours and the Dictionary's) as dark pills with Undo; the rest are in Review.
    private func correctionChips(_ t: Transcript) -> some View {
        let recent = Array(t.corrections.suffix(3).reversed())
        let more = t.corrections.count - recent.count
        return FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(recent) { c in
                UndoChip(text: "“\(c.from)” → \(c.to)") { undo(t, c) }
            }
            if more > 0 {
                Text(more == 1 ? "1 more in Review" : "\(more) more in Review")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.dim)
                    .frame(height: 34).contentShape(Rectangle())
                    .tapArea { withAnimation(Motion.snap) { view = .review } }
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    private func modeBar(_ t: Transcript, notesOpen: Bool, narrow: Bool, withToggle: Bool) -> some View {
        HStack(spacing: 12) {
            if withToggle {
                modeToggle
                Divider().frame(height: 18)
            }
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
                Button { selecting.toggle() } label: { ToolLabel(title: "Select text", art: .iconSelect, compact: false, on: selecting) }
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
            Button { app.continueRecording(t.id) } label: { ToolLabel(title: "Continue", art: .capture, compact: compact) }
                .buttonStyle(.plain)
                .disabled(t.status != .ready || t.audioFileName == nil || t.pendingAppend != nil || app.recorder.isRecording)
                .help("Record more and add it to the end of this transcript")
            Menu {
                ActionsMenuItems { runningAction = $0 }
                Divider()
                Button(SummaryAction.title(t)) { summarize(t) }
                    .disabled(t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
            } label: { ToolLabel(title: "Actions", art: .refine, compact: compact) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(t.status != .ready)
                .help("Run a saved action on this transcript: decisions and next steps, a brief, an email")
            Button { withAnimation(Motion.nav) { notesPref = !notesOpen } } label: { ToolLabel(title: "Notes", art: .iconNotes, compact: compact, on: notesOpen) }
                .buttonStyle(.plain).help(notesOpen ? "Hide the side column (summary, moments, details)" : "Show the side column (summary, moments, details)")
            Menu {
                Button("Larger text") { textSize = min(22, textSize + 1) }
                Button("Smaller text") { textSize = max(13, textSize - 1) }
                Button("Default size") { textSize = 16 }
            } label: { ToolLabel(title: "Text", art: .iconTextSize, compact: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Text size (⌘+ and ⌘−)")
        }
        .fixedSize()
    }

    // MARK: Content per mode

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing { processing(t) }
        else if t.status == .failed { failed(t) }
        else {
            // The Summary lives in the side column (TranscriptSummaryCard), or above the text when it's closed.
            switch view {
            case .original: readingSheet(original(t))
            case .document: DocumentView(transcript: t)
            case .review: review(t)
            }
        }
    }

    /// The reading lines, then the quiet filler toggle and, with Main speaker only on, the Background voices card.
    private func original(_ t: Transcript) -> some View {
        let hide = hideFillerSetting && !showFiller
        let background = mainSpeakerOnly ? t.backgroundSegments : []
        // Worked out once per transcript change, not on every render (Store+Memo.swift).
        let shown = app.store.displaySegments(t.id, hideFiller: hide, mainOnly: mainSpeakerOnly)
        let folds = app.store.sponsorFolds(t.id, hideFiller: hide, mainOnly: mainSpeakerOnly, engine: showEngine)
        let fillers = app.store.fillerCount(t.id)
        // Engine words: the same passages as the engine wrote them, read-only (corrections apply to the corrected lines).
        let segs = showEngine ? t.engineLines(for: shown) : shown
        return VStack(alignment: .leading, spacing: 12) {
            // Fix all, after a correction (Views/TrustViews.swift).
            FixAllBanner(transcriptID: t.id)
            if showEngine {
                Text(t.hasEngineWords ? "Engine words: exactly what the engine heard, before your corrections and Dictionary fixes."
                                      : "This transcript has no separate engine words, so these are the lines as they are.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute).padding(.leading, 84)
            }
            if selecting {
                SelectableLines(clock: app.player.clock, isPlaying: app.player.isPlaying, transcript: t, segments: segs, textSize: fontSize)
            } else {
                lines(t, segments: segs, folds: folds, editable: !showEngine)
            }
            if hideFillerSetting, fillers > 0 {
                FillerToggle(count: fillers, shown: $showFiller).padding(.leading, 84)
            }
            if !background.isEmpty {
                BackgroundVoicesCard(segments: background, compact: true,
                                     onPlay: { s in app.player.seek(to: s.start) },
                                     onMoveBack: { s in if let main = t.mainSpeaker { app.assign(transcript: t.id, segment: s.id, to: main) } })
                    .padding(.top, 6)
            }
        }
    }

    /// The reading sheet: card white, a 1.5 pt ink outline, the panel radius.
    @ViewBuilder private func readingSheet<V: View>(_ inner: V) -> some View {
        if look == .native {
            // Native: plain text on the window background.
            inner.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            inner
                .padding(.horizontal, 22).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                .inkEdge(outline: true, radius: Radius.record)
        }
    }

    private func lines(_ t: Transcript, segments: [Segment], folds: [SponsorFold.Place?], editable: Bool) -> some View {
        TranscriptLines(clock: app.player.clock, isPlaying: app.player.isPlaying, transcript: t, segments: segments, folds: folds, editable: editable, textSize: fontSize, selected: $selectedSegment)
    }

    private func review(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if t.corrections.isEmpty {
                placeholder("Nothing changed yet", "Corrections you make, and Dictionary fixes, show here side by side with the original so you can accept or undo them.")
            } else {
                VStack(spacing: 2) {
                    ForEach(t.corrections) { c in
                        HStack(alignment: .top, spacing: 12) {
                            ArtIcon(art: c.byDictionary ? .iconDictionary : .iconFeedback, size: 15).foregroundStyle(Ink.ink).frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) { Text(c.from).strikethrough().foregroundStyle(Ink.mute); Image(systemName: "arrow.right").font(.system(size: 10)); Text(c.to).fontWeight(.semibold) }
                                    .font(.system(size: 14))
                                if let seg = t.segments.first(where: { $0.id == c.segmentId }) {
                                    Text(seg.text).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2)
                                    Text(seg.start.timecode).font(Ink.mono(12)).foregroundStyle(Ink.dim).underline()
                                        .tapArea { app.player.seek(to: seg.start) }
                                        .help("Play from here").accessibilityAddTraits(.isButton)
                                }
                            }
                            Spacer()
                            StatusText(text: c.byDictionary ? "Dictionary" : "Your fix", tone: .dim)
                            Button("Undo") { undo(t, c) }.buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .flatRow(highlighted: false)
                    }
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .inkEdge(outline: true, radius: Radius.record)
    }


    private func processing(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SignalRings().frame(width: 40, height: 40).padding(6)
                VStack(alignment: .leading, spacing: 2) {
                    LiveStage(t) { t in Text(t.stageText).font(.system(size: 15, weight: .semibold)) }
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
                HStack(spacing: 8) {
                    Button("Retry") { app.retry(t) }.buttonStyle(PillButtonStyle(kind: .dark, size: .mini))
                    AllowDownloadButton(transcript: t)
                }
            }
        }
    }
}

/// "“Lit it's” → Lititz  [Undo]": a fix as a dark pill with a card-white Undo inside (accent text).
private struct UndoChip: View {
    var text: String
    var action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(text).lineLimit(1).truncationMode(.middle).foregroundStyle(Ink.paper)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Undo").foregroundStyle(Ink.accentText)
                .padding(.horizontal, 11).frame(height: 26)
                .background(Ink.card, in: Capsule())
                .contentShape(Capsule())
                .tapArea(action)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Undo \(text)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .padding(.leading, 14).padding(.trailing, 4)
        .frame(height: 34)
        .background(Ink.ink, in: Capsule())
    }
}

extension Notification.Name { static let verbatimFocusNote = Notification.Name("verbatimFocusNote") }

struct BarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// The header toggle's top, in window coordinates.
struct ToggleOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

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
