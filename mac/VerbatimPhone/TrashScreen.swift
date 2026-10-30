import SwiftUI

/// Library › Recently Deleted on the iPhone, on the refined kit (DESIGN.md §13): the serif title
/// with the count, the deleted recordings on a card with the days each has left, swipe right to restore and left to
/// delete now, and Restore all or Empty in the bar's menu.
struct TrashScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var confirmEmpty = false
    var body: some View {
        // `store.trash` filters and sorts every transcript; read it once per render.
        let trash = app.store.trash
        List {
            RefinedListTitle(title: "Recently Deleted", count: trash.isEmpty ? nil : "\(trash.count)")
            if trash.isEmpty {
                Section {
                    RefinedEmptyState(art: .iconDeleted, title: "Nothing here",
                                      message: "Recordings you delete stay here for 30 days, then go for good.")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                ForEach(trash) { t in
                    HStack(spacing: 12) {
                        KindBadge(kind: t.kind)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(2)
                            Text(daysLeft(t)).refinedFont(.meta).foregroundStyle(Refined.mute)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .leading) {
                        Button { app.restore(t.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }   // brand: system surface (swipe action)
                            .tint(Refined.sageText)
                    }
                    .swipeActions(edge: .trailing) { Button(role: .destructive) { app.purge(t.id) } label: { Label("Delete now", systemImage: "trash") } }
                }
            }
            .listRowBackground(Refined.card)
            .listRowSeparatorTint(Refined.separator)
        }
        .refinedListPage("Recently Deleted")
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
