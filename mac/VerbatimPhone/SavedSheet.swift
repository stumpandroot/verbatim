// brand: native file
import SwiftUI
import UIKit

// After Stop in the Native look (DESIGN.md §13.3): Saved to Library, a standard sheet with an inset grouped list, like
// Apple's own. The recorder itself is one sheet in both looks (RecorderSheet.swift); Verbose style says Audio only's
// "Saved. No transcript." in a toast instead, and a voice note goes straight to the Library.

/// A moment marked while recording: when, where from, and the name you gave it (empty until you name it). The same
/// mark as the Dynamic Island's, the Lock Screen's, and the Action button's (Model/Marks.swift); saved as bookmarks
/// with the recording (`RecordingMark.notes`), each on the line being said once the words are in.
typealias RecordingMoment = RecordingMark

/// What the Saved sheet shows for a recording that just stopped.
struct SavedRecording: Identifiable, Equatable {
    var id: UUID
    var length: Double
    var moments: Int
    var savedAt: Date
}

// MARK: - Saved

/// After Stop: Saved to Library, as a grouped sheet. The name, the transcription's progress, the kind, and the project,
/// then Open transcript (the one prominent button), Record another, and Discard as a destructive button at the foot.
/// Done closes it.
struct NativeSavedSheet: View {
    /// Whether the Saved sheet is on screen, for the self-test.
    static var visible = false
    @EnvironmentObject var app: PhoneState
    var saved: SavedRecording
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDiscard = false
    @State private var newProject = false
    @State private var projectName = ""
    /// The kinds offered here.
    private static let kinds: [RecordingKind] = [.note, .idea, .journal, .meeting]

    /// The live progress (StageClock): a tick re-renders this sheet's progress, not the screens under it.
    @ObservedObject private var stages = StageClock.shared
    private var t: Transcript? { app.store.transcript(saved.id).map(stages.applied(to:)) }
    /// Audio only: "Saved. No transcript.", with Open and Record another, and no kind or progress to show.
    private var audio: Bool { t?.showsAudioDetail == true }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(savedLine).font(.subheadline).foregroundStyle(NativeInk.secondary).monospacedDigit()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                Section("Name") {
                    TextField("Name", text: $name, prompt: Text("Verbose suggests one when it's transcribed"))
                        .submitLabel(.done)
                        .onSubmit { commitName() }
                }
                if audio {
                    Section {
                        Label { Text(AudioOnlyCopy.saved) } icon: { Image(systemName: "waveform") }
                            .foregroundStyle(NativeInk.label)
                    } footer: { Text("Transcribe is on its screen if you want words later.") }
                } else {
                    Section {
                        progressRow
                    }
                    Section("Kind") {
                        Picker("Kind", selection: Binding(get: { t?.kind ?? .note }, set: { k in app.store.update(saved.id) { $0.kind = k; $0.kindIsAuto = false } })) {
                            ForEach(Self.kinds) { k in Text(k.label).tag(k) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                Section {
                    projectRow
                }
                Section {
                    Button { commitName(); let id = saved.id; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { app.open(id) } } label: {
                        Text(audio ? "Open" : "Open transcript").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.phonePrimaryLarge)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    Button { commitName(); let again = audio; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { app.requestRecord(kind: again ? .audio : nil) } } label: {
                        Text("Record another").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.phoneSecondaryLarge)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                }
                Section {
                    // The recording is already saved, so Discard sits last, in the system's destructive red, and asks first.
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Asks before it moves the recording to Recently Deleted.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(audio ? "Saved" : "Saved to Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { commitName(); dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false; commitName() }
        .confirmationDialog("Move this recording to Recently Deleted?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { app.delete([saved.id]); dismiss() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("You can restore it for 30 days.")
        }
        // Here rather than at the root: an alert there can't show over this sheet.
        .alert("New project", isPresented: $newProject) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) { projectName = "" }
            Button("Create") {
                let n = projectName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { app.addToProject([saved.id], app.store.addProject(n).id) }
                projectName = ""
            }
        } message: { Text("The recording moves into it.") }
    }

    private var savedLine: String {
        let when = "\(HomeRecentStyle.day(saved.savedAt)), \(Formats.style(date: .none, time: .short).string(from: saved.savedAt))"
        return PremiumRules.savedLine(kind: t?.kind?.label ?? "Voice note", length: HomeRecentStyle.length(saved.length), when: when, moments: saved.moments)
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let t, t.title != n else { return }
        app.store.update(t.id) { $0.title = n; $0.titleIsAuto = false; $0.titleByModel = false }
    }

    private var progressRow: some View {
        let status = t?.status ?? .processing
        let fraction: Double = status == .ready ? 1 : (PremiumRules.stageFraction(t?.stage) ?? 0.04)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status == .ready ? "Ready to read" : status == .failed ? (t?.error ?? "Try again from the transcript.") : (t?.stageText ?? "Queued"))
                    .foregroundStyle(status == .failed ? NativeInk.danger : NativeInk.label).lineLimit(2)
                Spacer(minLength: 6)
                if status == .failed, let t { Button("Retry") { app.retry(t) }.buttonStyle(.borderless) }
            }
            Text(status == .ready ? "Transcribed on this iPhone" : status == .failed ? "Transcription didn't finish" : "Transcribing on this iPhone")
                .font(.footnote).foregroundStyle(NativeInk.secondary)
            ProgressView(value: fraction)
                .accessibilityLabel("Transcription progress")
        }
        .padding(.vertical, 2)
    }

    private var projectRow: some View {
        let current = t?.projectId.flatMap { id in app.store.projects.first { $0.id == id }?.name }
        return Menu {
            Button { app.move(saved.id, to: nil) } label: {
                if current == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            ForEach(app.store.projects) { p in
                Button { app.addToProject([saved.id], p.id) } label: {
                    if t?.projectId == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button { newProject = true } label: { Label("New project…", systemImage: "folder.badge.plus") }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(NativeInk.accent)
                Text("Project").foregroundStyle(NativeInk.label)
                Spacer(minLength: 6)
                Text(current ?? "None").foregroundStyle(NativeInk.secondary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(NativeInk.tertiary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Project")
        .accessibilityValue(current ?? "None")
    }
}
