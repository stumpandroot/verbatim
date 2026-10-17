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
                        Image(systemName: "link").font(.system(size: 10, weight: .bold))
                        Text("On the passage at \(s.start.timecode)").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Ink.iris)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(Ink.mute)
                    TextField(linked == nil ? "Add note… (click a line to link it)" : "Add note on this passage…", text: $draft).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focused).onSubmit(save)
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Ink.iris.opacity(0.5) : Ink.hairline))
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
                    row("Source", transcript.sourceLabel)
                    row("Engine", transcript.model.isEmpty ? "—" : transcript.model)
                    if let l = transcript.language { row("Language", l.uppercased()) }
                    // Same count as splitting `text` (the segments joined by spaces), without building the joined string.
                    row("Words", "\(transcript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count })")
                    row("Dictionary", "\(transcript.corrections.filter(\.byDictionary).count) fixes")
                    row("Kept", "On this Mac")
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
                HStack(spacing: 8) { Image(systemName: "info.circle"); Text("Details") }.font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
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
                    if note.isBookmark { Image(systemName: "bookmark.fill").font(.system(size: 10)) }
                    Text(at.timecode).font(.system(size: 11.5, design: .monospaced))
                }
                .foregroundStyle(note.isBookmark ? Ink.limeText : Ink.iris)
                .tapArea(onSeek)
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
        // Solid tinted blocks by kind: coral for a loose note, lime for a bookmark, iris for a passage note.
        .background(note.isBookmark ? Ink.limeTint : note.segmentId != nil ? Ink.irisTint : Ink.coralTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.hairline))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
    }
}
