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
                Overline(text: "Keyboard session", color: Ink.dim)
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
                Text(session.dictating ? "Listening" : session.isOn ? "Ready" : "Starting…")
                    .font(Ink.serif(24)).foregroundStyle(Ink.inkFixed)
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(Ink.persimmon, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .padding(.top, 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.dictating ? "Listening" : session.isOn ? "Session ready" : "Starting")

            if session.needsManualReturn {
                HStack(spacing: 12) {
                    Button("End session") { session.end(reason: nil) }
                        .buttonStyle(.brandSecondaryLarge)
                        .accessibilityHint("Turns off the microphone")
                    Button("Stay in Verbose") { session.showScreen = false }
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
        if session.startSource != nil { return "Your session is on." }
        if session.needsManualReturn { return session.dictating ? "Listening. Go back to talk." : "You're set." }
        return "Going back…"
    }

    /// The manual way back names the system's "◀ <app>" link at the top left first: it's one tap, and iOS shows
    /// it whenever another app opened Verbatim.
    private var detail: String {
        // Started from Control Center, the Action button, Shortcuts, the widget, or Settings: no app to go back to.
        if session.startSource != nil {
            if !session.isOn { return "Verbose turns on the microphone for the Verbose keyboard." }
            return "Go to the app you want to type in: swipe right along the bottom edge, or swipe up and choose it. Then tap the record button on the Verbose keyboard and talk."
        }
        if session.needsManualReturn {
            if session.dictating {
                return "Tap ◀ and your app's name at the top left, or swipe right along the bottom edge. Verbose is already listening: talk, then tap the check on the keyboard."
            }
            return "Tap ◀ and your app's name at the top left, or swipe right along the bottom edge. Then tap the record button on the Verbose keyboard and talk."
        }
        if session.dictating {
            return "Verbose switches back to your app in a moment and keeps listening. Talk, then tap the check on the keyboard."
        }
        return "Verbose switches back to your app in a moment. Dictation then happens right in the keyboard."
    }
}

// MARK: - Settings › Keyboard

/// How to add the Verbatim keyboard, the session's idle timeout, and what a session does with the microphone.
/// Google developer documentation style: second person, numbered steps.
struct KeyboardSetupScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.openURL) private var openURL
    /// In the App Group, so the keyboard reads it too (`KeyboardBridge.autoStart`).
    @AppStorage(KeyboardBridge.Key.autoStart, store: KeyboardBridge.defaults) private var autoStart = true
    /// Also in the App Group: the app reads them when a dictation ends or starts (`KeyboardBridge.polishAfter`,
    /// `KeyboardBridge.liveWords`).
    @AppStorage(KeyboardBridge.Key.polishAfter, store: KeyboardBridge.defaults) private var polishAfter = true
    @AppStorage(KeyboardBridge.Key.liveWords, store: KeyboardBridge.defaults) private var liveWords = true
    /// Also in the App Group: the app copies after each keyboard dictation, or the keyboard does (`KeyboardBridge.alwaysCopy`).
    @AppStorage(KeyboardBridge.alwaysCopyKey, store: KeyboardBridge.defaults) private var alwaysCopy = false

    private let steps = [
        "Open the Settings app.",
        "Go to General › Keyboard › Keyboards.",
        "Tap Add New Keyboard, and then tap Verbose.",
        "Tap Verbose in the list, and then turn on Allow Full Access.",
        "In any app, touch and hold the globe key, and then choose Verbose.",
    ]

    /// Ways to start a session without the keyboard opening Verbatim (the only ways in App Store builds).
    private let startWays: [(symbol: String, text: String)] = [
        ("square.grid.2x2", "Control Center: tap Edit, then Add a Control, and choose Start dictation session."),
        ("button.horizontal.top.press", "Action button: in Settings › Action Button, choose Shortcut, then Verbose › Start dictation session."),
        ("lock", "Lock Screen: touch and hold the Lock Screen, tap Customize, and add the Verbose widget."),
        ("mic", "Here: tap Start keyboard session above."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The Verbose keyboard puts dictation in every app. You tap the record button, talk, and tap the check; Verbose writes your words into the field.")
                    .font(.system(size: 16)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Add the keyboard").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim).accessibilityAddTraits(.isHeader).padding(.top, 6)
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

                Text("Sessions").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim).accessibilityAddTraits(.isHeader).padding(.top, 6)
                SessionCard(session: app.session)

                // Only when the keyboard can open Verbatim (never in App Store builds).
                if Distribution.current.keyboardOpensVerbatim {
                    SettingsToggleRow(icon: "mic", tint: Ink.persimmonTint, title: "Start dictating when you come back",
                                      subtitle: "The first tap opens Verbose and starts listening; no second tap.", isOn: $autoStart)
                        .cardSurface(radius: Radius.row)
                }

                SettingsToggleRow(icon: "sparkles", tint: Ink.persimmonTint, title: "Polish after inserting",
                                  subtitle: "Your words appear right away; Verbose swaps in the cleaned-up version a moment later.", isOn: $polishAfter)
                    .cardSurface(radius: Radius.row)

                SettingsToggleRow(icon: "text.bubble", tint: Ink.persimmonTint, title: "Show words as you speak",
                                  subtitle: "The keyboard shows your words while you talk, recognized on this iPhone.", isOn: $liveWords)
                    .cardSurface(radius: Radius.row)

                SettingsToggleRow(icon: "doc.on.clipboard", tint: Ink.persimmonTint, title: "Also copy each dictation",
                                  subtitle: "Each keyboard dictation also goes on the clipboard, so you can paste it somewhere else. The clock button in the keyboard shows your last dictations either way.", isOn: $alwaysCopy)
                    .cardSurface(radius: Radius.row)

                PhoneLowerAudioRow()

                Text(Distribution.current.keyboardOpensVerbatim
                     ? "The first time you tap the record button, Verbose opens for a second to turn on the microphone, then switches back. That starts a session: from then on, dictation starts right in the keyboard. The session shows in the Dynamic Island and on the Lock Screen, where you can end it. If Verbose can't switch back by itself, tap ◀ and your app's name at the top left."
                     : "A session keeps the microphone ready for the keyboard: while it's on, dictation starts right in the keyboard. The session shows in the Dynamic Island and on the Lock Screen, where you can end it.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Start a session from anywhere").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim).accessibilityAddTraits(.isHeader).padding(.top, 6)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(startWays.enumerated()), id: \.offset) { _, way in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: way.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.accentText).frame(width: 20)
                            Text(way.text).font(.system(size: 16)).foregroundStyle(Ink.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .cardSurface(radius: Radius.row)

                Text("Privacy").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim).accessibilityAddTraits(.isHeader).padding(.top, 6)
                Text("While a session is on, Verbose keeps the microphone open so dictation starts instantly, and the orange microphone dot stays on. Audio is only saved while you're dictating, and never leaves this iPhone. Each dictation is saved in Library › Dictations.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Why Full Access").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim).accessibilityAddTraits(.isHeader).padding(.top, 6)
                Text((Distribution.current.keyboardOpensVerbatim ? "Full Access lets the keyboard open Verbose to start a session and receive your words from it." : "Full Access lets the keyboard receive your words from Verbose and play haptics.") + " Listening and transcription happen in the Verbose app on this iPhone; the keyboard never sends what you type or say anywhere else.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.brandPrimaryLarge)
                .padding(.top, 8)
                .accessibilityHint("Opens Verbose's page in the Settings app")
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
                                .font(.system(size: 13)).monospacedDigit().foregroundStyle(Ink.mute)
                        } else {
                            Text("Runs until you end it").font(.system(size: 13)).monospacedDigit().foregroundStyle(Ink.mute)
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
            if !session.isOn {
                Button("Start keyboard session") { session.startFromOutside(.app) }
                    .buttonStyle(.brandPrimaryLarge)
                    .accessibilityHint("Turns on the microphone for the Verbose keyboard")
            }
            Divider()
            HStack {
                Text("End keyboard sessions after").font(.system(size: 16)).foregroundStyle(Ink.ink)
                Spacer(minLength: 8)
                Picker("End keyboard sessions after", selection: $session.timeoutSeconds) {
                    ForEach(KeyboardSession.timeoutChoices, id: \.seconds) { c in
                        Text(c.seconds == 0 ? c.label : "\(c.label) idle").tag(c.seconds)
                    }
                }
                .labelsHidden()
                .tint(Ink.accentText)
            }
        }
        .padding(16)
        .cardSurface(radius: Radius.row)
    }
}
