import SwiftUI

// Sponsor reads in the transcript and the player, shared by the Mac and iPhone apps. The rules are in
// Model/Sponsors.swift and Transcription/SponsorDetect.swift.

/// A folded sponsor read: one compact row, "Sponsor: Good Ranchers · 1:12", on the refined kit (DESIGN.md §13): the
/// sponsor glyph on a neutral square and the title on a card, inline with the lines. Click or tap to show the read's
/// lines; its menu plays the read or says it isn't a sponsor.
struct SponsorFoldRow: View {
    var span: SponsorSpan
    var open: Bool
    var compact = true
    var onToggle: () -> Void
    var onPlay: (() -> Void)? = nil
    var onNotSponsor: () -> Void
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(limitMotion ? nil : Motion.settle) { onToggle() } } label: {
                HStack(spacing: 10) {
                    IconGlyph(art: .iconSponsor, size: compact ? 14 : 16, color: Refined.ink)
                        .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                        .background(Refined.neutralSquare, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.square), style: .continuous))
                    Text(SponsorFold.title(span))
                        .refinedFont(.rowTitle, weight: .semibold).monospacedDigit()
                        .foregroundStyle(Refined.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Refined.mute)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .frame(minHeight: RefinedPlatform.mac ? 0 : CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SponsorFold.title(span).replacingOccurrences(of: " · ", with: ", "))
            .accessibilityHint(open ? "Hides the sponsor read" : "Shows the sponsor read")
            Menu { items } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Refined.dim)
                    .frame(width: RefinedPlatform.mac ? 30 : 44, height: RefinedPlatform.mac ? 26 : 44).contentShape(Rectangle())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Sponsor read options")
        }
        .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, compact ? 5 : 2)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .contextMenu { items }
    }

    @ViewBuilder private var items: some View {
        Button(open ? "Hide the read" : "Show the read") { withAnimation(limitMotion ? nil : Motion.settle) { onToggle() } }
        if let onPlay { Button("Play the read", action: onPlay) }
        Divider()
        Button("Not a sponsor", action: onNotSponsor)
    }
}

/// The transcript screen tells the player which reads to skip (Settings › Skip sponsor reads), and clears them
/// when it closes, unless another screen took them over (`Player.releaseSkipSpans`).
private struct SponsorSkipping: ViewModifier {
    var transcript: Transcript
    var player: Player
    @AppStorage(Transcript.skipSponsorsKey) private var skip = true

    func body(content: Content) -> some View {
        content
            .onAppear { apply(appearing: true) }
            .onDisappear { player.releaseSkipSpans(for: transcript.id) }
            .onChange(of: transcript.sponsors) { _, _ in apply(appearing: false) }
            .onChange(of: skip) { _, _ in apply(appearing: false) }
    }

    private func apply(appearing: Bool) {
        player.setSkipSpans(skip ? transcript.sponsorSpans.map { (start: $0.start, end: $0.end) } : [], for: transcript.id, appearing: appearing)
    }
}

extension View {
    /// A line inside a folded sponsor read: not drawn until its row is opened.
    @ViewBuilder func foldedAway(_ folded: Bool) -> some View {
        if folded { EmptyView() } else { self }
    }

    /// Playback on this screen jumps past the transcript's sponsor reads while Skip sponsor reads is on.
    func skipsSponsors(_ t: Transcript, player: Player) -> some View { modifier(SponsorSkipping(transcript: t, player: player)) }
}
