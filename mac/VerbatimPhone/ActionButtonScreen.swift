import SwiftUI
import UIKit

/// Settings › Action button (the approved ribbon mockup, screen 6): what the Action button does when Verbose is
/// its shortcut or control (Dictate a take, Record a voice note, or Live captions), where a take's words go, how
/// long an idle session stays on, and how to set the button up. Google developer documentation style.
struct ActionButtonScreen: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(Ribbon.actionChoiceKey) private var choiceRaw = Ribbon.ActionChoice.dictate.rawValue

    private var choice: Ribbon.ActionChoice { Ribbon.actionChoice(choiceRaw) }

    private let steps = [
        "Open the Settings app, and then tap Action Button.",
        "Swipe to Controls, tap Choose a Control, and then choose Verbose action. Or swipe to Shortcut and choose Verbose › Action button.",
        "Press the Action button. The first press opens Verbose to turn on the microphone; swipe right along the bottom edge to go back.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Action button").font(Ink.serif(30)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose what the Action button does when Verbose is set as its shortcut in Settings › Action Button.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(Array(Ribbon.ActionChoice.allCases.enumerated()), id: \.element) { i, c in
                        if i > 0 { SettingsDivider() }
                        ActionChoiceRow(choice: c, selected: c == choice) { choiceRaw = c.rawValue }
                    }
                }
                .cardSurface(radius: Radius.row)
                .padding(.top, 6)
                Text(choice.detail).font(.system(size: 13)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    SettingsRow(icon: "doc.on.clipboard", tint: Ink.butterTint, art: .iconPaste, title: "After a take",
                                subtitle: "Into the text field when the Verbose keyboard is open; otherwise on the clipboard and in the keyboard's Recent row.",
                                subtitleLines: nil) {
                        SettingsValue("Insert or copy")
                    }
                    .accessibilityElement(children: .combine)
                    SettingsDivider()
                    IdleTimeoutRow(session: app.session)
                }
                .cardSurface(radius: Radius.row)
                .padding(.top, 10)

                Text("Set up the Action button").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                    .accessibilityAddTraits(.isHeader).padding(.top, 16)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1).").font(Ink.mono(15, weight: .medium)).foregroundStyle(Ink.mute)
                            Text(step).font(.system(size: 16)).foregroundStyle(Ink.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .cardSurface(radius: Radius.row)

                Text("While a session is on, each press starts or stops a take without leaving the app you're in. The Dynamic Island shows Listening, then Copied or Inserted with the word count. The Lock Screen never shows your words. You can also add the Verbose session switch to Control Center, or say \u{201C}Dictate with Verbose\u{201D} to Siri.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Action button")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// End the session after: 10, 30, or 60 minutes idle. The same setting as Settings › Keyboard.
private struct IdleTimeoutRow: View {
    @ObservedObject var session: KeyboardSession
    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(icon: "timer", tint: Ink.butterTint, art: .iconRecent, title: "End the session after")
            Spacer(minLength: 8)
            Picker("End the session after", selection: $session.timeoutSeconds) {
                ForEach(KeyboardSession.timeoutChoices, id: \.seconds) { c in
                    Text("\(c.seconds / 60) min idle").tag(c.seconds)
                }
            }
            .labelsHidden()
            .tint(Ink.accentText)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 54)
    }
}

/// One choice: its icon, its name, and a radio mark. The whole row is the button.
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
                Text(choice.title).font(.system(size: 17)).foregroundStyle(Ink.ink)
                Spacer(minLength: 8)
                RadioMark(on: selected)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPress())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .sensoryFeedback(.selection, trigger: selected) { _, now in now }
    }

    private var art: BrandArt {
        switch choice {
        case .dictate: return .iconDictations
        case .voiceNote: return .capture
        case .captions: return .iconCaptions
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
