import SwiftUI
import UIKit

// Ask your library on the iPhone (mockup "Library features", sections 2b and 2c): Library › Ask (from the Library's
// card, or "Ask about …" under the Library's search field), with the question, the scope chips, and the answer with its
// citations above the matching passages; and Ask › Recipes, saved questions you run now or weekly, with their digests.
// A citation opens the transcript at that line and plays it. Built from the iPhone kit, so both looks follow.

struct AskRoute: Hashable { var query: String? = nil }
struct RecipesRoute: Hashable {}
struct RecipeRoute: Hashable { var id: UUID }

/// "Ask about “…”" under the Library's search field, in both looks.
struct AskAboutRow: View {
    var query: String
    @Environment(\.look) private var look
    var body: some View {
        NavigationLink(value: AskRoute(query: query)) {
            HStack(spacing: 10) {
                if look.isNative {
                    Image(systemName: "questionmark.bubble").font(.system(size: 16, weight: .medium)).foregroundStyle(NativeInk.accent)   // brand: native
                } else {
                    IconGlyph(art: .iconAsk, size: 18, color: Ink.ink)
                }
                Text("Ask about \u{201C}\(query)\u{201D}").font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.lookMute)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .modifier(AskCardSurface(radius: Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityIdentifier("library.askAbout")
        .accessibilityHint("Answers from your recordings, with the passages it used")
    }
}

/// A card: an outlined reader card (Verbose) or Premium's soft white card.
struct AskCardSurface: ViewModifier {
    var radius: CGFloat = Radius.row
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.isNative { content.premiumSoftCard(radius: 22) } else { content.phoneOutlined(radius: radius, fill: Ink.reader, line: 1.5) }
    }
}

// MARK: - Ask

struct AskScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var center = AskCenter.shared
    @Environment(\.look) private var look
    var route = AskRoute()
    @State private var query = ""
    @State private var scope = AskScope.all
    @State private var editing: PhoneRecipeDraft? = nil
    @State private var applied = false
    @FocusState private var focused: Bool
    /// What the screen showed last, for the self-test.
    static var shown: AskResult.State? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !look.isNative {
                    VStack(alignment: .leading, spacing: 4) {
                        PhoneEyebrow(text: "Library")
                        Text("Ask").font(Ink.serif(34)).foregroundStyle(.lookInk)
                    }
                    .padding(.top, 4)
                }
                field
                chips
                resultArea
                if let r = center.result, center.phase == .done, r.state == .answered {
                    passages(r)
                }
                NavigationLink(value: RecipesRoute()) {
                    HStack(spacing: 10) {
                        if look.isNative {
                            Image(systemName: "calendar").font(.system(size: 16, weight: .medium)).foregroundStyle(NativeInk.accent)   // brand: native
                        } else {
                            IconGlyph(art: .iconCalendar, size: 18, color: Ink.ink)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Recipes").font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk)
                            Text("Questions you ask again").font(.system(size: 13)).foregroundStyle(.lookMute)
                        }
                        Spacer(minLength: 6)
                        if !app.store.recipes.isEmpty { Text("\(app.store.recipes.count)").lookMono(13).foregroundStyle(.lookMute) }
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.lookMute)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 56)
                    .modifier(AskCardSurface())
                    .contentShape(Rectangle())
                }
                .buttonStyle(PhoneCardPress())
                .accessibilityIdentifier("ask.recipes")
                .padding(.top, 8)
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .phonePage()
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .toolbar {
            if !look.isNative { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let r = center.result, center.phase == .done {
                        Button { UIPasteboard.general.string = r.copyText; app.say("Copied") } label: { Label("Copy", systemImage: "doc.on.doc") }   // brand: system surface (menu)
                        Button { editing = PhoneRecipeDraft(question: r.question, scope: r.scope) } label: { Label("Save as Recipe", systemImage: "bookmark") }   // brand: system surface (menu)
                    }
                    Button { app.pushHere(RecipesRoute()) } label: { Label("Recipes", systemImage: "calendar") }   // brand: system surface (menu)
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

    private var field: some View {
        HStack(alignment: .top, spacing: 10) {
            if look.isNative {
                Image(systemName: "questionmark.bubble").font(.system(size: 17)).foregroundStyle(NativeInk.secondary).padding(.top, 2)   // brand: native
            } else {
                IconGlyph(art: .iconAsk, size: 19, color: Ink.ink).padding(.top, 1)
            }
            TextField("Ask about your recordings", text: $query, axis: .vertical)
                .font(.system(size: 17)).foregroundStyle(.lookInk)
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
        // The pill, as the search field (DESIGN.md §11.9): card white with the 1.5 pt ink outline in Verbose style.
        // 18 pt in from the ends keeps a wrapped question inside the rounded ends.
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background {
            if look.isNative {
                Capsule().fill(NativeInk.fillStrong)
            } else {
                Capsule().fill(Ink.card)
                    .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: focused ? 2 : 1.5))
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", scope.isAll) { scope.tapAll() }
                chip("This week", scope.range == .thisWeek) { scope.tapWeek() }
                chip("Thoughts", scope.source == .thoughts) { scope.tap(.thoughts) }
                chip("Meetings", scope.source == .meetings) { scope.tap(.meetings) }
                ForEach(app.store.projects) { p in chip(p.name, scope.source == .project(p.id)) { scope.tap(.project(p.id)) } }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
        .onChange(of: scope) { _, _ in if center.result != nil, !query.isEmpty { ask() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where to look")
    }

    private func chip(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        PhoneChip(label: look.isNative ? NativeTitleCase.apply(label) : label, selected: on, action: action)
    }

    @ViewBuilder private var resultArea: some View {
        switch center.phase {
        case .idle:
            Text("Ask in plain words, like \u{201C}What did Alex want changed on the homepage?\u{201D} Verbose finds the passages first, then answers on this iPhone.")
                .font(.system(size: 15)).foregroundStyle(.lookDim).fixedSize(horizontal: false, vertical: true)
        case .finding, .answering:
            HStack(spacing: 10) {
                ProgressView()
                Text(center.phase == .finding ? "Finding passages…" : "Answering from the passages…").font(.system(size: 15)).foregroundStyle(.lookDim)
            }
            .padding(.vertical, 8)
        case .done:
            if let r = center.result { PhoneAskResult(result: r) }
        }
    }

    /// The passages the answer read, under it (Verbose style's "matching passages").
    @ViewBuilder private func passages(_ r: AskResult) -> some View {
        let cited = Set((r.answer?.citations ?? []).map(\.segmentId))
        let others = r.found.filter { !cited.contains($0.segmentId) }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if look.isNative {
                    Text("Other passages").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.secondary).padding(.top, 8)
                } else {
                    PhoneDayHeader(text: "Other passages")
                }
                ForEach(others.prefix(6)) { s in PhoneAskPassage(source: s) }
            }
        }
    }
}

/// A result: the answer card with citations and footer, or what was found and why there's no answer.
struct PhoneAskResult: View {
    var result: AskResult
    var showsFooter = true
    @EnvironmentObject var app: PhoneState
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                if !look.isNative { PhoneEyebrow(text: result.state == .answered ? "Answer" : "No answer") }
                if let a = result.answer, result.state == .answered {
                    PhoneAskAnswerText(answer: a)
                    PhoneAskCitations(sources: a.citations)
                } else {
                    Text(result.message(scopeLabel: result.scope.label(projects: Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) }))))
                        .font(.system(size: 15)).foregroundStyle(.lookInk).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ask.message")
                    if !result.found.isEmpty { PhoneAskCitations(sources: result.found) }
                }
                if !look.isNative, showsFooter {
                    HStack(spacing: 6) {
                        IconGlyph(art: .iconPrivacy, size: 13, color: Ink.mute)
                        Text(result.state == .answered ? "Runs on this iPhone with Apple Intelligence." : "Found on this iPhone. Nothing left your device.")
                            .font(.system(size: 13)).foregroundStyle(.lookMute)
                    }
                }
            }
            .padding(16)
            .modifier(AskCardSurface())
            if look.isNative, showsFooter, result.state == .answered {
                Text(result.footer(native: true)).font(.system(size: 13)).foregroundStyle(NativeInk.secondary).padding(.horizontal, 4)
            }
        }
    }
}

