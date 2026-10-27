import SwiftUI
import UIKit

/// Settings › Action button (the notch mockup's section 06, and "Library features", section 3b): what the Action
/// button does when "Verbose action" is its control (Dictate, Record a voice note, Record or mark, Live captions,
/// What's playing, or New thought), each with whether it works in place or opens Verbose; where a take's words go; how
/// long an idle session stays on; and the Set up the Action button card with the three steps in iOS Settings › Action
/// Button and Open Settings. One intent, `ActionButtonIntent`, follows the choice, so the button is assigned once.
/// Google developer documentation style.
struct ActionButtonScreen: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(Ribbon.actionChoiceKey) private var choiceRaw = Ribbon.ActionChoice.dictate.rawValue

    private var choice: Ribbon.ActionChoice { Ribbon.actionChoice(choiceRaw) }

    static let steps = [
        "Open the Settings app, then tap Action Button.",
        "Swipe to Controls, then tap Choose a Control.",
        "Search for Verbose, then choose Verbose action.",
    ]

    var body: some View {
        // The Settings page scaffold: the serif compact title on the paper and an empty principal item, so the title
        // shows once.
        SettingsPageScaffold(title: "Action button") {
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.lede)
                    .font(.system(size: 15)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                PhoneEyebrow(text: "Press the Action button to")
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 10).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(Ribbon.ActionChoice.allCases.enumerated()), id: \.element) { i, c in
                        if i > 0 { SettingsDivider() }
                        ActionChoiceRow(choice: c, selected: c == choice) { choiceRaw = c.rawValue }
                    }
                }
                .cardSurface(radius: Radius.row)
                .padding(.top, 2)

                ActionButtonSetupCard { app.openAppSettings() }
                    .padding(.top, 10)

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
            }
        }
    }

    static let lede = "Choose what happens when you press the Action button. First, set it to Verbose in the Settings app (steps below)."
}

/// Set up the Action button (mockup "Library features", section 3b): the Action button icon, "Set up the *Action
/// button*" in the serif, the three steps with numbers in rings, and Open Settings. Verbose style: an ink-outlined
/// reader card. Premium Native: a grouped card with a bold title and the accent's button.
struct ActionButtonSetupCard: View {
    var openSettings: () -> Void
    @Environment(\.look) private var look

    var body: some View {
        let native = look.isNative
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconGlyph(art: .iconActionButton, size: 17, color: native ? NativeInk.accent : Ink.ink)
                    .frame(width: 30, height: 30)
                    .background(native ? NativeInk.fill : Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .accessibilityHidden(true)
                Group {
                    if native {
                        Text("Set up the Action button").font(.system(size: 17, weight: .semibold))
                    } else {
                        Text("Set up the \(Text("Action button").italic())").lookSerif(21)
                    }
                }
                .foregroundStyle(.lookInk)
                .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ActionButtonScreen.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.lookInk)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(native ? NativeInk.secondary : Ink.ink, lineWidth: 1.2))
                        Text(step).font(.system(size: 16)).foregroundStyle(.lookInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(i + 1): \(step)")
                }
            }
            Button("Open Settings", action: openSettings).buttonStyle(.phonePrimary)
                .accessibilityHint("Opens the Settings app.")
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.row)
        .overlay {
            if !native { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5) }
        }
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
        case .recordOrMark: return .iconMark
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
