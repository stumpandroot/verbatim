import SwiftUI
import AppKit

// Recently Deleted on the refined kit (DESIGN.md §13): the large serif title with the count,
// Restore all and Empty, then each transcript in a card with its kind's dot, when it was deleted and the days left,
// Restore, and Delete now. The empty screen is the kit's empty state.

/// Recently deleted: kept for 30 days, then removed with their audio.
struct TrashView: View {
    @Environment(AppState.self) var app
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
                        // Permanent, so a quiet button in danger, never the strong primary look (MAC-15).
                        Button(role: .destructive) { confirmEmpty(items) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Refined.danger).accessibilityHidden(true)
                                Text("Empty").foregroundStyle(Refined.danger)
                            }
                        }
                        .buttonStyle(RefinedActionStyle(kind: .quiet))
                        .help("Deletes every transcript here and its audio for good.")
                        .accessibilityLabel("Empty")
                    }
                }
                if items.isEmpty {
                    RefinedEmptyState(art: .iconDeleted, title: "Nothing here",
                                      message: "Transcripts you delete wait here for 30 days, so you can restore them.")
                } else {
                    // One view per row, the hairline inside it: Recently Deleted can hold hundreds (expired dictations
                    // land here), and the lazy stack then measures only the rows on screen.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            PaperDividedRow(divider: i > 0, leading: 16, trailing: 16) {
                                TrashRow(transcript: t, detail: daysLeft(t), restore: { app.restore([t.id]) }, purge: { confirmPurge(t) })
                            }
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

    /// "Deleted just now · 30 days left", "Deleted 2 hours ago · 30 days left". A delete time a moment ahead of now (a
    /// clock between devices) reads as now, never "in 0 seconds" (MAC-38).
    private func daysLeft(_ t: Transcript) -> String {
        guard let d = t.deletedAt else { return "" }
        let left = app.store.trashDaysLeft(t)
        let now = Date()
        let when = now.timeIntervalSince(d) < 60 ? "just now" : Self.relative.localizedString(for: min(d, now), relativeTo: now)
        return "Deleted \(when) · \(left) day\(left == 1 ? "" : "s") left"
    }

    /// Delete now is permanent, so it asks first, as Empty does.
    private func confirmPurge(_ t: Transcript) {
        let a = NSAlert()
        a.messageText = "Delete \u{201C}\(t.title)\u{201D} for good?"
        a.informativeText = "Its audio is deleted too. This can't be undone."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { app.purge([t.id]) }
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
            // Destructive: danger with the trash glyph and a word, never persimmon (MAC-15; DESIGN.md §1).
            Button(role: .destructive, action: purge) {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Refined.danger).accessibilityHidden(true)
                    Text("Delete now").refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.danger)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help("Deletes it and its audio for good.")
            .accessibilityLabel("Delete now")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
