import SwiftUI
import UIKit

// Ask your library on the iPhone (mockup "Library features", sections 2b and 2c): Library › Ask (from the Library's
// card, or "Ask about …" under the Library's search field), with the question, the scope chips, and the answer with its
// citations above the matching passages; and Ask › Recipes, saved questions you run now or weekly, with their digests.
// A citation opens the transcript at that line and plays it. On the refined kit (DESIGN.md §13)
// : the large serif title, the question in the kit's field, the kit's chips, and the answer on a card.

struct AskRoute: Hashable { var query: String? = nil }
struct RecipesRoute: Hashable {}
struct RecipeRoute: Hashable { var id: UUID }

/// "Ask about “…”" under the Library's search field (DESIGN.md §6.8): a row of the Library's card that opens Ask with
/// what you typed. A button that pushes, so the list adds no chevron of its own.
struct AskAboutRow: View {
    @EnvironmentObject var app: PhoneState
    var query: String
    var body: some View {
        Button { app.pushHere(AskRoute(query: query)) } label: {
            IconSquareRow(art: .iconAsk, hue: .neutral, title: "Ask about \u{201C}\(query)\u{201D}")
        }
        .buttonStyle(RefinedPress())
        .accessibilityIdentifier("library.askAbout")
        .accessibilityHint("Answers from your recordings, with the passages it used")
    }
}

// MARK: - Ask

