import SwiftUI
import AppKit
import AVFoundation

// Ask your library on the Mac (mockup "Library features", section 2a and 2c; redesign MAC-35), on the refined kit
// (DESIGN.md §13): one panel, "Search or ask", with a Search and Ask switch, scope chips, and the result. ⌘K opens it,
// and so does typing in the toolbar's search field, which keeps the keyboard while the panel shows its words. Search
// lists recordings and passages in the panel (the Library never filters under you while you type); ↓ and ↑ move through
// them and Return opens one. Ask answers with numbered citation chips, Copy, and Save as recipe. Make › Ask shows the
// same panel inline with Ask chosen, then recent questions, and Recipes (saved questions, run now or weekly, and their
// digests). A citation's play disc is sage, the playback color.

enum AskMode: String { case search, ask }
enum AskPane: String { case questions, recipes }

/// The panel's and the Ask screen's state, kept across visits.
@MainActor
final class AskNav: ObservableObject {
    static let shared = AskNav()
    @Published var panelOpen = false
    @Published var mode: AskMode = .ask
    @Published var query = ""
    @Published var scope = AskScope.all
    @Published var pane: AskPane = .questions
    @Published var selectedRecipe: UUID? = nil
    /// The recipe being made or edited (New recipe, Save as recipe, Schedule).
    @Published var editing: RecipeDraft? = nil
    /// The panel opened from typing in the toolbar's search field (MAC-35): that field keeps the keyboard, the panel's
    /// field shows the same words, and emptying the toolbar's field closes the panel.
    @Published private(set) var fromToolbar = false
    /// Search's chosen result, an index into `order`: the first until ↓ or ↑ moves it (`PanelKeys`).
    @Published var cursor = 0
    /// Search's results in the order shown, set by the panel as it draws. Not published.
    private(set) var order: [SearchPanelItem] = []
    /// The panel's own field has the keyboard (the key monitor reads it, Views/SearchPanelKeys.swift).
    var panelFieldFocused = false

    /// Opens the panel (⌘K, Edit › Find…, typing in the toolbar's search field), optionally on a question that it asks
    /// at once.
    func open(mode: AskMode? = nil, query: String? = nil, askNow: Bool = false, fromToolbar: Bool = false) {
        if let mode { self.mode = mode }
        if let query { self.query = query }
        if self.fromToolbar != fromToolbar { self.fromToolbar = fromToolbar }
        if cursor != 0 { cursor = 0 }
        panelOpen = true
        if askNow, self.mode == .ask, !self.query.trimmingCharacters(in: .whitespaces).isEmpty {
            AskCenter.shared.ask(self.query, scope: scope)
        }
    }

    func close() {
        panelOpen = false
        if fromToolbar { fromToolbar = false }
        AskPlayer.shared.stop()
    }

    func ask() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        AskCenter.shared.ask(q, scope: scope)
    }

    /// Save as recipe: the question and scope, ready to name a schedule.
    func saveAsRecipe(_ r: AskResult) {
        editing = RecipeDraft(question: r.question, scope: r.scope)
    }

    // MARK: The toolbar's field and Search (MAC-35)

    /// The toolbar's search field changed: its words go to the panel, which opens on Search at the first letter, and
    /// emptying the field closes a panel it opened. A write that only mirrors the panel's own words (the same text)
    /// changes nothing, and the field clearing as the panel closes leaves the question as it was.
    func toolbarChanged(_ v: String) {
        guard v != query else { return }
        if v.isEmpty {
            guard panelOpen, fromToolbar else { return }
            query = ""
            close()
            return
        }
        query = v
        if !panelOpen { open(mode: .search, fromToolbar: true) } else if !fromToolbar { fromToolbar = true }
    }

    /// Search's results as the panel draws them; new results put the cursor back on the first.
    func setOrder(_ new: [SearchPanelItem]) {
        guard new != order else { return }
        order = new
        if cursor != 0 { cursor = 0 }
    }

    /// ↓ or ↑ in Search: the next or previous result, staying on the first and last.
    func move(down: Bool) {
        let n = PanelKeys.step(from: cursor, count: order.count, down: down)
        if n != cursor { cursor = n }
    }

    /// Return in the panel's field or the toolbar's: Ask asks; Search opens the chosen result, or, when nothing matches,
    /// asks the words as a question instead. Opening is a keyboard navigation, so the transcript shows at once.
    func submit(_ app: AppState, fromToolbar: Bool = false) {
        if fromToolbar && !panelOpen { return }
        switch mode {
        case .ask:
            ask()
        case .search:
            if let i = PanelKeys.chosen(cursor, count: order.count) {
                let item = order[i]
                app.fromKeyboard { openResult(item, app: app) }
            } else if SearchPanelResults.searches(query) {
                mode = .ask
                ask()
            }
        }
    }

    /// Opens a Search result: a recording's transcript, or a passage's at its line.
    func openResult(_ item: SearchPanelItem, app: AppState) {
        close()
        if let s = item.segment { app.focusSegment = s }
        app.go(.transcript(item.transcript))
    }

    /// Show all in the Library: the Library filtered by the words, as search filtered it before, now only when you ask
    /// for it (its search chip clears it).
    func showInLibrary(_ app: AppState) {
        let q = query.trimmingCharacters(in: .whitespaces)
        close()
        app.search = q
        app.projectFilter = nil
        if app.screen != .library { app.go(.library) }
    }
}


