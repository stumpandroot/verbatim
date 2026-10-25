import SwiftUI
import AppKit

// brand: web style
//
// The transcript's side column in the website style (mac/DESIGN.md §11): the Summary on a butter panel with grain and
// the `strands` drawing, the Moments (notes and bookmarks) in a paper card with an ink outline, Export and Copy for AI
// pills, and Details.

// MARK: - Side column

struct NotesPanel: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var selectedSegment: UUID?
    @Binding var detailsOpen: Bool
    var onClose: () -> Void = {}
    /// Over the text in a narrow window: opaque paper, a close button, and a hairline edge.
    var drawer = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var linked: Segment? { selectedSegment.flatMap { id in transcript.segments.first { $0.id == id } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if drawer {
                    HStack {
                        Spacer()
                        Button { onClose() } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.dim)
                                .frame(width: 28, height: 28).background(Ink.chip, in: Circle())
                        }
                        .buttonStyle(.plain).help("Hide the side column").accessibilityLabel("Hide the side column")
                    }
                }
                TranscriptSummaryCard(transcript: transcript)
                moments
                actions
                details.padding(.top, 4)
            }
            .padding(.top, drawer ? 16 : 8).padding(.bottom, 28)
            .padding(.horizontal, drawer ? 18 : 2)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(drawer ? Ink.paper : Color.clear)
        .overlay(alignment: .leading) { if drawer { Ink.hairline.frame(width: 1) } }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimFocusNote)) { _ in focused = true }
    }

    // MARK: Moments

    /// "◇ Moments · 3", then each note or bookmark (its time in mono; click the time to play from there), and the
    /// field that adds one (linked to the selected passage, or to the playhead).
    private var moments: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: transcript.notes.isEmpty ? "Moments" : "Moments · \(transcript.notes.count)")
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            ForEach(Array(transcript.notes.enumerated()), id: \.element.id) { i, n in
                NoteCard(note: n, onSeek: { if let at = n.at { app.player.seek(to: at) } }, onDelete: { app.deleteNote(transcript: transcript.id, note: n.id) })
                    .staggerIn(i)
                    .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .identity))
            }
            if transcript.notes.isEmpty {
                Text("Thoughts, quotes to use, things to check. Press B while listening to bookmark a moment.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let s = linked {
                    HStack(spacing: 6) {
                        ArtIcon(art: .iconLinks, size: 12)
                        Text("On the passage at \(s.start.timecode)").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Ink.dim)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute)
                    TextField(linked == nil ? "Add note… (click a line to link it)" : "Add note on this passage…", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Ink.ink)
                        .focused($focused).onSubmit(save)
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(Ink.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: focused ? 2 : 1.5))
            }
            .padding(.top, 12)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .inkEdge(outline: true, radius: Radius.record)
        .animation(Motion.bounce, value: transcript.notes.map(\.id))
    }

    // MARK: Actions and details

    private var actions: some View {
        HStack(spacing: 8) {
            PillButton(title: "Export", kind: .dark, trailing: .arrow, enabled: transcript.status == .ready,
                       hint: "Export as text, Markdown, Word, subtitles, or JSON") {
                app.exportRequest = ExportRequest(ids: [transcript.id])
            }
            .help("Export as text, Markdown, Word, subtitles, or JSON")
            PillButton(title: "Copy for AI", kind: .line, enabled: transcript.status == .ready,
                       hint: "Copies the text with a header for an AI assistant") {
                CopyForAI.copy(transcript, app: app)
            }
            .help("Copy the text with its title, date, and source for an AI assistant (⌥⇧⌘C)")
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $detailsOpen) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Source", transcript.provenanceSource)
                row("Engine", transcript.model.isEmpty ? "—" : transcript.model)
                GridRow {
                    Text("Language").foregroundStyle(Ink.mute)
                    if transcript.status == .ready, transcript.audioFileName != nil, transcript.pendingAppend == nil {
                        TranscriptLanguageMenuMac(transcript: transcript)
                    } else {
                        Text(transcript.language.map(LanguageDetection.name) ?? "—").foregroundStyle(Ink.ink)
                    }
                }
                // Same count as splitting `text` (the segments joined by spaces), without building the joined string.
                row("Words", "\(transcript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count })")
                row("Dictionary", "\(transcript.corrections.filter(\.byDictionary).count) fixes")
                row("Kept", "On this Mac")
                row("Created", Formats.style(date: .medium, time: .short).string(from: transcript.createdAt))
                // Where the data went: local audio and text, a link's host, or cloud cleanup (Views/TrustViews.swift).
                GridRow(alignment: .top) { Text("Data").foregroundStyle(Ink.mute); DataPathBadge(transcript: transcript) }
            }
            .font(.system(size: 12.5)).padding(.top, 6)
            Picker("Project", selection: Binding(get: { transcript.projectId }, set: { v in app.store.update(transcript.id) { $0.projectId = v } })) {
                Text("None").tag(UUID?.none)
                ForEach(app.store.projects) { p in Text(p.name).tag(UUID?.some(p.id)) }
            }
            .controlSize(.small).padding(.top, 6)
            Button(role: .destructive) {
                app.go(.library)
                app.delete([transcript.id])
            } label: { Label("Delete transcript", systemImage: "trash") }
            .buttonStyle(.plain).foregroundStyle(Ink.mute).font(.system(size: 12.5)).padding(.top, 8)
        } label: {
            HStack(spacing: 8) { ArtIcon(art: .iconDetails, size: 15); Text("Details") }.font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
        }
    }

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        app.addNote(transcript: transcript.id, text: t, at: linked?.start ?? (app.player.time > 0 ? app.player.time : nil), segment: linked?.id)
        draft = ""
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(Ink.mute); Text(v).foregroundStyle(Ink.ink) }
    }
}

