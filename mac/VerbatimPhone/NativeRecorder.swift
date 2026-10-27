// brand: native file
import SwiftUI
import UIKit

// The record flow in the Native look (DESIGN.md §13.3; mockup "Verbose Native Redesign", section 4): a standard sheet
// with a grabber, like Voice Memos'. The kind and the date, a large SF Pro Light clock with monospaced digits, a
// waveform that scrolls under a red playhead with a ruler of seconds and the moments you marked as blue bookmarks,
// your words as they're heard, and the thumb row: Mark moment, Stop, and Pause. Swipe the sheet down and the
// recording keeps going in the tab bar's accessory (RecordAccessory.swift). Red marks only the live parts: the stop
// square and the playhead. Stop saves the recording and opens the Saved sheet. Verbose style keeps its own recorder
// (RecordScreen in HomeScreen.swift).

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

struct NativeRecorder: View {
    /// Whether the Native recorder is on screen, for the self-test.
    static var visible = false
    /// The stop square's color as drawn, for the self-test (it must be the record red).
    static var stopColor: Color? = nil
    @EnvironmentObject var app: PhoneState
    @State private var naming: RecordingMoment.ID? = nil
    @State private var nameDraft = ""
    /// Discard asks first: the recording moves to Recently Deleted.
    @State private var confirmDiscard = false
    @State private var discardLength = ""
    @State private var startedAt = Date()
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 64
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @Environment(\.limitMotion) private var limitMotion

    private var paused: Bool { app.recorder.isPaused }
    private var saving: Bool { app.savingRecording }
    private var adding: Transcript? { app.continuing.flatMap { app.store.transcript($0) } }

