import SwiftUI

/// Every transcript, grouped by day (pinned first), filtered by the sidebar project and the search field.
struct LibraryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let groups = Store.group(app.filtered)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } ?? "Library")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(app.filtered.count) transcripts").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                .staggerIn(0).padding(.bottom, 6)
                if groups.isEmpty {
                    HStack(spacing: 14) {
                        VerbieView(pose: app.search.isEmpty ? .ready : .nothing, tracksPointer: false).frame(width: 54, height: 72)
                        Text(app.search.isEmpty ? "Nothing in here yet." : "Nothing found for “\(app.search)”.").font(.system(size: 14)).foregroundStyle(Ink.mute)
                    }
                    .padding(.top, 30).staggerIn(1)
                }
                ForEach(Array(groups.enumerated()), id: \.element.label) { gi, g in
                    Text(g.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.mute).padding(.top, 22).padding(.bottom, 8).staggerIn(1 + gi * 2)
                    VStack(spacing: 8) {
                        ForEach(Array(g.items.enumerated()), id: \.element.id) { ii, t in
                            HistoryRow(transcript: t, open: { app.go(.transcript(t.id)) })
                                .staggerIn(2 + gi * 2 + ii)
                                .contextMenu { RowMenu(transcript: t) }
                        }
                    }
                }
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .animation(Motion.settle, value: app.filtered.map(\.id))
    }
}
