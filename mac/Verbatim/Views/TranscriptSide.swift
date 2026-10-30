import SwiftUI
import AppKit

// The Mac transcript's parts around the reading column, on the refined kit (DESIGN.md §13):
// the side column (the inspector in Native, a column beside the text in Verbose style) with Moments, Speakers, Export
// and Copy for AI, and Details; the Share and More menus (the toolbar's in Native, the page's in Verbose style); the
// glass player bar; and the kind-change offer under the header.

// MARK: - Side column

/// Moments (click a time to play from it; add a note at the selected passage or the playhead), Speakers with their
/// talk time, Export and Copy for AI, and Details. The summary and a template's results are tabs of their own.
struct TranscriptSide: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var nav: WindowNav
    @State private var note = ""
    @State private var detailsOpen = false
    @State private var renaming: Note? = nil
    @State private var renameDraft = ""
    @FocusState private var noteFocused: Bool

    private var linked: Segment? { nav.selectedSegment.flatMap { id in transcript.segments.first { $0.id == id } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                moments
                speakers
                HStack(spacing: 8) {
                    Button("Export…") { app.exportRequest = ExportRequest(ids: [transcript.id]) }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .help("Export as text, Markdown, Word, subtitles, or JSON")
                    Button("Copy for AI") { CopyForAI.copy(transcript, app: app) }
                        .buttonStyle(RefinedActionStyle())
                        .help("Copy the text with its title, date, and source for an AI assistant (⌥⇧⌘C)")
                }
                .disabled(transcript.status != .ready)
                TranscriptDetails(transcript: transcript, open: $detailsOpen)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 28)
        }
        .scrollIndicators(.never)
        .background(Refined.paper)
        .onReceive(NotificationCenter.default.publisher(for: .verbatimFocusNote)) { _ in noteFocused = true }
        .alert("Rename this moment", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Moment", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { if let n = renaming { app.renameNote(transcript: transcript.id, note: n.id, to: renameDraft) }; renaming = nil }
        } message: { Text("Your words replace the quoted line.") }
    }

    private func heading(_ title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
            Spacer()
            if let count, count > 0 { Text("\(count)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Moments

    private var moments: some View {
        let notes = transcript.notes
        return VStack(alignment: .leading, spacing: 8) {
            heading("Moments", count: notes.count)
            if notes.isEmpty {
                Text("Press B while listening to mark a moment, or add a note below.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
            } else {
                PaperList(notes, id: \.id, inset: 12, trailingInset: 12) { n in momentRow(n) }
            }
            if let s = linked {
                Text("On the passage at \(RefinedRules.time(s.start))").refinedFont(.meta).foregroundStyle(Refined.dim)
            }
            TextField(linked == nil ? "Add a note…" : "Add a note on this passage…", text: $note)
                .textFieldStyle(.plain).refinedFont(.body).foregroundStyle(Refined.ink)
                .focused($noteFocused)
                .onSubmit(save)
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(Refined.field, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous))
                .help("Click a line to link the note to it")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func momentRow(_ n: Note) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let at = n.at {
                Button { app.player.play(from: at) } label: {
                    HStack(spacing: 4) {
                        if n.isBookmark || n.isMark { MomentMark() }
                        Text(RefinedRules.time(at)).refinedFont(.meta, weight: .semibold).monospacedDigit().foregroundStyle(Refined.accentText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play from here")
                .accessibilityLabel("Play from \(RefinedRules.spokenTime(at))")
            }
            VStack(alignment: .leading, spacing: 2) {
                if let action = n.aiAction {
                    // Saved from an action: stays marked as Apple Intelligence's, not the transcript's.
                    HStack(spacing: 5) {
                        IconGlyph(art: .iconAI, size: 12, color: Refined.dim)
                        Text("\(action) · Made by Apple Intelligence").refinedFont(.caption, weight: .semibold).foregroundStyle(Refined.dim).lineLimit(1)
                    }
                }
                Text(Marks.words(n, in: transcript.segments)).refinedFont(.body).foregroundStyle(Refined.ink)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // Marked while recording: where from, in the one short form (DESIGN.md §18.3).
                if let from = Marks.shortSource(n) { Text(from).refinedFont(.caption).foregroundStyle(Refined.mute) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            if let at = n.at { Button("Play from \(RefinedRules.time(at))") { app.player.play(from: at) } }
            Button("Rename…") { renameDraft = Marks.words(n, in: transcript.segments); renaming = n }
            Divider()
            Button("Delete Moment", role: .destructive) { app.deleteNote(transcript: transcript.id, note: n.id) }
        }
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        app.addNote(transcript: transcript.id, text: text, at: linked?.start ?? (app.player.time > 0 ? app.player.time : nil), segment: linked?.id)
        note = ""
    }

    // MARK: Speakers

    @ViewBuilder private var speakers: some View {
        let shares = SpeakerShares.compute(transcript.segments.map { (speaker: $0.speaker ?? "", seconds: max(0, $0.end - $0.start)) })
            .filter { !$0.id.isEmpty }
        if shares.count >= 2 {
            let order = transcript.speakerOrder
            VStack(alignment: .leading, spacing: 8) {
                heading("Speakers", count: shares.count)
                PaperList(Array(shares.prefix(8)), id: \.id, inset: 12, trailingInset: 12) { s in
                    HStack(spacing: 8) {
                        SpeakerChip(name: name(s.id), index: order[s.id] ?? 0)
                        Spacer(minLength: 8)
                        Text("\(RefinedRules.time(s.seconds)) · \(s.percent)%").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name(s.id)), \(RefinedRules.spokenTime(s.seconds)), \(s.percent) percent")
                }
            }
        }
    }

    private func name(_ id: String) -> String {
        let n = transcript.speakers.first(where: { $0.id == id })?.name ?? ""
        return n.isEmpty ? id : n
    }
}

/// Details under the side column: source, engine, language (Transcribe again in another one), words, Dictionary fixes,
/// where it's kept, when it was made, where the data went, its project, and Delete.
struct TranscriptDetails: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @Binding var open: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Source", transcript.provenanceSource)
                row("Engine", transcript.model.isEmpty ? "—" : transcript.model)
                GridRow {
                    Text("Language").foregroundStyle(Refined.mute)
                    if transcript.status == .ready, transcript.audioFileName != nil, transcript.pendingAppend == nil {
                        TranscriptLanguageMenuMac(transcript: transcript)
                    } else {
                        Text(transcript.language.map(LanguageDetection.name) ?? "—").foregroundStyle(Refined.ink)
                    }
                }
                // Same count as splitting `text` (the segments joined by spaces), without building the joined string.
                row("Words", "\(transcript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count })")
                row("Dictionary", "\(transcript.corrections.filter(\.byDictionary).count) fixes")
                row("Kept", "On this Mac")
                row("Created", Formats.style(date: .medium, time: .short).string(from: transcript.createdAt))
                // Where the data went: local audio and text, a link's host, or cloud cleanup (Views/TrustViews.swift).
                GridRow(alignment: .top) { Text("Data").foregroundStyle(Refined.mute); DataPathBadge(transcript: transcript) }
            }
            .refinedFont(.meta).padding(.top, 6)
            Picker("Project", selection: Binding(get: { transcript.projectId }, set: { v in app.store.update(transcript.id) { $0.projectId = v } })) {
                Text("None").tag(UUID?.none)
                ForEach(app.store.projects) { p in Text(p.name).tag(UUID?.some(p.id)) }
            }
            .controlSize(.small).padding(.top, 6)
            Button(role: .destructive) {
                app.go(.library)
                app.delete([transcript.id])
            } label: { Text("Move to Recently Deleted") }
            .buttonStyle(.plain).foregroundStyle(Refined.mute).refinedFont(.meta).padding(.top, 8)
        } label: {
            Text("Details").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(Refined.mute); Text(v).foregroundStyle(Refined.ink).textSelection(.enabled) }
    }
}

/// Details › Language: what the transcript was transcribed in, and Transcribe again in… another language.
private struct TranscriptLanguageMenuMac: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    /// The language picked, waiting for the confirmation (`.some(nil)`: detect automatically).
    @State private var pending: String?? = nil

    var body: some View {
        Menu {
            Section("Transcribe again in") {
                Button("Detect automatically") { pending = .some(nil) }
                ForEach(LanguageDetection.pickableV3, id: \.self) { item($0) }
            }
            Section("With Apple speech recognition") {
                ForEach(LanguageDetection.pickableApple, id: \.self) { item($0) }
            }
        } label: {
            Text(transcript.language.map(LanguageDetection.name) ?? "Set language")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Transcribe again in another language")
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Transcribe Again") {
                if let choice = pending { app.coordinator.rerun(transcript.id, language: choice) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Verbose replaces this transcript's words, speakers, and Dictionary fixes. Your title, notes, and tags stay.")
        }
    }

    private func item(_ code: String) -> some View {
        Toggle(LanguageDetection.name(code), isOn: Binding(get: { code == transcript.language }, set: { _ in pending = .some(code) }))
    }

    private var confirmTitle: String {
        guard let choice = pending else { return "" }
        return choice.map { "Transcribe again in \(LanguageDetection.name($0))?" } ?? "Transcribe again and detect the language?"
    }
}

// MARK: - Share and More

/// Share's items: copy the tab you're on (⇧⌘C), with timestamps, the other version, the engine's words, for AI, and
/// Export. The toolbar's Share in Native and the page's in Verbose style.
struct TranscriptShareItems: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var nav: WindowNav

    var body: some View {
        let t = transcript
        Button("Copy (⇧⌘C)") { ExportMenu.copy(t, nav.copyVersion, app: app) }
        Button("Copy with Timestamps") { ExportMenu.copy(t, nav.copyVersion, timestamps: true, app: app) }
        Button(nav.copyVersion == .cleaned ? "Copy the Original" : "Copy the Cleaned Text") { ExportMenu.copy(t, nav.copyVersion.other, app: app) }
        Button("Copy Engine Words") { ExportMenu.copy(t, .engine, app: app) }
            .disabled(!t.hasEngineWords)
        Button("Copy for AI (⌥⇧⌘C)") { CopyForAI.copy(t, app: app) }
        Divider()
        Button("Export…") { app.exportRequest = ExportRequest(ids: [t.id]) }
    }
}

/// More's items: Mark This Moment, Continue Recording, Run a Template, Run an Action, Summarize, Review Changes, the
/// words to show and Select Text, Follow Playback, Transcribe Again with Whisper Turbo, and Text Size. The toolbar's
/// More in Native and the page's in Verbose style.
struct TranscriptMoreItems: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var nav: WindowNav

    var body: some View {
        let t = transcript
        let ready = t.status == .ready
        Button("Mark This Moment (B)") { nav.bookmark(t, app: app) }
            .disabled(t.audioFileName == nil || !ready)
        Button("Continue Recording") { app.continueRecording(t.id) }
            .disabled(!ready || t.audioFileName == nil || t.pendingAppend != nil || t.isAudioOnly || app.recorder.isRecording)
        Divider()
        Menu("Run a Template") {
            ForEach(TemplateOrigin.allCases) { o in
                let items = app.store.allTemplates.filter { $0.origin == o }
                if !items.isEmpty {
                    Section(o.title) {
                        ForEach(items) { tpl in
                            Button(tpl.name) { TemplateCenter.shared.run(tpl.id, on: t.id, store: app.store); nav.mode = .result }
                        }
                    }
                }
            }
        }
        .disabled(!ready)
        Menu("Run an Action") { ActionsMenuItems(transcript: t.id) { nav.runningAction = $0 } }
            .disabled(!ready)
        Button(SummaryAction.title(t)) { nav.mode = .summary; nav.summarize(t, app: app) }
            .disabled(!ready || t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
        Toggle("Review Changes", isOn: Binding(get: { nav.mode == .review }, set: { on in if on != (nav.mode == .review) { nav.toggleReview() } }))
            .disabled(!ready)
        Divider()
        Toggle("Show Engine Words", isOn: Binding(get: { nav.showEngine }, set: { v in nav.showEngine = v; if v { nav.mode = .original } }))
            .disabled(!ready)
        Toggle("Select Text", isOn: Binding(get: { nav.selecting }, set: { v in nav.selecting = v; if v { nav.mode = .original } }))
            .disabled(!ready)
        Toggle("Follow Playback", isOn: $nav.follow)
        Divider()
        Button(TurboRerun.title + "…") { app.turboAsk = t.id }
            .disabled(!ready || TurboRerun.unavailableReason(t) != nil)
        if let other = TurboRerun.switchTitle(t) { Button(other) { app.switchTranscriptVersion(t.id) } }
        Divider()
        Menu("Text Size") {
            Button("Larger Text (⌘+)") { nav.textSize = WindowNav.textSizes.clamp(nav.textSize + 1) }
            Button("Smaller Text (⌘−)") { nav.textSize = WindowNav.textSizes.clamp(nav.textSize - 1) }
            Button("Default Size") { nav.textSize = WindowNav.textSizes.normal }
        }
    }
}

// MARK: - Player

/// The transcript's player: the kit's glass bar (`GlassPlayerBar`) with the rail, its moments, the length, and the
/// speed's menu (the speeds, back and forward 5 seconds, Reduce background noise, Mark this moment, Follow playback).
/// Observes the player and the clock, so playback redraws the bar alone.
struct MacPlayerBar: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var player: Player
    @ObservedObject var clock: PlayerClock
    @ObservedObject var nav: WindowNav

    var body: some View {
        let total = max(clock.duration, transcript.duration, 1)
        GlassPlayerBar(isPlaying: player.isPlaying, elapsed: min(clock.time, total), duration: total,
                       moments: transcript.notes.filter { $0.isBookmark || $0.isMark }.compactMap(\.at),
                       speed: PlaybackSync.speedLabel(player.rate), status: clock.note,
                       onPlayPause: {
                           if !player.isPlaying { nav.follow = true }
                           player.toggle()
                       },
                       onSeek: { player.seek(to: $0) }) {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(PlaybackSync.speeds, id: \.self) { r in Text(PlaybackSync.speedLabel(r)).tag(r) }
            }
            Divider()
            Button("Back 5 Seconds (←)") { player.seek(to: max(0, clock.time - 5)) }
            Button("Forward 5 Seconds (→)") { player.seek(to: min(total, clock.time + 5)) }
            ReduceNoiseToggle(player: player)
            Divider()
            Button("Mark This Moment (B)") { nav.bookmark(transcript, app: app) }
            Toggle("Follow Playback", isOn: $nav.follow)
        }
        .help("Space plays or pauses; ← and → move 5 seconds")
        // The self-test's handle on the play button, which leads the bar.
        .overlay(alignment: .leading) {
            Color.clear.frame(width: 34, height: 34).padding(.leading, 9).allowsHitTesting(false).uiTarget("native-play")
        }
    }
}

