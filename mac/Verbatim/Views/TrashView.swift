import SwiftUI

/// Recently Deleted: kept for 30 days, then removed with their audio.
struct TrashView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let items = app.store.trash
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Recently Deleted").font(Ink.serif(30, weight: .regular)).foregroundStyle(Ink.ink)
                    Spacer()
                    if !items.isEmpty {
                        Button("Restore all") { app.restore(items.map(\.id)) }.buttonStyle(.bordered)
                        Button("Empty", role: .destructive) { confirmEmpty(items) }.buttonStyle(.bordered).tint(Ink.danger)
                    }
                }
                Text("Transcripts stay here for 30 days, then they and their audio are deleted for good.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.top, 4).padding(.bottom, 18)
                if items.isEmpty {
                    Text("Nothing here.").font(.system(size: 14)).foregroundStyle(Ink.mute)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            HStack(spacing: 14) {
                                Image(systemName: t.source.symbol).foregroundStyle(Ink.mute).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(daysLeft(t)).font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                                }
                                Spacer()
                                Button("Restore") { app.restore([t.id]) }.buttonStyle(.bordered).controlSize(.small)
                                Button("Delete now", role: .destructive) { app.purge([t.id]) }.buttonStyle(.plain).foregroundStyle(Ink.danger).font(.system(size: 12.5))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            if i < items.count - 1 { Divider().opacity(0.5) }
                        }
                    }
                    .background(NoteCardBackground(hover: false))
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }

    /// One formatter for every row (creating one per row is slow). Follows the current locale as it changes.
    private static let relative: RelativeDateTimeFormatter = {
        let r = RelativeDateTimeFormatter(); r.unitsStyle = .full; r.locale = .autoupdatingCurrent; return r
    }()

    private func daysLeft(_ t: Transcript) -> String {
        guard let d = t.deletedAt else { return "" }
        let left = app.store.trashDaysLeft(t)
        return "Deleted \(Self.relative.localizedString(for: d, relativeTo: Date())) · \(left) day\(left == 1 ? "" : "s") left"
    }

    private func confirmEmpty(_ items: [Transcript]) {
        let a = NSAlert()
        a.messageText = "Delete \(items.count) transcript\(items.count == 1 ? "" : "s") for good?"
        a.informativeText = "Their audio is deleted too. This can't be undone."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { app.purge(items.map(\.id)) }
    }
}
