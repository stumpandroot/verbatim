import SwiftUI

/// The saved actions as menu items, with a way to edit them.
struct ActionsMenuItems: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var settings = FlowSettings.shared
    var pick: (FlowAction) -> Void
    var body: some View {
        ForEach(settings.actions) { a in
            Button { pick(a) } label: { Label(a.name, systemImage: a.symbol) }
        }
        Divider()
        Button("Edit Actions…") { app.dictation.openSettings(tab: .actions) }
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
                Image(systemName: action.symbol).font(.system(size: 15)).foregroundStyle(Ink.persimmon)
                    .frame(width: 30, height: 30).background(Ink.persimmonTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.name).font(Ink.serif(20)).foregroundStyle(Ink.ink)
                    Text("On \(sourceLabel) · \(source.split(whereSeparator: \.isWhitespace).count.formatted()) words").font(.system(size: 12)).foregroundStyle(Ink.mute)
                }
                Spacer()
            }
            .padding(.bottom, 14)

            Group {
                switch state {
                case .running:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(part.isEmpty ? "Working on your Mac…" : part).font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    VStack(alignment: .leading, spacing: 0) {
                        // A solid marked strip, so the result never reads as the transcript.
                        HStack(spacing: 7) {
                            ArtIcon(art: .iconAI, size: 13)
                            Text(aiLabel).font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 6)
                            if !skipped.isEmpty { Text(skipped).font(.system(size: 11.5)).foregroundStyle(Ink.mute) }
                        }
                        .foregroundStyle(Ink.accentText)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.persimmonTint)
                        .accessibilityElement(children: .combine)
                        TextEditor(text: $result)
                            .font(.system(size: 14)).scrollContentBackground(.hidden)
                            .padding(10)
                            .accessibilityLabel("Result, editable. \(aiLabel)")
                    }
                    .background(Ink.reader, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.hairline))
                case .failed:
                    VStack(spacing: 6) {
                        Text("Couldn't run this action").font(Ink.serif(18)).foregroundStyle(Ink.ink)
                        Text(failure ?? (FlowCleanup.available ? "Apple's on-device model didn't answer. Try again, or try a shorter piece of text."
                                                   : "Actions use Apple Intelligence, which needs macOS 26 and Apple Intelligence turned on in System Settings."))
                            .font(.system(size: 13)).foregroundStyle(Ink.mute).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Motion.settle, value: state)

            HStack(spacing: 10) {
                if state == .done { Text("Apple Intelligence can be wrong. Edit the result before you keep it.").font(.system(size: 12)).foregroundStyle(Ink.mute) }
                Spacer()
                Button("Close") { stop(); dismiss() }.keyboardShortcut(.cancelAction)
                if state != .running { Button("Try Again") { start() } }
                if state == .done {
                    if let saveNote { Button("Save as Note") { saveNote(result); app.toast = Toast("Saved as a note"); dismiss() } }
                    Button("Copy") { Paster.copy(result); app.toast = Toast("Copied"); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 640, height: 500)
        .background(Ink.paper)
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

/// Settings › Actions: add, edit, reorder, and remove saved actions.
struct ActionSettings: View {
    @ObservedObject private var settings = FlowSettings.shared
    @State private var editing: FlowAction.ID? = nil
    @State private var confirmRestore = false

    var body: some View {
        SettingsPane(tab: .actions) {
            SettingsGroup(title: "Actions") {
                SettingsRow("actions.list", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($settings.actions) { $a in
                            DisclosureGroup(isExpanded: Binding(get: { editing == a.id }, set: { editing = $0 ? a.id : nil })) {
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("Name", text: $a.name).textFieldStyle(.roundedBorder)
                                    Text("Instruction").font(.system(size: 12)).foregroundStyle(Ink.mute)
                                    TextEditor(text: $a.instruction).font(.system(size: 13)).frame(minHeight: 70)
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.hairline))
                                    Picker("Long text", selection: $a.kind) {
                                        ForEach(FlowAction.Kind.allCases) { k in Text(k.title).tag(k) }
                                    }
                                    .fixedSize()
                                    Text(a.kind == .rewrite ? "Long text is done in parts, kept in order." : "Long text is done in parts, then the results are merged into one.")
                                        .font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                                    if TranscriptActions.isBuiltIn(a.id) {
                                        Text("On a transcript, this action reads the Original text with your corrections, never the Cleaned text, and adds nothing the transcript doesn't say.")
                                            .font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                                    }
                                    HStack {
                                        Button("Move Up") { move(a.id, by: -1) }.disabled(settings.actions.first?.id == a.id)
                                        Button("Move Down") { move(a.id, by: 1) }.disabled(settings.actions.last?.id == a.id)
                                        Spacer()
                                        Button("Delete", role: .destructive) {
                                            // After the row's fields let go of their bindings, or AppKit can read a removed index.
                                            let id = a.id
                                            editing = nil
                                            DispatchQueue.main.async { settings.actions.removeAll { $0.id == id } }
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                            } label: {
                                Label(a.name.isEmpty ? "Untitled action" : a.name, systemImage: a.symbol).font(.system(size: 13.5))
                            }
                        }
                    }
                }
                SettingsRow("actions.add") {
                    Button("Add Action") {
                        let new = FlowAction(name: "New action", instruction: "")
                        settings.actions.append(new); editing = new.id
                    }
                    .buttonStyle(.brandPrimary)
                }
                SettingsRow("actions.restore") {
                    Button("Restore Built-in Actions…") { confirmRestore = true }.buttonStyle(.brandSecondary)
                }
            }
        }
        .confirmationDialog("Restore the built-in actions?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) { settings.actions = FlowAction.builtIn }
        } message: { Text("Replaces your actions with the \(FlowAction.builtIn.count) that come with Verbatim, including Make a plan, Journal entry, Write a draft, Study notes, and Key points. Actions you added or changed are removed.") }
    }

    private func move(_ id: UUID, by d: Int) {
        guard let i = settings.actions.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard settings.actions.indices.contains(j) else { return }
        settings.actions.swapAt(i, j)
    }
}
