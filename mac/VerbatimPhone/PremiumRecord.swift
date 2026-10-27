// brand: native file
import SwiftUI
import UIKit

// The record flow in Premium Native (mockup "premium", section 01): a full-screen recorder with the timer in 88 pt
// rounded digits, a live waveform with the playhead in the middle, the moments you've marked, and Mark moment, Stop,
// and Pause. Stop saves the recording and opens the Saved sheet: the transcription's progress, a kind picker,
// Project, Open transcript, and Record another. Verbose style keeps its own recorder (RecordScreen in HomeScreen.swift).

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

// MARK: - The recorder

struct PremiumRecorder: View {
    /// Whether the Premium recorder is on screen, for the self-test.
    static var visible = false
    @EnvironmentObject var app: PhoneState
    @Binding var confirmDiscard: Bool
    @Binding var discardLength: String
    @State private var naming: RecordingMoment.ID? = nil
    @State private var nameDraft = ""
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 88

    private var paused: Bool { app.recorder.isPaused }
    private var saving: Bool { app.savingRecording }
    private var adding: Transcript? { app.continuing.flatMap { app.store.transcript($0) } }

    var body: some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 16).padding(.top, 6)
            ScrollView {
                VStack(spacing: 0) {
                    status.padding(.top, 30)
                    PremiumClock(live: app.recorder.live, size: min(clockSize, 112)).padding(.top, 12)
                    subline.padding(.top, 10).padding(.horizontal, 24)
                    PremiumLiveWave(live: app.recorder.live, paused: paused || saving)
                        .frame(height: 96).padding(.horizontal, 22).padding(.top, 30)
                    RecordLiveText(text: app.recordingWords)
                        .padding(.horizontal, 24).padding(.top, 18)
                    moments.padding(.horizontal, 20).padding(.top, 26)
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            controls.padding(.bottom, 24).padding(.top, 8)
        }
        .background { PremiumPageBackground(recorder: true) }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
        .alert("Name this moment", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Moment", text: $nameDraft)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") {
                if let id = naming, let i = app.recordingMoments.firstIndex(where: { $0.id == id }) {
                    app.recordingMoments[i].name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                naming = nil
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { app.minimizeRecorder() } label: {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).foregroundStyle(NativeInk.label)
                    .frame(width: 44, height: 44)
                    .premiumGlass(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize")
            .accessibilityHint("Keeps recording. Use the bar above the tab bar to come back.")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.accent)
                Text(HomeScreen.currentMic()).font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.label).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .premiumGlass(Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording from \(HomeScreen.currentMic())")
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(paused || saving ? NativeInk.secondary : Ink.persimmonFixed).frame(width: 9, height: 9)
            Text(statusText).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(paused || saving ? NativeInk.secondary : NativeInk.accent)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let what = adding.map { "Adds to “\($0.title)”" } ?? (app.recordingThought ? ThoughtRules.intoLine(PhoneState.thoughtPageTitle(app.todayPage)) : "Voice note")
        if saving { return "Saving…" }
        return "\(paused ? "Paused" : "Recording") · \(what)"
    }

    @ViewBuilder private var subline: some View {
        if paused, let reason = app.autoPauseReason {
            VStack(spacing: 10) {
                Text(reason).font(.system(size: 15)).foregroundStyle(NativeInk.label).multilineTextAlignment(.center)
                Button("Resume") { app.togglePause() }.buttonStyle(.phonePrimary)
            }
        } else {
            Text("Saved as you go. Keeps recording with the screen locked.")
                .font(.system(size: 15)).foregroundStyle(NativeInk.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var moments: some View {
        let list = app.recordingMoments
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Moments").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(list.suffix(4)) { m in
                    Button { nameDraft = m.name; naming = m.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill").font(.system(size: 16)).foregroundStyle(NativeInk.accent)
                            Text(HomeRecentStyle.length(m.at)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            Text(m.name.isEmpty ? "Moment" : m.name).font(.system(size: 16)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(m.name.isEmpty ? "Tap to name" : "Rename").font(.system(size: 14)).foregroundStyle(NativeInk.secondary)
                        }
                        .foregroundStyle(NativeInk.label)
                        .padding(.horizontal, 14).frame(minHeight: 50)
                        .premiumSoftCard(radius: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityLabel("Moment at \(HomeRecentStyle.length(m.at))\(m.name.isEmpty ? "" : ", \(m.name)")")
                    .accessibilityHint("Names this moment.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 36) {
                control("Mark moment", symbol: "bookmark") { app.markMoment() }
                    .disabled(paused || saving)
                    .opacity(paused || saving ? 0.5 : 1)
                Button { app.stopRecording() } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().fill(PremiumStyle.disc)
                            if saving { ProgressView().tint(Color.white) }
                            else { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white).frame(width: 28, height: 28) }
                        }
                        .frame(width: 86, height: 86)
                        .padding(6).background(PremiumStyle.ring, in: Circle())
                        .shadow(color: PremiumStyle.discShadow, radius: 14, y: 10)
                        Text(saving ? "Saving…" : "Stop").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeInk.label)
                    }
                    .padding(.top, -12)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(saving ? "Saving" : adding == nil ? "Stop and transcribe" : "Stop and add")
                control(paused ? "Resume" : "Pause", symbol: paused ? "play.fill" : "pause.fill") { app.togglePause() }
            }
            .disabled(saving)
            // Adding to an existing transcript skips the Saved sheet, so Discard stays here.
            if adding != nil {
                Button("Discard") {
                    discardLength = app.recorder.elapsed.timecode
                    confirmDiscard = true
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.danger)
                .disabled(saving)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func control(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(NativeInk.label)
                    .frame(width: 62, height: 62)
                    .premiumGlass(Circle())
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeInk.label).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// The 88 pt clock, on its own so only it redraws each second.
private struct PremiumClock: View {
    @ObservedObject var live: LiveMeter
    var size: CGFloat
    var body: some View {
        Text(PremiumRules.recorderClock(live.elapsed))
            .font(PremiumStyle.number(size)).tracking(-2)
            .foregroundStyle(NativeInk.label)
            .lineLimit(1).minimumScaleFactor(0.5)
            .accessibilityLabel(RecorderPresentation.accessibilityLabel(paused: false, saving: false, elapsed: live.elapsed))
    }
}

/// The live waveform: the newest levels up to the playhead in the middle, quiet stubs after it. One Canvas, no
/// per-bar views.
private struct PremiumLiveWave: View {
    @ObservedObject var live: LiveMeter
    var paused: Bool
    private static let bars = 48

    var body: some View {
        let bars = PremiumRules.waveBars(live.levels, count: Self.bars)
        let paused = paused
        Canvas { ctx, size in
            let gap: CGFloat = 3
            let w = max(2, (size.width - gap * CGFloat(Self.bars - 1)) / CGFloat(Self.bars))
            for (i, b) in bars.enumerated() {
                let h = max(3, CGFloat(b.height) * size.height)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                let color = b.past ? Ink.persimmonFixed.opacity(paused ? 0.45 : 1) : Ink.persimmonFixed.opacity(0.35)
                ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(color))
            }
            var head = Path()
            head.addRoundedRect(in: CGRect(x: size.width / 2 - 1, y: -6, width: 2, height: size.height + 12), cornerSize: CGSize(width: 1, height: 1))
            ctx.fill(head, with: .color(NativeInk.label.opacity(0.7)))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Saved

/// After Stop: Saved to Library, with Discard and Done, the transcription's progress, the kind, the project, Open
/// transcript, and Record another.
struct PremiumSavedSheet: View {
    /// Whether the Saved sheet is on screen, for the self-test.
    static var visible = false
    @EnvironmentObject var app: PhoneState
    var saved: SavedRecording
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDiscard = false
    @State private var newProject = false
    @State private var projectName = ""
    @FocusState private var nameFocused: Bool
    /// The kinds offered here, as in the mockup.
    private static let kinds: [RecordingKind] = [.note, .idea, .journal, .meeting]

    /// The live progress (StageClock): a tick re-renders this card's progress, not the screens under it.
    @ObservedObject private var stages = StageClock.shared
    private var t: Transcript? { app.store.transcript(saved.id).map(stages.applied(to:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("Discard") { confirmDiscard = true }
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(NativeInk.label)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .premiumGlass(Capsule())
                    Spacer()
                    Button("Done") { commitName(); dismiss() }
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(PremiumInk.onAccent)
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .background(NativeInk.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold)).foregroundStyle(NativeInk.accent)
                    .frame(width: 54, height: 54).background(PremiumInk.accentSoft, in: Circle())
                    .padding(.top, 8)
                    .accessibilityHidden(true)
                Text("Saved to Library").font(.system(size: 28, weight: .bold)).foregroundStyle(NativeInk.label)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                Text(savedLine).font(.system(size: 15)).foregroundStyle(NativeInk.secondary).monospacedDigit()
                    .padding(.top, 1)
                nameCard.padding(.top, 18)
                progressCard.padding(.top, 12)
                Text("Kind").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.secondary)
                    .padding(.top, 18).padding(.leading, 4)
                kinds.padding(.top, 8)
                projectRow.padding(.top, 16)
                VStack(spacing: 10) {
                    Button { commitName(); let id = saved.id; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { app.open(id) } } label: {
                        Text("Open transcript").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.phonePrimaryLarge)
                    Button { commitName(); dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { app.requestRecord() } } label: {
                        Text("Record another").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.phoneSecondaryLarge)
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(NativeInk.paper.ignoresSafeArea())
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

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Name").font(.system(size: 13)).foregroundStyle(NativeInk.secondary)
            TextField("", text: $name, prompt: Text("Verbose suggests one when it's transcribed").foregroundStyle(NativeInk.tertiary))
                .font(.system(size: 16)).foregroundStyle(NativeInk.label)
                .submitLabel(.done).focused($nameFocused)
                .onSubmit { commitName() }
                .accessibilityLabel("Name")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumSoftCard(radius: 18)
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let t, t.title != n else { return }
        app.store.update(t.id) { $0.title = n; $0.titleIsAuto = false; $0.titleByModel = false }
    }

    private var progressCard: some View {
        let status = t?.status ?? .processing
        let fraction: Double = status == .ready ? 1 : (PremiumRules.stageFraction(t?.stage) ?? 0.04)
        return VStack(alignment: .leading, spacing: 3) {
            Text(status == .ready ? "Transcribed on this iPhone" : status == .failed ? "Transcription didn't finish" : "Transcribing on this iPhone")
                .font(.system(size: 13)).foregroundStyle(NativeInk.secondary)
            HStack {
                Text(status == .ready ? "Ready to read" : status == .failed ? (t?.error ?? "Try again from the transcript.") : (t?.stageText ?? "Queued"))
                    .font(.system(size: 16)).foregroundStyle(status == .failed ? NativeInk.danger : NativeInk.label).lineLimit(2)
                Spacer(minLength: 6)
                if status == .failed, let t { Button("Retry") { app.retry(t) }.font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeInk.accent) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(NativeInk.fillStrong)
                    Capsule().fill(NativeInk.accent).frame(width: g.size.width * fraction)
                }
            }
            .frame(height: 4).padding(.top, 8)
            .accessibilityElement()
            .accessibilityLabel("Transcription progress")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumSoftCard(radius: 18)
    }

    private var kinds: some View {
        HStack(spacing: 8) {
            ForEach(Self.kinds) { k in
                let on = (t?.kind ?? .note) == k
                Button { app.store.update(saved.id) { $0.kind = k; $0.kindIsAuto = false } } label: {
                    Text(k.label).font(.system(size: 15, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? NativeInk.paper : NativeInk.label)
                        .padding(.horizontal, 14).frame(minHeight: 34)
                        .background(on ? NativeInk.label : NativeInk.fill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
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
                Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(NativeInk.accent)
                Text("Project").font(.system(size: 17)).foregroundStyle(NativeInk.label)
                Spacer(minLength: 6)
                Text(current ?? "None").font(.system(size: 17)).foregroundStyle(NativeInk.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeInk.tertiary)
            }
            .padding(.horizontal, 14).frame(minHeight: 52)
            .premiumSoftCard(radius: 18)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Project")
        .accessibilityValue(current ?? "None")
    }
}
