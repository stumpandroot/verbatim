import SwiftUI

/// What's new (the version at the foot of Settings, search, and Home's note): every build's
/// notes, newest first, from the bundled ReleaseNotes.json (Verbatim/Model/ReleaseNotes.swift). Verbose style: the
/// compact serif title, then one card per build with a mono eyebrow ("Build 203 · Oct 25"), its title in the serif,
/// and bullet items. Native: the large title and an inset grouped section per build, the build as its header.
struct WhatsNewScreen: View {
    var notes: [ReleaseNote] = ReleaseNotes.bundled
    @Environment(\.look) private var look
    @AppStorage(ReleaseNotes.lastSeenKey) private var lastSeen = 0
    /// How many What's new screens are on screen, for the UI tour's checks. A count rather than a flag, so a screen
    /// that appears before the one it replaces has gone can't leave it stuck.
    static var onScreen = 0
    static var visible: Bool { onScreen > 0 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !look.isNative {
                    PhoneCompactTitle(title: "What's new").padding(.top, 2)
                }
                if notes.isEmpty {
                    Text("The release notes aren't in this build.")
                        .font(.system(size: 15)).foregroundStyle(.lookMute)
                        .padding(.top, 18)
                }
                ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
                    Group {
                        if look.isNative { nativeSection(note) } else { verboseCard(note) }
                    }
                    .padding(.top, i == 0 ? (look.isNative ? 8 : 18) : (look.isNative ? 26 : 14))
                }
            }
            .padding(.horizontal, look.isNative ? 16 : 20).padding(.bottom, 32)
        }
        .phonePage()
        .navigationTitle("What's new")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .toolbar {
            // Verbose style puts the serif title on the paper.
            if !look.isNative {
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            }
        }
        .onAppear {
            Self.onScreen += 1
            // Opening What's new counts as seeing this build's note.
            if let current = ReleaseNotes.currentBuild, current > lastSeen { lastSeen = current }
        }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
    }

    /// Verbose style: a card with a hairline edge, the eyebrow, the serif title, and the items.
    private func verboseCard(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneEyebrow(text: note.heading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(note.spokenHeading)
            Text(note.title).lookSerif(22).foregroundStyle(.lookInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            items(note, size: 15)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.lookCard, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.record, style: .continuous).strokeBorder(.lookHairline))
    }

    /// Native: an inset grouped section headed by the build, the title in semibold, then the items.
    private func nativeSection(_ note: ReleaseNote) -> some View {
        NativeGroup(header: note.heading) {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.title).font(.headline).foregroundStyle(.lookInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                items(note, size: 15)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func items(_ note: ReleaseNote, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(note.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.lookMute).accessibilityHidden(true)
                    Text(item).foregroundStyle(.lookInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: size))
            }
        }
    }
}

/// Home's one-time note after an update: "What's new in build 205" and the build's title. Tapping it opens What's new;
/// the close button hides it. Either way it doesn't come back until a newer build with notes. Never a modal.
struct WhatsNewBanner: View {
    /// Space above the note, only while it shows.
    var top: CGFloat = 0
    var notes: [ReleaseNote] = ReleaseNotes.bundled
    var open: () -> Void
    @AppStorage(ReleaseNotes.lastSeenKey) private var lastSeen = 0
    /// The UI tour shows the note for a build of its choosing (the simulator's build has no entry).
    static var previewBuild: Int? = nil

    var body: some View {
        if let note = ReleaseNotes.pending(current: Self.previewBuild ?? ReleaseNotes.currentBuild, lastSeen: lastSeen, notes: notes),
           let number = note.number {
            HStack(spacing: 0) {
                Button {
                    lastSeen = max(lastSeen, number)
                    open()
                } label: {
                    HStack(spacing: 12) {
                        LookIcon(art: .iconNotes, symbol: "sparkles", size: 22, color: Ink.ink, nativeColor: NativeInk.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What's new in build \(number)")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk)
                            Text(note.title).font(.system(size: 13)).foregroundStyle(.lookMute).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens What's new")
                Button { lastSeen = max(lastSeen, number) } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.lookMute)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityHint("Hides this note")
                .padding(.trailing, 4)
            }
            .modifier(BannerSurface())
            .padding(.top, top)
            .transition(.opacity)
        }
    }

    /// Verbose style: card white with a hairline and the row radius. Native: a grouped card.
    private struct BannerSurface: ViewModifier {
        @Environment(\.look) private var look
        func body(content: Content) -> some View {
            if look.isNative {
                content.background(NativeInk.card, in: RoundedRectangle(cornerRadius: NativeMetrics.groupRadius, style: .continuous))
            } else {
                content
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.record, style: .continuous).strokeBorder(Ink.hairline))
            }
        }
    }
}