/// Plays a citation from its time in place, without leaving the panel or the screen (the transcript's own player is
/// left alone). Opens the audio off the main thread.
@MainActor
final class AskPlayer: ObservableObject {
    static let shared = AskPlayer()
    @Published private(set) var playing: String? = nil
    private var player: AVAudioPlayer? = nil
    private var loadID = 0

    /// Plays or pauses a source. False when its audio isn't on this Mac (a link, or not downloaded yet).
    @discardableResult
    func toggle(_ s: AskSource, store: Store) -> Bool {
        if playing == s.id { stop(); return true }
        guard let t = store.transcript(s.transcriptId), let url = store.audioURL(for: t), FileManager.default.fileExists(atPath: url.path) else { return false }
        stop()
        loadID += 1
        let id = loadID
        playing = s.id
        let start = s.start
        DispatchQueue.global(qos: .userInitiated).async {
            let p = try? AVAudioPlayer(contentsOf: url)
            DispatchQueue.main.async {
                guard id == self.loadID, let p else { if id == self.loadID { self.playing = nil }; return }
                p.currentTime = max(0, min(start, p.duration - 0.1))
                p.play()
                self.player = p
            }
        }
        return true
    }

    func stop() {
        loadID += 1
        player?.stop()
        player = nil
        playing = nil
    }
}

/// Opens a source's transcript at its line and plays from there.
@MainActor
enum AskOpen {
    static func transcript(_ s: AskSource, app: AppState) {
        AskPlayer.shared.stop()
        AskNav.shared.close()
        app.focusSegment = s.segmentId
        if let t = app.store.transcript(s.transcriptId) { WindowNav.shared.play(t, app: app) } else { app.go(.transcript(s.transcriptId)) }
    }
}

// MARK: - The panel

/// The panel over the window: a scrim (click it, or press Escape, to close) and the panel near the top. When it closes,
/// the toolbar's search field empties too.
struct AskPanelLayer: View {
    @Environment(AppState.self) var app
    @ObservedObject private var nav = AskNav.shared

