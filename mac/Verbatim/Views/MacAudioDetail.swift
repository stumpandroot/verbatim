import SwiftUI
import AppKit

// An Audio only recording's screen on the Mac (approved mockup "Verbose Brain Dump", section 4, October 27, 2026), on
// the refined kit (DESIGN.md §13), in place of the transcript while it has no words: the title
// you type over the kind's chip and when, the player as the main content (AudioPlayerCard: its waveform with the
// moments as ticks, back 5 seconds, play, and the speed), the moments with the names you give them, notes, Transcribe,
// and Share. Click Transcribe for a plain transcribe (a voice note when it's done), or open its menu to Transcribe As
// each kind. While it transcribes, the progress sits where Transcribe was. The window's inspector keeps the moments and
// Details (`MacAudioInspector`); the page shows the moments while the inspector is closed. Back is the toolbar's.

struct MacAudioDetail: View {
    @EnvironmentObject var app: AppState
    var id: UUID
    @EnvironmentObject private var nav: WindowNav
    @ObservedObject private var stages = StageClock.shared
    @State private var note = ""

    private var t: Transcript? { app.store.transcript(id).map(stages.applied(to:)) }

    /// On screen, for the self-test.
    static var shown: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let t {
                    VStack(alignment: .leading, spacing: 22) {
                        header(t)
                        MacAudioPlayer(transcript: t, player: app.player, clock: app.player.clock)
                        if !nav.inspector { MacAudioMoments(transcript: t) }
                        notes(t)
                        actions(t)
                        Text(AudioOnlyCopy.transcribeFooter).refinedFont(.meta).foregroundStyle(Refined.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: TranscriptView.column, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                } else {
                    Text("This recording was deleted.").refinedFont(.body).foregroundStyle(Refined.mute).padding(40)
                }
            }
            .softScrollEdges(.top)
        }
        .background(Refined.paper)
        .onKeyPress(.space) { if TranscriptView.typing { return .ignored }; app.player.toggle(); return .handled }
        .onAppear {
            Self.shown = id
            if let t, let u = app.store.audioURL(for: t) { app.player.loadAsync(u) }
        }
        .onDisappear { app.player.stop(); if Self.shown == id { Self.shown = nil } }
    }

    @ViewBuilder private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: Binding(get: { t.title }, set: { v in
                guard v != t.title else { return }
                app.store.updateDeferred(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
            }))
            .textFieldStyle(.plain)
            .refinedFont(.transcriptTitle).foregroundStyle(Refined.ink)
            .accessibilityLabel("Title")
            FlowRow(spacing: 8, lineSpacing: 6) {
                KindPickerChip(kind: t.kind ?? .audio, isAuto: t.kindIsAuto) { k in app.pickKind(k, for: t.id) }
                Text(RefinedRules.transcriptWhen(t.createdAt) + " \u{00B7} " + AudioOnlyRules.statusLine(t))
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            if t.status == .failed, let e = t.error { Text(e).refinedFont(.meta).foregroundStyle(Refined.accentText) }
        }
    }

    @ViewBuilder private func notes(_ t: Transcript) -> some View {
        let list = t.notes.filter { $0.at == nil }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Notes")
            if !list.isEmpty {
                PaperList(list, id: \.id, inset: 14, trailingInset: 14) { n in
                    Text(n.text).refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { Button("Delete Note", role: .destructive) { app.deleteNote(transcript: t.id, note: n.id) } }
                }
            }
            TextField("Add a note…", text: $note)
                .textFieldStyle(.plain).refinedFont(.body).foregroundStyle(Refined.ink)
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(Refined.field, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous))
                .onSubmit {
                    let text = note.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    app.addNote(transcript: t.id, text: text, at: nil, segment: nil)
                    note = ""
                }
        }
    }

    @ViewBuilder private func actions(_ t: Transcript) -> some View {
        HStack(spacing: 8) {
            if t.status == .processing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AudioOnlyRules.statusLine(t)).refinedFont(.meta).foregroundStyle(Refined.dim)
                    if t.processingDevice == Device.id { Button("Cancel") { app.coordinator.cancel(t.id) }.buttonStyle(RefinedActionStyle()) }
                }
                .uiTarget("audio-transcribing")
            } else {
                MacTranscribeMenu(transcript: t)
                    .uiTarget("audio-transcribe")
            }
            Button("Share") { share(t) }.buttonStyle(RefinedActionStyle())
                .help("Show the audio file in Finder")
        }
    }

    private func share(_ t: Transcript) {
        guard let u = app.store.audioURL(for: t), FileManager.default.fileExists(atPath: u.path) else {
            app.toast = Toast("The audio isn\u{2019}t on this Mac yet."); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
}

/// Transcribe: a click is the plain transcribe; the menu offers Transcribe As each kind, like Record As.
struct MacTranscribeMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript

    var body: some View {
        Menu {
            Section("Transcribe As") {
                ForEach(AudioOnlyRules.transcribeChoices, id: \.self) { k in
                    Button(AudioOnlyRules.choiceName(k).capitalized) { app.transcribeLater(transcript.id, as: k) }
                }
            }
        } label: {
            Text("Transcribe")
        } primaryAction: {
            app.transcribeLater(transcript.id)
        }
        .menuStyle(.button).buttonStyle(RefinedActionStyle(kind: .strong)).fixedSize()
        .disabled(!AudioOnlyRules.canTranscribe(transcript))
        .help("Make a transcript and file it as a voice note. Open the menu to transcribe it as a kind.")
        .accessibilityLabel("Transcribe")
    }
}

