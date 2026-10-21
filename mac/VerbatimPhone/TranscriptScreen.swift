import SwiftUI
import UIKit

/// A transcript: title, source, modes (Transcript, Document, Review), the reading lines, and a floating glass
/// player. Long-press a line to bookmark it, add a note, copy it, or open the video at that moment.
struct TranscriptScreen: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    var startMode: Mode = .transcript
    enum Mode: Hashable { case transcript, document, review }
    @State private var mode: Mode = .transcript
    @State private var showNotes = false
    @State private var shareItems: [Any]? = nil
    @State private var noteFor: Segment? = nil
    @State private var noteText = ""
    @State private var downloading = false
    @State private var didStart = false
    /// The system push slides the screen in; header, modes, and text stagger in behind it.
    @State private var seen = SeenRows()
    /// "2 filler lines hidden · Show": per screen, starting from Settings › Hide filler lines.
    @State private var showFiller = false
    @AppStorage(Transcript.hideFillerKey) private var hideFillerSetting = true
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false
    /// Why Summarize can't run here (Apple Intelligence unavailable), shown when the action is chosen.
    @State private var summaryUnavailable: String? = nil

    private var t: Transcript? { app.store.transcript(id) }

    var body: some View {
        Group {
            if let t {
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(t)
                                    .riseIn("header", index: 0, seen: seen, epoch: 0, base: 0.2, scrollRise: false)
                                if t.status == .ready {
                                    ModePicker(options: [(Mode.transcript, "Transcript"), (.document, "Document"), (.review, "Review")], selection: $mode)
                                        .padding(.top, 16)
                                        .riseIn("modes", index: 1, seen: seen, epoch: 0, base: 0.2, scrollRise: false)
                                }
                                content(t).padding(.top, 14)
                                    .riseIn("content", index: 2, seen: seen, epoch: 0, base: 0.2, scrollRise: false)
                            }
                            .padding(.horizontal, 20).padding(.top, 4)
                            .padding(.bottom, t.audioFileName != nil && t.status == .ready && mode != .document ? 120 : 32)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onAppear {
                            if let f = app.focusSegment, t.segments.contains(where: { $0.id == f }) {
                                app.focusSegment = nil; mode = .transcript
                                DispatchQueue.main.async { proxy.scrollTo(f, anchor: .center) }
                            }
                        }
                    }
                    if t.audioFileName != nil, t.status == .ready, mode != .document {
                        PhoneDock(transcript: t, clock: app.player.clock, downloading: downloading)
                            .padding(.horizontal, 14).padding(.bottom, 8)
                    }
                }
                .background(Ink.paper.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if t.status == .ready, t.audioFileName != nil, t.pendingAppend == nil {
                            Button { app.player.stop(); app.continueRecording(t.id) } label: { Image(systemName: "record.circle") }
                                .accessibilityLabel("Continue recording")
                        }
                        Button { showNotes = true } label: { Image(systemName: "note.text") }.accessibilityLabel("Notes")
                        Menu {
                            Button {
                                if let why = SummaryAction.unavailableReason { summaryUnavailable = why }
                                else { SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: false) }
                            } label: { Label(SummaryAction.title(t), systemImage: "text.quote") }
                            .disabled(t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
                            Divider()
                            Button { app.copyText(t) } label: { Label("Copy text", systemImage: "doc.on.doc") }
                            Divider()
                            ForEach(ExportFormat.allCases) { f in
                                Button(f.rawValue) { if let u = app.exportFile(t, as: f) { shareItems = [u] } }
                            }
                        } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Copy and export")
                        .disabled(t.status != .ready)
                    }
                }
                .alert("Summaries need Apple Intelligence", isPresented: Binding(get: { summaryUnavailable != nil }, set: { if !$0 { summaryUnavailable = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(summaryUnavailable ?? "") }
                .sheet(isPresented: $showNotes) { NotesSheet(id: id).presentationDetents([.medium, .large]) }
                .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ShareSheet(items: shareItems ?? []) }
                .alert("Add a note", isPresented: Binding(get: { noteFor != nil }, set: { if !$0 { noteFor = nil } })) {
                    TextField("Note", text: $noteText)
                    Button("Cancel", role: .cancel) { noteText = "" }
                    Button("Add") { if let s = noteFor { app.addNote(id, text: noteText, at: s.start, segment: s.id) }; noteText = "" }
                } message: { Text(noteFor.map { "At \($0.start.timecode)" } ?? "") }
                .onAppear {
                    if !didStart { didStart = true; mode = startMode }
                    if let u = app.store.audioURL(for: t) {
                        downloading = !Cloud.isDownloaded(u)
                        app.player.loadAsync(u)
                        if downloading { Task { _ = await Cloud.ensureDownloaded(u); downloading = false } }
                    }
                }
                .onDisappear { app.player.stop() }
            } else {
                Text("This transcript was deleted.").foregroundStyle(Ink.mute).frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.paper)
            }
        }
    }

    private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: Binding(get: { t.title }, set: { v in
                guard v != t.title else { return }
                app.store.updateDeferred(t.id) { $0.title = v; $0.titleIsAuto = false; $0.titleByModel = false }
            }), axis: .vertical)
                .font(Ink.serif(28)).foregroundStyle(Ink.ink).lineLimit(1...3)
            HStack(spacing: 6) {
                Text(t.sourceLabel)
                if t.duration > 0 { Text("·"); Text(t.duration.timecode).font(Ink.mono(13)) }
                if t.speakers.count >= 2 { Text("·"); Text("\(t.speakers.count) speakers") }
                if let k = t.kind { Text("·"); Text(k.label) }
            }
            .font(.system(size: 14)).foregroundStyle(Ink.mute)
            if t.titleIsAuto && t.titleByModel { AITitleNote() }
            if t.status == .ready {
                KindAndTags(transcript: t,
                            onPick: { k in app.store.update(t.id) { $0.kind = k; $0.kindIsAuto = false } },
                            onTags: { tags in app.store.update(t.id) { $0.tags = tags } })
                    .padding(.top, 8)
            }
            if t.pendingAppend != nil {
                HStack(spacing: 8) {
                    if t.processingDevice != nil { ProgressView().controlSize(.small) } else { Image(systemName: "waveform.badge.plus").foregroundStyle(Ink.accentText) }
                    Text(t.stageText).font(.system(size: 14)).foregroundStyle(Ink.dim).lineLimit(2)
                    Spacer(minLength: 4)
                    if t.processingDevice == nil {
                        Menu {
                            Button { app.retry(t) } label: { Label("Try again", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) { app.discardPendingAppend(t.id) } label: { Label("Discard new recording", systemImage: "trash") }
                        } label: { Text("Retry").font(.system(size: 14, weight: .semibold)) }
                    } else if t.processingDevice == Device.id {
                        Button("Cancel") { app.cancel(t.id) }.font(.system(size: 14))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Ink.persimmonTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 6)
            } else if t.status == .ready, t.stage == "Finding speakers" {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Finding speakers…") }
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            if let info = t.linkInfo { PhoneLinkCard(info: info).padding(.top, 8) }
        }
    }

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing {
            HStack(spacing: 14) {
                SignalRings(active: t.processingDevice == Device.id).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.stageText).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(t.processingDevice == Device.id ? "On this iPhone. The first run downloads the model once." : "It appears here when it's done.")
                        .font(.system(size: 14)).foregroundStyle(Ink.mute)
                }
            }
            .padding(.top, 20)
        } else if t.status == .failed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) { IconGlyph(art: .iconAttention, size: 20, color: Ink.accentText); Text("Transcription did not finish") }.font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.accentText)
                Text(t.error ?? "").font(.system(size: 14)).foregroundStyle(Ink.mute)
                Button("Retry") { app.retry(t) }.buttonStyle(.brandPrimary)
            }
            .padding(.top, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if mode != .review {
                    SummaryBlock(transcript: t, compact: true,
                                 onSummarize: { replacing in SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: replacing) },
                                 onSave: { s in app.store.update(t.id) { $0.summary = s; $0.summaryByModel = false } })
                }
                switch mode {
                case .transcript:
                    let background = mainSpeakerOnly ? t.backgroundSegments : []
                    VStack(alignment: .leading, spacing: 10) {
                        PhoneLines(transcript: t, segments: t.displaySegments(hideFiller: hideFillerSetting && !showFiller, mainOnly: mainSpeakerOnly),
                                   clock: app.player.clock, onNote: { noteFor = $0 })
                        if hideFillerSetting, t.fillerCount > 0 {
                            FillerToggle(count: t.fillerCount, shown: $showFiller).padding(.leading, 62)
                        }
                        if !background.isEmpty {
                            BackgroundVoicesCard(segments: background,
                                                 onPlay: { s in app.player.seek(to: s.start) },
                                                 onMoveBack: { s in if let main = t.mainSpeaker { app.assign(t.id, segment: s.id, to: main) } })
                                .padding(.top, 8)
                        }
                    }
                case .document: PhoneDocument(transcript: t)
                case .review: review(t)
                }
            }
        }
    }

    private func review(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if t.corrections.isEmpty {
                HStack(spacing: 14) {
                    EmptyStateArt(art: .refine, tint: Ink.petalTint)
                    Text("Nothing changed yet. Dictionary fixes and your corrections show here beside the original.").font(.system(size: 14)).foregroundStyle(Ink.dim)
                }
            }
            ForEach(t.corrections) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.byDictionary ? "book.closed" : "pencil").foregroundStyle(Ink.ink).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { Text(c.from).strikethrough().foregroundStyle(Ink.mute); Image(systemName: "arrow.right").font(.system(size: 10)); Text(c.to).fontWeight(.semibold) }
                        if let seg = t.segments.first(where: { $0.id == c.segmentId }) { Text(seg.text).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2) }
                    }
                    Spacer()
                    Button("Undo") {
                        app.store.undoCorrection(c, in: t.id)
                    }
                    .buttonStyle(.brandSecondary)
                }
                .padding(12)
                .cardSurface(radius: 12)
            }
        }
    }
}

