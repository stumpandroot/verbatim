import SwiftUI
import UIKit

// An Audio only recording's own screen (approved mockup "Verbose Brain Dump", section 4, October 27, 2026), on the
// refined kit (DESIGN.md §13) in both look settings, in place of the transcript while it has no words: a title you
// type over the kind's chip and when, the player as the main content (AudioPlayerCard), the moments (each takes a name
// you give it, since there's no line to quote), notes, Transcribe, and Share. Tap Transcribe for a plain transcribe (a
// voice note when it's done); touch and hold it to Transcribe as each kind, like Record as. While it transcribes, the
// progress is where Transcribe was, and the screen turns into the transcript when the words are in. The tab bar hides,
// as it does in a transcript.

struct PhoneAudioDetail: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var shareItems: [Any]? = nil
    /// This screen's place in `PhoneState.readingScreens`.
    @State private var readingToken = UUID()
    @State private var naming: Note? = nil
    @State private var nameDraft = ""
    @State private var addingNote = false
    @State private var noteDraft = ""
    @State private var confirmDelete = false
    /// Live progress while it transcribes (StageClock), so a tick redraws this screen's status only.
    @ObservedObject private var stages = StageClock.shared

    private var t: Transcript? { app.store.transcript(id).map(stages.applied(to:)) }

    var body: some View {
        Group {
            if let t {
                page(t)
            } else {
                Text("This recording was deleted.").refinedFont(.body).foregroundStyle(Refined.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbar }
        .onAppear {
            Self.shown = id
            if let t, let u = app.store.audioURL(for: t) { app.player.loadAsync(u) }
        }
        .onDisappear { app.player.stop(); if Self.shown == id { Self.shown = nil } }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ShareSheet(items: shareItems ?? []) }
        .alert("Name this moment", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Moment", text: $nameDraft)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") {
                if let n = naming {
                    let text = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    app.store.update(id) { x in if let i = x.notes.firstIndex(where: { $0.id == n.id }) { x.notes[i].text = text } }
                }
                naming = nil
            }
        }
        .alert("Add a note", isPresented: $addingNote) {
            TextField("Note", text: $noteDraft)
            Button("Cancel", role: .cancel) { noteDraft = "" }
            Button("Add") {
                let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { app.store.addNote(Note(text: text), to: id) }
                noteDraft = ""
            }
        }
        .confirmationDialog("Move this recording to Recently Deleted?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { app.delete([id]); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can restore it for 30 days.") }
        // Reading: Record's accessory turns off with the tab bar (RecordAccessory.swift).
        .onAppear { app.readingScreens.insert(readingToken) }
        .onDisappear { app.readingScreens.remove(readingToken) }
    }

    /// The Audio only screen on screen, for the self-test.
    static var shown: UUID? = nil

    // MARK: Pieces

    private func moments(_ t: Transcript) -> [Note] { t.notes.filter { $0.at != nil }.sorted { ($0.at ?? 0) < ($1.at ?? 0) } }
    private func plainNotes(_ t: Transcript) -> [Note] { t.notes.filter { $0.at == nil } }

    private func titleBinding(_ t: Transcript) -> Binding<String> {
        Binding(get: { t.title }, set: { v in
            guard v != t.title else { return }
            app.store.updateDeferred(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
        })
    }

    private func share(_ t: Transcript) {
        guard let u = app.store.audioURL(for: t) else { app.say("The audio isn't on this iPhone yet."); return }
        Task { @MainActor in
            if !Cloud.isDownloaded(u) { app.say("Downloading the audio…"); _ = await Cloud.ensureDownloaded(u) }
            guard FileManager.default.fileExists(atPath: u.path) else { app.say("The audio isn't on this iPhone yet. Try again in a moment."); return }
            shareItems = [u]
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let t {
                Button { share(t) } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
                Menu {
                    transcribeItems(t)
                    Divider()
                    Button { RenameCenter.shared.begin(t) } label: { Label("Rename", systemImage: "pencil") }   // brand: system surface (menu)
                    Button { addingNote = true } label: { Label("Add a note", systemImage: "note.text") }   // brand: system surface (menu)
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
                .accessibilityIdentifier("audio.more")
            }
        }
    }

    /// Transcribe as each kind, like Record as: Voice note, then the kinds.
    @ViewBuilder private func transcribeItems(_ t: Transcript) -> some View {
        Section("Transcribe as") {
            ForEach(AudioOnlyRules.transcribeChoices, id: \.self) { k in
                Button(AudioOnlyRules.choiceName(k)) { app.transcribeLater(t.id, as: k) }
            }
        }
        .disabled(!AudioOnlyRules.canTranscribe(t))
    }

    /// Transcribe: a tap is the plain transcribe; touch and hold opens Transcribe as. While it runs, the progress sits
    /// here instead.
    @ViewBuilder private func transcribeControl(_ t: Transcript) -> some View {
        if t.status == .processing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(AudioOnlyRules.statusLine(t)).refinedFont(.body).foregroundStyle(Refined.dim).lineLimit(2)
                Spacer(minLength: 6)
                if t.processingDevice == Device.id {
                    Button("Cancel") { app.cancel(t.id) }.buttonStyle(RefinedActionStyle())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("audio.transcribing")
        } else {
            Menu {
                transcribeItems(t)
            } label: {
                HStack(spacing: 6) {
                    IconGlyph(art: .iconDictations, size: 16, color: Refined.paper)
                    Text("Transcribe")
                }
            } primaryAction: {
                app.transcribeLater(t.id)
            }
            .menuStyle(.button)
            .buttonStyle(RefinedActionStyle(kind: .strong))
            .accessibilityLabel("Transcribe")
            .accessibilityHint("Makes a transcript and files it as a voice note. Touch and hold to transcribe as a kind.")
            .accessibilityIdentifier("audio.transcribe")
            .disabled(!AudioOnlyRules.canTranscribe(t))
        }
    }

    private func page(_ t: Transcript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: titleBinding(t), axis: .vertical)
                    .refinedFont(.transcriptTitle).foregroundStyle(Refined.ink).lineLimit(1...3)
                    .accessibilityLabel("Title")
                    .accessibilityAddTraits(.isHeader)
                FlowRow(spacing: 8, lineSpacing: 2) {
                    KindPickerChip(kind: t.kind ?? .audio, isAuto: t.kindIsAuto) { k in app.pickKind(k, for: t.id) }
                    Text(RefinedRules.transcriptWhen(t.createdAt) + " \u{00B7} " + AudioOnlyRules.statusLine(t))
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                }
                .padding(.top, 6)
                if t.status == .failed, let e = t.error {
                    Text(e).refinedFont(.meta).foregroundStyle(Refined.accentText).padding(.top, 4)
                }

                PhoneAudioPlayer(transcript: t, player: app.player, clock: app.player.clock)
                    .padding(.top, 14)

                let ms = moments(t)
                SerifSectionTitle(title: "Moments") {
                    if !ms.isEmpty { Text("\(ms.count)").refinedFont(.hint).monospacedDigit().foregroundStyle(Refined.mute) }
                }
                .padding(.top, 24).padding(.bottom, 8)
                if ms.isEmpty {
                    Text("Mark a moment while you record and it shows here.").refinedFont(.body).foregroundStyle(Refined.mute)
                } else {
                    PaperList(ms, id: \.id, inset: 14) { n in
                        Button { app.player.play(from: n.at ?? 0) } label: {
                            HStack(spacing: 10) {
                                MomentChip(time: Marks.clock(n.at ?? 0))
                                Text(n.text.isEmpty ? "Add a name" : n.text).refinedFont(.body)
                                    .foregroundStyle(n.text.isEmpty ? Refined.mute : Refined.ink).lineLimit(1)
                                Spacer(minLength: 6)
                                if let src = Marks.shortSource(n) { Text(src).refinedFont(.meta).foregroundStyle(Refined.mute) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { nameDraft = n.text; naming = n } label: { Label("Name this moment", systemImage: "pencil") }   // brand: system surface (context menu)
                        }
                        .accessibilityLabel("Moment at \(Marks.clock(n.at ?? 0)), \(n.text.isEmpty ? "no name" : n.text)")
                        .accessibilityHint("Plays from here. Touch and hold to name it.")
                        .accessibilityAction(named: "Name this moment") { nameDraft = n.text; naming = n }
                    }
                }

                SerifSectionTitle("Notes").padding(.top, 24).padding(.bottom, 8)
                let notes = plainNotes(t)
                if notes.isEmpty {
                    RefinedLink(title: "Add a note") { addingNote = true }
                } else {
                    PaperList(notes, id: \.id, inset: 14) { n in
                        Text(n.text).refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    RefinedLink(title: "Add a note") { addingNote = true }
                }

                HStack(spacing: 8) {
                    transcribeControl(t)
                    Button { share(t) } label: { Text("Share") }
                        .buttonStyle(RefinedActionStyle())
                }
                .padding(.top, 24)
                Text(AudioOnlyCopy.transcribeFooter).refinedFont(.meta).foregroundStyle(Refined.mute).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 40)
        }
    }
}

/// The player that is an Audio only recording's main content (the kit's `AudioPlayerCard`): its waveform, the time
/// and length, back 5 seconds, play, and the speed. Observes the player and the clock, so playback redraws this alone.
struct PhoneAudioPlayer: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @ObservedObject var player: Player
    @ObservedObject var clock: PlayerClock

    private var duration: Double { clock.duration > 0 ? clock.duration : transcript.duration }
    private var loaded: Bool { app.store.audioURL(for: transcript).map { clock.loadedURL == $0 } ?? false }

    var body: some View {
        AudioPlayerCard(isPlaying: player.isPlaying, elapsed: loaded ? clock.time : 0, duration: duration,
                        levels: transcript.waveform, moments: AudioWave.marks(transcript),
                        speed: PlaybackSync.speedLabel(player.rate),
                        onPlayPause: { player.toggle() }, onSeek: { player.seek(to: $0) }) {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { r in Text(PlaybackSync.speedLabel(r)).tag(r) }
            }
        }
        .accessibilityIdentifier("audio.player")
    }
}

