import SwiftUI
import AppKit

// brand: web style
//
// Make › Templates in the main window (mockup "Library features", sections 1a to 1c): the template library with
// filters, a template's sections and Run automatically chips beside it, the editor for your own, and Run automatically
// (one template or Off per kind, and three options). Built from the website-style kit (WebStyle.swift), which draws
// Premium Native too; the Native library is a grid of white cards (§13.2).

enum TemplatesPane: String { case library, auto }

/// The library's chips: All, one origin, or the ones that run automatically.
enum TemplateFilter: Hashable { case all, origin(TemplateOrigin), auto }

/// The Templates screen's state, kept across visits.
@MainActor
final class TemplatesNav: ObservableObject {
    static let shared = TemplatesNav()
    @Published var pane: TemplatesPane = .library
    @Published var filter: TemplateFilter = .all
    @Published var selected: UUID? = nil
    /// The template being edited: a new one, a copy, or one of yours.
    @Published var editing: TranscriptTemplate? = nil
    @Published var editingIsNew = false
    /// Try on a recording: the template and the recording.
    @Published var tryOn: TemplateTryOn? = nil

    func newTemplate() { editingIsNew = true; editing = TemplateLibrary.blank() }
    func duplicate(_ t: TranscriptTemplate) { editingIsNew = true; editing = TemplateLibrary.duplicate(t) }
    func edit(_ t: TranscriptTemplate) { editingIsNew = false; editing = t }
}

struct TemplateTryOn: Identifiable {
    let id = UUID()
    var template: TranscriptTemplate
    var transcript: UUID
}

/// Ready recordings to try a template on, newest first.
@MainActor
enum TemplateTryOnList {
    static func recent(_ store: Store, limit: Int = 12) -> [Transcript] {
        Array(store.live.filter { $0.status == .ready && !$0.isDictation && !$0.segments.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}

struct TemplatesView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = TemplatesNav.shared

    var body: some View {
        LookSwitch.mark("templates")
        return Group {
            switch nav.pane {
            case .library: TemplateLibraryPane()
            case .auto: RunAutomaticallyPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $nav.editing) { t in TemplateEditorSheet(draft: t, isNew: nav.editingIsNew).environmentObject(app) }
        .sheet(item: $nav.tryOn) { x in TemplateTryOnSheet(template: x.template, transcriptID: x.transcript).environmentObject(app) }
    }
}

/// A template card's surface: the reader card with an ink outline and a small hard shadow, or Premium's white card.
struct TemplateCardSurface: ViewModifier {
    var selected = false
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look == .native {
            // The selected card takes a neutral outline: the accent stays on the selected filter (review M-34).
            content.nativeGroup()
                .overlay { if selected { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.32), lineWidth: 1.5) } }
        } else {
            content
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                .inkEdge(outline: true, shadow: InkEdge.row, radius: Radius.record)
        }
    }
}

// MARK: - Library

