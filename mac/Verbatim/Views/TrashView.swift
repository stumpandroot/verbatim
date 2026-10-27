import SwiftUI

// brand: web style
//
// Recently deleted in the website style (mac/DESIGN.md §11; review M-17): the compact title with a mono count, a line
// pill to restore everything and a danger-outlined Empty, flat rows with the kind dot, a line mini pill to restore one,
// and "Delete now" in the danger color. The empty screen is the one horizontal card.

/// Recently deleted: kept for 30 days, then removed with their audio.
struct TrashView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let items = app.store.trash
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Recently", italic: "deleted", count: items.isEmpty ? nil : HomeCounts.countLabel(items.count, "transcript", "transcripts"),
                          lede: "Transcripts stay here for 30 days, then they and their audio are deleted for good.") {
                    if !items.isEmpty {
                        HStack(spacing: 8) {
                            PillButton(title: "Restore all", kind: .line, size: .mini, hint: "Puts every transcript back in your library.") {
                                app.restore(items.map(\.id))
                            }
                            DangerPill(title: "Empty", hint: "Deletes every transcript here and its audio for good.") { confirmEmpty(items) }
                        }
                    }
                }
                .padding(.bottom, 22)
                if items.isEmpty {
                    EmptyStateCard(art: .iconDeleted, title: "Nothing here",
                                   message: "Transcripts you delete wait here for 30 days, so you can restore them.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { t in
                            TrashRow(transcript: t, detail: daysLeft(t), restore: { app.restore([t.id]) }, purge: { app.purge([t.id]) })
                        }
                    }
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

/// A deleted transcript as a flat row: the kind dot, the title in the serif, when it was deleted and the days left,
/// then Restore (a line mini pill) and Delete now (danger text). No click on the row itself; the controls take clicks
/// through direct gestures (macOS 26 click safety).
private struct TrashRow: View {
    var transcript: Transcript
    var detail: String
    var restore: () -> Void
    var purge: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            KindDot(transcript: transcript, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                WebText.serif(transcript.title, italic: nil, size: 19).foregroundStyle(Ink.ink).lineLimit(1)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 10)
            PillButton(title: "Restore", kind: .line, size: .mini, hint: "Puts it back in your library.", action: restore)
            Text("Delete now").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.danger)
                .padding(.horizontal, 6).frame(height: 28)
                .contentShape(Rectangle())
                .tapArea(purge)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Delete now")
                .accessibilityHint("Deletes it and its audio for good.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { purge() }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .flatRow(highlighted: hover)
        .onHover { hover = $0 }
    }
}

/// A line pill in the danger color, for an action that deletes for good (never persimmon). Native: a bordered button
/// tinted with the system red.
private struct DangerPill: View {
    var title: String
    var hint: String
    var action: () -> Void
    @State private var hover = false
    @Environment(\.look) private var look

    var body: some View {
        if look == .native {
            Button(title, role: .destructive, action: action)
                .buttonStyle(.bordered).controlSize(.small).tint(NativeInk.danger)
                .help(hint)
        } else {
            Text(title).font(.system(size: PillSize.mini.font, weight: .semibold)).foregroundStyle(Ink.danger)
                .padding(.horizontal, PillSize.mini.padding).frame(height: PillSize.mini.height)
                .background {
                    ZStack {
                        Capsule().fill(Ink.danger.opacity(hover ? 0.08 : 0))
                        Capsule().strokeBorder(Ink.danger, lineWidth: 1.5)
                    }
                }
                .fixedSize()
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .tapArea(action)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityHint(hint)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        }
    }
}
