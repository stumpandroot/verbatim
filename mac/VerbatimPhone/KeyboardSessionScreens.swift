import SwiftUI
import UIKit

// MARK: - Session start screen

/// Over the app for the moment a keyboard session starts. Normally you see it for under a second before Verbatim
/// switches back to your app; when it can't switch back by itself, it tells you how.
struct SessionStartScreen: View {
    @ObservedObject var session: KeyboardSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Diamond().stroke(Ink.accentText, lineWidth: 1).frame(width: 7, height: 7)
                Overline(text: "Keyboard session", color: Ink.accentText)
            }
            .padding(.top, 24)
            .accessibilityElement(children: .combine)

            Text(title)
                .font(Ink.serif(34)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)

            Text(detail)
                .font(.system(size: 16)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            HStack(spacing: 18) {
                VoiceBars(level: session.isOn ? 0.35 : 0, color: Ink.inkFixed, barWidth: 14, maxHeight: 64)
                    .frame(width: 72)
                Text(session.isOn ? "Ready" : "Starting…")
                    .font(Ink.serif(24)).foregroundStyle(Ink.inkFixed)
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(Ink.persimmon, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.top, 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.isOn ? "Session ready" : "Starting")

            if session.needsManualReturn {
                HStack(spacing: 12) {
                    Button("End session") { session.end(reason: nil) }
                        .buttonStyle(.brandSecondaryLarge)
                        .accessibilityHint("Turns off the microphone")
                    Button("Stay in Verbatim") { session.showScreen = false }
                        .buttonStyle(.brandPrimaryLarge)
                        .accessibilityHint("Closes this screen. The session stays on.")
                }
                .padding(.top, 20)
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.paper.ignoresSafeArea())
    }

    private var title: String {
        if !session.isOn { return "Turning on the microphone…" }
        return session.needsManualReturn ? "You're set." : "Going back…"
    }

    private var detail: String {
        if session.needsManualReturn {
            return "Swipe right along the bottom edge to go back, or tap the app's name at the top left. Then tap the record button on the Verbatim keyboard and talk."
        }
        return "Verbatim switches back to your app in a moment. Dictation then happens right in the keyboard."
    }
}

// MARK: - Settings › Keyboard

/// How to add the Verbatim keyboard, the session's idle timeout, and what a session does with the microphone.
/// Google developer documentation style: second person, numbered steps.
struct KeyboardSetupScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.openURL) private var openURL

    private let steps = [
        "Open the Settings app.",
        "Go to General › Keyboard › Keyboards.",
        "Tap Add New Keyboard, and then tap Verbatim.",
        "Tap Verbatim in the list, and then turn on Allow Full Access.",
        "In any app, touch and hold the globe key, and then choose Verbatim.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The Verbatim keyboard puts dictation in every app. You tap the record button, talk, and tap the check; Verbatim writes your words into the field.")
                    .font(.system(size: 16)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Overline(text: "Add the keyboard", color: Ink.mute).padding(.top, 6)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1).").font(Ink.mono(15, weight: .medium)).foregroundStyle(Ink.accentText)
                            Text(step).font(.system(size: 16)).foregroundStyle(Ink.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .cardSurface(radius: 14)

                Overline(text: "Sessions", color: Ink.mute).padding(.top, 6)
                SessionCard(session: app.session)

                Text("The first time you tap the record button, Verbatim opens for a second to turn on the microphone, then switches back. That starts a session: from then on, dictation starts right in the keyboard. The session shows in the Dynamic Island and on the Lock Screen, where you can end it.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Overline(text: "Privacy", color: Ink.mute).padding(.top, 6)
                Text("While a session is on, Verbatim keeps the microphone open so dictation starts instantly, and the orange microphone dot stays on. Audio is only saved while you're dictating, and never leaves this iPhone. Each dictation is saved in Library › Dictations.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Overline(text: "Why Full Access", color: Ink.mute).padding(.top, 6)
                Text("Full Access lets the keyboard open Verbatim to start a session and receive your words from it. Listening and transcription happen in the Verbatim app on this iPhone; the keyboard never sends what you type or say anywhere else.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.brandPrimaryLarge)
                .padding(.top, 8)
                .accessibilityHint("Opens Verbatim's page in the Settings app")
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Keyboard")
    }
}

/// The session's state, End session, and the idle timeout.
private struct SessionCard: View {
    @ObservedObject var session: KeyboardSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(session.isOn ? Ink.persimmon : Ink.mute.opacity(0.4)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isOn ? "Session on" : "No session").font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.ink)
                    if session.isOn {
                        if let ends = session.endsAt {
                            (Text("Ends in ") + Text(timerInterval: Date()...max(Date(), ends), countsDown: true))
                                .font(Ink.mono(13)).foregroundStyle(Ink.mute)
                        } else {
                            Text("Runs until you end it").font(Ink.mono(13)).foregroundStyle(Ink.mute)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if session.isOn {
                    Button("End session") { session.end(reason: nil) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.accentText)
                        .accessibilityHint("Turns off the microphone")
                }
            }
            Divider()
            HStack {
                Text("End the session after").font(.system(size: 16)).foregroundStyle(Ink.ink)
                Spacer(minLength: 8)
                Picker("End the session after", selection: $session.timeoutSeconds) {
                    ForEach(KeyboardSession.timeoutChoices, id: \.seconds) { c in
                        Text(c.seconds == 0 ? c.label : "\(c.label) idle").tag(c.seconds)
                    }
                }
                .labelsHidden()
                .tint(Ink.accentText)
            }
        }
        .padding(16)
        .cardSurface(radius: 14)
    }
}
