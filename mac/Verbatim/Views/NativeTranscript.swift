import SwiftUI
import AppKit

// brand: native file
//
// The transcript's player and inspector in Premium Native (mockup "Premium Native", Mac transcript). The tabs and tools
// are in the window's toolbar (NativeChrome.swift). The player floats at the foot as a rounded bar: play in the accent,
// the time in tabular digits, a slider, the speed, and Follow. It stays opaque (a white card with a soft shadow, not
// glass): DESIGN.md §5.1 keeps text off blur, and §13.1 keeps the Mac's player bar opaque. The inspector stacks the
// summary on a persimmon gradient card, Moments, Speakers, Export and Copy for AI, and Details.

/// The player at the foot of the transcript.
struct NativePlayerBar: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock
    @ObservedObject var nav: NativeNav

    var body: some View {
        let total = max(clock.duration, transcript.duration, 1)
        HStack(spacing: 12) {
            Button { app.player.toggle() } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(PremiumInk.onAccent)
                    .offset(x: app.player.isPlaying ? 0 : 1)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Ink.nativeAccent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).help("Play or pause (Space)")
            .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
            .uiTarget("native-play")
            if let note = clock.note {
                Text(note).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .onAppear { AccessibilityNotification.Announcement(note).post() }
            } else {
                (Text(clock.time.timecode) + Text(" / \(total.timecode)"))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
            }
            Slider(value: Binding(get: { min(clock.time, total) }, set: { app.player.seek(to: $0) }), in: 0...total)
                .controlSize(.small)
                .tint(Ink.nativeAccent)
                .accessibilityLabel("Playback position")
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(String(format: "%g", r))×") { app.player.setRate(Float(r)) } }
                Divider()
                ReduceNoiseToggle(player: app.player)
            } label: {
                Text("\(String(format: "%g", app.player.rate))×").font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Playback speed, and Reduce background noise").accessibilityLabel("Playback speed and noise")
            Button(nav.follow ? "Following" : "Follow") { nav.follow.toggle() }
                .buttonStyle(PremiumBorderedButtonStyle(height: 28, tinted: nav.follow))
                .help(nav.follow ? "The text follows playback. Click to stop following." : "Keep the playing passage in view")
                .accessibilityValue(nav.follow ? "On" : "Off")
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: 52)
        .background {
            Capsule().fill(PremiumInk.card)
                .shadow(color: PremiumInk.shadow, radius: 14, y: 6)
                .overlay(Capsule().strokeBorder(PremiumInk.cardEdge, lineWidth: 0.5))
        }
        .frame(maxWidth: 820)
    }
}

// MARK: - Inspector