struct TemplateLibraryPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = TemplatesNav.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @Environment(\.look) private var look

    var body: some View {
        let all = app.store.allTemplates
        let settings = auto.settings.pruned(existing: Set(all.map(\.id)))
        let shown = filtered(all, settings)
        let selected = shown.first { $0.id == nav.selected } ?? shown.first
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Templates", count: "\(all.count) templates",
                          lede: "Turn a transcript into notes, a plan, or a draft. Pick one per kind to run when a recording finishes. For text you select in any app, use Actions in Settings.") {
                    HStack(spacing: 8) {
                        TemplatesPaneSwitch()
                        PillButton(title: "New template", kind: .dark, size: .mini, icon: .webPlus) { nav.newTemplate() }
                            .uiTarget("templates-new")
                    }
                }
                chips(all, settings)
                HStack(alignment: .top, spacing: 22) {
                    Group {
                        if look == .native { grid(shown, settings, selected: selected?.id) } else { list(shown, settings, selected: selected?.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    if let selected {
                        TemplateDetailCard(template: selected)
                            .frame(width: 340)
                            .id(selected.id)
                    }
                }
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 1180, alignment: .leading)
        }
    }

    private func filtered(_ all: [TranscriptTemplate], _ s: AutoRunSettings) -> [TranscriptTemplate] {
        switch nav.filter {
        case .all: return all
        case .origin(let o): return TemplateLibrary.filtered(all, origin: o, autoOnly: false, settings: s)
        case .auto: return TemplateLibrary.filtered(all, origin: nil, autoOnly: true, settings: s)
        }
    }

    private func chips(_ all: [TranscriptTemplate], _ s: AutoRunSettings) -> some View {
        let autoCount = all.filter { !s.kinds(for: $0.id).isEmpty }.count
        return HStack(spacing: 6) {
            FilterChip(title: "All", count: all.count, selected: nav.filter == .all) { nav.filter = .all }
            ForEach([TemplateOrigin.builtIn, .scenario, .yours]) { o in
                FilterChip(title: o.title, count: all.filter { $0.origin == o }.count, selected: nav.filter == .origin(o)) { nav.filter = .origin(o) }
                    .uiTarget("templates-filter-\(o.rawValue)")
            }
            FilterChip(title: "Runs automatically", count: autoCount, selected: nav.filter == .auto) { nav.filter = .auto }
        }
    }

    /// Verbose: flat rows under "Scenarios · 8" headers.
    private func list(_ shown: [TranscriptTemplate], _ s: AutoRunSettings, selected: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(TemplateOrigin.allCases) { o in
                let items = shown.filter { $0.origin == o }
                if !items.isEmpty {
                    DayHeader(text: "\(o.title) · \(items.count)").padding(.top, o == TemplateOrigin.allCases.first ? 0 : 14).padding(.bottom, 2)
                    ForEach(items) { t in row(t, s, selected: t.id == selected) }
                }
            }
            if shown.isEmpty {
                Text("No templates here yet. Choose New template to make your own.").font(.system(size: 13.5)).foregroundStyle(Ink.dim).padding(.vertical, 12)
            }
        }
    }

    private func row(_ t: TranscriptTemplate, _ s: AutoRunSettings, selected: Bool) -> some View {
        let parts = TemplateTitle.split(t.name)
        let kinds = s.kinds(for: t.id)
        return FlatRowButton(selected: selected, action: { nav.selected = t.id }) { _ in
            HStack(spacing: 14) {
                IconGlyph(art: t.art, size: 17, color: Ink.ink)
                    .frame(width: 34, height: 34)
                    .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                // The auto state goes in the meta line, so the name has the whole row (review M-31).
                VStack(alignment: .leading, spacing: 2) {
                    WebText.serif(parts.0, italic: parts.1, size: 19).foregroundStyle(Ink.ink).lineLimit(1)
                    Text(TemplateAutoBadge.metaLine(summary: TemplateLibrary.summaryLine(t), kinds: kinds))
                        .font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .accessibilityLabel(t.name + (kinds.isEmpty ? "" : ", runs automatically for " + kinds.map(\.label).joined(separator: ", ")))
        .uiTarget("template-row-\(t.id.uuidString.prefix(8))")
    }

    // brand: native begin
    /// Premium Native: white cards with the symbol in the accent, three to a row, under plain headers.
    private func grid(_ shown: [TranscriptTemplate], _ s: AutoRunSettings, selected: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(TemplateOrigin.allCases) { o in
                let items = shown.filter { $0.origin == o }
                if !items.isEmpty {
                    Text(o.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, o == TemplateOrigin.allCases.first ? 0 : 10)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(items) { t in card(t, s, selected: t.id == selected) }
                    }
                }
            }
        }
    }

    private func card(_ t: TranscriptTemplate, _ s: AutoRunSettings, selected: Bool) -> some View {
        let kinds = s.kinds(for: t.id)
        return Button { nav.selected = t.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                // The accent symbol sits bare (no tinted circle, DESIGN.md §13.2).
                Image(systemName: t.nativeSymbol).font(.system(size: 17)).foregroundStyle(NativeInk.accent)
                    .frame(width: 24, height: 24, alignment: .leading)
                    .padding(.bottom, 4)
                Text(t.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(TemplateLibrary.summaryLine(t)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !kinds.isEmpty {
                    Label("Runs for " + kinds.map(\.label).joined(separator: ", "), systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .contentShape(Rectangle())
            .modifier(TemplateCardSurface(selected: selected))
        }
        .buttonStyle(.plain)
        .uiTarget("template-row-\(t.id.uuidString.prefix(8))")
    }
    // brand: native end
}

/// "↻ Auto · Meeting": a template that runs automatically for some kinds.
struct TemplateAutoBadge: View {
    /// A list row's meta line: "Runs for Meeting · Decisions, next steps" (the kinds first), or the summary alone.
    static func metaLine(summary: String, kinds: [RecordingKind]) -> String {
        guard !kinds.isEmpty else { return summary }
        let runs = "Runs for " + kinds.map(\.label).joined(separator: ", ")
        return summary.isEmpty ? runs : runs + " · " + summary
    }

    var kinds: [RecordingKind]
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            Text("Auto · " + kinds.map(\.label).joined(separator: ", ")).lineLimit(1)
        }
        .font(.system(size: 12)).foregroundStyle(Ink.mute)
    }
}

// MARK: - Detail

/// A template beside the library: its eyebrow, name, description, sections, the kinds it runs for automatically, Try on
/// a recording, and Duplicate and edit (or Edit, Duplicate, and Delete for yours).
struct TemplateDetailCard: View {
    @EnvironmentObject var app: AppState
    var template: TranscriptTemplate
    @ObservedObject private var nav = TemplatesNav.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @State private var confirmDelete = false
    @Environment(\.look) private var look

    var body: some View {
        let parts = TemplateTitle.split(template.name)
        let kinds = template.kinds.isEmpty ? AutoRunSettings.kinds : template.kinds
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: template.origin.eyebrow)
                WebText.serif(parts.0, italic: parts.1, size: 28).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(TemplateLibrary.summaryLine(template)).font(.system(size: 13)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Sections").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute).padding(.bottom, 4)
                ForEach(Array(template.sections.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", i + 1)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                        Text(s.name).font(.system(size: 13)).foregroundStyle(Ink.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(s.format.title).font(.system(size: 12)).foregroundStyle(Ink.dim)
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Runs automatically for").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                // Kinds are neutral: in Native a chosen kind is a neutral capsule with a check, so the accent stays on the
                // selected filter (review M-34).
                FlowRow(spacing: 6, lineSpacing: 6) {
                    ForEach(kinds) { k in
                        FilterChip(title: k.label, selected: auto.settings.template(for: k) == template.id, small: true, neutral: true) {
                            auto.toggle(template.id, for: k)
                        }
                        .uiTarget("template-kind-\(k.rawValue)")
                    }
                }
                Text("A kind runs one template. Choosing it here replaces the one it had.").font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TemplateTryOnMenu(template: template)
                // Native keeps one prominent button on the screen (New Template); these are bordered there.
                let main: PillKind = look == .native ? .line : .dark
                if template.isEditable {
                    PillButton(title: "Edit", kind: main, size: .mini) { nav.edit(template) }.uiTarget("template-edit")
                    PillButton(title: "Duplicate", kind: .line, size: .mini) { nav.duplicate(template) }
                } else {
                    PillButton(title: "Duplicate and edit", kind: main, size: .mini) { nav.duplicate(template) }.uiTarget("template-duplicate")
                }
            }
            if template.isEditable {
                Button("Delete template…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.danger)
            }
            HStack(alignment: .top, spacing: 7) {
                IconGlyph(art: .iconPrivacy, size: 14, color: Ink.mute)
                Text(TemplateCopy.onDevice("Mac")).font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TemplateCardSurface())
        .confirmationDialog("Delete \u{201C}\(template.name)\u{201D}?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let id = template.id
                nav.selected = nil
                auto.removed(id)
                DispatchQueue.main.async { app.store.templates.removeAll { $0.id == id } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Results it already wrote stay in their transcripts. Kinds that ran it turn Off.") }
    }
}

/// Try on a recording: a menu of recent recordings; the result shows in a sheet and nothing is saved.
struct TemplateTryOnMenu: View {
    @EnvironmentObject var app: AppState
    var template: TranscriptTemplate
    var title = "Try on a recording"
    var onPick: ((UUID) -> Void)? = nil
    @ObservedObject private var nav = TemplatesNav.shared

    var body: some View {
        let recent = TemplateTryOnList.recent(app.store)
        Menu {
            if recent.isEmpty { Text("No recordings yet") }
            ForEach(recent) { t in
                Button(t.title) {
                    if let onPick { onPick(t.id) } else { nav.tryOn = TemplateTryOn(template: template, transcript: t.id) }
                }
            }
        } label: {
            PillLabel(title: title, kind: .line, size: .mini, trailing: .chevron)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title)
    }
}

/// Library | Run automatically: the shared view switch (DESIGN.md §11.15), the same on both panes.
private struct TemplatesPaneSwitch: View {
    @ObservedObject private var nav = TemplatesNav.shared
    var body: some View {
        SegmentedCapsule(label: "Templates view", options: [TemplatesPane.library, .auto], selection: $nav.pane,
                         title: { $0 == .library ? "Library" : "Run automatically" }, small: true,
                         target: { $0 == .library ? "templates-library" : "templates-auto" })
    }
}

// MARK: - Run automatically

struct RunAutomaticallyPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = TemplatesNav.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @Environment(\.look) private var look

    var body: some View {
        let all = app.store.allTemplates
        let settings = auto.settings.pruned(existing: Set(all.map(\.id)))
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Run", italic: "automatically", count: "\(settings.assignedCount) of \(AutoRunSettings.kinds.count) kinds",
                          lede: "When a recording of a kind finishes, its template runs after the transcript and summary.") {
                    TemplatesPaneSwitch()
                }
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Kind").frame(width: 190, alignment: .leading)
                        Text("Template").frame(width: 230, alignment: .leading)
                        Text("This month")
                        Spacer(minLength: 0)
                    }
                    .font(Ink.mono(12)).foregroundStyle(Ink.mute)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
                    .accessibilityHidden(true)
                    ForEach(AutoRunSettings.kinds) { k in kindRow(k, all, settings) }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .modifier(TemplateCardSurface())
                HStack(spacing: 12) {
                    option("Skip short recordings", "Under 2 minutes", $auto.settings.skipShort, target: "auto-skip")
                    option("Show the result first", "Open transcripts on it", $auto.settings.showFirst, target: "auto-first")
                    option("Notify me when it's done", "For recordings over 20 minutes", $auto.settings.notify, target: "auto-notify")
                }
                HStack(spacing: 7) {
                    IconGlyph(art: .iconPrivacy, size: 14, color: Ink.mute)
                    Text(TemplateCopy.onDevice("Mac") + " Your iPhone keeps its own choices; the results sync with the library.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                }
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    private func kindRow(_ k: RecordingKind, _ all: [TranscriptTemplate], _ s: AutoRunSettings) -> some View {
        let assigned = s.template(for: k)
        let note = AutoRunRules.monthNote(AutoRunRules.runsThisMonth(app.store.live, kind: k), kind: k, assigned: assigned != nil)
        let suggested = all.filter { $0.kinds.contains(k) }
        let others = all.filter { !$0.kinds.contains(k) }
        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                kindIcon(k)
                Text(k.label).font(.system(size: 13.5)).foregroundStyle(Ink.ink)
            }
            .frame(width: 190, alignment: .leading)
            Picker("Template for \(k.label)", selection: Binding<UUID?>(get: { assigned }, set: { auto.set($0, for: k) })) {
                Text("Off").tag(UUID?.none)
                Divider()
                ForEach(suggested) { t in Text(t.name).tag(UUID?.some(t.id)) }
                if !suggested.isEmpty && !others.isEmpty { Divider() }
                ForEach(others) { t in Text(t.name).tag(UUID?.some(t.id)) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .frame(width: 230, alignment: .leading)
            .uiTarget("auto-kind-\(k.rawValue)")
            Text(note).font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }

    @ViewBuilder private func kindIcon(_ k: RecordingKind) -> some View {
        if look == .native {
            Image(systemName: k.nativeSymbol).font(.system(size: 13)).foregroundStyle(NativeInk.accent).frame(width: 24, height: 24)   // brand: native
        } else {
            IconGlyph(art: k.art, size: 18, color: Ink.ink)
                .frame(width: 28, height: 28)
                .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
    }

    private func option(_ title: String, _ detail: String, _ on: Binding<Bool>, target: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Ink.mute)
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: on).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .uiTarget(target)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .modifier(TemplateCardSurface())
    }
}

// MARK: - Editor

/// New template, Duplicate and edit, or Edit: the name, the kinds it suits, what it should write (the no-add rule is
/// added for you), its sections in order with a format each, and Try on a recording before you save.
struct TemplateEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TranscriptTemplate
    var isNew: Bool
    @State private var problem: String? = nil
    @State private var tryOn: TemplateTryOn? = nil

    init(draft: TranscriptTemplate, isNew: Bool) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The fields scroll when the sheet would be taller than the window, so the footer always shows.
            ViewThatFits(in: .vertical) {
                fields
                ScrollView { fields.padding(.trailing, 10) }
            }
            Rectangle().fill(Ink.hairline).frame(height: 1)
            HStack(spacing: 10) {
                IconGlyph(art: .iconPrivacy, size: 14, color: Ink.mute)
                // The one on-device promise, in SF Pro 12.5 dim (DESIGN.md §8, M-65).
                Text(TemplateCopy.onDevice("Mac")).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // macOS order (review M-32): Try on at the left; Cancel and Save, the default action, at the right.
            HStack(spacing: 8) {
                TemplateTryOnMenu(template: draft, title: "Try on", onPick: { tryOn = TemplateTryOn(template: draft, transcript: $0) })
                Spacer(minLength: 8)
                if let problem { Text(problem).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.danger).lineLimit(2) }
                PillButton(title: "Cancel", kind: .line, size: .regular) { dismiss() }
                PillButton(title: "Save", kind: .dark, size: .regular) { save() }.uiTarget("editor-save")
            }
            .background {
                // Return saves and Escape cancels, as a sheet's default and cancel buttons do.
                ZStack {
                    Button("") { save() }.keyboardShortcut(.defaultAction)
                    Button("") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 20)
        .frame(width: 660)
        .frame(maxHeight: TemplateEditorSheet.maxHeight(window: app.mainWindow?.contentLayoutRect.height))
        .background(Ink.paper)
        .sheet(item: $tryOn) { x in TemplateTryOnSheet(template: x.template, transcriptID: x.transcript).environmentObject(app) }
    }

    /// The window's content height less 80, so the sheet never runs past the window (no window: no cap).
    static func maxHeight(window: CGFloat?) -> CGFloat {
        guard let window, window > 0 else { return .infinity }
        return max(360, window - 80)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Yours")
                WebText.serif(isNew ? "New" : "Edit", italic: "template", size: 30).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    label("Name")
                    TextField("Website client call", text: $draft.name).textFieldStyle(.roundedBorder).font(.system(size: 13.5))
                        .uiTarget("editor-name")
                }
                .frame(width: 260)
                VStack(alignment: .leading, spacing: 6) {
                    label("Use it for")
                    FlowRow(spacing: 6, lineSpacing: 6) {
                        ForEach(AutoRunSettings.kinds) { k in
                            FilterChip(title: k.label, selected: draft.kinds.contains(k), small: true) {
                                if let i = draft.kinds.firstIndex(of: k) { draft.kinds.remove(at: i) } else { draft.kinds.append(k) }
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                label("What should it write?")
                TextEditor(text: $draft.instructions)
                    .font(.system(size: 13.5)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 88)
                    .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.outlineStrong, lineWidth: 1))
                    .accessibilityLabel("What should it write")
                Text(TemplateCopy.ruleNote).font(.system(size: 11.5)).foregroundStyle(Ink.mute)
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Sections")
                VStack(spacing: 0) {
                    ForEach(Array(draft.sections.enumerated()), id: \.element.id) { i, s in sectionRow(i, s) }
                }
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
                // An ink text link (TextLink, M-61): adding a section has nothing to do with recording, so it's never persimmon.
                TextLink(title: "Add a section", glyph: .plus) { draft.sections.append(TemplateSection("", .bullets)) }
                    .uiTarget("editor-add-section")
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.ink)
    }

    private func sectionRow(_ i: Int, _ s: TemplateSection) -> some View {
        let id = s.id
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.mute).accessibilityHidden(true)
            TextField("Section name", text: Binding(get: { draft.sections.first { $0.id == id }?.name ?? "" },
                                                    set: { v in if let j = draft.sections.firstIndex(where: { $0.id == id }) { draft.sections[j].name = v } }))
                .textFieldStyle(.plain).font(.system(size: 13.5))
            Picker("Format", selection: Binding(get: { draft.sections.first { $0.id == id }?.format ?? .bullets },
                                                set: { v in if let j = draft.sections.firstIndex(where: { $0.id == id }) { draft.sections[j].format = v } })) {
                ForEach(TemplateSectionFormat.allCases) { f in Text(f.title).tag(f) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button { move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(i == 0).help("Move up").accessibilityLabel("Move \(s.name) up")
            Button { move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(i == draft.sections.count - 1).help("Move down").accessibilityLabel("Move \(s.name) down")
            Button {
                // After the row's fields let go of their bindings, or AppKit can read a removed index.
                DispatchQueue.main.async { draft.sections.removeAll { $0.id == id } }
            } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.borderless).help("Remove this section").accessibilityLabel("Remove \(s.name)")
        }
        .padding(.horizontal, 12).frame(height: 40)
        .overlay(alignment: .bottom) { if i < draft.sections.count - 1 { Rectangle().fill(Ink.hairline).frame(height: 1) } }
    }

    private func move(_ id: UUID, by d: Int) {
        guard let i = draft.sections.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard draft.sections.indices.contains(j) else { return }
        DispatchQueue.main.async { draft.sections.swapAt(i, j) }
    }

    private func save() {
        var t = draft
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.instructions = t.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in t.sections.indices { t.sections[i].name = t.sections[i].name.trimmingCharacters(in: .whitespaces) }
        if let p = TemplateLibrary.problem(t) { problem = p; return }
        if let i = app.store.templates.firstIndex(where: { $0.id == t.id }) { app.store.templates[i] = t } else { app.store.templates.append(t) }
        TemplatesNav.shared.selected = t.id
        TemplatesNav.shared.filter = .all
        app.toast = Toast(isNew ? "Saved \u{201C}\(t.name)\u{201D}" : "Template saved")
        dismiss()
    }
}

// MARK: - Try on

/// A template's result on one recording, made on this Mac and never saved: copy it, or close.
struct TemplateTryOnSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var template: TranscriptTemplate
    var transcriptID: UUID
    @StateObject private var preview = TemplatePreview()

    var body: some View {
        let t = app.store.transcript(transcriptID)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Try on")
                WebText.serif(template.name.isEmpty ? "Untitled" : template.name, size: 24).foregroundStyle(Ink.ink)
                Text("On \u{201C}\(t?.title ?? "a recording")\u{201D}. Nothing is saved.").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
            Group {
                switch preview.phase {
                case .running:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(preview.part.isEmpty ? "Working on your Mac…" : preview.part).font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    ScrollView {
                        TemplateResultBody(text: preview.text, heading: Ink.serif(18), textFont: .system(size: 13.5),
                                           ink: AnyShapeStyle(Ink.ink), dim: AnyShapeStyle(Ink.mute))
                            .padding(14)
                    }
                    .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
                case .failed:
                    VStack(spacing: 6) {
                        Text("Couldn't run this template").font(Ink.serif(18)).foregroundStyle(Ink.ink)
                        Text(preview.failure ?? "Apple's on-device model didn't answer. Try again.")
                            .font(.system(size: 13)).foregroundStyle(Ink.mute).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if preview.phase == .done {
                Text(TemplateCopy.footer(madeOn: "Mac", here: "Mac")).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: "Close", kind: .line, size: .mini) { preview.stop(); dismiss() }
                if preview.phase != .running, let t { PillButton(title: "Try again", kind: .line, size: .mini) { preview.start(template, on: t) } }
                if preview.phase == .done {
                    PillButton(title: "Copy", kind: .dark, size: .mini) { Paster.copy(preview.text); app.toast = Toast("Copied") }
                }
            }
        }
        .padding(22)
        .frame(width: 600, height: 520)
        .background(Ink.paper)
        .onAppear { if let t { preview.start(template, on: t) } }
        .onDisappear { preview.stop() }
    }
}
