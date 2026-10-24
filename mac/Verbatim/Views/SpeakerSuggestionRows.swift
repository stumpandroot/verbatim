import SwiftUI

// brand: web style

/// Name suggestions for a transcript's speakers (SpeakerNames), under the kind and tags: "Speaker 1 might be Ginna
/// Cross" with the reason in small mute text, then Use and Dismiss. One quiet row per speaker. Nothing is renamed
/// until you choose Use, which renames the speaker the way typing a name does. Shared by the Mac and the iPhone.
struct SpeakerSuggestionRows: View {
    var transcript: Transcript
    var onUse: (SpeakerSuggestion) -> Void
    var onDismiss: (SpeakerSuggestion) -> Void

    var body: some View {
        let list = transcript.visibleSpeakerSuggestions
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(list) { row($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("speaker-suggestions")
        }
    }

    private func speakerLabel(_ s: SpeakerSuggestion) -> String {
        transcript.speakers.first { $0.id == s.speakerId }?.label ?? s.speakerId
    }

    private func words(_ s: SpeakerSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("\(speakerLabel(s)) might be ") + Text(s.name).fontWeight(.semibold).foregroundStyle(Ink.ink))
                .font(.system(size: Self.textSize)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
            if !s.reasons.isEmpty {
                Text(s.reasonText)
                    .font(.system(size: Self.reasonSize)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    #if os(macOS)
    private static let textSize: CGFloat = 13.5
    private static let reasonSize: CGFloat = 12

    private func row(_ s: SpeakerSuggestion) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ArtIcon(art: .iconSpeakers, size: 16).foregroundStyle(Ink.dim).accessibilityHidden(true)
            words(s)
            Spacer(minLength: 8)
            Button("Use") { onUse(s) }
                .buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                .help("Rename \(speakerLabel(s)) to \(s.name)")
                .accessibilityLabel("Use \(s.name) for \(speakerLabel(s))")
            Button("Dismiss") { onDismiss(s) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
                .accessibilityLabel("Dismiss the suggestion for \(speakerLabel(s))")
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
    #else
    private static let textSize: CGFloat = 14
    private static let reasonSize: CGFloat = 12.5

    private func row(_ s: SpeakerSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconGlyph(art: .iconSpeakers, size: 18, color: Ink.dim).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                words(s)
                HStack(spacing: 14) {
                    Button { onUse(s) } label: {
                        Text("Use").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                            .padding(.horizontal, 14).frame(minHeight: 32)
                            .background(PhoneInk.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(s.name) for \(speakerLabel(s))")
                    Button { onDismiss(s) } label: {
                        Text("Dismiss").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                            .frame(minHeight: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss the suggestion for \(speakerLabel(s))")
                }
            }
        }
    }
    #endif
}