struct AskScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var center = AskCenter.shared
    var route = AskRoute()
    @State private var query = ""
    @State private var scope = AskScope.all
    /// Recipes are hidden until you show them, or while you have one (consolidation, `RecipesSetting`).
    @AppStorage(RecipesSetting.key) private var showRecipes = false
    @State private var editing: RecipeDraft? = nil
    @State private var applied = false
    @FocusState private var focused: Bool
    /// What the screen showed last, for the self-test.
    static var shown: AskResult.State? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LargeSerifTitle(title: "Ask", eyebrow: "Library")
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                field
                chips
                resultArea
                if let r = center.result, center.phase == .done, r.state == .answered {
                    passages(r)
                }
                if RecipesSetting.shows(stored: showRecipes, hasRecipes: !app.store.recipes.isEmpty) {
                    PaperCard {
                        NavigationLink(value: RecipesRoute()) {
                            HStack(spacing: 12) {
                                IconSquare(art: .iconCalendar, hue: .sage)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Recipes").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                                    Text("Questions you ask again").refinedFont(.meta).foregroundStyle(Refined.mute)
                                }
                                Spacer(minLength: 6)
                                if !app.store.recipes.isEmpty {
                                    Text("\(app.store.recipes.count)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                                }
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.faint)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RefinedRowPress())
                        .accessibilityIdentifier("ask.recipes")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The serif title sits on the page; the bar keeps only Apple's buttons.
            ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let recipesShown = RecipesSetting.shows(stored: showRecipes, hasRecipes: !app.store.recipes.isEmpty)
                    if let r = center.result, center.phase == .done {
                        Button { UIPasteboard.general.string = r.copyText; app.say("Copied"); Haptics.play(.copied) } label: { Label("Copy", systemImage: "doc.on.doc") }   // brand: system surface (menu)
                        if recipesShown {
                            Button { editing = RecipeDraft(question: r.question, scope: r.scope) } label: { Label("Save as Recipe", systemImage: "bookmark") }   // brand: system surface (menu)
                        }
                    }
                    if recipesShown {
                        Button { app.pushHere(RecipesRoute()) } label: { Label("Recipes", systemImage: "calendar") }   // brand: system surface (menu)
                    }
                    Toggle("Show Recipes", isOn: $showRecipes).disabled(!app.store.recipes.isEmpty)
                    if !center.history.isEmpty {
                        Menu("Recent Questions") {
                            ForEach(center.history) { h in Button(h.question) { query = h.question; scope = h.scope; center.show(h) } }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .sheet(item: $editing) { d in PhoneRecipeEditor(draft: d).environmentObject(app) }
        .onAppear {
            guard !applied else { return }
            applied = true
            if let q = route.query, !q.trimmingCharacters(in: .whitespaces).isEmpty {
                query = q
                ask()
            } else if center.result == nil {
                focused = true
            }
        }
        .onChange(of: center.phase) { _, p in if p == .done { Self.shown = center.result?.state } }
    }

    private func ask() {
        focused = false
        center.ask(query, scope: scope)
    }

    /// The question in the kit's field: the field wash (an edge under Increase Contrast), the Ask glyph, and up to four
    /// lines. Return asks.
    private var field: some View {
        HStack(alignment: .top, spacing: 10) {
            IconGlyph(art: .iconAsk, size: 19, color: Refined.mute).padding(.top, 1)
            TextField("Ask about your recordings", text: $query, axis: .vertical)
                .refinedFont(.body).foregroundStyle(Refined.ink)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit { ask() }
                .onChange(of: query) { _, q in
                    // Return in a multi-line field adds a line: treat it as Ask.
                    if q.hasSuffix("\n") { query = String(q.dropLast()); ask() }
                }
                .accessibilityIdentifier("ask.field")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
        .refinedFieldBox()
    }

    private var chips: some View {
        RefinedChipRow(label: "Where to look", margin: 20) {
            RefinedChip(title: "All", selected: scope.isAll) { scope.tapAll() }
            RefinedChip(title: "This week", selected: scope.range == .thisWeek) { scope.tapWeek() }
            RefinedChip(title: "Thoughts", selected: scope.source == .thoughts) { scope.tap(.thoughts) }
            RefinedChip(title: "Meetings", selected: scope.source == .meetings) { scope.tap(.meetings) }
            ForEach(app.store.projects) { p in RefinedChip(title: p.name, selected: scope.source == .project(p.id)) { scope.tap(.project(p.id)) } }
        }
        .padding(.horizontal, -20)
        .onChange(of: scope) { _, _ in if center.result != nil, !query.isEmpty { ask() } }
    }

    @ViewBuilder private var resultArea: some View {
        switch center.phase {
        case .idle:
            Text("Ask in plain words, like \u{201C}What did Alex want changed on the homepage?\u{201D} Verbose finds the passages first, then answers on this iPhone.")
                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        case .finding, .answering:
            HStack(spacing: 10) {
                ProgressView()
                Text(center.phase == .finding ? "Finding passages…" : "Answering from the passages…").refinedFont(.body).foregroundStyle(Refined.dim)
            }
            .padding(.vertical, 8)
        case .done:
            if let r = center.result { PhoneAskResult(result: r) }
        }
    }

    /// The passages the answer read, under it.
    @ViewBuilder private func passages(_ r: AskResult) -> some View {
        let cited = Set((r.answer?.citations ?? []).map(\.segmentId))
        let others = r.found.filter { !cited.contains($0.segmentId) }
        if !others.isEmpty {
            PaperGroup("Other passages") {
                ForEach(Array(others.prefix(6).enumerated()), id: \.element.id) { i, s in
                    if i > 0 { PaperDivider(leading: 14) }
                    PhoneAskPassage(source: s)
                }
            }
            .padding(.top, 8)
        }
    }
}

/// A result: the answer card with citations and footer, or what was found and why there's no answer.
struct PhoneAskResult: View {
    var result: AskResult
    var showsFooter = true
    @EnvironmentObject var app: PhoneState
    /// The last footer line an answer card drew, for the self-test.
    static var footerShown: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.state == .answered ? "Answer" : "No answer").refinedFont(.meta).foregroundStyle(Refined.mute)
            if let a = result.answer, result.state == .answered {
                PhoneAskAnswerText(answer: a)
                PhoneAskCitations(sources: a.citations)
            } else {
                Text(result.message(scopeLabel: result.scope.label(projects: Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) }))))
                    .refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.message")
                if !result.found.isEmpty { PhoneAskCitations(sources: result.found) }
            }
            if showsFooter {
                HStack(spacing: 6) {
                    IconGlyph(art: .iconPrivacy, size: 13, color: Refined.mute)
                    Text(result.state == .answered ? "Runs on this iPhone with Apple Intelligence." : "Found on this iPhone. Nothing left your device.")
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                // What the answer read: "From 9 passages in 2 recordings, answered on this iPhone." (DESIGN.md §19).
                if result.state == .answered {
                    Text(result.footer(short: true)).refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ask.footer")
                        .onAppear { Self.footerShown = result.footer(short: true) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }
}

/// The answer's paragraphs, bullets, and headings, with citation numbers after each sentence.
struct PhoneAskAnswerText: View {
    var answer: AskAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(answer.blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h):
                    Text(h).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                case .paragraph(let s):
                    Text(attributed(s)).refinedFont(.reading).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Refined.dim)
                        Text(attributed(s)).refinedFont(.reading).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Each sentence, then its citation numbers in the accent on the persimmon tint.
    private func attributed(_ sentences: [AskSentence]) -> AttributedString {
        var out = AttributedString()
        for (i, s) in sentences.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            out += AttributedString(s.text)
            for n in s.cites {
                out += AttributedString("\u{2009}")
                var m = AttributedString("\u{2009}\(n)\u{2009}")
                m.font = .system(size: 13, weight: .semibold).monospacedDigit()
                m.foregroundColor = Refined.accentText
                m.backgroundColor = Refined.persimmonTint
                out += m
            }
        }
        return out
    }
}

/// Citations: rows in a card, each with its number, the recording and where in it, and a sage play disc with the time.
/// A tap opens the transcript at that line and plays it.
struct PhoneAskCitations: View {
    var sources: [AskSource]
    @EnvironmentObject var app: PhoneState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { i, s in
                if i > 0 { PaperDivider(leading: 34) }
                Button { open(s) } label: { row(s) }
                    .buttonStyle(RefinedRowPress())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Source \(s.number), \(s.title), at \(AskFormat.time(s.start))")
                    .accessibilityHint("Opens the transcript at this line and plays it")
                    .accessibilityIdentifier("ask.cite.\(s.number)")
            }
        }
    }

    private func open(_ s: AskSource) {
        app.autoplay = s.transcriptId
        app.open(s.transcriptId, segment: s.segmentId)
    }

    private func row(_ s: AskSource) -> some View {
        let parts = s.title.components(separatedBy: " · ")
        return HStack(spacing: 12) {
            Text("\(s.number)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Refined.accentText)
                .frame(width: 22, height: 22).background(Refined.persimmonTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.first ?? s.title).refinedFont(.rowTitle).foregroundStyle(Refined.ink).lineLimit(1)
                if parts.count > 1 {
                    Text(parts.dropFirst().joined(separator: " · ")).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(Refined.badge(.sage))
                    ArtIcon(art: .iconPlay, size: 9, lineWidth: 1.3).foregroundStyle(Refined.onBadge(.sage))
                }
                .frame(width: 22, height: 22)
                Text(AskFormat.time(s.start)).refinedFont(.meta, weight: .semibold).monospacedDigit().foregroundStyle(Refined.ink)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
        .contentShape(Rectangle())
    }
}

/// A passage the answer didn't cite, as a row in the passages' card: its recording, time, and words.
struct PhoneAskPassage: View {
    var source: AskSource
    @EnvironmentObject var app: PhoneState
    var body: some View {
        PaperRowButton(action: { app.autoplay = source.transcriptId; app.open(source.transcriptId, segment: source.segmentId) }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(source.title).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(AskFormat.time(source.start)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                }
                Text(source.text).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(3).multilineTextAlignment(.leading)
            }
            .padding(14)
        }
        .accessibilityHint("Opens the transcript at \(AskFormat.time(source.start))")
    }
}

