import SwiftUI

/// "Who was this with?" under a call's header, where speaker suggestions sit (DESIGN.md §6.10, Names on a call): a
/// finished two-track call whose other side is still "FaceTime" or "Speaker 2" with nothing to suggest
/// (`Transcript.callPartnerToAsk`). One quiet card on the refined kit, like a suggestion's: the question, a name field
/// that offers names from Contacts (only when access is already allowed; it never asks) and names you've given
/// speakers before as you type, Use, and Dismiss. Use, Return, or a name renames the speaker across the transcript the
/// way Use on a suggestion does; Dismiss hides it for this transcript. Mac only.
struct WhoWasThisRow: View {
    @Environment(AppState.self) var app
    var transcript: Transcript
    var speaker: Speaker
    @State private var typed = ""
    @State private var known: [String] = []
    @FocusState private var focused: Bool

    private var matches: [String] {
        MeetingNames.typeahead(typed, in: known, selfNames: MeetingNames.selfNames())
            .filter { $0.lowercased() != typed.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconGlyph(art: .iconSpeakers, size: 16, color: Refined.dim).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Who was this with?").refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                    Text("The other side is labeled \(speaker.label). A name here replaces it throughout the transcript.")
                        .refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 8) {
                    TextField("Name", text: $typed)
                        .textFieldStyle(.plain).refinedFont(.body).foregroundStyle(Refined.ink)
                        .focused($focused)
                        .onSubmit { use(typed) }
                        .padding(.horizontal, 10).frame(minHeight: 28)
                        .background(Refined.field, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous))
                        .frame(maxWidth: 260)
                        .accessibilityLabel("Name for \(speaker.label)")
                        .accessibilityIdentifier("who-was-this-field")
                    Button("Use") { use(typed) }
                        .buttonStyle(RefinedActionStyle())
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Rename \(speaker.label) to this name")
                    Button("Dismiss") { app.dismissWhoWasThis(transcript: transcript.id) }
                        .buttonStyle(.plain)
                        .refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.dim)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                        .uiTarget("who-was-this-dismiss")
                        .accessibilityLabel("Dismiss. Keep \(speaker.label) as it is")
                }
                if !matches.isEmpty {
                    FlowRow(spacing: 6, lineSpacing: 6) {
                        ForEach(matches, id: \.self) { n in
                            Button(n) { use(n) }
                                .buttonStyle(RefinedActionStyle())
                                .help("Rename \(speaker.label) to \(n)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Names that match")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("who-was-this")
        .uiTarget("who-was-this")
        .task(id: transcript.id) {
            // Names you've given speakers before, then your contacts' (read only when access is already allowed).
            let past = SpeakerNames.pastNames(app.store.live, excluding: transcript.id)
            let contacts = await ContactNames.allNames()
            known = contacts + past
        }
    }

    private func use(_ name: String) {
        let n = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !n.isEmpty else { return }
        app.renameSpeaker(transcript: transcript.id, speaker: speaker.id, to: n)
        typed = ""
    }
}
