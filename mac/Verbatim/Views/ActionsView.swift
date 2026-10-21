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
struct ActionSheet: View {
    let action: FlowAction
    let source: String
    let sourceLabel: String
    var saveNote: ((String) -> Void)? = nil

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var result = ""
    @State private var state: Phase = .running
    @State private var part = ""
    @State private var runID = 0
    @State private var job: Task<Void, Never>? = nil

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
                    TextEditor(text: $result)
                        .font(.system(size: 14)).scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Ink.reader, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.hairline))
                        .accessibilityLabel("Result, editable")
                case .failed:
                    VStack(spacing: 6) {
                        Text("Couldn't run this action").font(Ink.serif(18)).foregroundStyle(Ink.ink)
                        Text(FlowCleanup.available ? "Apple's on-device model didn't answer. Try again, or try a shorter piece of text."
                                                   : "Actions use Apple Intelligence, which needs macOS 26 and Apple Intelligence turned on in System Settings.")
                            .font(.system(size: 13)).foregroundStyle(Ink.mute).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Motion.settle, value: state)

            HStack(spacing: 10) {
                if state == .done { Text("Written by Apple Intelligence, which can be wrong. Edit the result before you keep it.").font(.system(size: 12)).foregroundStyle(Ink.mute) }
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
        state = .running; part = ""
        let instruction = action.instruction, kind = action.kind, text = source
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
        } message: { Text("Replaces your actions with the eight that come with Verbatim. Actions you added or changed are removed.") }
    }

    private func move(_ id: UUID, by d: Int) {
        guard let i = settings.actions.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard settings.actions.indices.contains(j) else { return }
        settings.actions.swapAt(i, j)
    }
}
