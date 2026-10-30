import SwiftUI
import AppKit
import AVFoundation

// Ask your library on the Mac (mockup "Library features", section 2a and 2c), on the refined kit (DESIGN.md §13):
// the ⌘K panel, "Search or ask", with a Search and Ask switch, scope chips, the answer with
// numbered citation chips, Copy, and Save as recipe; and Make › Ask, with Questions (ask here, and recent questions)
// and Recipes (saved questions, run now or weekly, and their digests). The toolbar's search field is the window's one
// search field; Return there asks. Search keeps the Library's search: it filters the Library and lists matching
// passages. A citation's play disc is sage, the playback color.

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

    /// Opens the panel (⌘K, Edit › Find in Transcripts, Return in the toolbar's search field), optionally on a question that
    /// it asks at once.
    func open(mode: AskMode? = nil, query: String? = nil, askNow: Bool = false) {
        if let mode { self.mode = mode }
        if let query { self.query = query }
        panelOpen = true
        if askNow, self.mode == .ask, !self.query.trimmingCharacters(in: .whitespaces).isEmpty {
            AskCenter.shared.ask(self.query, scope: scope)
        }
    }

    func close() {
        panelOpen = false
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

/// The ⌘K panel over the window: a scrim (click it, or press Escape, to close) and the panel near the top.
struct AskPanelLayer: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = AskNav.shared
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        ZStack(alignment: .top) {
            if nav.panelOpen {
                Refined.onFill.opacity(0.24)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { nav.close() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                AskPanel()
                    .frame(width: 760)
                    .padding(.top, 64)
                    .transition(limitMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
            }
        }
        .animation(limitMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.16), value: nav.panelOpen)
    }
}

struct AskPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = AskNav.shared
    @ObservedObject private var center = AskCenter.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            PaperDivider(leading: 0)
            // As tall as the result, up to 460 pt; past that it scrolls.
            ViewThatFits(in: .vertical) {
                panelContent
                ScrollView { panelContent }
            }
            .frame(maxHeight: 460)
            if nav.mode == .ask { recipesStrip }
        }
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.record))
        .onAppear { focused = true }
        .onExitCommand { nav.close() }
        .onChange(of: nav.query) { _, q in if nav.mode == .search { app.search = q } }
        .onChange(of: nav.mode) { _, m in
            if m == .search { app.search = nav.query } else { focused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search or ask")
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            AskScopeChips(scope: $nav.scope)
            if nav.mode == .ask {
                AskResultBody(context: .panel)
            } else {
                searchBody
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            IconGlyph(art: nav.mode == .ask ? .iconAsk : .iconNotes, size: 22, color: Refined.accentText)
            TextField(nav.mode == .ask ? "Ask a question about your recordings" : "Find the line you need", text: $nav.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .foregroundStyle(Refined.ink)
                .focused($focused)
                .onSubmit { submit() }
                .uiTarget("ask-field")
            modeSwitch
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    private func submit() {
        switch nav.mode {
        case .ask: nav.ask()
        case .search:
            // Today's search: the Library, filtered.
            app.search = nav.query
            app.projectFilter = nil
            if app.screen != .library { app.go(.library) }
            nav.close()
        }
    }

    /// Search and Ask, the kit's segmented control.
    private var modeSwitch: some View {
        RefinedSegmented(label: "Search or ask", options: [(AskMode.search, "Search"), (AskMode.ask, "Ask")], selection: $nav.mode)
            .fixedSize()
            .background {
                // The self-test's handles on each half.
                HStack(spacing: 0) {
                    Color.clear.uiTarget("ask-mode-search")
                    Color.clear.uiTarget("ask-mode-ask")
                }
                .allowsHitTesting(false)
            }
    }

    /// Search: the matching passages (the Library behind the panel is filtered the same way). Return shows the Library.
    @ViewBuilder private var searchBody: some View {
        let q = nav.query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 {
            Text("Type at least two letters to find matching lines. Press Return to see them in the Library.")
                .refinedFont(.body).foregroundStyle(Refined.dim)
        } else {
            let list = nav.scope.isAll ? app.store.live : app.store.live.filter { nav.scope.includes($0) }
            let hits = LibrarySearch.passages(list.sorted { $0.createdAt > $1.createdAt }, query: q, perTranscript: 3, cap: 60)
            if hits.isEmpty {
                Text("No passages match \u{201C}\(q)\u{201D}. Switch to Ask to ask about it in your own words.")
                    .refinedFont(.body).foregroundStyle(Refined.dim)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hits.prefix(8)) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.transcript.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                            ForEach(hit.lines) { s in
                                AskSearchLine(transcript: hit.transcript, segment: s, query: q)
                            }
                        }
                    }
                }
            }
        }
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

/// One matching line in Search: its time and words; a click opens the transcript there.
private struct AskSearchLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var segment: Segment
    var query: String
    @State private var hover = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(AskFormat.time(segment.start)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).frame(width: 48, alignment: .leading)
            Text(segment.text).refinedFont(.rowTitle).foregroundStyle(Refined.ink).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Refined.neutral : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .tapArea {
            AskNav.shared.close()
            app.focusSegment = segment.id
            app.go(.transcript(transcript.id))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the transcript at \(AskFormat.time(segment.start))")
    }
}

// MARK: - Scope chips

/// All, This week, Thoughts, Meetings, and each project.
struct AskScopeChips: View {
    @Binding var scope: AskScope
    @EnvironmentObject var app: AppState

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
    @EnvironmentObject var app: AppState
    @AppStorage(RecipesSetting.key) private var showRecipes = false
    private var hasRecipes: Bool { !app.store.recipes.isEmpty }
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let a = result.answer, result.state == .answered {
                AskAnswerText(answer: a)
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
                    Text(h).font(.system(size: size + 3, design: .serif)).foregroundStyle(Refined.ink)
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
    @EnvironmentObject var app: AppState
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
    @EnvironmentObject var app: AppState
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
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = AskNav.shared
    /// Recipes are hidden until you show them, or while you have one (consolidation, `RecipesSetting`).
    @AppStorage(RecipesSetting.key) private var showRecipes = false

    var body: some View {
        NavMarks.mark("ask")
        let recipes = RecipesSetting.shows(stored: showRecipes, hasRecipes: !app.store.recipes.isEmpty)
        let pane: AskPane = recipes ? nav.pane : .questions
        return ScrollView {
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
                case .questions: AskQuestionsPane()
                case .recipes: AskRecipesPane()
                }
            }
            .padding(.horizontal, 40).padding(.top, 18).padding(.bottom, 40)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdges(.top)
        .background(Refined.paper)
        .sheet(item: $nav.editing) { d in RecipeEditorSheet(draft: d).environmentObject(app) }
    }
}

/// Ask › Questions: the field, the scope, the answer, and recent questions on this Mac.
struct AskQuestionsPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = AskNav.shared
    @ObservedObject private var center = AskCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconGlyph(art: .iconAsk, size: 20, color: Refined.accentText)
                    TextField("Ask a question about your recordings", text: $nav.query)
                        .textFieldStyle(.plain).font(.system(size: 17)).foregroundStyle(Refined.ink)
                        .onSubmit { nav.mode = .ask; nav.ask() }
                        .uiTarget("ask-screen-field")
                    Button("Ask") { nav.ask() }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .disabled(nav.query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .refinedFieldBox()
                AskScopeChips(scope: $nav.scope)
                AskResultBody(context: .screen)
            }
            .padding(20)
            .modifier(TemplateCardSurface())
            if !center.history.isEmpty {
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
    @EnvironmentObject var app: AppState
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
    @EnvironmentObject var app: AppState
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
