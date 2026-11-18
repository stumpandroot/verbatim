import SwiftUI
import UIKit

// Quick actions (DESIGN.md §6.9; mockup "Verbose quick actions", November 17, 2026): up to three actions under a
// transcript's title, in your order, and Edit quick actions, which chooses them and holds your prompt for an
// assistant. The list and its rules are `QuickActions` (Export/ExportCore.swift, tested by tools/test-export.sh).

/// The shown actions and the prompt, kept on this iPhone.
@MainActor
final class QuickActionsStore: ObservableObject {
    static let shared = QuickActionsStore()
    @Published var shown: [QuickAction] {
        didSet { UserDefaults.standard.set(QuickActions.encode(shown), forKey: QuickActions.key) }
    }
    @Published var prompt: String {
        didSet { UserDefaults.standard.set(prompt, forKey: QuickActions.promptKey) }
    }

    private init() {
        shown = QuickActions.decode(UserDefaults.standard.string(forKey: QuickActions.key))
        prompt = UserDefaults.standard.string(forKey: QuickActions.promptKey) ?? ""
    }
}

extension QuickAction {
    var art: BrandArt {
        switch self {
        case .copyForAI: return .iconCopy
        case .sendToAI, .openInClaude, .openInChatGPT: return .iconShare
        case .export: return .iconExport
        case .copyText: return .iconNotes
        case .copyTimestamps: return .iconRecent
        }
    }

    /// Whether the button says "Copied" for a moment after a tap.
    var copies: Bool { self == .copyForAI || self == .copyText || self == .copyTimestamps }
}

extension PhoneState {
    /// What Copy for AI copies and Send to AI shares: your prompt, when there is one, over the transcript and its header.
    func textForAI(_ t: Transcript) -> String {
        QuickActions.withPrompt(QuickActionsStore.shared.prompt, t.copyForAI)
    }
}

/// The row under a transcript's meta line: the shown actions as the kit's buttons (the first one strong), then Edit.
/// It wraps onto a second line at large text sizes.
struct QuickActionsRow: View {
    @Environment(PhoneState.self) var app
    var transcript: Transcript
    /// The tab's text, for Copy text and Copy with timestamps.
    var copyVersion: Exporter.CopyVersion
    /// Opens the share sheet with these items (the transcript screen owns the sheet).
    var share: ([Any]) -> Void
    @ObservedObject private var store = QuickActionsStore.shared
    @State private var copied: QuickAction? = nil
    @State private var editing = false
    /// This row's place in `rows`.
    @State private var token = UUID()
    /// The rows on screen, by row (a screen being left can disappear after the next one appears), and the last
    /// action run, for the self-test.
    private static var rows: [UUID: [QuickAction]] = [:]
    static var onScreen: [QuickAction] { rows.count == 1 ? rows.values.first ?? [] : [] }
    static var rowsOnScreen: Int { rows.count }
    static var lastRun: QuickAction? = nil

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(Array(store.shown.enumerated()), id: \.element) { i, a in
                Button { run(a) } label: {
                    HStack(spacing: 7) {
                        IconGlyph(art: a.art, size: 18, color: i == 0 ? Refined.paper : Refined.ink)
                            .accessibilityHidden(true)
                        Text(copied == a ? "Copied" : a.title)
                    }
                }
                .buttonStyle(RefinedActionStyle(kind: i == 0 ? .strong : .quiet))
                .accessibilityIdentifier("quickAction.\(a.rawValue)")
            }
            Button { editing = true } label: {
                IconGlyph(art: .iconFeedback, size: 18, color: Refined.ink)
            }
            .buttonStyle(RefinedActionStyle())
            .accessibilityLabel("Edit quick actions")
            .accessibilityIdentifier("quickAction.edit")
        }
        .sheet(isPresented: $editing) {
            NavigationStack { EditQuickActionsView(onDone: { editing = false }) }
                .phoneState(app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimEditQuickActions)) { note in
            editing = (note.object as? Bool) ?? true
        }
        .onAppear { Self.rows[token] = store.shown }
        .onChange(of: store.shown) { _, now in Self.rows[token] = now }
        .onDisappear { Self.rows[token] = nil }
    }

    private func run(_ a: QuickAction) {
        Self.lastRun = a
        switch a {
        case .copyForAI: app.copyForAI(transcript)
        case .sendToAI: share([app.textForAI(transcript)])
        // The Mac's actions (QuickActions.catalog): never stored or offered on iPhone.
        case .openInClaude, .openInChatGPT: break
        case .export: app.exportRequest = ExportRequest(ids: [transcript.id])
        case .copyText: app.copyText(transcript, copyVersion)
        case .copyTimestamps: app.copyText(transcript, copyVersion, timestamps: true)
        }
        guard a.copies else { return }
        copied = a
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copied == a { copied = nil }
        }
    }
}