/// The player, the kit's `AudioPlayerCard`. Observes the player and the clock, so playback redraws this alone.
struct MacAudioPlayer: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var player: Player
    @ObservedObject var clock: PlayerClock

    private var duration: Double { clock.duration > 0 ? clock.duration : transcript.duration }
    private var loaded: Bool { app.store.audioURL(for: transcript).map { clock.loadedURL == $0 } ?? false }

    var body: some View {
        AudioPlayerCard(isPlaying: player.isPlaying, elapsed: loaded ? clock.time : 0, duration: duration,
                        levels: transcript.waveform, moments: AudioWave.marks(transcript),
                        speed: PlaybackSync.speedLabel(player.rate), playID: "audio-play",
                        onPlayPause: { player.toggle() }, onSeek: { player.seek(to: $0) }) {
            ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { r in
                Button(PlaybackSync.speedLabel(r)) { player.setRate(r) }
            }
        }
        .help("Space plays or pauses")
    }
}

/// The moments: each one's time (click to play from it), the name you give it (double-click or right-click to name
/// it), and where it was marked.
struct MacAudioMoments: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var naming: UUID? = nil
    @State private var draft = ""

    var body: some View {
        let ms = transcript.notes.filter { $0.at != nil }.sorted { ($0.at ?? 0) < ($1.at ?? 0) }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Moments") {
                if !ms.isEmpty { Text("\(ms.count)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute) }
            }
            if ms.isEmpty {
                Text("Mark a moment while you record and it shows here.").refinedFont(.meta).foregroundStyle(Refined.mute)
            } else {
                PaperList(ms, id: \.id, inset: 12, trailingInset: 12) { n in row(n) }
            }
        }
    }

    private func row(_ n: Note) -> some View {
        HStack(spacing: 10) {
            MomentChip(time: Marks.clock(n.at ?? 0))
                .contentShape(Capsule())
                .tapArea { app.player.play(from: n.at ?? 0) }
                .help("Play from here")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Play from \(Marks.clock(n.at ?? 0))")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { app.player.play(from: n.at ?? 0) }
            if naming == n.id {
                TextField("Name this moment", text: $draft).textFieldStyle(.roundedBorder).refinedFont(.body)
                    .onSubmit { rename(n) }
            } else {
                Text(n.text.isEmpty ? "Add a name" : n.text).refinedFont(.body)
                    .foregroundStyle(n.text.isEmpty ? Refined.mute : Refined.ink).lineLimit(1)
                    .onTapGesture(count: 2) { draft = n.text; naming = n.id }
            }
            Spacer(minLength: 6)
            if let src = Marks.shortSource(n) { Text(src).refinedFont(.caption).foregroundStyle(Refined.mute) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contextMenu {
            Button("Name This Moment") { draft = n.text; naming = n.id }
            Button("Delete Moment", role: .destructive) { app.deleteNote(transcript: transcript.id, note: n.id) }
        }
    }

    private func rename(_ n: Note) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        app.store.update(transcript.id) { x in if let i = x.notes.firstIndex(where: { $0.id == n.id }) { x.notes[i].text = text } }
        naming = nil
    }
}

/// The inspector beside an Audio only recording: its moments and its kind.
struct MacAudioInspector: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MacAudioMoments(transcript: transcript)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Details").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
                    Picker("Kind", selection: Binding(get: { transcript.kind ?? .audio }, set: { k in app.pickKind(k, for: transcript.id) })) {
                        ForEach(RecordingKind.pickable) { k in Text(k.label).tag(k) }
                    }
                    Text(AudioOnlyCopy.noTemplate).refinedFont(.meta).foregroundStyle(Refined.mute)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 28)
        }
        .background(Refined.paper)
    }
}
