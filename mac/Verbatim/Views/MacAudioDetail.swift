import SwiftUI
import AppKit

// brand: web style
//
// An Audio only recording's screen on the Mac (approved mockup "Verbose Brain Dump", section 4, October 27, 2026), in
// place of the transcript while it has no words: the title you type, the player as the main content (its waveform,
// moments as ticks, back 5 seconds, play, and the speed), the moments with the names you give them, notes, Share, and
// Transcribe. Click Transcribe for a plain transcribe (a voice note when it's done), or open its menu to Transcribe As
// each kind. While it transcribes, the progress sits where Transcribe was. Verbose style draws the reader sheet; Native
// draws plain sections, with the moments and Details in the inspector (`MacAudioInspector`).

struct MacAudioDetail: View {
    @EnvironmentObject var app: AppState
    var id: UUID
    @Environment(\.look) private var look
    @ObservedObject private var stages = StageClock.shared
    @State private var note = ""

    private var t: Transcript? { app.store.transcript(id).map(stages.applied(to:)) }

    /// On screen, for the self-test.
    static var shown: UUID? = nil

    var body: some View {
        ScrollView {
            if let t {
                VStack(alignment: .leading, spacing: 18) {
                    header(t)
                    MacAudioPlayer(transcript: t, clock: app.player.clock)
                    if look != .native { MacAudioMoments(transcript: t) }
                    notes(t)
                    actions(t)
                    Text(AudioOnlyCopy.transcribeFooter).font(.system(size: 12.5)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.dim))
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 40).padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            } else {
                Text("This recording was deleted.").foregroundStyle(Ink.mute).padding(40)
            }
        }
        .background(Ink.paper)
        .onAppear {
            Self.shown = id
            if let t, let u = app.store.audioURL(for: t) { app.player.loadAsync(u) }
        }
        .onDisappear { app.player.stop(); if Self.shown == id { Self.shown = nil } }
    }

    private func when(_ t: Transcript) -> String {
        "\(HomeRecentStyle.day(t.createdAt)), \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
    }

    @ViewBuilder private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: t.duration > 0 ? "Audio only · \(HomeRecentStyle.length(t.duration))" : "Audio only")
            TextField("Title", text: Binding(get: { t.title }, set: { v in
                guard v != t.title else { return }
                app.store.updateDeferred(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
            }))
            .textFieldStyle(.plain)
            .font(look == .native ? .system(size: 26, weight: .bold) : Ink.serif(34))
            .foregroundStyle(Ink.ink)
            .accessibilityLabel("Title")
            Text("\(when(t)) · \(AudioOnlyRules.statusLine(t))").font(.system(size: 13)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.mute))
            if t.status == .failed, let e = t.error { Text(e).font(.system(size: 12.5)).foregroundStyle(Ink.danger) }
            KindChip(kind: t.kind, isAuto: t.kindIsAuto, compact: true) { k in app.pickKind(k, for: t.id) }
                .padding(.top, 2)
        }
    }

    @ViewBuilder private func notes(_ t: Transcript) -> some View {
        let list = t.notes.filter { $0.at == nil }
        VStack(alignment: .leading, spacing: 8) {
            if look == .native { Text("Notes").font(.system(size: 13, weight: .semibold)) } else { WebText.serif("Notes", size: 23).foregroundStyle(Ink.ink) }
            ForEach(list) { n in
                Text(n.text).font(.system(size: 14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
                    .contextMenu { Button("Delete Note", role: .destructive) { app.deleteNote(transcript: t.id, note: n.id) } }
            }
            TextField("Add a note…", text: $note)
                .textFieldStyle(.roundedBorder).font(.system(size: 13))
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
            PillButton(title: "Share", kind: .line, size: .mini, icon: .iconShare) { share(t) }
            if t.status == .processing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AudioOnlyRules.statusLine(t)).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    if t.processingDevice == Device.id { PillButton(title: "Cancel", kind: .line, size: .mini) { app.coordinator.cancel(t.id) } }
                }
                .uiTarget("audio-transcribing")
            } else {
                MacTranscribeMenu(transcript: t)
                    .uiTarget("audio-transcribe")
            }
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
            PillLabel(title: "Transcribe", kind: .dark, size: .mini, icon: .iconDictations, trailing: .chevron)
        } primaryAction: {
            app.transcribeLater(transcript.id)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(!AudioOnlyRules.canTranscribe(transcript))
        .help("Make a transcript and file it as a voice note. Open the menu to transcribe it as a kind.")
        .accessibilityLabel("Transcribe")
    }
}