extension Notification.Name {
    /// Opens (true) or closes (false) Edit quick actions over the transcript; the self-test uses it.
    static let verbatimEditQuickActions = Notification.Name("verbatim.editQuickActions")
}

/// Edit quick actions: the shown actions in a list you drag to reorder, the rest under More actions, and your prompt.
/// Two ways in, as Edit Home has: the row's Edit button presents it in a sheet with Done (`onDone`), and Settings ›
/// Personalization › Transcript quick actions pushes it.
struct EditQuickActionsView: View {
    var onDone: (() -> Void)? = nil
    @ObservedObject private var store = QuickActionsStore.shared
    @Environment(\.limitMotion) private var limitMotion
    /// Whether it's on screen, for the self-test.
    static var visible = false

    var body: some View {
        let shown = store.shown
        let hidden = QuickActions.hidden(shown)
        List {
            Section {
                intro
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            Section {
                RefinedListHeading("Shown")
                ForEach(Array(shown.enumerated()), id: \.element) { i, a in
                    row(a, on: true, canAdd: true, first: i == 0, last: i == shown.count - 1)
                }
                .onMove { from, to in store.shown = QuickActions.moving(shown, from: from, to: to) }
            }
            .listSectionSeparator(.hidden)
            if !hidden.isEmpty {
                Section {
                    RefinedListHeading(QuickActions.canAdd(shown) ? "More actions" : "More actions. Hide one to add another.")
                    ForEach(Array(hidden.enumerated()), id: \.element) { i, a in
                        row(a, on: false, canAdd: QuickActions.canAdd(shown), first: i == 0, last: i == hidden.count - 1)
                    }
                }
                .listSectionSeparator(.hidden)
            }
            Section {
                RefinedListHeading("Prompt for AI")
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Summarize this and list the action items.", text: $store.prompt, axis: .vertical)
                        .refinedFont(.rowTitle).foregroundStyle(Refined.ink).lineLimit(2...6)
                        .accessibilityLabel("Prompt for AI")
                    Text("Goes above the transcript in Copy for AI and Send to AI. Leave it empty to send the transcript alone.")
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 30))
                .listRowBackground(PaperRowBackground(first: true, last: true))
                .listRowSeparator(.hidden)
                .moveDisabled(true)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Quick actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The serif title sits on the page; the bar keeps only Apple's buttons.
            ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            if let onDone {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).fontWeight(.semibold) }
            }
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            LargeSerifTitle(title: "Quick actions")
                .accessibilityAddTraits(.isHeader)
            Text("Up to three actions show under a transcript's title. Drag to reorder.")
                .refinedFont(.body).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8).padding(.bottom, 4)
    }

    private func row(_ a: QuickAction, on: Bool, canAdd: Bool, first: Bool, last: Bool) -> some View {
        HStack(spacing: 12) {
            IconGlyph(art: a.art, size: 20, color: on ? Refined.ink : Refined.dim)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).refinedFont(.rowTitle).foregroundStyle(on ? Refined.ink : Refined.dim).lineLimit(1)
                Text(a.detail).refinedFont(.meta).foregroundStyle(Refined.mute)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button {
                withAnimation(limitMotion ? nil : .snappy(duration: 0.25)) {
                    store.shown = on ? QuickActions.removing(a, from: store.shown) : QuickActions.adding(a, to: store.shown)
                }
            } label: {
                RefinedCheckbox(on: on, size: 22)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!on && !canAdd)
            .accessibilityLabel(on ? "Hide \(a.title)" : "Show \(a.title)")
            .accessibilityHint(!on && !canAdd ? "Three are shown. Hide one to add another." : "")
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 30))
        .listRowBackground(PaperRowBackground(first: first, last: last))
        .listRowSeparator(last ? .hidden : .automatic, edges: .bottom)
        .listRowSeparatorTint(Refined.separator)
        .accessibilityElement(children: .contain)
    }
}
