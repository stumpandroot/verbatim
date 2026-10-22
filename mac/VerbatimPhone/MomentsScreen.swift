import SwiftUI

/// Every timed note and bookmark across transcripts, with stills from kept video (made on the Mac).
struct MomentsScreen: View {
    @EnvironmentObject var app: PhoneState
    /// Cards rise in once; the first screenful staggers when you switch to Moments.
    @State private var seen = SeenRows()
    @State private var entrance = 0
    var body: some View {
        let moments = app.store.live.flatMap { t in t.notes.filter { $0.at != nil }.map { Moment(t: t, n: $0) } }.sorted { $0.n.createdAt > $1.n.createdAt }
        ScrollView {
            if moments.isEmpty {
                VStack(spacing: 12) {
                    IconPlate(art: .iconMoments, size: 96)
                    Text("Bookmark a moment while a transcript plays, or long-press a line.").font(.system(size: 15)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                }
                .padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                    let t = m.t, n = m.n
                    Button { app.open(t.id, segment: n.segmentId ?? t.segments.last { $0.start <= (n.at ?? 0) }?.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let f = n.frameFile { StillImage(file: f).frame(height: 96).clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)) }
                            HStack(spacing: 4) {
                                if n.isBookmark { ArtIcon(art: .bookmark, size: 12) }
                                Text((n.at ?? 0).timecode).font(Ink.mono(11.5))
                            }
                            .foregroundStyle(n.isBookmark ? Ink.butterText : Ink.dim)
                            Text(n.text).font(.system(size: 14)).foregroundStyle(Ink.ink).lineLimit(4).multilineTextAlignment(.leading)
                            Text(t.title).font(Ink.serif(13)).foregroundStyle(Ink.mute).lineLimit(1)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(n.isBookmark ? Ink.butterTint : Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(n.isBookmark ? Color.clear : Ink.hairline))
                    }
                    .buttonStyle(SoftPress())
                    .riseIn(m.id, index: i, seen: seen, epoch: entrance)
                    .contextMenu {
                        if let info = t.linkInfo, info.supportsTimestamps, let u = info.url(at: n.at ?? 0) { Link(destination: u) { Label("Open video", systemImage: "play.rectangle") } }   // brand: system surface (context menu)
                        Button(role: .destructive) { app.deleteNote(t.id, note: n.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .tabEntrance(.moments) { seen.entered(); entrance += 1 }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Moments")
    }
}

struct Moment: Identifiable { let t: Transcript; let n: Note; var id: UUID { n.id } }