    var body: some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 16).padding(.top, 14)
            ScrollView {
                VStack(spacing: 0) {
                    heading.padding(.top, 8).padding(.horizontal, 24)
                    NativeRecorderClock(live: app.recorder.live, size: min(clockSize, 84)).padding(.top, 10)
                    if paused, let reason = app.autoPauseReason {
                        VStack(spacing: 10) {
                            Text(reason).font(.subheadline).foregroundStyle(NativeInk.label).multilineTextAlignment(.center)
                            Button("Resume") { app.togglePause() }.buttonStyle(.phonePrimary)
                        }
                        .padding(.horizontal, 24).padding(.top, 8)
                    }
                    NativeRecorderWave(live: app.recorder.live, moments: app.recordingMoments, paused: paused || saving, still: limitMotion)
                        .frame(height: 150).padding(.top, 18)
                    RecordLiveText(text: app.recordingWords)
                        .padding(.horizontal, 24).padding(.top, 18)
                    moments.padding(.horizontal, 16).padding(.top, 18)
                }
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            controls.padding(.bottom, 20).padding(.top, 8)
        }
        .background(NativeInk.plain.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .onAppear {
            Self.visible = true
            // The slide-in belongs to Verbose style's full-screen recorder; the sheet slides up on its own.
            RecordScreen.slideInNext = false
            startedAt = Date().addingTimeInterval(-app.recorder.live.elapsed)
        }
        .onDisappear { Self.visible = false }
        .sensoryFeedback(trigger: paused) { _, _ in Haptics.feedback(.impact(weight: .light)) }
        .accessibilityAction(.escape) { app.minimizeRecorder() }
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
        .confirmationDialog("Move this recording to Recently Deleted?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { app.discardRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("\(discardLength) recorded. You can restore it for 30 days.")
        }
    }

    /// Minimize on the leading side (the sheet's swipe does the same), the microphone on the trailing side.
    private var topBar: some View {
        HStack {
            Button { app.minimizeRecorder() } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(NativeInk.label)
                    .frame(width: 44, height: 44)
                    .nativeGlass(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize")
            .accessibilityHint("Keeps recording. Record in the tab bar brings it back.")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.subheadline.weight(.semibold))
                Text(HomeScreen.currentMic()).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(NativeInk.label)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .nativeGlass(Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording from \(HomeScreen.currentMic())")
        }
    }

    /// "Voice note" (or the kind, "New thought", or what it adds to) over the day and time it started; then, when a
    /// template runs at the end, which one.
    private var heading: some View {
        VStack(spacing: 2) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(NativeInk.label)
                .multilineTextAlignment(.center).lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(statusLine).font(.subheadline).foregroundStyle(NativeInk.secondary).monospacedDigit()
            if adding == nil, app.recordingChoice.template(settings: auto.settings, templates: app.store.allTemplates) != nil {
                Text(app.recordingChoice.recorderLine(settings: auto.settings, templates: app.store.allTemplates))
                    .font(.footnote).foregroundStyle(NativeInk.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var title: String {
        if let adding { return "Adds to “\(adding.title)”" }
        if app.recordingThought { return "New thought" }
        return app.recordingChoice.name
    }

    private var statusLine: String {
        let when = "\(HomeRecentStyle.day(startedAt)), \(Formats.style(date: .none, time: .short).string(from: startedAt))"
        if saving { return "Saving…" }
        if paused { return "Paused · \(when)" }
        return when
    }

    /// The moments so far, in one gray cell: "3 moments" and their times. A tap names the newest one.
    @ViewBuilder private var moments: some View {
        let list = app.recordingMoments
        if !list.isEmpty || app.lastMark != nil {
            Button {
                guard let m = list.last else { return }
                nameDraft = m.name; naming = m.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bookmark.fill").foregroundStyle(NativeInk.accent)
                    Text(app.lastMark.map { Marks.confirmation($0) } ?? NativeRules.momentsLabel(list.count))
                        .foregroundStyle(NativeInk.label).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(list.suffix(3).map { NativeRules.shortClock(Int($0.at)) }.joined(separator: " · "))
                        .monospacedDigit().foregroundStyle(NativeInk.secondary).lineLimit(1)
                }
                .font(.body)
                .padding(.horizontal, 16).frame(minHeight: 50)
                .background(NativeInk.fill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NativeRules.momentsLabel(list.count))
            .accessibilityValue(list.map { NativeRules.shortClock(Int($0.at)) }.joined(separator: ", "))
            .accessibilityHint("Names the newest moment.")
        }
    }

    /// The thumb row: Mark moment, Stop (the red square in a gray ring), and Pause or Resume. Adding to a transcript
    /// skips the Saved sheet, so Discard sits under it.
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                control("Mark moment", symbol: "bookmark") { app.markMoment() }
                    .disabled(paused || saving)
                    .frame(maxWidth: .infinity)
                Button { app.stopRecording() } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().strokeBorder(NativeInk.gray, lineWidth: 4)
                            if saving { ProgressView() }
                            else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(NativeInk.record).frame(width: 32, height: 32)
                                    .onAppear { NativeRecorder.stopColor = NativeInk.record }
                            }
                        }
                        .frame(width: 76, height: 76)
                        Text(saving ? "Saving…" : "Stop").font(.footnote).foregroundStyle(NativeInk.secondary).lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(saving ? "Saving" : "Stop")
                .accessibilityHint(adding == nil && !app.recordingThought ? "Stops and transcribes the recording." : "Stops and adds the recording.")
                .accessibilityIdentifier("native.recorder.stop")
                .frame(maxWidth: .infinity)
                control(paused ? "Resume" : "Pause", symbol: paused ? "play.fill" : "pause.fill") { app.togglePause() }
                    .frame(maxWidth: .infinity)
            }
            .disabled(saving)
            if adding != nil {
                Button("Discard", role: .destructive) {
                    discardLength = app.recorder.elapsed.timecode
                    confirmDiscard = true
                }
                .font(.body.weight(.semibold))
                .disabled(saving)
            }
        }
        .padding(.horizontal, 12)
    }

    private func control(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(NativeInk.label)
                    .frame(width: 58, height: 58)
                    .background(NativeInk.fill, in: Circle())
                Text(label).font(.footnote).foregroundStyle(NativeInk.secondary).lineLimit(1).fixedSize()
            }
            .padding(.top, 9)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The clock, on its own so only it redraws as the time moves: SF Pro Light with monospaced digits, minutes, seconds,
/// and hundredths.
private struct NativeRecorderClock: View {
    @ObservedObject var live: LiveMeter
    var size: CGFloat
    var body: some View {
        Text(NativeRules.recorderClock(live.elapsed))
            .font(.system(size: size, weight: .light)).monospacedDigit()
            .foregroundStyle(NativeInk.label)
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 16)
            .accessibilityLabel(RecorderPresentation.accessibilityLabel(paused: false, saving: false, elapsed: live.elapsed))
    }
}

