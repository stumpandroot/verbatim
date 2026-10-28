import SwiftUI
import UIKit

// An Audio only recording's own screen (approved mockup "Verbose Brain Dump", section 4, October 27, 2026), in place of
// the transcript while it has no words: the player as the main content, a title you type, the moments (each takes a
// name you give it, since there's no line to quote), notes, Share, and Transcribe. Tap Transcribe for a plain
// transcribe (a voice note when it's done); touch and hold it to Transcribe as each kind, like Record as. While it
// transcribes, the progress is where Transcribe was, and the screen turns into the transcript when the words are in.
// The tab bar hides, as it does in a transcript.

struct PhoneAudioDetail: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    @Environment(\.look) private var look
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
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30

    private var t: Transcript? { app.store.transcript(id).map(stages.applied(to:)) }

    var body: some View {
        Group {
            if let t {
                if look.isNative { native(t) } else { verbose(t) }
            } else {
                Text("This recording was deleted.").foregroundStyle(.lookMute).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        // Reading: Native's Record accessory turns off with the tab bar (RecordAccessory.swift).
        .onAppear { app.readingScreens.insert(readingToken) }
        .onDisappear { app.readingScreens.remove(readingToken) }
    }

    /// The Audio only screen on screen, for the self-test.
    static var shown: UUID? = nil

    // MARK: Pieces

    private func moments(_ t: Transcript) -> [Note] { t.notes.filter { $0.at != nil }.sorted { ($0.at ?? 0) < ($1.at ?? 0) } }
    private func plainNotes(_ t: Transcript) -> [Note] { t.notes.filter { $0.at == nil } }

    private func when(_ t: Transcript) -> String {
        "\(HomeRecentStyle.day(t.createdAt)), \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
    }

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
    @ViewBuilder private func transcribeControl(_ t: Transcript, native: Bool) -> some View {
        if t.status == .processing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(AudioOnlyRules.statusLine(t)).font(.system(size: 15)).foregroundStyle(native ? AnyShapeStyle(NativeInk.secondary) : AnyShapeStyle(Ink.dim)).lineLimit(2)
                Spacer(minLength: 6)
                if t.processingDevice == Device.id {
                    Button("Cancel") { app.cancel(t.id) }.font(.system(size: 15))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("audio.transcribing")
        } else {
            Menu {
                transcribeItems(t)
            } label: {
                if native {
                    Label("Transcribe", systemImage: "text.bubble").font(.body)   // brand: native
                } else {
                    HStack(spacing: 6) {
                        IconGlyph(art: .iconDictations, size: 15, color: Ink.ink)
                        Text("Transcribe").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                    }
                    .padding(.horizontal, 14).frame(height: 32)
                    .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5))
                    .contentShape(Capsule())
                }
            } primaryAction: {
                app.transcribeLater(t.id)
            }
            .accessibilityLabel("Transcribe")
            .accessibilityHint("Makes a transcript and files it as a voice note. Touch and hold to transcribe as a kind.")
            .accessibilityIdentifier("audio.transcribe")
            .disabled(!AudioOnlyRules.canTranscribe(t))
        }
    }

    // MARK: Verbose

    private func verbose(_ t: Transcript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PhoneEyebrow(text: t.duration > 0 ? "Audio only · \(HomeRecentStyle.length(t.duration))" : "Audio only")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Title", text: titleBinding(t), axis: .vertical)
                        .font(Ink.serif(titleSize)).tracking(-0.6).foregroundStyle(.lookInk).lineLimit(1...3)
                        .accessibilityLabel("Title")
                    IconGlyph(art: .iconFeedback, size: 17, color: Ink.mute).accessibilityHidden(true)
                }
                .padding(.top, 6)
                Text("\(when(t)) · \(AudioOnlyRules.statusLine(t))").font(.system(size: 14)).foregroundStyle(.lookMute).padding(.top, 4)
                if t.status == .failed, let e = t.error {
                    Text(e).font(.system(size: 13)).foregroundStyle(Ink.danger).padding(.top, 4)
                }
                KindChip(kind: t.kind, isAuto: t.kindIsAuto, compact: true) { k in app.pickKind(k, for: t.id) }
                    .padding(.top, 10)

                PhoneAudioPlayer(transcript: t, clock: app.player.clock, native: false)
                    .padding(.top, 18)

                let ms = moments(t)
                HStack(alignment: .firstTextBaseline) {
                    Text("Moments").lookSerif(22).foregroundStyle(.lookInk)
                    if !ms.isEmpty { Text("\(ms.count)").font(Ink.mono(13)).foregroundStyle(.lookMute) }
                }
                .padding(.top, 24)
                if ms.isEmpty {
                    Text("Mark a moment while you record and it shows here.").font(.system(size: 14)).foregroundStyle(.lookMute).padding(.top, 6)
                }
                ForEach(ms) { n in
                    Button { app.player.play(from: n.at ?? 0) } label: {
                        HStack(spacing: 10) {
                            HStack(spacing: 5) {
                                IconGlyph(art: .iconMarked, size: 13, color: Ink.inkFixed)
                                Text(Marks.clock(n.at ?? 0)).font(Ink.mono(12)).foregroundStyle(Ink.inkFixed)
                            }
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(PhoneInk.butter, in: Capsule())
                            Text(n.text.isEmpty ? "Add a name" : n.text).font(.system(size: 15))
                                .foregroundStyle(n.text.isEmpty ? AnyShapeStyle(Ink.mute) : AnyShapeStyle(Ink.ink)).lineLimit(1)
                            Spacer(minLength: 6)
                            if let src = Marks.shortSource(n) { Text(src).font(.system(size: 12.5)).foregroundStyle(.lookMute) }
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(.lookHairline).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { nameDraft = n.text; naming = n } label: { Label("Name this moment", systemImage: "pencil") }   // brand: system surface (context menu)
                    }
                    .accessibilityLabel("Moment at \(Marks.clock(n.at ?? 0)), \(n.text.isEmpty ? "no name" : n.text)")
                    .accessibilityHint("Plays from here. Touch and hold to name it.")
                }

                Text("Notes").lookSerif(22).foregroundStyle(.lookInk).padding(.top, 24)
                let notes = plainNotes(t)
                if notes.isEmpty {
                    Button { addingNote = true } label: { Text("Add a note").font(.system(size: 15)).foregroundStyle(.lookMute) }
                        .buttonStyle(.plain).padding(.top, 6)
                } else {
                    ForEach(notes) { n in
                        Text(n.text).font(.system(size: 16)).foregroundStyle(.lookInk).fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(radius: Radius.row)
                            .padding(.top, 8)
                    }
                }

                HStack(spacing: 8) {
                    Button { share(t) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold))
                            Text("Share").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Ink.ink)
                        .padding(.horizontal, 14).frame(height: 32)
                        .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    transcribeControl(t, native: false)
                }
                .padding(.top, 24)
                Text(AudioOnlyCopy.transcribeFooter).font(.system(size: 13)).foregroundStyle(.lookMute).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 40)
        }
        .phoneTopFade()
        .phonePage(plain: true)
    }

    // MARK: Native
    // brand: native begin

    private func native(_ t: Transcript) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: titleBinding(t), axis: .vertical)
                        .font(.title.bold()).foregroundStyle(NativeInk.label).lineLimit(1...3)
                        .accessibilityLabel("Title")
                    Text("Audio · \(when(t))" + (t.duration > 0 ? " · \(HomeRecentStyle.length(t.duration))" : ""))
                        .font(.subheadline).foregroundStyle(NativeInk.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            }
            Section {
                PhoneAudioPlayer(transcript: t, clock: app.player.clock, native: true)
                    .padding(.vertical, 8)
            }
            Section("Moments") {
                let ms = moments(t)
                if ms.isEmpty {
                    Text("No moments").foregroundStyle(NativeInk.secondary)
                }
                ForEach(ms) { n in
                    Button { app.player.play(from: n.at ?? 0) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill").foregroundStyle(NativeInk.accent)
                            Text(n.text.isEmpty ? "Untitled moment" : n.text).foregroundStyle(n.text.isEmpty ? NativeInk.secondary : NativeInk.label).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Marks.clock(n.at ?? 0)).monospacedDigit().foregroundStyle(NativeInk.secondary)
                        }
                    }
                    .contextMenu { Button { nameDraft = n.text; naming = n } label: { Label("Name this moment", systemImage: "pencil") } }
                    .accessibilityHint("Plays from here. Touch and hold to name it.")
                }
            }
            Section("Notes") {
                ForEach(plainNotes(t)) { n in Text(n.text).foregroundStyle(NativeInk.label) }
                Button("Add a note") { addingNote = true }
            }
            Section {
                transcribeControl(t, native: true)
                if t.status == .failed, let e = t.error { Text(e).font(.footnote).foregroundStyle(NativeInk.danger) }
            } footer: { Text(AudioOnlyCopy.transcribeFooter) }
            Section("Details") {
                Picker("Kind", selection: Binding(get: { t.kind ?? .audio }, set: { k in app.pickKind(k, for: t.id) })) {
                    ForEach(RecordingKind.pickable) { k in Text(k.label).tag(k) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    // brand: native end
}

/// The player that is an Audio only recording's main content: its waveform (the played part in the playback color),
/// the time and length, back 15 seconds, play, and the speed. Observes only the clock, so playback redraws this alone.
struct PhoneAudioPlayer: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock
    var native: Bool

    private var duration: Double { clock.duration > 0 ? clock.duration : transcript.duration }
    private var played: Double { duration > 0 ? min(1, clock.time / duration) : 0 }
    private var loaded: Bool { app.store.audioURL(for: transcript).map { clock.loadedURL == $0 } ?? false }

    var body: some View {
        VStack(spacing: 10) {
            if native {
                AudioWave(levels: transcript.waveform, played: loaded ? played : 0, marks: AudioWave.marks(transcript),
                          bar: NativeInk.tertiary, playedColor: NativeInk.label, mark: NativeInk.accent, bars: 64)   // brand: native
                    .frame(height: 58)
            } else {
                AudioWave(levels: transcript.waveform, played: loaded ? played : 0, marks: AudioWave.marks(transcript),
                          bar: Ink.ink, playedColor: Ink.panelSage, mark: PhoneInk.butter, bars: 64)
                    .frame(height: 76)
            }
            HStack {
                Text(Marks.clock(loaded ? clock.time : 0)).monospacedDigit()
                Spacer()
                Text(native ? "−" + Marks.clock(max(0, duration - (loaded ? clock.time : 0))) : Marks.clock(duration)).monospacedDigit()
            }
            .font(native ? .footnote : Ink.mono(12))
            .foregroundStyle(native ? AnyShapeStyle(NativeInk.secondary) : AnyShapeStyle(Ink.mute))
            HStack(spacing: 36) {
                // Back 5 seconds, as the transcript's player does.
                Button { app.player.seek(to: max(0, clock.time - 5)) } label: {
                    if native { Image(systemName: "gobackward.5").font(.title2) }   // brand: native
                    else { IconGlyph(art: .iconBack5, size: 22, color: Ink.ink) }
                }
                .accessibilityLabel("Back 5 seconds")
                Button { app.player.toggle() } label: {
                    if native {
                        Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34))   // brand: native
                            .foregroundStyle(NativeInk.label)
                    } else {
                        ZStack {
                            Circle().fill(Ink.panelSage)
                            IconGlyph(art: app.player.isPlaying ? .iconPause : .iconPlay, size: 22, color: Ink.inkFixed)
                        }
                        .frame(width: 56, height: 56)
                    }
                }
                .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("audio.play")
                Menu {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { r in
                        Button { app.player.setRate(r) } label: { Text(r == 1 ? "1×" : String(format: "%g×", r)) }
                    }
                } label: {
                    Text(app.player.rate == 1 ? "1×" : String(format: "%g×", app.player.rate))
                        .font(native ? .body.weight(.semibold) : Ink.mono(14)).monospacedDigit()
                        .foregroundStyle(native ? AnyShapeStyle(NativeInk.label) : AnyShapeStyle(Ink.ink))
                        .frame(minWidth: 36)
                }
                .accessibilityLabel("Speed")
            }
            .buttonStyle(.plain)
        }
        .padding(native ? 0 : 16)
        .background { if !native { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Ink.reader) } }
        .overlay { if !native { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline) } }
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
