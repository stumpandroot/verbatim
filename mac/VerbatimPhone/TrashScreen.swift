import SwiftUI

struct TrashScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var confirmEmpty = false
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
        .toolbar {
            if !trash.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { restoreAll(trash) } label: { Label("Restore all", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { confirmEmpty = true } label: { Label("Empty Recently Deleted…", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Restore all or empty")
                }
            }
        }
        .confirmationDialog(trash.count == 1 ? "Delete this transcript now?" : "Delete all \(trash.count) transcripts now?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { emptyTrash(trash) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their audio and text are deleted for good, on every device that syncs them. You can’t undo this.") }
    }

    private func restoreAll(_ list: [Transcript]) {
        for t in list { app.store.restore(t.id) }
        app.say(list.count == 1 ? "Restored" : "Restored \(list.count) transcripts")
    }

    private func emptyTrash(_ list: [Transcript]) {
        for t in list { app.purge(t.id) }
        app.say("Recently Deleted is empty")
    }
    private func daysLeft(_ t: Transcript) -> String {
        guard let d = t.deletedAt else { return "" }
        let left = app.store.trashDaysLeft(t)
        return "\(left) day\(left == 1 ? "" : "s") left · swipe right to restore"
    }
}