    var body: some View {
        ZStack(alignment: .top) {
            if nav.panelOpen {
                Refined.onFill.opacity(0.24)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { nav.close() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                // It nearly always opens from the keyboard (⌘K, ⌘F, or typing in the toolbar's field), so it's there at
                // once: a 0.1 s fade at most and no drop (DESIGN.md §7, keyboard actions don't animate;
                // `KeyMotion.recallFade`). The scrim fades with it.
                AskPanel()
                    .frame(width: 760)
                    .padding(.top, 64)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: KeyMotion.recallFade), value: nav.panelOpen)
        .onChange(of: nav.panelOpen) { _, open in if !open { app.toolbarQuery = "" } }
    }
}

/// Search or ask, one component (MAC-35): over the window (⌘K, or typing in the toolbar's search field), or `inline` on
/// Make › Ask. The field, the Search and Ask switch, the scope chips, then the result: Search's recordings and passages,
/// or Ask's answer.
struct AskPanel: View {
    /// On the Ask page: no scrim, no recipes strip, and the page scrolls it.
    var inline = false
    @Environment(AppState.self) var app
    @ObservedObject private var nav = AskNav.shared
    @ObservedObject private var center = AskCenter.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            PaperDivider(leading: 0)
            if inline {
                panelContent
            } else {
                // As tall as the result, up to 460 pt; past that it scrolls, and keeps the chosen result in view.
                ScrollViewReader { proxy in
                    ViewThatFits(in: .vertical) {
                        panelContent
                        ScrollView { panelContent }
                    }
                    .frame(maxHeight: 460)
                    .onChange(of: nav.cursor) { _, c in if nav.order.indices.contains(c) { proxy.scrollTo(nav.order[c]) } }
                }
            }
            if nav.mode == .ask && !inline { recipesStrip }
        }
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.record))
        // Over the window, the panel's field takes the keyboard, unless you're typing in the toolbar's field.
        .onAppear { if !inline && !nav.fromToolbar { focused = true } }
        .onExitCommand { if !inline { nav.close() } }
        .onChange(of: focused) { _, f in if !inline { nav.panelFieldFocused = f } }
        // Opened from the toolbar, the two fields show the same words.
        .onChange(of: nav.query) { _, q in if !inline && nav.fromToolbar { app.toolbarQuery = q } }
        .onChange(of: nav.mode) { _, _ in if !inline && !nav.fromToolbar { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search or ask")
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            AskScopeChips(scope: $nav.scope)
            if nav.mode == .ask {
                AskResultBody(context: inline ? .screen : .panel)
            } else {
                searchBody
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            IconGlyph(art: nav.mode == .ask ? .iconAsk : .search, size: 22, color: Refined.accentText)
            TextField(nav.mode == .ask ? "Ask a question about your recordings" : "Find a recording or the line you need", text: $nav.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .foregroundStyle(Refined.ink)
                .focused($focused)
                // Return: Ask asks; Search opens the chosen result at once (a keyboard navigation doesn't slide,
                // DESIGN.md §7).
                .onSubmit { app.fromKeyboard { submit() } }
                .uiTarget(inline ? "ask-inline-field" : "ask-field")
            modeSwitch
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    private func submit() { nav.submit(app) }

    /// Search and Ask, the kit's segmented control.
    private var modeSwitch: some View {
        RefinedSegmented(label: "Search or ask", options: [(AskMode.search, "Search"), (AskMode.ask, "Ask")], selection: $nav.mode)
            .fixedSize()
            .background {
                // The self-test's handles on each half.
                HStack(spacing: 0) {
                    Color.clear.uiTarget(inline ? "ask-inline-mode-search" : "ask-mode-search")
                    Color.clear.uiTarget(inline ? "ask-inline-mode-ask" : "ask-mode-ask")
                }
                .allowsHitTesting(false)
            }
    }

    /// The scope's recordings, newest first, for Search.
    private var searchList: [Transcript] {
        let list = nav.scope.isAll ? app.store.live : app.store.live.filter { nav.scope.includes($0) }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    /// Search (MAC-35): recordings whose title matches, then the matching lines, one list the arrow keys walk
    /// (`SearchPanelResults`); the chosen one, where Return goes, takes the selection's tint and the focus bar. Nothing
    /// here filters the Library; Show all in the Library does, when you ask.
    @ViewBuilder private var searchBody: some View {
        let q = nav.query.trimmingCharacters(in: .whitespaces)
        let results = SearchPanelResults.find(q, in: SearchPanelResults.searches(q) ? searchList : [])
        let items = results.items
        Group {
            if !SearchPanelResults.searches(q) {
                Text("Type at least two letters to find recordings and the lines that match.")
                    .refinedFont(.body).foregroundStyle(Refined.dim)
            } else if results.isEmpty {
                Text("Nothing matches \u{201C}\(q)\u{201D}. Press Return to ask about it in your own words.")
                    .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if !results.recordings.isEmpty {
                        groupLabel("Recordings")
                        ForEach(results.recordings, id: \.id) { t in
                            let item = SearchPanelItem.recording(t.id)
                            SearchPanelRow(title: t.title, detail: AttributedString(Self.meta(t)), quiet: true,
                                           chosen: items.firstIndex(of: item) == nav.cursor) { open(item) }
                                .id(item)
                        }
                    }
                    if !results.passages.isEmpty {
                        groupLabel("Passages").padding(.top, results.recordings.isEmpty ? 0 : 8)
                        ForEach(results.passages, id: \.transcript.id) { p in
                            ForEach(p.lines) { s in
                                let item = SearchPanelItem.passage(transcript: p.transcript.id, segment: s.id)
                                SearchPanelRow(title: "\(p.transcript.title) \u{00B7} \(AskFormat.time(s.start))",
                                               detail: ReadingHighlight.marked(AttributedString(s.text), query: q), quiet: false,
                                               chosen: items.firstIndex(of: item) == nav.cursor) { open(item) }
                                    .id(item)
                            }
                        }
                    }
                    RefinedLink(title: "Show all in the Library") { nav.showInLibrary(app) }
                        .uiTarget(inline ? "ask-inline-show-library" : "ask-show-library")
                }
            }
        }
        .onChange(of: items, initial: true) { _, new in nav.setOrder(new) }
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// A click on a result opens it as Return does, but slides in, as a click does.
    private func open(_ item: SearchPanelItem) { nav.openResult(item, app: app) }

    /// A recording's line in Search: its kind, length, and day ("Voice note · 6:52 · Nov 3").
    static func meta(_ t: Transcript) -> String {
        [RecordingKind.refinedName(t.refinedKind), HomeRecentStyle.length(t.duration), t.createdAt.formatted(.dateTime.month(.abbreviated).day())]
            .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// Your recipes, one click to run (the answer opens in Ask › Recipes).
    @ViewBuilder private var recipesStrip: some View {
        let recipes = app.store.recipes
        if !recipes.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                Text("Recipes").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                RefinedChipRow(label: "Recipes") {
                    ForEach(recipes) { r in
                        RefinedChip(title: r.question, selected: false) {
                            AskRecipeCenter.shared.run(r)
                            AskNav.shared.pane = .recipes
                            AskNav.shared.selectedRecipe = r.id
                            nav.close()
                            app.go(.ask)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Refined.paper)
            .overlay(alignment: .top) { PaperDivider(leading: 0) }
        }
    }
}

/// One Search result in the panel (MAC-35): a recording's title and what it is, or a passage's recording and time over
/// its line with the words in butter (the found color). The chosen one, where Return goes, takes the selection's tint
/// with the leading focus bar (MAC-25), and the pointer's row the stripe. A Button, so Tab with Full Keyboard Access and
/// VoiceOver reach it (MAC-23).
struct SearchPanelRow: View {
    var title: String
    var detail: AttributedString
    /// A recording's line is quiet (`mute`, meta); a passage's words are the reading ink.
    var quiet: Bool
    var chosen: Bool
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                Text(detail).refinedFont(quiet ? .meta : .body).foregroundStyle(quiet ? Refined.mute : Refined.ink).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(chosen ? Refined.persimmonTint : hover ? Refined.stripe : Color.clear))
        .overlay(alignment: .leading) { if chosen { FocusBar() } }
        .onHover { hover = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(quiet ? "Opens the transcript" : "Opens the transcript at this line")
    }
}

// MARK: - Scope chips

/// All, This week, Thoughts, Meetings, and each project.
struct AskScopeChips: View {
    @Binding var scope: AskScope
    @Environment(AppState.self) var app

    var body: some View {
        RefinedChipRow(label: "Where to look") {
            chip("All", scope.isAll, id: "all") { scope.tapAll() }
            chip("This week", scope.range == .thisWeek, id: "week") { scope.tapWeek() }
            chip("Thoughts", scope.source == .thoughts, id: "thoughts") { scope.tap(.thoughts) }
            chip("Meetings", scope.source == .meetings, id: "meetings") { scope.tap(.meetings) }
            ForEach(app.store.projects) { p in
                chip(p.name, scope.source == .project(p.id), id: "project") { scope.tap(.project(p.id)) }
            }
        }
    }

    private func chip(_ title: String, _ on: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        RefinedChip(title: title, selected: on, action: action)
            .uiTarget("ask-scope-\(id)")
    }
}

// MARK: - The result

/// Where a result shows: the panel, the Ask screen, or a recipe's digest.
enum AskContext { case panel, screen, digest }

/// The current question's result (the panel and Ask › Questions).
struct AskResultBody: View {
    var context: AskContext
    @ObservedObject private var center = AskCenter.shared
    @ObservedObject private var nav = AskNav.shared

    var body: some View {
        switch center.phase {
        case .idle:
            Text(nav.query.isEmpty ? "Ask in plain words, like \u{201C}What did Alex want changed on the homepage?\u{201D} Verbose finds the passages first, then answers on this Mac with Apple Intelligence."
                 : "Press Return to ask.")
                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        case .finding, .answering:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(center.phase == .finding ? "Finding passages…" : "Answering from the passages…").refinedFont(.body).foregroundStyle(Refined.dim)
            }
        case .done:
            if let r = center.result { AskResultView(result: r, context: context) }
        }
    }
}

/// A result: the answer with its citations and footer, or what was found instead and why.
struct AskResultView: View {
    var result: AskResult
    var context: AskContext
    @Environment(AppState.self) var app
    @AppStorage(RecipesSetting.key) private var showRecipes = false
    private var hasRecipes: Bool { !app.store.recipes.isEmpty }
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let a = result.answer, result.state == .answered {
                AskAnswerText(answer: a)
                GroundingNoteText(note: GroundingChecks.answerNote(a, question: result.question, duration: { app.store.transcript($0)?.duration }))
                AskCitationChips(sources: a.citations)
            } else {
                Text(result.message(scopeLabel: result.scope.label(projects: projectNames)))
                    .refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                    .uiTarget("ask-message")
                if !result.found.isEmpty { AskCitationChips(sources: result.found) }
            }
            footer
        }
    }

    private var projectNames: [UUID: String] { Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) }) }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if result.state == .answered {
                Text(result.footer(short: false)).refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            } else if result.state == .searchOnly {
                Text("Found on this \(result.device). Nothing leaves it.").refinedFont(.meta).foregroundStyle(Refined.dim)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.copyText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            } label: {
                HStack(spacing: 6) {
                    if !copied { IconGlyph(art: .iconCopy, size: 13, color: Refined.ink) }
                    Text(copied ? "\u{2713} Copied" : "Copy")
                }
            }
            .buttonStyle(RefinedActionStyle())
            .uiTarget("ask-copy")
            if context != .digest, RecipesSetting.shows(stored: showRecipes, hasRecipes: hasRecipes) {
                Button("Save as recipe") { AskNav.shared.saveAsRecipe(result) }
                    .buttonStyle(RefinedActionStyle())
                    .uiTarget("ask-save-recipe")
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { PaperDivider(leading: 0) }
    }
}

