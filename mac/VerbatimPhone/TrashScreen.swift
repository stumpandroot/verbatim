import SwiftUI

struct TrashScreen: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        // `store.trash` filters and sorts every transcript; read it once per render.
        let trash = app.store.trash
        List {
            if trash.isEmpty {
                Text("Nothing here.").foregroundStyle(Ink.mute).listRowBackground(Color.clear)
            }
            ForEach(trash) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(daysLeft(t)).font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                .listRowBackground(Ink.card)
                .swipeActions(edge: .leading) { Button { app.restore(t.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(Ink.sageText) }
                .swipeActions(edge: .trailing) { Button(role: .destructive) { app.purge(t.id) } label: { Label("Delete now", systemImage: "trash") } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Recently Deleted")
    }
    private func daysLeft(_ t: Transcript) -> String {
        guard let d = t.deletedAt else { return "" }
        let left = app.store.trashDaysLeft(t)
        return "\(left) day\(left == 1 ? "" : "s") left · swipe right to restore"
    }
}