/// The reading lines. Reads the playhead without observing it: the lines re-render only when the playing
/// passage changes (`playingIDs`), not on every 20 Hz tick, so the playing tint moves without re-rendering the screen.
struct PhoneLines: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    /// The lines to show (filler and background voices already left out by the screen).
    var segments: [Segment]
    var clock: PlayerClock
    var onNote: (Segment) -> Void
    @State private var renaming: Speaker? = nil
    @State private var newName = ""
    /// The passages under the playhead as of the last tick. Only a change here re-renders the lines; the tint
    /// itself is worked out from the clock in `body`.
    @State private var playingIDs: Set<UUID> = []

    /// The playing rule: under the playhead, and either playing or moved off the start.
    static func playing(_ segments: [Segment], at now: Double, isPlaying: Bool) -> Set<UUID> {
        guard isPlaying || now > 0 else { return [] }
        var out = Set<UUID>()
        for s in segments where now >= s.start && now < s.end { out.insert(s.id) }
        return out
    }

    var body: some View {
        let _ = playingIDs
        let saved = Set(transcript.notes.filter(\.isBookmark).compactMap(\.segmentId))
        let segs = segments
        let current = Self.playing(segs, at: clock.time, isPlaying: app.player.isPlaying)
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(segs.enumerated()), id: \.element.id) { i, s in
                let showSpeaker = transcript.speakers.count >= 2 && s.speaker != nil && (i == 0 || segs[i - 1].speaker != s.speaker)
                let playing = current.contains(s.id)
                VStack(alignment: .leading, spacing: 3) {
                    if showSpeaker, let n = transcript.speakerName(s.speaker) {
                        // Tap the name to rename the speaker or move this line to someone else.
                        Menu {
                            if let sid = s.speaker, let sp = transcript.speakers.first(where: { $0.id == sid }) {
                                Button { newName = sp.name; renaming = sp } label: { Label("Rename \(n)…", systemImage: "pencil") }
                            }
                            Section("This line is") {
                                ForEach(transcript.speakers) { sp in
                                    Button { app.assign(transcript.id, segment: s.id, to: sp.id) } label: {
                                        Label(sp.label, systemImage: sp.id == s.speaker ? "checkmark" : "person")
                                    }
                                }
                                Button { app.assign(transcript.id, segment: s.id, to: nil) } label: { Label("No speaker", systemImage: "person.slash") }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(n).font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Ink.dim).padding(.top, 10).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Speaker: \(n). Rename or reassign")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(s.start.timecode).font(Ink.mono(12)).foregroundStyle(Ink.mute).frame(width: 44, alignment: .leading)
                            .onTapGesture { app.player.seek(to: s.start); if !app.player.isPlaying { app.player.toggle() } }
                            .accessibilityLabel("Play from \(s.start.timecode)").accessibilityAddTraits(.isButton)
                        Text(s.text).font(.system(size: 17)).foregroundStyle(Ink.ink).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 6)
                    .background(playing ? Ink.playing : saved.contains(s.id) ? Ink.saved : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .id(s.id)
                .contentShape(Rectangle())
                .contextMenu {
                    Button { app.addNote(transcript.id, text: String(s.text.prefix(60)), at: s.start, segment: s.id, bookmark: true) } label: { Label("Bookmark", systemImage: "bookmark") }
                    Button { onNote(s) } label: { Label("Add note…", systemImage: "note.text.badge.plus") }
                    Button { UIPasteboard.general.string = "“\(s.text)”"; app.say("Quote copied") } label: { Label("Copy quote", systemImage: "quote.opening") }
                    if let info = transcript.linkInfo, info.supportsTimestamps, let u = info.url(at: s.start) {
                        Button { UIPasteboard.general.string = "“\(s.text)” \(u.absoluteString)"; app.say("Quote and link copied") } label: { Label("Copy quote with link", systemImage: "link") }
                        Link(destination: u) { Label("Open video at \(s.start.timecode)", systemImage: "play.rectangle") }
                    }
                }
            }
        }
        .alert("Name this speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("First and last name", text: $newName).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { if let sp = renaming { app.renameSpeaker(transcript.id, speaker: sp.id, to: newName) }; renaming = nil }
        } message: { Text("Changes every line from this speaker, on this iPhone and your Mac.") }
        .onReceive(clock.$time) { now in syncPlaying(at: now) }
        .onChange(of: app.player.isPlaying) { _, _ in syncPlaying(at: clock.time) }
        .onChange(of: transcript.segments) { _, _ in syncPlaying(at: clock.time) }
    }

    @MainActor private func syncPlaying(at now: Double) {
        let ids = Self.playing(transcript.segments, at: now, isPlaying: app.player.isPlaying)
        if ids != playingIDs { playingIDs = ids }
    }
}