/// The answer's paragraphs, bullets, and headings, each sentence followed by its citation numbers.
struct AskAnswerText: View {
    var answer: AskAnswer
    var size: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(answer.blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h):
                    Text(h).font(Refined.serif(size + 3)).foregroundStyle(Refined.ink)
                        .padding(.top, 4).accessibilityAddTraits(.isHeader)
                case .paragraph(let s):
                    Text(attributed(s)).font(.system(size: size)).foregroundStyle(Refined.ink).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.system(size: size)).foregroundStyle(Refined.dim)
                        Text(attributed(s)).font(.system(size: size)).foregroundStyle(Refined.ink).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func attributed(_ sentences: [AskSentence]) -> AttributedString {
        var out = AttributedString()
        for (i, s) in sentences.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            out += AttributedString(s.text)
            for n in s.cites {
                out += AttributedString("\u{2009}")
                var m = AttributedString("\u{2009}\(n)\u{2009}")
                m.font = .system(size: max(12, size - 3), weight: .semibold).monospacedDigit()
                m.foregroundColor = Refined.dim
                m.backgroundColor = Refined.neutral
                out += m
            }
        }
        return out
    }
}

/// Citations as chips: the number, the sage play disc, the title, and the time. A click plays from that time here
/// (the one playing takes the sage playing wash); right-click opens the transcript at the line.
struct AskCitationChips: View {
    var sources: [AskSource]
    @Environment(AppState.self) var app
    @ObservedObject private var player = AskPlayer.shared