// MARK: - Recipes

struct RecipesScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var center = AskRecipeCenter.shared
    @State private var editing: RecipeDraft? = nil
    static var shown: Int? = nil

    var body: some View {
        let recipes = app.store.recipes
        let scheduled = recipes.filter { center.schedule($0.id) != nil }
        let anytime = recipes.filter { center.schedule($0.id) == nil }
        SettingsPageScaffold(title: "Recipes") {
            Text("Questions you ask again. Run one now, or schedule it weekly on this iPhone.")
                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            if recipes.isEmpty {
                SettingsPageGroup(title: "Try one", footer: "Tap one to save it. You can change the question, where it looks, and when it runs.", first: true) {
                    ForEach(Array(RecipeSuggestions.all(projects: app.store.projects.map { ($0.id, $0.name) }).enumerated()), id: \.offset) { i, s in
                        if i > 0 { SettingsDivider() }
                        Button {
                            let sched = s.schedule.map { RecipeSchedule(weekday: $0.weekday, hour: $0.hour, minute: $0.minute) }
                            _ = center.add(s.question, scope: s.scope, schedule: sched)
                        } label: {
                            SettingsRow(hue: .neutral, art: s.schedule == nil ? .iconAsk : .iconCalendar,
                                        title: s.question, subtitle: subtitle(s.scope, s.schedule.map { RecipeSchedule(weekday: $0.weekday, hour: $0.hour, minute: $0.minute) })) {
                                Image(systemName: "plus.circle").foregroundStyle(Refined.accentText)
                            }
                        }
                        .buttonStyle(SettingsRowPress())
                        .accessibilityIdentifier("recipes.suggestion.\(i)")
                    }
                }
            }
            if !scheduled.isEmpty {
                SettingsPageGroup(title: "Scheduled", first: true) { rows(scheduled) }
            }
            if !anytime.isEmpty {
                SettingsPageGroup(title: "Any time", first: scheduled.isEmpty) { rows(anytime) }
            }
            if let d = center.digests.first, let r = recipes.first(where: { $0.id == d.recipeId }) {
                SettingsPageGroup(title: "Last digest") {
                    NavigationLink(value: RecipeRoute(id: r.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.ranAt.formatted(.dateTime.weekday(.wide).month(.wide).day()) + (d.scheduled ? " · On schedule" : ""))
                                .refinedFont(.meta).foregroundStyle(Refined.mute)
                            Text(r.question).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                            if let a = d.result.answer {
                                Text(a.firstSentence).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsRowPress())
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = RecipeDraft(question: "", scope: .all) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New recipe")
            }
        }
        .sheet(item: $editing) { d in PhoneRecipeEditor(draft: d).environmentObject(app) }
        .onAppear { Self.shown = recipes.count }
        .onChange(of: recipes.count) { _, n in Self.shown = n }
    }

    private func subtitle(_ scope: AskScope, _ s: RecipeSchedule?) -> String {
        let names = Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) })
        return [s?.shortLabel, scope.label(projects: names)].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func rows(_ list: [AskRecipe]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
            if i > 0 { SettingsDivider() }
            NavigationLink(value: RecipeRoute(id: r.id)) {
                SettingsRow(hue: .neutral,
                            art: center.schedule(r.id) == nil ? .iconAsk : .iconCalendar, title: r.question,
                            subtitle: subtitle(r.scope, center.schedule(r.id)), subtitleLines: 1) {
                    if center.running.contains(r.id) {
                        ProgressView()
                    } else {
                        Button("Run") { center.run(r) }
                            .buttonStyle(RefinedActionStyle(kind: .quiet))
                            .accessibilityIdentifier("recipes.run.\(i)")
                    }
                }
            }
            .buttonStyle(SettingsRowPress())
        }
    }
}