// MARK: - The kind-change offer

/// "Now a Journal. Run Daily reflection?" or "Now a Brain dump. Run Plan my day?" under the header when the kind
/// changed after a template ran, or a recording was filed as a Brain dump: Run runs it (and opens its tab), Not now
/// never offers again. Nothing runs on its own.
struct KindOfferRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var onRun: () -> Void = {}
    @ObservedObject private var center = TemplateCenter.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared

    var body: some View {
        if let offer = AutoRunRules.offer(transcript, settings: auto.settings, templates: app.store.allTemplates),
           !center.isPending(transcript.id), center.busyTemplate(transcript.id) == nil {
            HStack(spacing: 10) {
                Text(offer.text).refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Run") {
                    center.run(offer.template, on: transcript.id, store: app.store, replacing: offer.result, kind: offer.kind)
                    onRun()
                }
                .buttonStyle(RefinedActionStyle(kind: .strong))
                .uiTarget("result-offer-run")
                Button("Not now") {
                    app.store.update(transcript.id) { x in
                        if offer.result == nil { AutoRunRules.dismissBrainDumpOffer(offer, on: &x, device: Device.id); return }
                        if let i = x.templateResults?.firstIndex(where: { $0.id == offer.result }) { x.templateResults?[i].offerDismissed = offer.kind.rawValue }
                    }
                }
                .buttonStyle(RefinedActionStyle())
                .uiTarget("result-offer-dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
    }
}