/// The transcript's side column in the inspector: the summary card, Moments (click a time to play from it; add one
/// at the selected passage or the playhead), Speakers by talk time, Export and Copy for AI, and Details.
struct PremiumTranscriptInspector: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var nav: NativeNav
    @ObservedObject private var center = SummaryCenter.shared
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmReplace = false
    @State private var note = ""
    @State private var detailsOpen = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Templates' results, unless Show the result first put them above the text (TemplateResultsSection).
                if !TemplateResultsSection.showsFirst(transcript) { TemplateResultsSection(transcript: transcript) }
                summary
                moments
                speakers
                HStack(spacing: 8) {
                    Button("Export…") { app.exportRequest = ExportRequest(ids: [transcript.id]) }
                        .buttonStyle(PremiumProminentButtonStyle())
                        .help("Export as text, Markdown, Word, subtitles, or JSON")
                    Button("Copy for AI") { CopyForAI.copy(transcript, app: app) }
                        .buttonStyle(PremiumBorderedButtonStyle())
                        .help("Copy the text with its title, date, and source for an AI assistant (⌥⇧⌘C)")
                }
                .disabled(transcript.status != .ready)
                TranscriptDetails(transcript: transcript, open: $detailsOpen)
                    .padding(.horizontal, 4).padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 28)
        }
        .scrollIndicators(.never)
        .onReceive(NotificationCenter.default.publisher(for: .verbatimFocusNote)) { _ in noteFocused = true }
        .confirmationDialog("Replace your edited summary?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { SummaryCenter.shared.summarize(transcript.id, store: app.store, replacingEdits: true) }
            Button("Keep Mine", role: .cancel) {}
        } message: {
            Text("Apple Intelligence writes a new summary, and your edits are gone.")
        }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        let running = center.isRunning(transcript.id)
        if editing {
            editor
        } else if let s = transcript.summary, !s.isEmpty {
            let regenerate: (() -> Void)? = Summarizer.available && !running ? { regenerateSummary() } : nil
            PremiumSummaryCard(summary: s, byModel: transcript.summaryByModel,
                               onEdit: { draft = s.plainText; editing = true },
                               onRegenerate: regenerate)
            if running { progress }
        } else if running {
            progress.padding(14).frame(maxWidth: .infinity, alignment: .leading).premiumCard()
        } else if let why = center.failures[transcript.id] {
            VStack(alignment: .leading, spacing: 10) {
                Text(why).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if Summarizer.available {
                    Button("Try Again") { nav.summarize(transcript, app: app) }.buttonStyle(PremiumBorderedButtonStyle(height: 26))
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).premiumCard()
        }
    }

    /// Regenerate asks first when the summary has your edits.
    private func regenerateSummary() {
        if transcript.summaryIsEdited { confirmReplace = true } else { nav.summarize(transcript, app: app) }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            let p = center.progress[transcript.id] ?? 0
            Text(p > 0 ? "Writing a summary… \(Int(p * 100))%" : "Writing a summary…").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An overview, then one key point per line starting with “- ”.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(size: 13)).lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(PremiumInk.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Button("Save") {
                    let parsed = TranscriptSummary.parse(draft)
                    app.store.update(transcript.id) { $0.summary = parsed.isEmpty ? nil : parsed; $0.summaryByModel = false }
                    editing = false
                }
                .buttonStyle(PremiumProminentButtonStyle(height: 26))
                Button("Cancel") { editing = false }.buttonStyle(PremiumBorderedButtonStyle(height: 26))
            }
        }
        .padding(14)
        .premiumCard(radius: 20)
    }

    // MARK: Moments

    private var moments: some View {
        let notes = transcript.notes
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Moments").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !notes.isEmpty { Text("\(notes.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if notes.isEmpty {
                Text("Press B while listening to bookmark a moment, or add a note below.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            ForEach(notes) { n in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let at = n.at {
                        Button(at.timecode) { app.player.seek(to: at) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(PremiumInk.accentText)
                            .frame(minWidth: 34, alignment: .leading)
                            .help("Play from here")
                            .accessibilityLabel("Play from \(at.timecode)")
                    } else {
                        Image(systemName: "note.text").font(.system(size: 11)).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Marks.words(n, in: transcript.segments)).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        // Marked while recording: where from ("Lock Screen", "Mac · ⌃⌥B").
                        if let from = Marks.shortSource(n) {
                            Label(from, systemImage: "bookmark.fill").font(.system(size: 11.5)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .contextMenu {
                    Button("Delete Moment", role: .destructive) { app.deleteNote(transcript: transcript.id, note: n.id) }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField(nav.selectedSegment == nil ? "Add a note…" : "Add a note on this passage…", text: $note)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($noteFocused)
                    .onSubmit(save)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(PremiumInk.fill, in: Capsule())
            .padding(.top, 12)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let linked = nav.selectedSegment.flatMap { id in transcript.segments.first { $0.id == id } }
        app.addNote(transcript: transcript.id, text: text, at: linked?.start ?? (app.player.time > 0 ? app.player.time : nil), segment: linked?.id)
        note = ""
    }

    // MARK: Speakers

    @ViewBuilder private var speakers: some View {
        let shares = SpeakerShares.compute(transcript.segments.map { (speaker: $0.speaker ?? "", seconds: max(0, $0.end - $0.start)) })
            .filter { !$0.id.isEmpty }
        if shares.count >= 2 {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Speakers").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(shares.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityAddTraits(.isHeader)
                ForEach(Array(shares.prefix(6).enumerated()), id: \.element.id) { i, s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(name(s.id)).font(.system(size: 12.5)).lineLimit(1)
                            Spacer()
                            Text("\(s.percent)%").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PremiumInk.fillStrong)
                                Capsule().fill(Ink.nativeAccent.opacity(i == 0 ? 1 : 0.55)).frame(width: g.size.width * CGFloat(s.percent) / 100)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.top, 9)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name(s.id)), \(s.percent) percent")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }

    private func name(_ id: String) -> String {
        let n = transcript.speakers.first(where: { $0.id == id })?.name ?? ""
        return n.isEmpty ? id : n
    }
}
