import SwiftUI
import AppKit

// MARK: - Notes panel

struct NotesPanel: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var selectedSegment: UUID?
    @Binding var detailsOpen: Bool
    var onClose: () -> Void = {}
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var linked: Segment? { selectedSegment.flatMap { id in transcript.segments.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Notes").font(.system(size: 19, weight: .bold))
                Spacer()
                Text("\(transcript.notes.count)").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                Button { onClose() } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 26, height: 26).background(Ink.track, in: Circle()) }
                    .buttonStyle(.plain).help("Hide notes")
            }
            VStack(alignment: .leading, spacing: 6) {
                if let s = linked {
                    HStack(spacing: 6) {
                        ArtIcon(art: .iconLinks, size: 12)
                        Text("On the passage at \(s.start.timecode)").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Ink.iris)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(Ink.mute)
                    TextField(linked == nil ? "Add note… (click a line to link it)" : "Add note on this passage…", text: $draft).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focused).onSubmit(save)
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(focused ? Ink.iris.opacity(0.5) : Ink.hairline))
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(transcript.notes.enumerated()), id: \.element.id) { i, n in
                        NoteCard(note: n, onSeek: { if let at = n.at { app.player.seek(to: at) } }, onDelete: { app.deleteNote(transcript: transcript.id, note: n.id) })
                            .staggerIn(i)
                            .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .identity))
                    }
                    if transcript.notes.isEmpty {
                        Text("Thoughts, quotes to use, things to check. Press B while listening to bookmark a moment.")
                            .font(.system(size: 12.5)).foregroundStyle(Ink.mute).padding(.top, 8)
                    }
                }
            }
            .animation(Motion.bounce, value: transcript.notes.map(\.id))
            Spacer(minLength: 0)
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
                HStack(spacing: 8) { ArtIcon(art: .iconDetails, size: 15); Text("Details") }.font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.notes)
        .overlay(alignment: .leading) { Ink.hairline.frame(width: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimFocusNote)) { _ in focused = true }
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
            Text("Verbatim replaces this transcript's words, speakers, and Dictionary fixes. Your title, notes, and tags stay.")
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

struct NoteCard: View {
    var note: Note
    var onSeek: () -> Void
    var onDelete: () -> Void
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let f = note.frameFile {
                FrameImage(file: f).frame(height: 120).padding(.bottom, 4).tapArea(onSeek)
            }
            if let at = note.at {
                HStack(spacing: 5) {
                    if note.isBookmark { ArtIcon(art: .bookmark, size: 12) }
                    Text(at.timecode).font(.system(size: 11.5, design: .monospaced))
                }
                .foregroundStyle(note.isBookmark ? Ink.butterText : Ink.iris)
                .tapArea(onSeek)
            }
            if let action = note.aiAction {
                // Saved from an action: stays marked as Apple Intelligence's, not the transcript's.
                HStack(spacing: 5) {
                    ArtIcon(art: .iconAI, size: 12)
                    Text("\(action) · Made by Apple Intelligence").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(Ink.dim)
                .accessibilityElement(children: .combine)
            }
            Text(note.text).font(.system(size: 14)).foregroundStyle(Ink.ink).lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Menu { Button("Delete", role: .destructive) { onDelete() } } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hover ? 1 : 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        // Bookmarks on butter tint (saved); notes on neutral cards, so they never borrow an action hue.
        .background(note.isBookmark ? Ink.butterTint : Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
    }
}