/// The player: the waveform with the played part in the playback color and the moments as ticks, the time and length,
/// back 5 seconds, play, and the speed. Observes only the clock.
struct MacAudioPlayer: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock
    @Environment(\.look) private var look

    private var duration: Double { clock.duration > 0 ? clock.duration : transcript.duration }
    private var loaded: Bool { app.store.audioURL(for: transcript).map { clock.loadedURL == $0 } ?? false }
    private var played: Double { loaded && duration > 0 ? min(1, clock.time / duration) : 0 }

    var body: some View {
        VStack(spacing: 10) {
            if look == .native {
                AudioWave(levels: transcript.waveform, played: played, marks: AudioWave.marks(transcript),
                          bar: Color.secondary.opacity(0.45), playedColor: Color.primary, mark: Color.accentColor, bars: 90)   // brand: native
                    .frame(height: 64)
            } else {
                AudioWave(levels: transcript.waveform, played: played, marks: AudioWave.marks(transcript),
                          bar: Ink.ink, playedColor: Ink.panelSage, mark: Ink.butter, bars: 90)
                    .frame(height: 80)
            }
            HStack {
                Text(Marks.clock(loaded ? clock.time : 0))
                Spacer()
                Text(Marks.clock(duration))
            }
            .font(Ink.mono(12)).foregroundStyle(Ink.mute)
            HStack(spacing: 28) {
                Button { app.player.seek(to: max(0, clock.time - 5)) } label: { ArtIcon(art: .iconBack5, size: 20) }
                    .buttonStyle(.plain).help("Back 5 seconds").accessibilityLabel("Back 5 seconds")
                Button { app.player.toggle() } label: {
                    ZStack {
                        Circle().fill(look == .native ? Color.primary.opacity(0.08) : Ink.panelSage)
                        ArtIcon(art: app.player.isPlaying ? .iconPause : .iconPlay, size: 20).foregroundStyle(look == .native ? Ink.ink : Ink.inkFixed)
                    }
                    .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
                .uiTarget("audio-play")
                Menu {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { r in
                        Button(r == 1 ? "1×" : String(format: "%g×", r)) { app.player.setRate(r) }
                    }
                } label: { Text(app.player.rate == 1 ? "1×" : String(format: "%g×", app.player.rate)).font(Ink.mono(13)) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Speed")
            }
            .foregroundStyle(Ink.ink)
        }
        .padding(18)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(look == .native ? Ink.hairline : Ink.ink, lineWidth: look == .native ? 1 : 1.5))
    }
}

/// The moments: each one's time (click to play from it), the name you give it, and where it was marked.
struct MacAudioMoments: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @Environment(\.look) private var look
    @State private var naming: UUID? = nil
    @State private var draft = ""

    var body: some View {
        let ms = transcript.notes.filter { $0.at != nil }.sorted { ($0.at ?? 0) < ($1.at ?? 0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if look == .native { Text("Moments").font(.system(size: 13, weight: .semibold)) } else { WebText.serif("Moments", size: 23).foregroundStyle(Ink.ink) }
                if !ms.isEmpty { Text("\(ms.count)").font(Ink.mono(12.5)).foregroundStyle(Ink.mute) }
            }
            if ms.isEmpty {
                Text("Mark a moment while you record and it shows here.").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
            ForEach(ms) { n in
                HStack(spacing: 10) {
                    Button(Marks.clock(n.at ?? 0)) { app.player.play(from: n.at ?? 0) }
                        .buttonStyle(.plain).font(Ink.mono(12.5))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(look == .native ? Color.primary.opacity(0.08) : Ink.butter, in: Capsule())
                        .foregroundStyle(look == .native ? Ink.ink : Ink.inkFixed)
                        .help("Play from here")
                    if naming == n.id {
                        TextField("Name this moment", text: $draft).textFieldStyle(.roundedBorder).font(.system(size: 13))
                            .onSubmit { rename(n) }
                    } else {
                        Text(n.text.isEmpty ? "Add a name" : n.text).font(.system(size: 13))
                            .foregroundStyle(n.text.isEmpty ? Ink.mute : Ink.ink).lineLimit(1)
                            .onTapGesture(count: 2) { draft = n.text; naming = n.id }
                    }
                    Spacer(minLength: 6)
                    if let src = Marks.shortSource(n) { Text(src).font(.system(size: 11.5)).foregroundStyle(Ink.mute) }
                }
                .contextMenu {
                    Button("Name This Moment") { draft = n.text; naming = n.id }
                    Button("Delete Moment", role: .destructive) { app.deleteNote(transcript: transcript.id, note: n.id) }
                }
            }
        }
    }

    private func rename(_ n: Note) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        app.store.update(transcript.id) { x in if let i = x.notes.firstIndex(where: { $0.id == n.id }) { x.notes[i].text = text } }
        naming = nil
    }
}

/// Native: the inspector beside an Audio only recording: its moments and its kind.
struct MacAudioInspector: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MacAudioMoments(transcript: transcript)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Details").font(.system(size: 13, weight: .semibold))
                    Picker("Kind", selection: Binding(get: { transcript.kind ?? .audio }, set: { k in app.pickKind(k, for: transcript.id) })) {
                        ForEach(RecordingKind.pickable) { k in Text(k.label).tag(k) }
                    }
                    Text(AudioOnlyCopy.noTemplate).font(.system(size: 12)).foregroundStyle(Ink.mute)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 28)
        }
    }
}