    var body: some View {
        AskFlow(spacing: 8) {
            ForEach(sources) { s in AskCitationChip(source: s, playing: player.playing == s.id) }
        }
    }
}

struct AskCitationChip: View {
    var source: AskSource
    var playing: Bool
    @Environment(AppState.self) var app
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(source.number)").refinedFont(.meta, weight: .semibold).monospacedDigit().foregroundStyle(Refined.dim)
                .frame(minWidth: 16)
            ZStack {
                Circle().fill(Refined.sage)
                IconGlyph(art: playing ? .iconPause : .iconPlay, size: 9, color: Refined.onFill)
            }
            .frame(width: 18, height: 18)
            Text(source.title).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
            Text(AskFormat.time(source.start)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.dim)
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .frame(height: 30)
        .background(Capsule().fill(playing ? Refined.playing : (hover ? Refined.neutral : Refined.stripe)))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .tapArea { if !AskPlayer.shared.toggle(source, store: app.store) { AskOpen.transcript(source, app: app) } }
        .contextMenu {
            Button("Open Transcript at \(AskFormat.time(source.start))") { AskOpen.transcript(source, app: app) }
            Button("Copy Passage") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.text, forType: .string) }
        }
        .help(source.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source \(source.number), \(source.title), at \(AskFormat.time(source.start))")
        .accessibilityHint(playing ? "Pauses" : "Plays the recording from this time")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open transcript") { AskOpen.transcript(source, app: app) }
        .uiTarget("ask-cite-\(source.number)")
    }
}