/// The floating glass player: play, skip, scrubber, time, speed, bookmark.
struct PhoneDock: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock
    var downloading: Bool
    var body: some View {
        let total = max(app.player.duration, transcript.duration, 0.1)
        VStack(spacing: 8) {
            Slider(value: Binding(get: { min(clock.time, total) }, set: { app.player.seek(to: $0) }), in: 0...total)
                .tint(Ink.persimmon)
                .accessibilityLabel("Playback position")
            HStack(spacing: 18) {
                Text("\(clock.time.timecode) / \(total.timecode)").font(Ink.mono(12.5)).foregroundStyle(Ink.ink)
                Spacer()
                Button { app.player.seek(to: max(0, clock.time - 5)) } label: { Image(systemName: "gobackward.5") }.accessibilityLabel("Back 5 seconds")
                Button { app.player.toggle() } label: {
                    Group {
                        if downloading { ProgressView().tint(Ink.onInteractive) }
                        else { Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold)) }
                    }
                    .foregroundStyle(Ink.onInteractive).frame(width: 50, height: 50)
                }
                .buttonStyle(RaisedKeyStyle(fill: Ink.interactive))
                .disabled(downloading)
                .accessibilityLabel(downloading ? "Downloading audio" : app.player.isPlaying ? "Pause" : "Play")
                Button { app.player.seek(to: min(total, clock.time + 5)) } label: { Image(systemName: "goforward.5") }.accessibilityLabel("Forward 5 seconds")
                Spacer()
                Button {
                    let at = clock.time
                    let seg = transcript.segments.first { at >= $0.start && at < $0.end }
                    app.addNote(transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
                } label: { Image(systemName: "bookmark") }.accessibilityLabel("Bookmark this moment")
            }
            .font(.system(size: 18)).foregroundStyle(Ink.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .floatingGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct PhoneLinkCard: View {
    var info: LinkInfo
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.track)
                if let f = info.thumbnailFile { StillImage(file: f).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
                else { Image(systemName: "play.rectangle").foregroundStyle(Ink.mute) }
            }
            .frame(width: 72, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text([info.channel, info.site].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(info.uploadDisplay ?? URL(string: info.url)?.host ?? "").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let u = URL(string: info.url) {
                Link(destination: u) { Image(systemName: "play.rectangle").font(.system(size: 18)) }.foregroundStyle(Ink.ink).accessibilityLabel("Open video")
            }
        }
        .padding(8)
        .cardSurface(radius: 12)
    }
}

/// Notes and bookmarks for one transcript, newest first, with an add field.
struct NotesSheet: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a note…", text: $draft, axis: .vertical).focused($focused)
                        Button("Add") {
                            let at = app.player.loadedURL != nil && app.player.time > 0 ? app.player.time : nil
                            app.addNote(id, text: draft, at: at, segment: nil); draft = ""
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(app.store.transcript(id)?.notes ?? []) { n in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                if n.isBookmark { Image(systemName: "bookmark.fill").font(.system(size: 11)) }
                                if let at = n.at { Text(at.timecode).font(Ink.mono(12)) }
                            }
                            .foregroundStyle(n.isBookmark ? Ink.sageText : Ink.accentText)
                            if let f = n.frameFile { StillImage(file: f).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8)) }
                            Text(n.text).font(.system(size: 15)).foregroundStyle(Ink.ink)
                        }
                        .listRowBackground(n.isBookmark ? Ink.butterTint : n.segmentId != nil ? Ink.petalTint : Ink.persimmonTint)
                        .onTapGesture { if let at = n.at { app.player.seek(to: at) } }
                    }
                    .onDelete { idx in
                        let notes = app.store.transcript(id)?.notes ?? []
                        for i in idx { app.deleteNote(id, note: notes[i].id) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper)
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
