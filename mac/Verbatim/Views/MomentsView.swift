import SwiftUI
import AppKit

/// Every note and bookmark pinned to a moment, across all transcripts: a reference notebook.
/// Stills appear when the video is on this Mac (kept from a link, or the original import).
struct MomentsView: View {
    @EnvironmentObject var app: AppState
    @State private var kind = "All"

    struct Moment: Identifiable {
        let note: Note
        let transcript: Transcript
        var id: UUID { note.id }
    }

    private var all: [Moment] {
        app.filtered.flatMap { t in t.notes.filter { $0.at != nil }.map { Moment(note: $0, transcript: t) } }
            .sorted { $0.note.createdAt > $1.note.createdAt }
    }
    private var shown: [Moment] {
        let q = app.search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { m in
            switch kind {
            case "Bookmarks": if !m.note.isBookmark { return false }
            case "Notes": if m.note.isBookmark { return false }
            case "With stills": if m.note.frameFile == nil { return false }
            default: break
            }
            return q.isEmpty || m.note.text.lowercased().contains(q) || m.transcript.title.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Moments").font(Ink.serif(30, weight: .regular)).foregroundStyle(Ink.ink)
                    Text("\(shown.count) saved").font(.system(size: 13)).foregroundStyle(Ink.mute)
                    Spacer()
                }
                Text("Notes and bookmarks with a time, from every transcript. Click one to land on that passage. Keep a link's video to get a still for each.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.top, 4)
                HStack(spacing: 6) {
                    ForEach(["All", "Bookmarks", "Notes", "With stills"], id: \.self) { k in SiteChip(label: k, on: kind == k) { kind = k } }
                }
                .padding(.top, 14)
                if shown.isEmpty {
                    HStack(spacing: 16) {
                        IconPlate(art: .iconMoments, size: 80)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(all.isEmpty ? "No moments yet" : "Nothing matches").font(Ink.serif(20, weight: .regular))
                            Text("While a transcript plays, press B to bookmark the moment, or click a line and add a note.")
                                .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
                        }
                        Spacer()
                    }
                    .padding(20).background(NoteCardBackground(hover: false)).padding(.top, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(shown) { m in MomentCard(note: m.note, transcript: m.transcript) }
                    }
                    .padding(.top, 18)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

struct MomentCard: View {
    @EnvironmentObject var app: AppState
    var note: Note
    var transcript: Transcript
    @State private var hover = false

    private var at: Double { note.at ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let f = note.frameFile {
                FrameImage(file: f).frame(height: 150)
            } else if let info = transcript.linkInfo, info.thumbnailFile != nil {
                Thumbnail(info: info).frame(height: 150).opacity(0.85)
            }
            HStack(spacing: 6) {
                if note.isBookmark { Image(systemName: "bookmark.fill").font(.system(size: 10)) }
                Text(at.timecode).font(.system(size: 11.5, design: .monospaced))
                Spacer()
                if let info = transcript.linkInfo, info.supportsTimestamps {
                    Button { if let u = info.url(at: at) { NSWorkspace.shared.open(u) } } label: { Image(systemName: "play.rectangle") }
                        .buttonStyle(.plain).help("Open the video at \(at.timecode)").opacity(hover ? 1 : 0.5)
                }
            }
            .foregroundStyle(note.isBookmark ? Ink.limeText : Ink.iris)
            Text(note.text.isEmpty ? quote : note.text).font(.system(size: 14)).foregroundStyle(Ink.ink).lineSpacing(3).lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(transcript.title).font(Ink.serif(14, weight: .regular)).foregroundStyle(Ink.mute).lineLimit(1)
        }
        .padding(12)
        .background(note.isBookmark ? Ink.limeTint : note.segmentId != nil ? Ink.irisTint : Ink.coralTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .onTapGesture { open() }
        .contextMenu {
            Button("Open transcript at \(at.timecode)") { open() }
            if let info = transcript.linkInfo, info.supportsTimestamps, let u = info.url(at: at) {
                Button("Open video at \(at.timecode)") { NSWorkspace.shared.open(u) }
                Button("Copy link to this moment") { copy(u.absoluteString) }
            }
            if let v = transcript.videoFile { Button("Show video in Finder") { app.showKept(v.path) } }
            Divider()
            Button("Delete", role: .destructive) { app.deleteNote(transcript: transcript.id, note: note.id) }
        }
    }

    /// The passage the moment points at, for bookmarks with no text.
    private var quote: String {
        let seg = transcript.segments.first { $0.id == note.segmentId } ?? transcript.segments.last { $0.start <= at }
        return seg.map { "“\($0.text.trimmingCharacters(in: .whitespaces))”" } ?? "Bookmark"
    }

    private func open() {
        let seg = note.segmentId ?? transcript.segments.last { $0.start <= at }?.id
        app.focusSegment = seg
        app.go(.transcript(transcript.id))
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); app.toast = Toast("Copied") }
}
