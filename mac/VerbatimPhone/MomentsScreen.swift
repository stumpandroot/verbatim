import SwiftUI

/// Every timed note and bookmark across transcripts, in the website style: a compact title with the count in mono,
/// soft chips (All, Bookmarks, Notes, With stills), and one column of cards. Bookmarks are butter with the quote in
/// the italic serif; notes are paper with an ink outline; a still from kept video sits on top where there is one.
/// The first card without a still of its own shows the circles drawing on sage, the screen's one moving drawing.
struct MomentsScreen: View {
    @EnvironmentObject var app: PhoneState
    /// The chip, kept when a look switch rebuilds Moments (`LookKeep`).
    @State private var show: Show = LookKeep.momentsShow
    /// Pushed inside another tab (Moments isn't in the bar): the navigation bar shows, with Back.
    var pushed = false
    @Environment(\.look) private var look

    enum Show: Hashable { case all, bookmarks, notes, stills }

    var body: some View {
        // Once per library change (Store+Memo.swift), not on every render.
        let all = app.store.memo("phone.moments") { app.store.live.flatMap { t in t.notes.filter { $0.at != nil }.map { Moment(t: t, n: $0) } }.sorted { $0.n.createdAt > $1.n.createdAt } }
        let moments = all.filter { m in
            switch show {
            case .all: return true
            case .bookmarks: return m.n.isBookmark
            case .notes: return !m.n.isBookmark
            case .stills: return m.n.frameFile != nil
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PhoneCompactTitle(title: "Moments", count: "\(all.count) saved")
                    .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PhoneChip(label: "All", selected: show == .all) { show = .all }
                        PhoneChip(label: "Bookmarks", selected: show == .bookmarks) { show = show == .bookmarks ? .all : .bookmarks }
                        PhoneChip(label: "Notes", selected: show == .notes) { show = show == .notes ? .all : .notes }
                        if all.contains(where: { $0.n.frameFile != nil }) {
                            PhoneChip(label: "With stills", selected: show == .stills) { show = show == .stills ? .all : .stills }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 14).padding(.bottom, 4)

                if moments.isEmpty {
                    VStack(spacing: 12) {
                        IconPlate(art: .iconMoments, size: 96)
                        Text(all.isEmpty ? "Bookmark a moment while a transcript plays, or long-press a line." : "Nothing here yet.")
                            .font(.system(size: 15)).foregroundStyle(.lookDim).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                        let t = m.t, n = m.n
                        Button { app.open(t.id, segment: n.segmentId ?? t.segments.last { $0.start <= (n.at ?? 0) }?.id) } label: {
                            PhoneMomentCard(transcript: t, note: n)
                        }
                        .buttonStyle(PhoneCardPress())
                        .contextMenu {
                            if let info = t.linkInfo, info.supportsTimestamps, let u = info.url(at: n.at ?? 0) { Link(destination: u) { Label("Open video", systemImage: "play.rectangle") } }   // brand: system surface (context menu)
                            Button(role: .destructive) { app.deleteNote(t.id, note: n.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            }
        }
        .onChange(of: show) { _, v in LookKeep.momentsShow = v }
        .phonePage()
        .navigationTitle("Moments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if pushed && !look.isNative { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        }
        .toolbar(pushed ? .visible : .hidden, for: .navigationBar)
    }
}

/// One moment: the still on top when there is one, the kind's glyph and the mono timecode with a round play mark, the
/// words (a bookmark's as a quote in the italic serif), and the recording's title in the serif. Bookmarks sit on butter
/// (saved); notes are outlined reader cards. No drawing header, so the list keeps two card styles.
struct PhoneMomentCard: View {
    var transcript: Transcript
    var note: Note
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var quoteSize: CGFloat = 19
    @ScaledMetric(relativeTo: .footnote) private var titleSize: CGFloat = 15
    @Environment(\.look) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        let bookmark = note.isBookmark
        // Native: every card is a grouped card, so text takes the label color.
        let on: Color = look.isNative ? NativeInk.label : bookmark ? Ink.inkFixed : Ink.ink
        return VStack(alignment: .leading, spacing: 0) {
            if let f = note.frameFile {
                StillImage(file: f).frame(height: 120).frame(maxWidth: .infinity).clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconGlyph(art: note.isMark ? .iconMarked : bookmark ? .iconPin : (note.aiAction != nil ? .iconAI : .iconNotes), size: 16, color: on)
                    Text((note.at ?? 0).timecode).lookMono(12).foregroundStyle(on)
                    // Marked while recording: where from ("Lock Screen", "Mac, ⌃⌥B").
                    if let from = Marks.shortSource(note) {
                        Text(from).font(.system(size: 13)).foregroundStyle(on).opacity(0.78).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    ArtIcon(art: .iconPlay, size: 12, lineWidth: 1.4)
                        .foregroundStyle(on)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(on, lineWidth: 1.3))
                        .accessibilityHidden(true)
                }
                if bookmark {
                    Text("“\(Marks.words(note, in: transcript.segments))”").lookSerif(quoteSize).italic().foregroundStyle(on)
                        .lineSpacing(2).lineLimit(6).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(note.text).font(.system(size: textSize)).foregroundStyle(on)
                        .lineSpacing(4).lineLimit(8).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(transcript.title).lookSerif(titleSize).foregroundStyle(on).opacity(0.7).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if bookmark { PhonePanelFill(color: PhoneInk.butter, shape: shape) } else { shape.fill(.lookCard) }
        }
        .clipShape(shape)
        .overlay { if !bookmark, !look.isNative { shape.strokeBorder(Ink.ink, lineWidth: 1.5) } }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bookmark ? "Bookmark" : "Note") at \((note.at ?? 0).timecode)\(Marks.shortSource(note).map { ", marked from \($0)" } ?? ""): \(Marks.words(note, in: transcript.segments)). \(transcript.title)")
        .accessibilityHint("Opens the transcript at this moment.")
    }
}

struct Moment: Identifiable { let t: Transcript; let n: Note; var id: UUID { n.id } }