/// One recipe: its latest answer with citations, Run now, Edit, and its earlier answers on this iPhone.
struct RecipeScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    var id: UUID
    @ObservedObject private var center = AskRecipeCenter.shared
    @State private var editing: RecipeDraft? = nil

    var body: some View {
        if let r = app.store.recipes.first(where: { $0.id == id }) {
            content(r)
        } else {
            Text("This recipe was deleted.").refinedFont(.body).foregroundStyle(Refined.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Refined.paper.ignoresSafeArea())
        }
    }

    private func content(_ r: AskRecipe) -> some View {
        let names = Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) })
        let digests = center.digests.filter { $0.recipeId == r.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text([center.schedule(r.id)?.label, r.scope.label(projects: names)].compactMap { $0 }.joined(separator: " · "))
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                    Text(r.question).refinedFont(.transcriptTitle).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, 8)
                HStack(spacing: 10) {
                    Button(center.running.contains(r.id) ? "Running…" : "Run now") { center.run(r) }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .disabled(center.running.contains(r.id))
                        .accessibilityIdentifier("recipe.run")
                    Button(center.schedule(r.id) == nil ? "Schedule" : "Edit") { editing = draft(r) }
                        .buttonStyle(RefinedActionStyle(kind: .quiet))
                }
                if let d = digests.first {
                    Text(d.ranAt.formatted(date: .abbreviated, time: .shortened) + (d.scheduled ? " · Ran on schedule" : " · Ran now"))
                        .refinedFont(.meta).foregroundStyle(Refined.mute).padding(.top, 6)
                    PhoneAskResult(result: d.result)
                } else if center.running.contains(r.id) {
                    HStack(spacing: 10) { ProgressView(); Text("Finding passages and answering…").refinedFont(.body).foregroundStyle(Refined.dim) }
                } else {
                    Text("No answer yet. Tap Run now, or Schedule to run it every week on this iPhone.").refinedFont(.body).foregroundStyle(Refined.dim)
                }
                if digests.count > 1 {
                    Text("Earlier").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader).padding(.top, 8)
                    ForEach(digests.dropFirst()) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.ranAt.formatted(date: .abbreviated, time: .shortened)).refinedFont(.meta).foregroundStyle(Refined.mute)
                            PhoneAskResult(result: d.result, showsFooter: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { d in PhoneRecipeEditor(draft: d).environmentObject(app) }
    }

    private func draft(_ r: AskRecipe) -> RecipeDraft { RecipeDraft(r, schedule: center.schedule(r.id)) }
}