/// The answer's paragraphs, bullets, and headings, with citation numbers after each sentence.
struct PhoneAskAnswerText: View {
    var answer: AskAnswer
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(answer.blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h):
                    Text(h).font(look.isNative ? .system(size: 16, weight: .semibold) : Ink.serif(19)).foregroundStyle(.lookInk).accessibilityAddTraits(.isHeader)
                case .paragraph(let s):
                    Text(attributed(s)).font(.system(size: 16)).foregroundStyle(.lookInk).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.lookDim)
                        Text(attributed(s)).font(.system(size: 16)).foregroundStyle(.lookInk).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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
                if look.isNative {
                    m.font = .system(size: 13, weight: .semibold)
                    m.foregroundColor = NativeInk.accent
                    m.backgroundColor = NativeInk.accent.opacity(0.12)
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

/// Citations: Verbose style's neutral chips (number, play, title, time), or Premium's rows with a play pill. A tap opens
/// the transcript at that line and plays it.
struct PhoneAskCitations: View {
    var sources: [AskSource]
    @EnvironmentObject var app: PhoneState
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: look.isNative ? 0 : 8) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { i, s in
                if look.isNative, i > 0 { Divider().padding(.leading, 34) }
                Button { open(s) } label: { if look.isNative { nativeRow(s) } else { chip(s) } }
                    .buttonStyle(SoftPress())
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

    private func chip(_ s: AskSource) -> some View {
        HStack(spacing: 8) {
            Text("\(s.number)").font(Ink.mono(12)).foregroundStyle(Ink.dim)
                .frame(minWidth: 20, minHeight: 20)
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
            ZStack { Circle().fill(Ink.ink); ArtIcon(art: .iconPlay, size: 9, lineWidth: 1.3).foregroundStyle(Ink.paper) }.frame(width: 20, height: 20)
            Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            Text(AskFormat.time(s.start)).font(Ink.mono(12)).foregroundStyle(Ink.dim)
        }
        .padding(.leading, 6).padding(.trailing, 12).frame(minHeight: 36)
        .background(Capsule().fill(Ink.card))
        .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }

    // brand: native begin
    private func nativeRow(_ s: AskSource) -> some View {
        let parts = s.title.components(separatedBy: " · ")
        return HStack(spacing: 12) {
            Text("\(s.number)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(NativeInk.accent)
                .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(NativeInk.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.first ?? s.title).font(.system(size: 16)).foregroundStyle(NativeInk.label).lineLimit(1)
                if parts.count > 1 { Text(parts.dropFirst().joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(NativeInk.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 9))
                Text(AskFormat.time(s.start)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(NativeInk.label)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(NativeInk.fill))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    // brand: native end
}

/// A passage the answer didn't cite: its recording, time, and words.
struct PhoneAskPassage: View {
    var source: AskSource
    @EnvironmentObject var app: PhoneState
    var body: some View {
        Button { app.autoplay = source.transcriptId; app.open(source.transcriptId, segment: source.segmentId) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(source.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(AskFormat.time(source.start)).lookMono(12).foregroundStyle(.lookMute)
                }
                Text(source.text).font(.system(size: 15)).foregroundStyle(.lookDim).lineLimit(3).multilineTextAlignment(.leading)
            }
            .padding(14)
            .cardSurface(radius: Radius.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityHint("Opens the transcript at \(AskFormat.time(source.start))")
    }
}

/// Native's chip names are title case ("This Week", "Website Refresh").
enum NativeTitleCase {
    static func apply(_ s: String) -> String {
        s.split(separator: " ").map { w in
            let lower = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "by"]
            return lower.contains(w.lowercased()) ? String(w) : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: - Recipes

struct RecipesScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var center = AskRecipeCenter.shared
    @State private var editing: PhoneRecipeDraft? = nil
    static var shown: Int? = nil

    var body: some View {
        let recipes = app.store.recipes
        let scheduled = recipes.filter { center.schedule($0.id) != nil }
        let anytime = recipes.filter { center.schedule($0.id) == nil }
        SettingsPageScaffold(title: "Recipes") {
            Text("Questions you ask again. Run one now, or schedule it weekly on this iPhone.")
                .font(.system(size: 15)).foregroundStyle(.lookDim).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            if recipes.isEmpty {
                SettingsPageGroup(title: "Try one", footer: "Tap one to save it. You can change the question, where it looks, and when it runs.", first: true) {
                    ForEach(Array(RecipeSuggestions.all(projects: app.store.projects.map { ($0.id, $0.name) }).enumerated()), id: \.offset) { i, s in
                        if i > 0 { SettingsDivider() }
                        Button {
                            let sched = s.schedule.map { RecipeSchedule(weekday: $0.weekday, hour: $0.hour, minute: $0.minute) }
                            _ = center.add(s.question, scope: s.scope, schedule: sched)
                        } label: {
                            SettingsRow(icon: s.schedule == nil ? "questionmark.bubble" : "calendar", tint: Ink.neutralChip, art: s.schedule == nil ? .iconAsk : .iconCalendar,
                                        title: s.question, subtitle: subtitle(s.scope, s.schedule.map { RecipeSchedule(weekday: $0.weekday, hour: $0.hour, minute: $0.minute) })) {
                                Image(systemName: "plus.circle").foregroundStyle(.lookAccentText)
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
                                .font(.system(size: 13)).foregroundStyle(.lookMute)
                            Text(r.question).font(.system(size: 17, weight: .semibold)).foregroundStyle(.lookInk)
                            if let a = d.result.answer {
                                Text(a.firstSentence).font(.system(size: 15)).foregroundStyle(.lookDim).lineLimit(2).multilineTextAlignment(.leading)
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
                Button { editing = PhoneRecipeDraft(question: "", scope: .all) } label: { Image(systemName: "plus") }
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
                SettingsRow(icon: center.schedule(r.id) == nil ? "questionmark.bubble" : "calendar", tint: Ink.neutralChip,
                            art: center.schedule(r.id) == nil ? .iconAsk : .iconCalendar, title: r.question,
                            subtitle: subtitle(r.scope, center.schedule(r.id)), subtitleLines: 1) {
                    if center.running.contains(r.id) {
                        ProgressView()
                    } else {
                        Button("Run") { center.run(r) }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.lookAccentText)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(.lookCard))
                            .buttonStyle(.plain)
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
    @State private var editing: PhoneRecipeDraft? = nil
    @Environment(\.look) private var look

    var body: some View {
        if let r = app.store.recipes.first(where: { $0.id == id }) {
            content(r)
        } else {
            Text("This recipe was deleted.").foregroundStyle(.lookMute).frame(maxWidth: .infinity, maxHeight: .infinity).phonePage()
        }
    }

    private func content(_ r: AskRecipe) -> some View {
        let names = Dictionary(uniqueKeysWithValues: app.store.projects.map { ($0.id, $0.name) })
        let digests = center.digests.filter { $0.recipeId == r.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    PhoneEyebrow(text: [center.schedule(r.id)?.label, r.scope.label(projects: names)].compactMap { $0 }.joined(separator: " · "))
                    Text(r.question).lookSerif(28).foregroundStyle(.lookInk).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                HStack(spacing: 10) {
                    Button { center.run(r) } label: {
                        Text(center.running.contains(r.id) ? "Running…" : "Run now").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(look.isNative ? PremiumInk.onAccent : Ink.paper)
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(Capsule().fill(look.isNative ? NativeInk.accent : Ink.ink))
                    }
                    .buttonStyle(PhoneCardPress()).disabled(center.running.contains(r.id))
                    .accessibilityIdentifier("recipe.run")
                    Button { editing = draft(r) } label: {
                        Text(center.schedule(r.id) == nil ? "Schedule" : "Edit").font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk)
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(Capsule().strokeBorder(look.isNative ? NativeInk.separator : Ink.ink, lineWidth: 1.5))
                    }
                    .buttonStyle(PhoneCardPress())
                }
                if let d = digests.first {
                    Text(d.ranAt.formatted(date: .abbreviated, time: .shortened) + (d.scheduled ? " · Ran on schedule" : " · Ran now"))
                        .lookMono(12).foregroundStyle(.lookMute).padding(.top, 6)
                    PhoneAskResult(result: d.result)
                } else if center.running.contains(r.id) {
                    HStack(spacing: 10) { ProgressView(); Text("Finding passages and answering…").font(.system(size: 15)).foregroundStyle(.lookDim) }
                } else {
                    Text("No answer yet. Tap Run now, or Schedule to run it every week on this iPhone.").font(.system(size: 15)).foregroundStyle(.lookDim)
                }
                if digests.count > 1 {
                    PhoneDayHeader(text: "Earlier").padding(.top, 8)
                    ForEach(digests.dropFirst()) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.ranAt.formatted(date: .abbreviated, time: .shortened)).lookMono(12).foregroundStyle(.lookMute)
                            PhoneAskResult(result: d.result, showsFooter: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .phonePage()
        .navigationTitle(look.isNative ? "Recipe" : "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { d in PhoneRecipeEditor(draft: d).environmentObject(app) }
    }

    private func draft(_ r: AskRecipe) -> PhoneRecipeDraft {
        var d = PhoneRecipeDraft(recipeId: r.id, question: r.question, scope: r.scope)
        if let s = center.schedule(r.id) { d.scheduled = true; d.weekday = s.weekday; d.hour = s.hour; d.minute = s.minute }
        return d
    }
}

struct PhoneRecipeDraft: Identifiable {
    let id = UUID()
    var recipeId: UUID? = nil
    var question: String
    var scope: AskScope
    var scheduled = false
    var weekday = 6
    var hour = 16
    var minute = 0
}

/// New recipe, Save as recipe, and Edit: the question, where it looks, and a weekly time on this iPhone.
struct PhoneRecipeEditor: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State var draft: PhoneRecipeDraft
    @State private var confirmDelete = false

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date() },
                set: { d in draft.hour = Calendar.current.component(.hour, from: d); draft.minute = Calendar.current.component(.minute, from: d) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("What did I say about Website refresh", text: $draft.question, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("recipe.question")
                }
                Section("Where to look") {
                    Toggle("This week only", isOn: Binding(get: { draft.scope.range == .thisWeek }, set: { draft.scope.range = $0 ? .thisWeek : .allTime }))
                    Picker("Recordings", selection: Binding(get: { draft.scope.source }, set: { draft.scope.source = $0 })) {
                        Text("All").tag(AskScope.Source.all)
                        Text("Thoughts").tag(AskScope.Source.thoughts)
                        Text("Meetings").tag(AskScope.Source.meetings)
                        ForEach(app.store.projects) { p in Text(p.name).tag(AskScope.Source.project(p.id)) }
                    }
                }
                Section {
                    Toggle("Run every week", isOn: $draft.scheduled)
                    if draft.scheduled {
                        Picker("Day", selection: $draft.weekday) {
                            ForEach(1...7, id: \.self) { d in Text(RecipeSchedule.dayName(d)).tag(d) }
                        }
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("iOS runs it when it gives Verbose time near then, so it can come later than you set. It also runs the next time you open Verbose. Schedules stay on this iPhone; the recipe syncs with your Mac.")
                }
                if draft.recipeId != nil {
                    Section {
                        Button("Delete recipe", role: .destructive) { confirmDelete = true }
                    }
                }
            }
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
