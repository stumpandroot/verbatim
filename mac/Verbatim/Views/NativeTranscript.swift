import SwiftUI
import AppKit

// brand: native file
//
// The transcript's player and inspector in the Native look (mockup "Verbose Native Redesign", section 9). Original and
// Cleaned and the tools are in the window's toolbar (NativeChrome.swift). The player floats over the foot of the
// reading column as a system glass bar with text, as Apple's own players are (decision 9; this reverses the opaque bar
// of the October 25 look): play, back 15 seconds, the time in tabular digits, the waveform as the scrubber in label
// color with moments as accent marks, the length, the speed, and Follow. The inspector lists the summary, Moments,
// Speakers with their talk time, Export and Copy for AI, and Details as plain sections.

/// The player at the foot of the transcript.
struct NativePlayerBar: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock
    @ObservedObject var nav: NativeNav

    var body: some View {
        let total = max(clock.duration, transcript.duration, 1)
        HStack(spacing: 10) {
            Button { app.player.toggle() } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).help("Play or pause (Space)")
            .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
            .uiTarget("native-play")
            Button { app.player.seek(to: max(0, app.player.time - 15)) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).help("Back 15 seconds")
            .accessibilityLabel("Back 15 seconds")
            if let note = clock.note {
                Text(note).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .onAppear { AccessibilityNotification.Announcement(note).post() }
            } else {
                Text(clock.time.timecode).font(.system(size: 12.5, weight: .medium).monospacedDigit()).lineLimit(1).fixedSize()
                    .accessibilityLabel("Played \(clock.time.timecode)")
            }
            // The waveform is the scrubber: label color, the played part solid, moments as accent marks.
            WaveTrack(values: transcript.waveform, progress: min(1, clock.time / total),
                      marks: transcript.notes.filter(\.isBookmark).compactMap { $0.at }.map { $0 / total },
                      track: Color.primary.opacity(0.22), played: Color.primary.opacity(0.85), mark: NativeInk.accent, head: Color.primary) { p in
                app.player.seek(to: p * total)
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(clock.time.timecode) of \(total.timecode)")
            .accessibilityAdjustableAction { d in
                app.player.seek(to: max(0, min(total, app.player.time + (d == .increment ? 15 : -15))))
            }
            Text(total.timecode).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(String(format: "%g", r))×") { app.player.setRate(Float(r)) } }
                Divider()
                ReduceNoiseToggle(player: app.player)
            } label: {
                Text("\(String(format: "%g", app.player.rate))×").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Playback speed, and Reduce background noise").accessibilityLabel("Playback speed and noise")
            Button { nav.follow.toggle() } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(nav.follow ? AnyShapeStyle(NativeInk.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(nav.follow ? "The text follows playback. Click to stop following." : "Keep the playing passage in view")
            .accessibilityLabel("Follow playback")
            .accessibilityValue(nav.follow ? "On" : "Off")
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .frame(height: 46)
        .nativeGlassBar()
        .frame(maxWidth: 720)
    }
}

extension View {
    /// Native's player bar: the system's glass in a capsule (macOS 26), which turns solid under Reduce Transparency.
    /// Text on it is the system's own (DESIGN.md §13.5). Earlier systems draw the toolbar's material.
    @ViewBuilder func nativeGlassBar() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.bar, in: Capsule())
                .overlay(Capsule().strokeBorder(NativeInk.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Inspector

/// The transcript's side column in the inspector, as plain sections with bold headings (mockup section 9): Templates'
/// results, the summary, Moments (click a time to play from it; add a note at the selected passage or the playhead),
/// Speakers with their talk time, Export and Copy for AI, and Details.
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
            VStack(alignment: .leading, spacing: 18) {
                // Templates' results, unless Show the result first put them above the text (TemplateResultsSection).
                if !TemplateResultsSection.showsFirst(transcript) { TemplateResultsSection(transcript: transcript) }
                summary
                moments
                speakers
                HStack(spacing: 8) {
                    Button("Export…") { app.exportRequest = ExportRequest(ids: [transcript.id]) }
                        .buttonStyle(.borderedProminent)
                        .help("Export as text, Markdown, Word, subtitles, or JSON")
                    Button("Copy for AI") { CopyForAI.copy(transcript, app: app) }
                        .buttonStyle(.bordered)
                        .help("Copy the text with its title, date, and source for an AI assistant (⌥⇧⌘C)")
                }
                .disabled(transcript.status != .ready)
                TranscriptDetails(transcript: transcript, open: $detailsOpen)
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

    private func heading(_ title: String, count: Int? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let count, count > 0 { Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        let running = center.isRunning(transcript.id)
        if editing {
            editor
        } else if let s = transcript.summary, !s.isEmpty {
            let regenerate: (() -> Void)? = Summarizer.available && !running ? { regenerateSummary() } : nil
            VStack(alignment: .leading, spacing: 8) {
                NativeSummaryText(summary: s, byModel: transcript.summaryByModel,
                                  onEdit: { draft = s.plainText; editing = true },
                                  onRegenerate: regenerate)
                if running { progress }
            }
        } else if running {
            VStack(alignment: .leading, spacing: 6) { heading("Summary"); progress }
        } else if let why = center.failures[transcript.id] {
            VStack(alignment: .leading, spacing: 8) {
                heading("Summary")
                Text(why).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if Summarizer.available {
                    Button("Try Again") { nav.summarize(transcript, app: app) }.controlSize(.small)
                }
            }
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
            heading("Summary")
            Text("An overview, then one key point per line starting with “- ”.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(size: 13)).lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(6)
                .background(NativeInk.content, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(NativeInk.separator))
            HStack(spacing: 8) {
                Button("Save") {
                    let parsed = TranscriptSummary.parse(draft)
                    app.store.update(transcript.id) { $0.summary = parsed.isEmpty ? nil : parsed; $0.summaryByModel = false }
                    editing = false
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { editing = false }
            }
            .controlSize(.small)
        }
    }

    // MARK: Moments

    private var moments: some View {
        let notes = transcript.notes
        return VStack(alignment: .leading, spacing: 0) {
            heading("Moments", count: notes.count)
            if notes.isEmpty {
                Text("Press B while listening to bookmark a moment, or add a note below.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            ForEach(notes) { n in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: n.isBookmark ? "bookmark.fill" : "note.text").font(.system(size: 11))
                        .foregroundStyle(n.isBookmark ? AnyShapeStyle(NativeInk.accent) : AnyShapeStyle(.secondary))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    if let at = n.at {
                        Button(at.timecode) { app.player.seek(to: at) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(NativeInk.accent)
                            .frame(minWidth: 32, alignment: .leading)
                            .help("Play from here")
                            .accessibilityLabel("Play from \(at.timecode)")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Marks.words(n, in: transcript.segments)).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        // Marked while recording: where from, in the one short form (DESIGN.md §18.3: "Lock Screen",
                        // "Mac · ⌃⌥B").
                        if let from = Marks.shortSource(n) {
                            Text(from).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 9)
                .contextMenu {
                    Button("Delete Moment", role: .destructive) { app.deleteNote(transcript: transcript.id, note: n.id) }
                }
            }
            TextField(nav.selectedSegment == nil ? "Add a note…" : "Add a note on this passage…", text: $note)
                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                .focused($noteFocused)
                .onSubmit(save)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                heading("Speakers", count: shares.count)
                ForEach(shares.prefix(6), id: \.id) { s in
                    HStack(spacing: 9) {
                        // Initials on system gray, as Contacts draws a person with no photo.
                        Text(initial(name(s.id))).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Circle().fill(Color(nsColor: .systemGray)))
                            .accessibilityHidden(true)
                        Text(name(s.id)).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(s.seconds.timecode).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name(s.id)), \(s.seconds.timecode), \(s.percent) percent")
                }
            }
        }
    }

    private func name(_ id: String) -> String {
        let n = transcript.speakers.first(where: { $0.id == id })?.name ?? ""
        return n.isEmpty ? id : n
    }

    private func initial(_ name: String) -> String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }
}
