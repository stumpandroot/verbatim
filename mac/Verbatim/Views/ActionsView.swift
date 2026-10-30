import SwiftUI

/// A saved action's glyph (DESIGN.md §3): its BrandArt in place of the SF Symbol name it's saved with, so stored
/// actions and older builds keep reading the same `symbol`. Menus, a system surface, still show the symbol.
extension FlowAction {
    var art: BrandArt {
        switch symbol {
        case "envelope": return .iconMail
        case "checklist", "list.bullet.clipboard": return .iconChecklist
        case "doc.text": return .iconTerms
        case "list.bullet": return .iconBullets
        case "arrow.down.right.and.arrow.up.left": return .iconTighten
        case "globe": return .iconLanguage
        case "film": return .iconFilm
        case "book.closed": return .iconNotes
        case "square.and.pencil": return .iconFeedback
        case "graduationcap": return .iconStudy
        case "text.quote": return .iconQuote
        default: return .iconAI   // sparkles, wand.and.stars, and actions you add
        }
    }
}

/// The saved actions as menu items, with a way to edit them. On a transcript (`transcript`), Plan my day and Daily
/// reflection run as the templates they are, so the result is a template result (a plan with Send to Reminders).
struct ActionsMenuItems: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var settings = FlowSettings.shared
    var transcript: UUID? = nil
    var pick: (FlowAction) -> Void
    var body: some View {
        ForEach(settings.actions) { a in
            Button {
                if let id = transcript, TemplateLibrary.scenarioIDs.contains(a.id) { TemplateCenter.shared.run(a.id, on: id, store: app.store) }
                else { pick(a) }
            } label: { Label(a.name, systemImage: a.symbol) }   // brand: system surface (context menu)
        }
        Divider()
        Button("Edit in Templates…") { app.dictation.openTemplates(text: true) }
    }
}

/// Runs a saved action on text inside Verbatim and shows the result before anything is kept.
/// Nothing changes until you copy it or save it as a note, so closing the sheet is the undo.
/// With `transcript`, a transcript action (TranscriptActions) runs on that transcript's Original text with
/// corrections, with the relaxed-guardrails retry; other actions run on `source` through FlowCleanup.
struct ActionSheet: View {
    let action: FlowAction
    let source: String
    let sourceLabel: String
    var transcript: Transcript? = nil
    /// The mark on the result, so it never reads as the transcript.
    var aiLabel: String = "Made by Apple Intelligence"
    var saveNote: ((String) -> Void)? = nil

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var result = ""
    @State private var state: Phase = .running
    @State private var part = ""
    @State private var runID = 0
    @State private var job: Task<Void, Never>? = nil
    @State private var failure: String? = nil
    @State private var skipped = ""

