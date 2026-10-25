import SwiftUI

// brand: web style
//
// What's new on the Mac: Settings › What's new (also Verbose › What's New… in the app menu, the What's New… buttons in
// About and General › Updates, and Home's note after an update). Every build's notes, newest first, from the bundled
// ReleaseNotes.json (Model/ReleaseNotes.swift). Verbose style: the pane's eyebrow and serif title, then a card per
// build with a mono eyebrow ("Build 203 · Oct 25"), its title in the serif, and bullet items. Native: the bold title
// and a grouped Form section per build, headed by the build.

struct WhatsNewSettingsPane: View {
    var notes: [ReleaseNote] = ReleaseNotes.bundled

    var body: some View {
        SettingsPane(tab: .whatsNew) {
            VStack(alignment: .leading, spacing: 22) {
                if notes.isEmpty {
                    Text("The release notes aren't in this build.").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                ForEach(notes) { WhatsNewCard(note: $0) }
            }
            .settingsAnchor("whatsNew.builds")
        }
        // Opening What's new counts as seeing this build's note on Home.
        .onAppear { ReleaseNotes.markSeen() }
    }
}

/// One build: Verbose style's card with the eyebrow inside, or Native's Form section with the build as its header.
struct WhatsNewCard: View {
    var note: ReleaseNote
    @Environment(\.look) private var look

    var body: some View {
        if look == .native {
            SettingsGroup(title: note.heading) {
                content.padding(.horizontal, 12).padding(.vertical, 10)
            }
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: note.heading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(note.spokenHeading)
                content
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()
        }
    }

    private var content: some View {
        let native = look == .native
        return VStack(alignment: .leading, spacing: native ? 6 : 8) {
            Text(note.title)
                .font(native ? .system(size: 15, weight: .semibold) : Ink.serif(24))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: native ? 4 : 6) {
                ForEach(Array(note.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Ink.mute).accessibilityHidden(true)
                        Text(item).foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: native ? 13 : 14))
                    .lineSpacing(native ? 1 : 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Home's one-time note after an update: "What's new in build 205 · Version notes". Click it to open What's new; the
/// close button hides it. Either way it doesn't come back until a newer build with notes. Never a modal or a sheet.
struct WhatsNewHomeLine: View {
    /// Space above the line, only while it shows.
    var top: CGFloat = 0
    var notes: [ReleaseNote] = ReleaseNotes.bundled
    var open: () -> Void
    @AppStorage(ReleaseNotes.lastSeenKey) private var lastSeen = 0
    @Environment(\.look) private var look
    @State private var hover = false
    /// The UI self-test shows the note for a build of its choosing.
    static var previewBuild: Int? = nil

    var body: some View {
        if let note = ReleaseNotes.pending(current: Self.previewBuild ?? ReleaseNotes.currentBuild, lastSeen: lastSeen, notes: notes),
           let number = note.number {
            let native = look == .native
            HStack(spacing: 0) {
                Button {
                    lastSeen = max(lastSeen, number)
                    open()
                } label: {
                    HStack(spacing: 10) {
                        ArtIcon(art: .iconNotes, size: 16, lineWidth: 1.4).foregroundStyle(native ? NativeInk.accent : Ink.ink)
                        (Text("What's new in build \(number)").fontWeight(.semibold) + Text("  ·  " + note.title).foregroundStyle(Ink.dim))
                            .font(.system(size: 13)).foregroundStyle(Ink.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(native ? "Read More" : "Read more").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(native ? NativeInk.accent : Ink.ink)
                            .underline(!native && hover)
                    }
                    .padding(.leading, 14).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .accessibilityLabel("What's new in build \(number): \(note.title)")
                .accessibilityHint("Opens What's new in Settings")
                Button { lastSeen = max(lastSeen, number) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.mute)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide this note")
                .accessibilityLabel("Close")
                .padding(.trailing, 6)
            }
            .modifier(LineSurface())
            .padding(.top, top)
            .transition(.opacity)
        }
    }

    /// Verbose style: card white, the row radius, and the ink outline. Native: a group box.
    private struct LineSurface: ViewModifier {
        @Environment(\.look) private var look
        func body(content: Content) -> some View {
            if look == .native {
                content.nativeGroup(radius: 8)
            } else {
                content
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .inkEdge(outline: true, radius: Radius.row)
            }
        }
    }
}

/// "What's New…" in the app menu, under About: opens Settings › What's new.
struct WhatsNewMenuButton: View {
    var open: () -> Void
    var body: some View {
        Button("What's New…", action: open)
    }
}