/// New recipe, Save as recipe, and Edit: the question, where it looks, and a weekly time on this iPhone.
struct PhoneRecipeEditor: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State var draft: RecipeDraft
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("What did I say about Website refresh", text: $draft.question, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("recipe.question")
                }
                .listRowBackground(Refined.card)
                Section("Where to look") {
                    Toggle("This week only", isOn: Binding(get: { draft.scope.range == .thisWeek }, set: { draft.scope.range = $0 ? .thisWeek : .allTime }))
                    Picker("Recordings", selection: Binding(get: { draft.scope.source }, set: { draft.scope.source = $0 })) {
                        Text("All").tag(AskScope.Source.all)
                        Text("Thoughts").tag(AskScope.Source.thoughts)
                        Text("Meetings").tag(AskScope.Source.meetings)
                        ForEach(app.store.projects) { p in Text(p.name).tag(AskScope.Source.project(p.id)) }
                    }
                }
                .listRowBackground(Refined.card)
                Section {
                    Toggle("Run every week", isOn: $draft.scheduled)
                    if draft.scheduled {
                        Picker("Day", selection: $draft.weekday) {
                            ForEach(1...7, id: \.self) { d in Text(RecipeSchedule.dayName(d)).tag(d) }
                        }
                        DatePicker("Time", selection: $draft.timeOfDay, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("iOS runs it when it gives Verbose time near then, so it can come later than you set. It also runs the next time you open Verbose. Schedules stay on this iPhone; the recipe syncs with your Mac.")
                }
                .listRowBackground(Refined.card)
                if draft.recipeId != nil {
                    Section {
                        Button("Delete recipe", role: .destructive) { confirmDelete = true }
                    }
                    .listRowBackground(Refined.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Refined.paper.ignoresSafeArea())
            .navigationTitle(draft.recipeId == nil ? "New recipe" : "Edit recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("recipe.save")
                }
            }
            .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete recipe", role: .destructive) { if let id = draft.recipeId { AskRecipeCenter.shared.delete(id) }; dismiss() }
            } message: { Text("Its answers on this iPhone go too.") }
        }
    }

    private func save() {
        let q = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let schedule = draft.scheduled ? RecipeSchedule(weekday: draft.weekday, hour: draft.hour, minute: draft.minute) : nil
        let center = AskRecipeCenter.shared
        if let id = draft.recipeId, var r = app.store.recipes.first(where: { $0.id == id }) {
            r.question = q; r.scope = draft.scope
            center.update(r)
            let old = center.schedule(id)
            let same = old.map { o in schedule.map { o.weekday == $0.weekday && o.hour == $0.hour && o.minute == $0.minute } ?? false } ?? (schedule == nil)
            if !same { center.setSchedule(schedule, for: id) }
        } else {
            _ = center.add(q, scope: draft.scope, schedule: schedule)
        }
        dismiss()
    }
}