// MARK: - In the Library

/// An Audio only row's play button and waveform in the Library (DESIGN.md §6.8): plays here, without opening it. The
/// play disc is sage (sage means playback), the played part of the waveform follows playback while this recording is
/// the one playing, and its moments are butter ticks.
struct PhoneAudioRowPlayer: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript

    var body: some View { RowPlayer(transcript: transcript, clock: app.player.clock) }
}

/// The row player's body, observing only the playhead's clock.
private struct RowPlayer: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock

    private var url: URL? { app.store.audioURL(for: transcript) }
    private var isMine: Bool { url != nil && clock.loadedURL == url }
    private var playing: Bool { isMine && app.player.isPlaying }
    private var played: Double { isMine && clock.duration > 0 ? clock.time / clock.duration : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button { play() } label: {
                ZStack {
                    Circle().fill(Refined.sage)
                    IconGlyph(art: playing ? .iconPause : .iconPlay, size: 14, color: Refined.onFill)
                }
                .frame(width: 34, height: 34)
                .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playing ? "Pause" : "Play")
            .accessibilityHint("Plays \(transcript.title) here, without opening it.")
            .accessibilityIdentifier("library.audio.play")
            AudioWave(levels: transcript.waveform, played: played, marks: AudioWave.marks(transcript),
                      bar: Refined.waveRest, playedColor: Refined.played, mark: Refined.butter, bars: 54)
                .frame(height: 30)
                .accessibilityHidden(true)
        }
    }

    private func play() {
        guard let url else { app.say("The audio isn't on this iPhone yet."); return }
        if isMine, app.player.canPlay { app.player.toggle() } else { app.player.loadAsync(url, autoplay: true) }
    }
}