    enum Phase { case running, done, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Actions are neutral (DESIGN.md §1): an ink glyph on a neutral square; persimmon means Record.
                IconSquare(art: action.art, hue: .neutral)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.name).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                    Text("On \(sourceLabel) · \(source.split(whereSeparator: \.isWhitespace).count.formatted()) words").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
                Spacer()
            }
            .padding(.bottom, 14)

            Group {
                switch state {
                case .running:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(part.isEmpty ? "Working on your Mac…" : part).refinedFont(.meta).foregroundStyle(Refined.mute)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    VStack(alignment: .leading, spacing: 0) {
                        // A marked strip, so the result never reads as the transcript.
                        HStack(spacing: 7) {
                            IconGlyph(art: .iconAI, size: 13, color: Refined.ink)
                            Text(aiLabel).refinedFont(.meta, weight: .semibold)
                            Spacer(minLength: 6)
                            if !skipped.isEmpty { Text(skipped).refinedFont(.caption).foregroundStyle(Refined.mute) }
                        }
                        .foregroundStyle(Refined.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Refined.neutral)
                        .accessibilityElement(children: .combine)
                        TextEditor(text: $result)
                            .refinedFont(.body).foregroundStyle(Refined.ink).scrollContentBackground(.hidden)
                            .padding(10)
                            .accessibilityLabel("Result, editable. \(aiLabel)")
                    }
                    .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                case .failed:
                    VStack(spacing: 6) {
                        Text("Couldn't run this action").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                        Text(failure ?? (FlowCleanup.available ? "Apple's on-device model didn't answer. Try again, or try a shorter piece of text."
                                                   : "Actions use Apple Intelligence, which needs macOS 26 and Apple Intelligence turned on in System Settings."))
                            .refinedFont(.body).foregroundStyle(Refined.mute).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Motion.settle, value: state)

            HStack(spacing: 10) {
                if state == .done { Text("Apple Intelligence can be wrong. Edit the result before you keep it.").refinedFont(.meta).foregroundStyle(Refined.mute) }
                Spacer()
                Button("Close") { stop(); dismiss() }.keyboardShortcut(.cancelAction)
                if state != .running { Button("Try again") { start() } }
                if state == .done {
                    if let saveNote { Button("Save as note") { saveNote(result); app.toast = Toast("Saved as a note"); dismiss() } }
                    Button("Copy") { Paster.copy(result); app.toast = Toast("Copied"); dismiss() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 640, height: 500)
        .background(Refined.paper)
        .tint(Refined.accentText)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    /// Stops a run in progress: the model stops after the part it's on.
    private func stop() { runID += 1; job?.cancel(); job = nil }

    private func start() {
        stop()
        let id = runID
        state = .running; part = ""; failure = nil; skipped = ""
        let instruction = action.instruction, kind = action.kind, text = source
        if let t = transcript {
            let timestamps = TranscriptActions.spec(action.id)?.timestamps ?? false
            job = Task { @MainActor in
                do {
                    let out = try await TranscriptActions.run(instruction: instruction, extracts: kind == .extract, timestamps: timestamps, on: t) { i, n in
                        Task { @MainActor in if id == runID { part = n > 1 ? "Part \(i) of \(n)" : "" } }
                    }
                    guard id == runID else { return }
                    result = out.text
                    skipped = out.skippedParts > 0 ? "Apple Intelligence declined \(out.skippedParts) of \(out.totalParts) parts; their words aren’t here" : ""
                    state = .done
                } catch {
                    guard id == runID, !(error is CancellationError) else { return }
                    failure = (error as? LocalizedError)?.errorDescription
                    state = .failed
                }
            }
            return
        }
        job = Task { @MainActor in
            let out = await FlowCleanup.apply(instruction: instruction, to: text, kind: kind) { i, n in
                if id == runID { part = n > 1 ? "Part \(i) of \(n)" : "" }
            }
            guard id == runID else { return }   // closed or restarted meanwhile
            if let out { result = out; state = .done } else { state = .failed }
        }
    }
}

/// A text action beside the Templates list (Settings › Actions moved here in the consolidation, October 28, 2026): its
/// name, instruction, and how long text is handled, edited in place, with Move up, Move down, and Delete. It works on
/// text you select in any app (the Ribbon's menu) and on recordings (a transcript's or a dictation's Actions menu).
struct TextActionDetailCard: View {
    var actionID: UUID
    @ObservedObject private var settings = FlowSettings.shared
    @ObservedObject private var nav = TemplatesNav.shared
    @State private var confirmDelete = false

    private var index: Int? { settings.actions.firstIndex { $0.id == actionID } }

    var body: some View {
        if let i = index {
            let a = settings.actions[i]
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text action").refinedFont(.meta).foregroundStyle(Refined.mute)
                    Text(a.name.isEmpty ? "Untitled action" : a.name).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Works on " + TemplateScope.textAction.title.lowercased()).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                    Text("Select text in any app and choose it from the Ribbon's menu, or run it from a transcript's or a dictation's Actions menu.")
                        .refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                    TextField("Name", text: field(\.name)).textFieldStyle(.roundedBorder)
                        .uiTarget("text-action-name")
                    Text("Instruction").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                    TextEditor(text: field(\.instruction)).refinedFont(.body).foregroundStyle(Refined.ink).frame(minHeight: 90)
                        .scrollContentBackground(.hidden).padding(4)
                        .refinedFieldBox()
                        .accessibilityLabel("Instruction")
                    Picker("Long text", selection: field(\.kind)) {
                        ForEach(FlowAction.Kind.allCases) { k in Text(k.title).tag(k) }
                    }
                    .fixedSize()
                    Text(a.kind == .rewrite ? "Long text is done in parts, kept in order." : "Long text is done in parts, then the results are merged into one.")
                        .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Move up") { move(by: -1) }.buttonStyle(RefinedActionStyle()).disabled(i == 0)
                    Button("Move down") { move(by: 1) }.buttonStyle(RefinedActionStyle()).disabled(i >= settings.actions.count - 1)
                }
                Button("Delete text action…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(RefinedActionStyle())
                    .uiTarget("text-action-delete")
                HStack(alignment: .top, spacing: 7) {
                    IconGlyph(art: .iconPrivacy, size: 14, color: Refined.mute)
                    Text("On this Mac with Apple Intelligence. Nothing leaves it.").refinedFont(.meta).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(TemplateCardSurface())
            .confirmationDialog("Delete \u{201C}\(a.name)\u{201D}?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    // After the fields let go of their bindings, or AppKit can read a removed index.
                    nav.selected = nil
                    DispatchQueue.main.async { settings.actions.removeAll { $0.id == actionID } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("It leaves the Ribbon's menu and the Actions menus. Restore the ones that come with Verbose from the list.") }
        }
    }

    /// A binding to one field of this action, by ID, so a reorder or a delete elsewhere never writes the wrong one.
    private func field<V>(_ path: WritableKeyPath<FlowAction, V>) -> Binding<V> {
        Binding(get: { settings.actions.first { $0.id == actionID }.map { $0[keyPath: path] } ?? FlowAction(name: "", instruction: "")[keyPath: path] },
                set: { v in if let i = settings.actions.firstIndex(where: { $0.id == actionID }) { settings.actions[i][keyPath: path] = v } })
    }

    private func move(by d: Int) {
        guard let i = index else { return }
        let j = i + d
        guard settings.actions.indices.contains(j) else { return }
        settings.actions.swapAt(i, j)
    }
}