/// Lays chips in rows that wrap.
struct AskFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Make › Ask

struct AskView: View {
    @Environment(AppState.self) var app
    @ObservedObject private var nav = AskNav.shared
    /// Recipes are hidden until you show them, or while you have one (consolidation, `RecipesSetting`).
    @AppStorage(RecipesSetting.key) private var showRecipes = false

    var body: some View {
        NavMarks.mark("ask")
        let recipes = RecipesSetting.shows(stored: showRecipes, hasRecipes: !app.store.recipes.isEmpty)
        let pane: AskPane = recipes ? nav.pane : .questions
        // Two columns (mockup "Verbose Mac Columns"): the question and answer on the left, recent questions on the
        // right. Recipes keep their own list and digest columns.
        return MacColumns(mainMax: pane == .questions ? MacColumnsMetrics.readingMax : nil) {
            VStack(alignment: .leading, spacing: 18) {
                RefinedPageHeader(title: "Ask", count: recipes ? AskResult.plural(app.store.recipes.count, "recipe", "recipes") : nil,
                                  lede: pane == .questions ? "Ask about your recordings. Verbose finds the passages first, then answers on this Mac."
                                                           : "Questions you ask again. Run one now, or schedule it weekly.") {
                    if recipes {
                        RefinedSegmented(label: "Ask view", options: [(AskPane.questions, "Questions"), (AskPane.recipes, "Recipes")], selection: $nav.pane)
                            .fixedSize()
                            .background {
                                HStack(spacing: 0) {
                                    Color.clear.uiTarget("ask-pane-questions")
                                    Color.clear.uiTarget("ask-pane-recipes")
                                }
                                .allowsHitTesting(false)
                            }
                        Button { nav.editing = RecipeDraft(question: "", scope: nav.scope) } label: { Label("New recipe", systemImage: "plus") }
                            .buttonStyle(RefinedActionStyle(kind: .strong))
                            .uiTarget("ask-new-recipe")
                    }
                    Menu {
                        Toggle("Show Recipes", isOn: $showRecipes)
                            .disabled(!app.store.recipes.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.ink)
                            .frame(width: 30, height: 30)
                            .background(Refined.neutral, in: Circle())
                            .contentShape(Circle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Recipes: questions you save and run again, now or every week")
                    .accessibilityLabel("More")
                    .uiTarget("ask-more")
                }
                switch pane {
                case .questions: AskQuestionsPane(part: .main).macColumnsTop()
                case .recipes: AskRecipesPane()
                }
            }
        } side: {
            if pane == .questions { AskQuestionsPane(part: .side) }
        }
        .background(Refined.paper)
        // The page's panel opens with Ask chosen; its switch can still pick Search.
        .onAppear { if nav.mode != .ask { nav.mode = .ask } }
        .sheet(item: $nav.editing) { d in RecipeEditorSheet(draft: d).appState(app) }
    }
}

/// Ask › Questions: the Search or ask panel inline with Ask chosen (`.main`), and recent questions on this Mac (`.side`,
/// the page's side column).
struct AskQuestionsPane: View {
    enum Part { case main, side }
    var part: Part = .main
    @Environment(AppState.self) var app
    @ObservedObject private var nav = AskNav.shared
    @ObservedObject private var center = AskCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The same panel as ⌘K's, inline, with Ask chosen (MAC-35).
            if part == .main { AskPanel(inline: true) }
            if part == .side, center.history.isEmpty {
                MacSideCard(title: "Recent questions") {
                    Text("Questions you ask show here.").font(.system(size: 12)).foregroundStyle(Refined.dim)
                }
            }
            if part == .side, !center.history.isEmpty {
                PaperGroup("Recent questions · \(center.history.count)") {
                    ForEach(Array(center.history.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { PaperDivider(leading: 48, trailing: 14) }
                        PaperRowButton(selected: center.result?.id == r.id, action: { nav.query = r.question; nav.scope = r.scope; center.show(r) }) {
                            HStack(spacing: 12) {
                                IconSquare(art: .iconAsk, hue: .neutral)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.question).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                                    Text(r.scope.label(projects: names) + " · " + r.askedAt.formatted(date: .abbreviated, time: .shortened))
                                        .refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                RefinedStatus(text: r.state == .answered ? "Answered" : "No answer", accent: r.state == .answered)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private var names: [UUID: String] { Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) }) }
}

/// Ask › Recipes: the recipes on the left, the selected one's latest digest on the right; the three examples when
/// there are none.
struct AskRecipesPane: View {
    @Environment(AppState.self) var app
    @ObservedObject private var nav = AskNav.shared
    @ObservedObject private var center = AskRecipeCenter.shared

    var body: some View {
        let recipes = app.store.recipes
        if recipes.isEmpty {
            empty
        } else {
            let selected = recipes.first { $0.id == nav.selectedRecipe } ?? recipes.first!
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recipes) { r in card(r, selected: r.id == selected.id) }
                    HStack(spacing: 8) {
                        IconGlyph(art: .iconPrivacy, size: 14, color: Refined.mute)
                        Text(TemplateCopy.onDevice("Mac")).refinedFont(.meta).foregroundStyle(Refined.dim)
                    }
                    .padding(.top, 4)
                }
                .frame(width: 380, alignment: .topLeading)
                digest(selected)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var names: [UUID: String] { Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) }) }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            RefinedEmptyState(art: .iconAsk, title: "No recipes yet",
                              message: "A recipe is a question you ask again, with where to look. Run it any time, or every week. Start with one of these, or make your own.",
                              action: "New recipe") { nav.editing = RecipeDraft(question: "", scope: nav.scope) }
            Text("Try one").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
            AskFlow(spacing: 8) {
                ForEach(Array(RecipeSuggestions.all(projects: app.store.projects.map { ($0.id, $0.name) }).enumerated()), id: \.offset) { i, s in
                    RefinedChip(title: s.question, selected: false) {
                        let sched = s.schedule.map { RecipeSchedule(weekday: $0.weekday, hour: $0.hour, minute: $0.minute) }
                        if let r = AskRecipeCenter.shared.add(s.question, scope: s.scope, schedule: sched) { nav.selectedRecipe = r.id }
                    }
                    .uiTarget("ask-suggestion-\(i)")
                }
            }
        }
    }

    private func scheduleLine(_ r: AskRecipe) -> String {
        let when = center.schedule(r.id)?.label ?? "Run when you need it"
        return "\(when) · \(r.scope.label(projects: names))"
    }

    private func card(_ r: AskRecipe, selected: Bool) -> some View {
        let scheduled = center.schedule(r.id) != nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(r.question).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(2)
            HStack(spacing: 6) {
                IconGlyph(art: scheduled ? .iconCalendar : .iconAsk, size: 13, color: Refined.mute)
                Text(scheduleLine(r)).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            }
            HStack(spacing: 6) {
                Button(center.running.contains(r.id) ? "Running…" : "Run now") {
                    nav.selectedRecipe = r.id
                    AskRecipeCenter.shared.run(r)
                }
                .buttonStyle(RefinedActionStyle(kind: selected ? .strong : .quiet))
                .disabled(center.running.contains(r.id))
                .uiTarget("ask-run-\(r.id.uuidString.prefix(8))")
                Button(scheduled ? "Edit schedule" : "Schedule") { nav.editing = draft(r) }
                    .buttonStyle(RefinedActionStyle())
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TemplateCardSurface(selected: selected))
        .contentShape(Rectangle())
        .onTapGesture { nav.selectedRecipe = r.id }
        .contextMenu {
            Button("Edit Recipe…") { nav.editing = draft(r) }
            Button("Delete Recipe", role: .destructive) { AskRecipeCenter.shared.delete(r.id) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .uiTarget("ask-recipe-\(r.id.uuidString.prefix(8))")
    }

    private func draft(_ r: AskRecipe) -> RecipeDraft { RecipeDraft(r, schedule: center.schedule(r.id)) }

    @ViewBuilder private func digest(_ r: AskRecipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = center.latest(r.id) {
                Text(dayLine(d)).refinedFont(.meta).foregroundStyle(Refined.mute)
                Text(r.question).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                Text(r.scope.label(projects: names)).refinedFont(.meta).foregroundStyle(Refined.dim)
                AskResultView(result: d.result, context: .digest)
            } else if center.running.contains(r.id) {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Finding passages and answering…").refinedFont(.body).foregroundStyle(Refined.dim) }
            } else {
                Text("No answer yet. Choose Run now, or Schedule to run it every week.").refinedFont(.body).foregroundStyle(Refined.dim)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(TemplateCardSurface())
    }

    /// "Fri, Oct 23 · 4:00 PM · Ran on schedule".
    private func dayLine(_ d: AskDigest) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d · h:mm a"
        return f.string(from: d.ranAt) + (d.scheduled ? " · Ran on schedule" : " · Ran now")
    }
}

// MARK: - The recipe editor

struct RecipeEditorSheet: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) private var dismiss
    @State var draft: RecipeDraft
    @State private var confirmDelete = false

    var body: some View {
        RefinedSheet(title: draft.recipeId == nil ? "New recipe" : "Edit recipe") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Question").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
                TextField("What did I say about Website refresh", text: $draft.question)
                    .textFieldStyle(.roundedBorder).refinedFont(.body)
                    .uiTarget("recipe-question")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Where to look").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
                AskScopeChips(scope: $draft.scope)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Run every week on this Mac", isOn: $draft.scheduled).toggleStyle(.switch)
                    .refinedSwitchTint()
                    .uiTarget("recipe-schedule")
                if draft.scheduled {
                    HStack(spacing: 10) {
                        Picker("Day", selection: $draft.weekday) {
                            ForEach(1...7, id: \.self) { d in Text(RecipeSchedule.dayName(d)).tag(d) }
                        }
                        .labelsHidden().frame(width: 140)
                        DatePicker("Time", selection: $draft.timeOfDay, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                    Text("Verbose runs it when this Mac is awake and Verbose is open, or the next time it opens. Schedules stay on this Mac; the recipe syncs with your iPhone.")
                        .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if draft.recipeId != nil {
                Button("Delete Recipe", role: .destructive) { confirmDelete = true }
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .uiTarget("recipe-save")
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Recipe", role: .destructive) { if let id = draft.recipeId { AskRecipeCenter.shared.delete(id) }; dismiss() }
        } message: { Text("Its answers on this Mac go too.") }
    }

    private func save() {
        let q = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let schedule = draft.scheduled ? RecipeSchedule(weekday: draft.weekday, hour: draft.hour, minute: draft.minute) : nil
        if let id = draft.recipeId, var r = app.store.recipes.first(where: { $0.id == id }) {
            r.question = q; r.scope = draft.scope
            AskRecipeCenter.shared.update(r)
            // Only a changed time resets when it counts from (an unchanged one keeps its catch-up).
            let old = AskRecipeCenter.shared.schedule(id)
            let same = old.map { o in schedule.map { o.weekday == $0.weekday && o.hour == $0.hour && o.minute == $0.minute } ?? false } ?? (schedule == nil)
            if !same { AskRecipeCenter.shared.setSchedule(schedule, for: id) }
            AskNav.shared.selectedRecipe = id
        } else if let r = AskRecipeCenter.shared.add(q, scope: draft.scope, schedule: schedule) {
            AskNav.shared.selectedRecipe = r.id
            AskNav.shared.pane = .recipes
        }
        dismiss()
    }
}