/// The waveform under the playhead: the newest levels scroll in from the right and stop at the red playhead in the
/// middle, under a ruler of seconds with the moments you marked as blue bookmarks. One Canvas, no per-bar views. In
/// label color, so it reads as content. Under Limit animation it still updates in place (it only moves when your
/// voice does).
private struct NativeRecorderWave: View {
    @ObservedObject var live: LiveMeter
    var moments: [RecordingMoment]
    var paused: Bool
    var still: Bool
    /// The meter publishes about every 70 ms, so its 28 levels cover about two seconds left of the playhead.
    private static let secondsShown = 28 * 0.07

    var body: some View {
        let levels = live.levels
        let elapsed = live.elapsed
        let paused = paused
        let marks = moments.map(\.at)
        Canvas { ctx, size in
            let ruler: CGFloat = 26
            let playX = size.width / 2
            let pxPerSecond = playX / CGFloat(Self.secondsShown)
            // Ruler: a tick and a label for each second, a short tick each half second.
            for tick in NativeRules.rulerTicks(elapsed: elapsed, window: Self.secondsShown * 2.2) {
                let x = playX - CGFloat(tick.back * Self.secondsShown * 2.2) * pxPerSecond
                guard x >= 0 else { continue }
                ctx.fill(Path(CGRect(x: x - 0.5, y: ruler - 7, width: 1, height: 7)), with: .color(NativeInk.tertiary))
                let label = Text(NativeRules.shortClock(tick.second)).font(.caption2).monospacedDigit().foregroundStyle(NativeInk.secondary)
                ctx.draw(label, at: CGPoint(x: x, y: ruler - 16))
                let half = x + pxPerSecond / 2
                if half < playX { ctx.fill(Path(CGRect(x: half - 0.5, y: ruler - 4, width: 1, height: 4)), with: .color(NativeInk.tertiary)) }
            }
            // Bars: the newest at the playhead, older to the left.
            let waveTop = ruler + 10, waveHeight = size.height - waveTop - 6
            let count = levels.count
            let slot = playX / CGFloat(max(count, 1))
            let barWidth = max(2, slot * 0.55)
            for (i, v) in levels.enumerated() {
                let h = max(3, CGFloat(min(1, max(0.04, Double(v)))) * waveHeight)
                let x = playX - CGFloat(count - i) * slot + (slot - barWidth) / 2
                let rect = CGRect(x: x, y: waveTop + (waveHeight - h) / 2, width: barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(NativeInk.label.opacity(paused ? 0.4 : 1)))
            }
            // Moments: a blue bookmark on the ruler and a hairline down through the wave.
            for at in marks {
                let x = playX - CGFloat(elapsed - at) * pxPerSecond
                guard x >= 0, x <= playX else { continue }
                ctx.fill(Path(CGRect(x: x - 0.5, y: ruler, width: 1, height: size.height - ruler)), with: .color(NativeInk.accent.opacity(0.6)))
                var mark = Path()
                mark.move(to: CGPoint(x: x - 4, y: ruler - 2)); mark.addLine(to: CGPoint(x: x + 4, y: ruler - 2))
                mark.addLine(to: CGPoint(x: x + 4, y: ruler + 9)); mark.addLine(to: CGPoint(x: x, y: ruler + 6))
                mark.addLine(to: CGPoint(x: x - 4, y: ruler + 9)); mark.closeSubpath()
                ctx.fill(mark, with: .color(NativeInk.accent))
            }
            // The playhead: system red, while recording; gray while paused.
            let head = paused ? NativeInk.secondary : NativeInk.record
            ctx.fill(Path(CGRect(x: playX - 1, y: ruler - 4, width: 2, height: size.height - ruler)), with: .color(head))
            ctx.fill(Path(ellipseIn: CGRect(x: playX - 4, y: ruler - 8, width: 8, height: 8)), with: .color(head))
            ctx.fill(Path(ellipseIn: CGRect(x: playX - 4, y: size.height - 8, width: 8, height: 8)), with: .color(head))
        }
        .accessibilityHidden(true)
    }
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
                Section {
                    projectRow
                }
                Section {
                    Button { commitName(); let id = saved.id; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { app.open(id) } } label: {
                        Text("Open transcript").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.phonePrimaryLarge)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    Button { commitName(); dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { app.requestRecord() } } label: {
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
            .navigationTitle("Saved to Library")
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