// MARK: - Summary card

/// The transcript's Summary on a butter panel (paper grain, the `strands` drawing): a mono eyebrow that folds it, the
/// overview in serif, up to 5 key points, the AI label, and Edit and Regenerate as fixed-ink pills. Same behavior as
/// the shared `SummaryBlock` (Edit makes it the person's own; Regenerate asks before replacing an edited one), drawn
/// in fixed ink so it reads on butter in both appearances. Shows only when `SummaryBlock.shows` says so.
struct TranscriptSummaryCard: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    /// The drawing moves; at most one per screen, so pass false where another one already moves.
    var moving = true

    @ObservedObject private var center = SummaryCenter.shared
    @AppStorage("summary.collapsed") private var collapsed = false
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmReplace = false
    @Environment(\.limitMotion) private var limitMotion

    private var animation: Animation { limitMotion ? Motion.fade : Motion.settle }
    private var running: Bool { center.isRunning(transcript.id) }

    var body: some View {
        if SummaryBlock.shows(transcript, center: center) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !collapsed { content.transition(.opacity) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .colorPanel(Ink.panelButter, radius: Radius.record) {
                PanelArt(kind: .strands, running: moving).frame(width: 170, height: 113).offset(x: 4, y: -18)
            }
            .confirmationDialog("Replace your edited summary?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { summarize(replacing: true) }
                Button("Keep mine", role: .cancel) {}
            } message: {
                Text("Apple Intelligence writes a new summary, and your edits are gone.")
            }
        }
    }

    private func summarize(replacing: Bool) {
        SummaryCenter.shared.summarize(transcript.id, store: app.store, replacingEdits: replacing)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Eyebrow(text: "Summary", color: Ink.panelInk)
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.panelInk.opacity(0.7))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .tapArea { withAnimation(animation) { collapsed.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Summary")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(collapsed ? "Shows the summary" : "Hides the summary")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityAction { withAnimation(animation) { collapsed.toggle() } }
    }

    @ViewBuilder private var content: some View {
        if editing {
            editor
        } else if let s = transcript.summary {
            VStack(alignment: .leading, spacing: 12) {
                if !s.overview.isEmpty {
                    Text(s.overview).font(Ink.serif(18)).foregroundStyle(Ink.panelInk).lineSpacing(2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !s.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .top, spacing: 9) {
                                Circle().fill(Ink.panelInk).frame(width: 4, height: 4).padding(.top, 7)
                                Text(p).font(.system(size: 13.5)).foregroundStyle(Ink.panelInk).lineSpacing(2)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Key points")
                }
                footer(s)
            }
        } else if running {
            progressRow
        } else if let why = center.failures[transcript.id] {
            VStack(alignment: .leading, spacing: 10) {
                Text(why).font(.system(size: 13)).foregroundStyle(Ink.panelInk).fixedSize(horizontal: false, vertical: true)
                if Summarizer.available {
                    PillButton(title: "Try again", kind: .line, size: .mini, fixedInk: true) { summarize(replacing: false) }
                }
            }
        }
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progressText).font(.system(size: 13)).foregroundStyle(Ink.panelInk)
        }
    }

    private var progressText: String {
        if let p = center.progress[transcript.id], p > 0 { return "Writing a summary… \(Int(p * 100))%" }
        return "Writing a summary…"
    }

    private func footer(_ s: TranscriptSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if transcript.summaryByModel {
                Label { Text(AIGeneratedNote.summary) } icon: { ArtIcon(art: .iconAI, size: 13) }
                    .font(.system(size: 12)).foregroundStyle(Ink.panelInk.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
            if running {
                progressRow
            } else if let why = center.failures[transcript.id] {
                Text(why).font(.system(size: 12.5)).foregroundStyle(Ink.panelInk).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                PillButton(title: "Edit", kind: .line, size: .mini, fixedInk: true) {
                    draft = s.plainText
                    withAnimation(animation) { editing = true }
                }
                if Summarizer.available, !running {
                    PillButton(title: "Regenerate", kind: .line, size: .mini, fixedInk: true) {
                        if transcript.summaryIsEdited { confirmReplace = true } else { summarize(replacing: false) }
                    }
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An overview, then one key point per line starting with “- ”.")
                .font(.system(size: 12)).foregroundStyle(Ink.inkFixed.opacity(0.8))
            TextEditor(text: $draft)
                .font(.system(size: 13.5)).lineSpacing(3).foregroundStyle(Ink.inkFixed)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(Ink.readerFixed, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.inkFixed, lineWidth: 1.5))
            HStack(spacing: 8) {
                PillButton(title: "Save", kind: .dark, size: .mini, fixedInk: true) {
                    let parsed = TranscriptSummary.parse(draft)
                    app.store.update(transcript.id) { $0.summary = parsed.isEmpty ? nil : parsed; $0.summaryByModel = false }
                    withAnimation(animation) { editing = false }
                }
                PillButton(title: "Cancel", kind: .line, size: .mini, fixedInk: true) {
                    withAnimation(animation) { editing = false }
                }
            }
        }
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


/// One moment in the Moments card: a hairline above, the time in mono (a bookmark glyph before it; click to play from
/// there), and the note. A still from a link sits above it. Saved from an action, it says so. The ⋯ menu (under the
/// pointer) and the context menu delete it.
struct NoteCard: View {
    var note: Note
    var onSeek: () -> Void
    var onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let f = note.frameFile {
                FrameImage(file: f).frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .tapArea(onSeek)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let at = note.at {
                    HStack(spacing: 4) {
                        if note.isBookmark { ArtIcon(art: .bookmark, size: 12) }
                        Text(at.timecode).font(Ink.mono(12))
                    }
                    .foregroundStyle(note.isBookmark ? Ink.butterText : Ink.dim)
                    .fixedSize()
                    .tapArea(onSeek)
                    .help("Play from here")
                    .accessibilityAddTraits(.isButton)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let action = note.aiAction {
                        // Saved from an action: stays marked as Apple Intelligence's, not the transcript's.
                        HStack(spacing: 5) {
                            ArtIcon(art: .iconAI, size: 12)
                            Text("\(action) · Made by Apple Intelligence").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(Ink.dim)
                        .accessibilityElement(children: .combine)
                    }
                    Text(note.text.isEmpty ? (note.isBookmark ? "Bookmark" : "") : note.text)
                        .font(.system(size: 13)).foregroundStyle(Ink.ink).lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 18)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
        .overlay(alignment: .topTrailing) {
            Menu { Button("Delete", role: .destructive) { onDelete() } } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.top, 9)
            .opacity(hover ? 1 : 0)
            .accessibilityLabel("More actions for this moment")
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { Button("Delete", role: .destructive) { onDelete() } }
        .animation(Motion.touch, value: hover)
    }
}
