import SwiftUI

// Recently Deleted on the refined kit (DESIGN.md §13): the large serif title with the count,
// Restore all and Empty, then each transcript in a card with its kind's dot, when it was deleted and the days left,
// Restore, and Delete now. The empty screen is the kit's empty state.

/// Recently deleted: kept for 30 days, then removed with their audio.
struct TrashView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let items = app.store.trash
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RefinedPageHeader(title: "Recently Deleted", count: items.isEmpty ? nil : HomeCounts.countLabel(items.count, "transcript", "transcripts"),
                                  lede: "Transcripts stay here for 30 days, then they and their audio are deleted for good.") {
                    if !items.isEmpty {
                        Button("Restore all") { app.restore(items.map(\.id)) }
                            .buttonStyle(RefinedActionStyle())
                            .help("Puts every transcript back in your library.")
                        Button("Empty", role: .destructive) { confirmEmpty(items) }
                            .buttonStyle(RefinedActionStyle(kind: .strong))
                            .help("Deletes every transcript here and its audio for good.")
                    }
                }
                if items.isEmpty {
                    RefinedEmptyState(art: .iconDeleted, title: "Nothing here",
                                      message: "Transcripts you delete wait here for 30 days, so you can restore them.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { PaperDivider(leading: 16, trailing: 16) }
                            TrashRow(transcript: t, detail: daysLeft(t), restore: { app.restore([t.id]) }, purge: { app.purge([t.id]) })
                        }
                    }
                    .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 18).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges(.top)
        .background(Refined.paper)
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

/// A deleted transcript as a row in the card: the kind's dot, the title, when it was deleted and the days left, then
/// Restore and Delete now. No click on the row itself.
private struct TrashRow: View {
    var transcript: Transcript
    var detail: String
    var restore: () -> Void
    var purge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            KindBadge(kind: transcript.kind, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                Text(detail).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 10)
            Button("Restore", action: restore)
                .buttonStyle(RefinedActionStyle())
                .help("Puts it back in your library.")
            Button("Delete now", role: .destructive, action: purge)
                .buttonStyle(.plain).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                .padding(.horizontal, 6)
                .help("Deletes it and its audio for good.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
