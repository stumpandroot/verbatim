import SwiftUI

// Sponsor reads in the transcript and the player, shared by the Mac and iPhone apps. The rules are in
// Model/Sponsors.swift and Transcription/SponsorDetect.swift.

/// A folded sponsor read: one compact row, "Sponsor: Good Ranchers · 1:12", in the Background voices card's form
/// (a neutral tile with the glyph, card white, a hairline) but inline with the lines. Click or tap to show the read's
/// lines; its menu plays the read or says it isn't a sponsor.
struct SponsorFoldRow: View {
    var span: SponsorSpan
    var open: Bool
    var compact = true
    var onToggle: () -> Void
    var onPlay: (() -> Void)? = nil
    var onNotSponsor: () -> Void
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(limitMotion ? nil : Motion.settle) { onToggle() } } label: {
                HStack(spacing: 10) {
                    glyph
                    Text(SponsorFold.title(span))
                        .font(.system(size: compact ? 13.5 : 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(look.isNative ? Color.primary : Ink.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(look.isNative ? Color.secondary : Ink.mute)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SponsorFold.title(span).replacingOccurrences(of: " · ", with: ", "))
            .accessibilityHint(open ? "Hides the sponsor read" : "Shows the sponsor read")
            Menu { items } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(look.isNative ? Color.secondary : Ink.dim)
                    .frame(width: 30, height: compact ? 26 : 32).contentShape(Rectangle())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Sponsor read options")
        }
        .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, compact ? 5 : 6)
        .modifier(SponsorRowSurface(native: look.isNative, compact: compact))
        .contextMenu { items }
    }

    /// The sponsor glyph on a neutral tile in Verbose style; a plain gray symbol in Native.
    @ViewBuilder private var glyph: some View {
        if look.isNative {
            Image(systemName: "tag").font(.system(size: compact ? 13 : 15)).foregroundStyle(.secondary)   // brand: native
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
        } else {
            IconGlyph(art: .iconSponsor, size: compact ? 14 : 16, color: Ink.ink)
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
    }

    @ViewBuilder private var items: some View {
        Button(open ? "Hide the read" : "Show the read") { withAnimation(limitMotion ? nil : Motion.settle) { onToggle() } }
        if let onPlay { Button("Play the read", action: onPlay) }
        Divider()
        Button("Not a sponsor", action: onNotSponsor)
    }
}

/// The fold row's surface: card white with a hairline in Verbose style; in Native, a gray rounded row like a
/// disclosure group's, with no edge.
private struct SponsorRowSurface: ViewModifier {
    var native: Bool
    var compact: Bool
    func body(content: Content) -> some View {
        if native {
            content.background(.fill.tertiary, in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))   // brand: native
        } else {
            content
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
        }
    }
}

/// The transcript screen tells the player which reads to skip (Settings › Skip sponsor reads), and clears them
/// when it closes.
private struct SponsorSkipping: ViewModifier {
    var transcript: Transcript
    var player: Player
    @AppStorage(Transcript.skipSponsorsKey) private var skip = true

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onDisappear { player.skipSpans = [] }
            .onChange(of: transcript.sponsors) { _, _ in apply() }
            .onChange(of: skip) { _, _ in apply() }
    }

    private func apply() {
        player.skipSpans = skip ? transcript.sponsorSpans.map { (start: $0.start, end: $0.end) } : []
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

/// "Skipped sponsor" in the dock, where the time usually is, for a moment after playback jumps past a read. Read
/// aloud by VoiceOver. Never a dialog.
struct SkippedSponsorNote: View {
    var text: String
    var size: CGFloat = 12.5
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(Ink.paperFixed).lineLimit(1).fixedSize()
            .transition(.opacity)
            .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}
