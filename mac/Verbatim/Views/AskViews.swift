import SwiftUI
import AppKit
import AVFoundation

// brand: web style
//
// Ask your library on the Mac (mockup "Library features", section 2a and 2c): the ⌘K panel, "Search or ask", with a
// Search and Ask switch, scope chips, the answer with numbered citation chips, Copy, and Save as recipe; the sidebar's
// Search or ask field that opens it; and Make › Ask, with Questions (ask here, and recent questions) and Recipes
// (saved questions, run now or weekly, and their digests). Search keeps the Library's search: it filters the Library
// and lists matching passages. Built from the website-style kit, which draws Premium Native too.

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

    /// Opens the panel (⌘K, the sidebar's field, Return in the toolbar's search field), optionally on a question that
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

/// A recipe in the editor: its question, scope, and (on this Mac) weekly time.
struct RecipeDraft: Identifiable {
    let id = UUID()
    var recipeId: UUID? = nil
    var question: String
    var scope: AskScope
    var scheduled = false
    var weekday = 6
    var hour = 16
    var minute = 0
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
    @Environment(\.look) private var look
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        ZStack(alignment: .top) {
            if nav.panelOpen {
                (look == .native ? Color.black.opacity(0.18) : Ink.ink.opacity(0.28))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { nav.close() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                AskPanel()
                    .frame(width: look == .native ? 760 : 780)
                    .padding(.top, look == .native ? 70 : 54)
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
    @Environment(\.look) private var look
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            Rectangle().fill(look == .native ? Color.primary.opacity(0.08) : Ink.hairline).frame(height: 1)   // brand: native
            // As tall as the result, up to 460 pt; past that it scrolls.
            ViewThatFits(in: .vertical) {
                panelContent
                ScrollView { panelContent }
            }
            .frame(maxHeight: 460)
            if nav.mode == .ask, look != .native { recipesStrip }
        }
        .background(panelSurface)
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

    @ViewBuilder private var panelSurface: some View {
        if look == .native {
            // Spotlight's surface: the system glass on macOS 26 (it carries its own depth), the content color before.
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))   // brand: native
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(PremiumInk.card)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(NativeInk.separator, lineWidth: 0.5))
            }
        } else {
            RoundedRectangle(cornerRadius: Radius.record, style: .continuous).fill(Ink.reader)
                .inkEdge(outline: true, shadow: CGSize(width: 7, height: 9), radius: Radius.record)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            if look == .native {
                Image(systemName: nav.mode == .ask ? "questionmark.bubble" : "magnifyingglass").font(.system(size: 18)).foregroundStyle(NativeInk.accent)   // brand: native
            } else {
                IconGlyph(art: nav.mode == .ask ? .iconAsk : .iconNotes, size: 22, color: Ink.ink)
            }
            TextField(nav.mode == .ask ? "Ask a question about your recordings" : "Find the line you need", text: $nav.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .foregroundStyle(Ink.ink)
                .focused($focused)
                .onSubmit { submit() }
                .uiTarget("ask-field")
            if look == .native { nativeModeMenu } else { modeSwitch }
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

    /// Verbose style: Search and Ask in an ink segmented capsule.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach([AskMode.search, .ask], id: \.self) { m in
                Text(m == .search ? "Search" : "Ask")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(nav.mode == m ? Ink.paper : Ink.ink)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(nav.mode == m ? Ink.ink : Color.clear))
                    .contentShape(Capsule())
                    .tapArea { nav.mode = m }
                    .accessibilityAddTraits(nav.mode == m ? [.isButton, .isSelected] : .isButton)
                    .uiTarget("ask-mode-\(m.rawValue)")
            }
        }
        .padding(3)
        .background(Capsule().fill(Ink.chip))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search or ask")
    }

    // brand: native begin
    /// Premium Native: a pop-up button, "Ask" or "Search".
    private var nativeModeMenu: some View {
        Picker("", selection: $nav.mode) {
            Text("Ask").tag(AskMode.ask)
            Text("Search").tag(AskMode.search)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .uiTarget("ask-mode-menu")
    }
    // brand: native end

    /// Search: the matching passages (the Library behind the panel is filtered the same way). Return shows the Library.
    @ViewBuilder private var searchBody: some View {
        let q = nav.query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 {
            Text("Type at least two letters to find matching lines. Press Return to see them in the Library.")
                .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
        } else {
            let list = nav.scope.isAll ? app.store.live : app.store.live.filter { nav.scope.includes($0) }
            let hits = LibrarySearch.passages(list.sorted { $0.createdAt > $1.createdAt }, query: q, perTranscript: 3, cap: 60)
            if hits.isEmpty {
                Text("No passages match \u{201C}\(q)\u{201D}. Switch to Ask to ask about it in your own words.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hits.prefix(8)) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.transcript.title).font(look == .native ? .system(size: 14, weight: .semibold) : Ink.serif(16)).foregroundStyle(Ink.ink).lineLimit(1)
                            ForEach(hit.lines) { s in
                                AskSearchLine(transcript: hit.transcript, segment: s, query: q)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Verbose style: your recipes, one tap to run (the answer opens in Ask › Recipes).
    @ViewBuilder private var recipesStrip: some View {
        let recipes = app.store.recipes
        if !recipes.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Recipes").font(Ink.mono(12.5)).foregroundStyle(Ink.mute)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recipes) { r in
                            FilterChip(title: r.question, selected: false) {
                                AskRecipeCenter.shared.run(r)
                                AskNav.shared.pane = .recipes
                                AskNav.shared.selectedRecipe = r.id
                                nav.close()
                                app.go(.ask)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Ink.paper.opacity(0.6))
            .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
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
            Text(AskFormat.time(segment.start)).font(Ink.mono(12)).foregroundStyle(Ink.mute).frame(width: 48, alignment: .leading)
            Text(segment.text).font(.system(size: 13.5)).foregroundStyle(Ink.ink).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(hover ? Ink.wash : Color.clear))
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
    @Environment(\.look) private var look

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if look != .native { Text("In").font(Ink.mono(12.5)).foregroundStyle(Ink.mute).padding(.trailing, 4) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", scope.isAll, id: "all") { scope.tapAll() }
                    chip("This week", scope.range == .thisWeek, id: "week") { scope.tapWeek() }
                    chip("Thoughts", scope.source == .thoughts, id: "thoughts") { scope.tap(.thoughts) }
                    chip("Meetings", scope.source == .meetings, id: "meetings") { scope.tap(.meetings) }
                    ForEach(app.store.projects) { p in
                        chip(p.name, scope.source == .project(p.id), id: "project") { scope.tap(.project(p.id)) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where to look")
    }

    private func chip(_ title: String, _ on: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        FilterChip(title: look == .native ? NativeText.titleCase(title) : title, selected: on, small: true, action: action)
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
    @Environment(\.look) private var look

    var body: some View {
        switch center.phase {
        case .idle:
            Text(nav.query.isEmpty ? "Ask in plain words, like \u{201C}What did Alex want changed on the homepage?\u{201D} Verbose finds the passages first, then answers on this Mac with Apple Intelligence."
                 : "Press Return to ask.")
                .font(.system(size: 13.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        case .finding, .answering:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(center.phase == .finding ? "Finding passages…" : "Answering from the passages…").font(.system(size: 13.5)).foregroundStyle(Ink.dim)
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
    @Environment(\.look) private var look
    @AppStorage(RecipesSetting.key) private var showRecipes = false
    private var hasRecipes: Bool { !app.store.recipes.isEmpty }
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let a = result.answer, result.state == .answered {
                AskAnswerText(answer: a)
                if look == .native { AskCitationRows(sources: a.citations) } else { AskCitationChips(sources: a.citations) }
            } else {
                Text(result.message(scopeLabel: result.scope.label(projects: projectNames)))
                    .font(.system(size: 14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    .uiTarget("ask-message")
                if !result.found.isEmpty {
                    if look == .native { AskCitationRows(sources: result.found) } else { AskCitationChips(sources: result.found) }
                }
            }
            footer
        }
    }

    private var projectNames: [UUID: String] { Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) }) }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if result.state == .answered {
                Text(result.footer(native: look == .native)).font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            } else if look != .native, result.state == .searchOnly {
                Text("Found on this \(result.device). Nothing leaves it.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            }
            Spacer(minLength: 8)
            PillButton(title: copied ? "✓ Copied" : "Copy", kind: .line, size: .mini, icon: copied ? nil : .iconCopy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.copyText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            }
            .uiTarget("ask-copy")
            if context != .digest, RecipesSetting.shows(stored: showRecipes, hasRecipes: hasRecipes) {
                PillButton(title: "Save as recipe", kind: .line, size: .mini) { AskNav.shared.saveAsRecipe(result) }
                    .uiTarget("ask-save-recipe")
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(look == .native ? Color.primary.opacity(0.07) : Ink.hairline).frame(height: 1) }   // brand: native
    }
}

/// The answer's paragraphs, bullets, and headings, each sentence followed by its citation numbers.
struct AskAnswerText: View {
    var answer: AskAnswer
    var size: CGFloat = 15
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(answer.blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h):
                    Text(h).font(look == .native ? .system(size: size, weight: .semibold) : Ink.serif(size + 3)).foregroundStyle(Ink.ink)
                        .padding(.top, 4).accessibilityAddTraits(.isHeader)
                case .paragraph(let s):
                    Text(attributed(s)).font(.system(size: size)).foregroundStyle(Ink.ink).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.system(size: size)).foregroundStyle(Ink.dim)
                        Text(attributed(s)).font(.system(size: size)).foregroundStyle(Ink.ink).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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
                if look == .native {
                    m.font = .system(size: size - 3, weight: .semibold)
                    m.foregroundColor = NativeInk.accent   // brand: native
                    m.backgroundColor = NativeInk.accent.opacity(0.12)   // brand: native
                } else {
                    m.font = Ink.mono(12)
                    m.foregroundColor = Ink.dim
                    m.backgroundColor = Ink.chip
                }
                out += m
            }
        }
        return out
    }
}

/// Verbose style: neutral chips, number, play, title, and time. A click plays from that time here (the one playing
/// takes the sage playing wash); right-click opens the transcript at the line.
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
            Text("\(source.number)").font(Ink.mono(12)).foregroundStyle(Ink.dim)
                .frame(minWidth: 18, minHeight: 18)
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
            ZStack {
                Circle().fill(Ink.ink)
                ArtIcon(art: playing ? .iconPause : .iconPlay, size: 9, lineWidth: 1.3).foregroundStyle(Ink.paper)
            }
            .frame(width: 18, height: 18)
            Text(source.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            Text(AskFormat.time(source.start)).font(Ink.mono(12)).foregroundStyle(Ink.dim)
        }
        .padding(.leading, 6).padding(.trailing, 12)
        .frame(height: 32)
        .background(Capsule().fill(playing ? Ink.playing : (hover ? Ink.cardHover : Ink.card)))
        .overlay(Capsule().strokeBorder(playing ? Ink.ink : Ink.hairline, lineWidth: playing ? 1.5 : 1))
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

// brand: native begin
/// Premium Native: citations as rows in one white box, number, title, date, and a play pill with the time.
struct AskCitationRows: View {
    var sources: [AskSource]
    @EnvironmentObject var app: AppState
    @ObservedObject private var player = AskPlayer.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider().padding(.leading, 44) }
                row(s)
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PremiumInk.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NativeInk.separator, lineWidth: 0.5))
    }

    private func row(_ s: AskSource) -> some View {
        let on = player.playing == s.id
        return HStack(spacing: 12) {
            Text("\(s.number)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
                Text(s.createdAt.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 9))
                Text(AskFormat.time(s.start)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(on ? NativeInk.accent.opacity(0.18) : NativeInk.bordered))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .tapArea { if !AskPlayer.shared.toggle(s, store: app.store) { AskOpen.transcript(s, app: app) } }
        .contextMenu {
            Button("Open Transcript at \(AskFormat.time(s.start))") { AskOpen.transcript(s, app: app) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source \(s.number), \(s.title), at \(AskFormat.time(s.start))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open transcript") { AskOpen.transcript(s, app: app) }
        .uiTarget("ask-cite-\(s.number)")
    }
}
// brand: native end

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
        LookSwitch.mark("ask")
        let recipes = RecipesSetting.shows(stored: showRecipes, hasRecipes: !app.store.recipes.isEmpty)
        let pane: AskPane = recipes ? nav.pane : .questions
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Ask", count: recipes ? AskResult.plural(app.store.recipes.count, "recipe", "recipes") : nil,
                          lede: pane == .questions ? "Ask about your recordings. Verbose finds the passages first, then answers on this Mac."
                                                   : "Questions you ask again. Run one now, or schedule it weekly.") {
                    HStack(spacing: 6) {
                        if recipes {
                            FilterChip(title: "Questions", selected: pane == .questions) { nav.pane = .questions }.uiTarget("ask-pane-questions")
                            FilterChip(title: "Recipes", selected: pane == .recipes) { nav.pane = .recipes }.uiTarget("ask-pane-recipes")
                            PillButton(title: "New recipe", kind: .dark, size: .mini, icon: .webPlus) { nav.editing = RecipeDraft(question: "", scope: nav.scope) }
                                .uiTarget("ask-new-recipe")
                        }
                        Menu {
                            Toggle("Show Recipes", isOn: $showRecipes)
                                .disabled(!app.store.recipes.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ink)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(Ink.ink, lineWidth: 1.5))
                                .contentShape(Circle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Recipes: questions you save and run again, now or every week")
                        .accessibilityLabel("More")
                        .uiTarget("ask-more")
                    }
                }
                switch pane {
                case .questions: AskQuestionsPane()
                case .recipes: AskRecipesPane()
                }
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .sheet(item: $nav.editing) { d in RecipeEditorSheet(draft: d).environmentObject(app) }
    }
}

/// Ask › Questions: the field, the scope, the answer, and recent questions on this Mac.
struct AskQuestionsPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = AskNav.shared
    @ObservedObject private var center = AskCenter.shared
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if look == .native {
                        Image(systemName: "questionmark.bubble").font(.system(size: 17)).foregroundStyle(NativeInk.accent)   // brand: native
                    } else {
                        IconGlyph(art: .iconAsk, size: 20, color: Ink.ink)
                    }
                    TextField("Ask a question about your recordings", text: $nav.query)
                        .textFieldStyle(.plain).font(.system(size: 17)).foregroundStyle(Ink.ink)
                        .onSubmit { nav.mode = .ask; nav.ask() }
                        .uiTarget("ask-screen-field")
                    PillButton(title: "Ask", kind: .dark, size: .mini, enabled: !nav.query.trimmingCharacters(in: .whitespaces).isEmpty) { nav.ask() }
                }
                AskScopeChips(scope: $nav.scope)
                AskResultBody(context: .screen)
            }
            .padding(20)
            .modifier(TemplateCardSurface())
            if !center.history.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    DayHeader(text: "Recent questions · \(center.history.count)").padding(.bottom, 2)
                    ForEach(center.history) { r in
                        FlatRowButton(selected: center.result?.id == r.id, action: { nav.query = r.question; nav.scope = r.scope; center.show(r) }) { _ in
                            HStack(spacing: 12) {
                                IconGlyph(art: .iconAsk, size: 16, color: Ink.ink)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.question).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(r.scope.label(projects: names) + " · " + r.askedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                StatusText(text: r.state == .answered ? "Answered" : "No answer")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
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
    @Environment(\.look) private var look

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
                        IconGlyph(art: .iconPrivacy, size: 14, color: Ink.mute)
                        Text(TemplateCopy.onDevice("Mac")).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
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
            EmptyStateCard(art: .iconAsk, title: "No recipes yet",
                           message: "A recipe is a question you ask again, with where to look. Run it any time, or every week. Start with one of these, or make your own.",
                           button: "New recipe") { nav.editing = RecipeDraft(question: "", scope: nav.scope) }
            DayHeader(text: "Try one")
            AskFlow(spacing: 8) {
                ForEach(Array(RecipeSuggestions.all(projects: app.store.projects.map { ($0.id, $0.name) }).enumerated()), id: \.offset) { i, s in
                    FilterChip(title: s.question, selected: false) {
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
        let parts = WebText.splitLastWord(r.question)
        let scheduled = center.schedule(r.id) != nil
        return VStack(alignment: .leading, spacing: 8) {
            if look == .native {
                Text(r.question).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
            } else {
                WebText.serif(parts.0, italic: parts.1, size: 19).foregroundStyle(Ink.ink).lineLimit(2)
            }
            HStack(spacing: 6) {
                IconGlyph(art: scheduled ? .iconCalendar : .iconAsk, size: 13, color: Ink.dim)
                Text(scheduleLine(r)).font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            HStack(spacing: 6) {
                PillButton(title: center.running.contains(r.id) ? "Running…" : "Run now", kind: selected ? .dark : .line, size: .mini,
                           enabled: !center.running.contains(r.id)) {
                    nav.selectedRecipe = r.id
                    AskRecipeCenter.shared.run(r)
                }
                .uiTarget("ask-run-\(r.id.uuidString.prefix(8))")
                PillButton(title: scheduled ? "Edit schedule" : "Schedule", kind: .line, size: .mini) { nav.editing = draft(r) }
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
        .uiTarget("ask-recipe-\(r.id.uuidString.prefix(8))")
    }

    private func draft(_ r: AskRecipe) -> RecipeDraft {
        var d = RecipeDraft(recipeId: r.id, question: r.question, scope: r.scope)
        if let s = center.schedule(r.id) { d.scheduled = true; d.weekday = s.weekday; d.hour = s.hour; d.minute = s.minute }
        return d
    }

    @ViewBuilder private func digest(_ r: AskRecipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = center.latest(r.id) {
                let parts = WebText.splitLastWord(r.question)
                Text(dayLine(d)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                if look == .native {
                    Text(r.question).font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.ink)
                } else {
                    WebText.serif(parts.0, italic: parts.1, size: 26).foregroundStyle(Ink.ink)
                }
                Text(r.scope.label(projects: names)).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                AskResultView(result: d.result, context: .digest)
            } else if center.running.contains(r.id) {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Finding passages and answering…").font(.system(size: 13.5)).foregroundStyle(Ink.dim) }
            } else {
                Text("No answer yet. Choose Run now, or Schedule to run it every week.").font(.system(size: 13.5)).foregroundStyle(Ink.dim)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(TemplateCardSurface())
    }

    /// "Fri Oct 23 · 4:00 PM · Ran on schedule".
    private func dayLine(_ d: AskDigest) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE MMM d · h:mm a"
        return f.string(from: d.ranAt) + (d.scheduled ? " · Ran on schedule" : " · Ran now")
    }
}

// MARK: - The recipe editor

struct RecipeEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var draft: RecipeDraft
    @State private var confirmDelete = false

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date() },
                set: { d in draft.hour = Calendar.current.component(.hour, from: d); draft.minute = Calendar.current.component(.minute, from: d) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.recipeId == nil ? "New recipe" : "Edit recipe").font(Ink.serif(26)).foregroundStyle(Ink.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text("Question").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.dim)
                TextField("What did I say about Website refresh", text: $draft.question)
                    .textFieldStyle(.roundedBorder).font(.system(size: 14))
                    .uiTarget("recipe-question")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Where to look").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.dim)
                AskScopeChips(scope: $draft.scope)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Run every week on this Mac", isOn: $draft.scheduled).toggleStyle(.switch)
                    .uiTarget("recipe-schedule")
                if draft.scheduled {
                    HStack(spacing: 10) {
                        Picker("Day", selection: $draft.weekday) {
                            ForEach(1...7, id: \.self) { d in Text(RecipeSchedule.dayName(d)).tag(d) }
                        }
                        .labelsHidden().frame(width: 140)
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                    Text("Verbose runs it when this Mac is awake and Verbose is open, or the next time it opens. Schedules stay on this Mac; the recipe syncs with your iPhone.")
                        .font(.system(size: 12)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if draft.recipeId != nil {
                    Button("Delete Recipe", role: .destructive) { confirmDelete = true }.buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillButtonStyle(kind: .line, size: .mini)).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PillButtonStyle(kind: .dark, size: .mini)).keyboardShortcut(.defaultAction)
                    .disabled(draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .uiTarget("recipe-save")
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Ink.paper)
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
