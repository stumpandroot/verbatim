import SwiftUI

/// Name suggestions for a transcript's speakers (SpeakerNames), under the header's meta line, on the refined kit
/// (DESIGN.md §13): "Speaker 1 might be Ginna Cross" with the reason in small mute text, then Use and Dismiss. One
/// quiet row per speaker. Nothing is renamed until you choose Use, which renames the speaker the way typing a name
/// does. Shared by the Mac and the iPhone.
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
            (Text("\(speakerLabel(s)) might be ") + Text(s.name).fontWeight(.semibold).foregroundStyle(Refined.ink))
                .refinedFont(.body).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
            if !s.reasons.isEmpty {
                Text(s.reasonText)
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func buttons(_ s: SpeakerSuggestion) -> some View {
        HStack(spacing: 8) {
            Button("Use") { onUse(s) }
                .buttonStyle(RefinedActionStyle())
                .help("Rename \(speakerLabel(s)) to \(s.name)")
                .accessibilityLabel("Use \(s.name) for \(speakerLabel(s))")
            Button("Dismiss") { onDismiss(s) }
                .buttonStyle(.plain)
                .refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.dim)
                .frame(minHeight: RefinedPlatform.mac ? 28 : CGFloat(RefinedRules.minTapTarget))
                .contentShape(Rectangle())
                .accessibilityLabel("Dismiss the suggestion for \(speakerLabel(s))")
        }
    }

    #if os(macOS)
    private func row(_ s: SpeakerSuggestion) -> some View {
        HStack(alignment: .center, spacing: 10) {
            IconGlyph(art: .iconSpeakers, size: 16, color: Refined.dim).accessibilityHidden(true)
            words(s)
            Spacer(minLength: 8)
            buttons(s)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }
    #else
    private func row(_ s: SpeakerSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconGlyph(art: .iconSpeakers, size: 18, color: Refined.dim).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                words(s)
                buttons(s)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }
    #endif
}
