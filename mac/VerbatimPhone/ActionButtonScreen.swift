import SwiftUI
import UIKit

/// Settings › Action button (the notch mockup's section 06): what the Action button does when "Verbose action" is
/// its control (Dictate, Record a voice note, Live captions, What's playing, or New thought), each with whether it
/// works in place or opens Verbose; where a take's words
/// go; how long an idle session stays on; and the three steps in iOS Settings › Action Button. One intent,
/// `ActionButtonIntent`, follows the choice, so the button is assigned once. Google developer documentation style.
struct ActionButtonScreen: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(Ribbon.actionChoiceKey) private var choiceRaw = Ribbon.ActionChoice.dictate.rawValue

    private var choice: Ribbon.ActionChoice { Ribbon.actionChoice(choiceRaw) }

    private let steps = [
        "Open the Settings app, and then tap Action Button.",
        "Swipe to Controls, tap Choose a Control, and then choose Verbose action.",
        "Press the Action button to try it.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Action button").lookSerif(30).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose what the Action button does when Verbose action is set as its control in Settings › Action Button.")
                    .font(.system(size: 15)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(Array(Ribbon.ActionChoice.allCases.enumerated()), id: \.element) { i, c in
                        if i > 0 { SettingsDivider() }
                        ActionChoiceRow(choice: c, selected: c == choice) { choiceRaw = c.rawValue }
                    }
                }
                .cardSurface(radius: Radius.row)
                .padding(.top, 6)

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("After a take").font(.system(size: 16)).foregroundStyle(.lookInk)
                        Spacer(minLength: 8)
                        SettingsValue("Insert or copy")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(minHeight: 50)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Into the text field when the Verbose keyboard is open; otherwise on the clipboard and in the keyboard's Recent row.")
                    Rectangle().fill(.lookHairline).frame(height: 1).padding(.leading, 14)
                    IdleTimeoutRow(session: app.session)
                }
                .cardSurface(radius: Radius.row)
                .padding(.top, 6)

                Text("While a session is on, the orange microphone dot shows at the top of the screen. Audio is saved only while you dictate.")
                    .font(.system(size: 13)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                Text("Set up the Action button").font(.system(size: 13, weight: .semibold)).foregroundStyle(.lookDim)
                    .accessibilityAddTraits(.isHeader).padding(.top, 16)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1).").lookMono(15, weight: .medium).foregroundStyle(.lookMute)
                            Text(step).font(.system(size: 16)).foregroundStyle(.lookInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .cardSurface(radius: Radius.row)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .phonePage()
        .navigationTitle("Action button")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// End the session after: 10 or 30 minutes, 1, 2, or 4 hours idle, or Until I end it. The same setting as
/// Settings › Keyboard.
private struct IdleTimeoutRow: View {
    @ObservedObject var session: KeyboardSession
    var body: some View {
        HStack(spacing: 10) {
            Text("End the session after").font(.system(size: 16)).foregroundStyle(.lookInk)
            Spacer(minLength: 8)
            Picker("End the session after", selection: $session.timeoutSeconds) {
                ForEach(KeyboardSession.timeoutChoices, id: \.seconds) { c in
                    Text(c.seconds == 0 ? c.label : "\(Ribbon.timeoutShortLabel(c.seconds)) idle").tag(c.seconds)
                }
            }
            .labelsHidden()
            .tint(Ink.accentText)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(minHeight: 50)
    }
}

/// One choice: its icon, its name, whether it works in place or opens Verbose, and a radio mark. The whole row is
/// the button. A choice this iPhone can't do is dimmed and says why.
private struct ActionChoiceRow: View {
    var choice: Ribbon.ActionChoice
    var selected: Bool
    var pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                IconGlyph(art: art, size: 20, color: Ink.ink)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).font(.system(size: 17)).foregroundStyle(.lookInk)
                    Text(choice.detail).font(.system(size: 13)).foregroundStyle(.lookMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                RadioMark(on: selected)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
            .opacity(choice.available ? 1 : 0.5)
        }
        .buttonStyle(SettingsRowPress())
        .disabled(!choice.available)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .sensoryFeedback(.selection, trigger: selected) { _, now in now }
    }

    private var art: BrandArt {
        switch choice {
        case .dictate: return .iconDictations
        case .voiceNote: return .iconVoice
        case .captions: return .iconCaptions
        case .whatsPlaying: return .iconLowerAudio
        case .quickCapture: return .iconThought
        }
    }
}

/// The mockup's radio: an outlined circle, filled with ink when chosen.
private struct RadioMark: View {
    var on: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Ink.ink : Ink.mute, lineWidth: on ? 5 : 1.5)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
