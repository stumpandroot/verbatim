import SwiftUI
import UIKit

// MARK: - Session start screen

/// Over the app for the moment a keyboard session starts. In your builds you normally see it for under a second
/// before Verbatim switches back to your app; when it can't switch back by itself (always in App Store builds), it
/// shows how to go back: a coach card with two illustrated ways for the first five session starts, then a line. A link that didn't come from
/// the keyboard just now (the Lock Screen widget, another app) asks first, and the microphone stays off until you
/// tap Start session.
struct SessionStartScreen: View {
    @ObservedObject var session: KeyboardSession
    @Environment(\.look) private var look

    var body: some View {
        if session.confirming != nil { confirmation } else { starting }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionEyebrow()
            .padding(.top, 24)

            Text("Start a keyboard session?")
                .lookSerif(34).foregroundStyle(.lookInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)

            Text("Verbose turns on the microphone so you can dictate with the Verbose keyboard in any app. The orange microphone dot stays on until the session ends. Audio is saved only while you dictate.")
                .font(.system(size: 16)).foregroundStyle(.lookDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            HStack(spacing: 12) {
                Button("Not now") { session.declineStart() }
                    .buttonStyle(.phoneSecondaryLarge)
                    .accessibilityHint("Closes this screen. The microphone stays off.")
                Button("Start session") { session.confirmStart() }
                    .buttonStyle(.phonePrimaryLarge)
                    .accessibilityHint("Turns on the microphone for the Verbose keyboard")
            }
            .padding(.top, 26)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .phonePage()
    }

    private var starting: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SessionEyebrow()
                .padding(.top, 24)

                Text(title)
                    .lookSerif(34).foregroundStyle(.lookInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)

                if showsWayBack {
                    Text(Ribbon.coachTitle(sourceApp: session.sourceAppName))
                        .lookSerif(22).foregroundStyle(.lookInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    if let detail = takeDetail {
                        Text(detail)
                            .font(.system(size: 16)).foregroundStyle(.lookDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                    switch session.coach {
                    case .full:
                        WayBackCoach(sourceApp: session.sourceAppName, showsBreadcrumb: showsBreadcrumb)
                            .padding(.top, 20)
                    case .reminder:
                        Text(reminderLine)
                            .font(.system(size: 15)).foregroundStyle(.lookDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                } else {
                    Text(detail)
                        .font(.system(size: 16)).foregroundStyle(.lookDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }

                // A status, not a recording: a neutral card with an ink outline, and persimmon only on the voice bars.
                HStack(spacing: 18) {
                    VoiceBars(level: session.isOn ? 0.35 : 0, color: look.isNative ? NativeInk.accent : Ink.persimmon, barWidth: 14, maxHeight: 64)
                        .frame(width: 72)
                    Text(session.dictating ? "Listening" : session.isOn ? "Ready" : "Starting…")
                        .lookSerif(24).foregroundStyle(.lookInk)
                    Spacer(minLength: 0)
                }
                .padding(22)
                .frame(maxWidth: .infinity, minHeight: showsWayBack && session.coach == .full ? 96 : 120, alignment: .leading)
                .modifier(SessionStatusSurface())
                .padding(.top, 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(session.dictating ? "Listening" : session.isOn ? "Session ready" : "Starting")

                if Ribbon.showsFirstDictationNote(done: session.firstDictationDone) {
                    FirstDictationNote().padding(.top, 14)
                }

                // The instruction above is the hero (go back to your app), so neither button is the dark primary:
                // Stay in Verbose is a line pill and End session a quiet text button, side by side as on Session ended.
                if session.needsManualReturn {
                    HStack(spacing: 12) {
                        Button("Stay in Verbose") { session.showScreen = false }
                            .buttonStyle(.phoneSecondaryLarge)
                            .accessibilityHint("Closes this screen. The session stays on.")
                        Button("End session") { session.end(reason: nil) }
                            .buttonStyle(SessionQuietButton())
                            .accessibilityHint("Turns off the microphone")
                    }
                    .padding(.top, 20)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .phonePage()
    }

    /// Once the session is on and you have to go back yourself (always in App Store builds, which can't switch
    /// back; in your builds when switching back didn't work; and for any start from outside the keyboard), the
    /// screen says how: the coach card for the first five session starts, then one line. It stays until you leave.
    private var showsWayBack: Bool { session.isOn && (session.needsManualReturn || session.startSource != nil) }

    /// iOS shows "◀ <app>" at the top left when another app opened Verbose (the keyboard's link). A start from
    /// Control Center, the Action button, or Shortcuts has none.
    private var showsBreadcrumb: Bool { session.startSource == nil }

    private var reminderLine: String {
        let crumb = showsBreadcrumb ? ", " + Ribbon.breadcrumbLine(sourceApp: session.sourceAppName) : ""
        return "Swipe right along the bottom edge" + crumb + "."
    }

    private var title: String {
        if !session.isOn { return "Turning on the microphone…" }
        if session.startedForTake, session.dictating { return "Listening. Go back to talk." }
        if showsWayBack { return "Your session is on." }
        return "Going back…"
    }

    /// Under the coach while a take started from the Action button listens: how it ends.
    private var takeDetail: String? {
        if session.startedForTake, session.dictating {
            return "Talk, then press the Action button again: your words go into the Verbose keyboard if it's open, or on the clipboard."
        }
        if session.dictating, session.startSource == nil { return "Verbose is already listening: talk, then tap the check on the keyboard." }
        return nil
    }

    /// Before the session is on, and while your builds switch back by themselves.
    private var detail: String {
        if session.startedForTake, !session.isOn { return "Verbose turns on the microphone and starts listening." }
        if !session.isOn { return "Verbose turns on the microphone for the Verbose keyboard." }
        if session.dictating {
            return "Verbose switches back to your app in a moment and keeps listening. Talk, then tap the check on the keyboard."
        }
        return "Verbose switches back to your app in a moment. Dictation then happens right in the keyboard."
    }
}

/// The two ways back to your app, drawn small in the brand: the home indicator with a dot that slides right (still
/// under Reduce Motion or Limit animation, with an arrow), and the status bar's "◀ Messages" link.
private struct WayBackCoach: View {
    var sourceApp: String?
    var showsBreadcrumb: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(illustration: AnyView(SwipeHint()), text: "Swipe right along the bottom edge")
            if showsBreadcrumb {
                Rectangle().fill(.lookHairline).frame(height: 1).padding(.leading, 112)
                row(illustration: AnyView(BreadcrumbHint(name: sourceApp)), text: Ribbon.breadcrumbLine(sourceApp: sourceApp))
            }
        }
        .cardSurface(radius: Radius.row)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showsBreadcrumb ? "Swipe right along the bottom edge, " + Ribbon.breadcrumbLine(sourceApp: sourceApp) : "Swipe right along the bottom edge")
    }

    private func row(illustration: AnyView, text: String) -> some View {
        HStack(spacing: 16) {
            illustration.frame(width: 84, height: 56)
            Text(text).font(.system(size: 16, weight: .medium)).foregroundStyle(.lookInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// The bottom of a phone: its edge, the home indicator, and a persimmon dot that travels right along it.
private struct SwipeHint: View {
    @Environment(\.limitMotion) private var limitMotion
    @State private var travel = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous)
                    .stroke(.lookInk, lineWidth: 1.5)
                    .frame(width: w, height: h)
                Capsule().fill(.lookInk).frame(width: w * 0.46, height: 4)
                    .position(x: w / 2, y: h - 9)
                Circle().fill(.lookMark).frame(width: 12, height: 12)
                    .position(x: limitMotion || travel ? w * 0.72 : w * 0.28, y: h - 9)
                    .opacity(limitMotion ? 1 : (travel ? 0.15 : 1))
                if limitMotion {
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.lookAccentText)
                        .position(x: w * 0.5, y: h - 24)
                }
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !limitMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).delay(0.3).repeatForever(autoreverses: false)) { travel = true }
        }
    }
}

/// The status bar's top left with "◀ Messages" (or "◀ Your app"), outlined in persimmon where you tap.
private struct BreadcrumbHint: View {
    var name: String?
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                    .stroke(.lookInk, lineWidth: 1.5)
                    .frame(width: w, height: h)
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    Text(name ?? "Your app").font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(.lookInk)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .overlay(Capsule().stroke(.lookMark, lineWidth: 2))
                .frame(maxWidth: w - 16, alignment: .leading)
                .offset(x: 8, y: 9)
                Text("9:41").lookMono(9).foregroundStyle(.lookMute)
                    .position(x: w - 18, y: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

/// "Your first dictation takes a few seconds longer…": until the first keyboard dictation succeeds.
struct FirstDictationNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Diamond().stroke(.lookAccentText, lineWidth: 1).frame(width: 7, height: 7).padding(.top, 6)
            Text(Ribbon.firstDictationNote)
                .font(.system(size: 14)).foregroundStyle(.lookDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.row)
        .accessibilityElement(children: .combine)
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
    /// Also in the App Group, read by the app: the expanded Dynamic Island's words line (`Ribbon.islandWordsKey`).
    @AppStorage(Ribbon.islandWordsKey, store: KeyboardBridge.defaults) private var islandWords = false
    /// Also in the App Group: the app copies after each keyboard dictation, or the keyboard does (`KeyboardBridge.alwaysCopy`).
    @AppStorage(KeyboardBridge.alwaysCopyKey, store: KeyboardBridge.defaults) private var alwaysCopy = false

    private let steps = [
        "Open the Settings app.",
        "Go to General › Keyboard › Keyboards.",
        "Tap Add New Keyboard, and then tap Verbose.",
        "Tap Verbose in the list, and then turn on Allow Full Access.",
        "In any app, touch and hold the globe key, and then choose Verbose.",
    ]

    /// The suggested ways to start a session: the keyboard's Start a session and the Action button (consolidation,
    /// October 28, 2026). The Control Center switch and the Start dictation session widget stay available (Settings ›
    /// Features › Widgets and controls) but aren't suggested here.
    private let startWays: [(symbol: String, text: String)] = [
        ("keyboard", "The Verbose keyboard: tap Start a session. Verbose opens and turns on the microphone."),
        ("button.horizontal.top.press", "Action button: in Settings › Action Button, choose Controls › Verbose action. The first press starts a session and a take; see Verbose › Settings › Action button."),
        ("mic", "Here: tap Start keyboard session above."),
    ]

    var body: some View {
        // The Settings page scaffold (serif compact title, as Appearance and Templates use) and the shared section
        // label; the five switches share one card.
        SettingsPageScaffold(title: "Keyboard") {
            VStack(alignment: .leading, spacing: 16) {
                Text("The Verbose keyboard puts dictation in every app. You tap the dictate button, talk, and tap the check.")
                    .font(.system(size: 16)).foregroundStyle(.lookInk)
                    .fixedSize(horizontal: false, vertical: true)

                DictateButtonSettings()
                    .padding(.top, 6)

                SettingsPageLabel(text: "Add the keyboard").padding(.top, 6)
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

                SettingsPageLabel(text: "Sessions").padding(.top, 6)
                SessionCard(session: app.session)
                FirstDictationNoteRow(session: app.session)

                // Every build: the keyboard opens Verbose to start a session (App Store builds too, since October 2026).
                VStack(spacing: 0) {
                    SettingsToggleRow(title: "Start dictating when you come back",
                                      subtitle: "The first tap opens Verbose and starts listening; no second tap.", isOn: $autoStart)
                    SettingsDivider()
                    SettingsToggleRow(title: "Polish after inserting",
                                      subtitle: "Your words appear right away; Verbose swaps in the cleaned-up version a moment later.", isOn: $polishAfter)
                    SettingsDivider()
                    SettingsToggleRow(title: "Show words as you speak",
                                      subtitle: "The keyboard shows your words while you talk, recognized on this iPhone.", isOn: $liveWords)
                    SettingsDivider()
                    SettingsToggleRow(title: "Show words in the Dynamic Island",
                                      subtitle: "When you touch and hold the Dynamic Island during a take, it shows your last few words. The Lock Screen never shows your words.", isOn: $islandWords)
                    SettingsDivider()
                    SettingsToggleRow(title: "Also copy each dictation",
                                      subtitle: "Each keyboard dictation also goes on the clipboard, so you can paste it somewhere else. The clock button in the keyboard shows your last dictations either way.", isOn: $alwaysCopy)
                }
                .cardSurface(radius: Radius.row)

                PhoneLowerAudioRow()

                KeyboardTypingHapticsRow()

                Text(Distribution.current.returnsToHostApp
                     ? "The first time you tap the record button, Verbose opens for a second to turn on the microphone, then switches back. That starts a session: from then on, dictation starts right in the keyboard. The session shows in the Dynamic Island and on the Lock Screen, where you can end it. If Verbose can't switch back by itself, tap ◀ and your app's name at the top left."
                     : "The first time you tap Start a session, Verbose opens to turn on the microphone. Go back to your app with ◀ and its name at the top left, or swipe right along the bottom edge. That starts a session: from then on, dictation starts right in the keyboard. The session shows in the Dynamic Island and on the Lock Screen, where you can end it.")
                    .font(.system(size: 15)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsPageLabel(text: "Start a session from anywhere").padding(.top, 6)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(startWays.enumerated()), id: \.offset) { _, way in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: way.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.lookAccentText).frame(width: 20)
                            Text(way.text).font(.system(size: 16)).foregroundStyle(.lookInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .cardSurface(radius: Radius.row)

                SettingsPageLabel(text: "Privacy").padding(.top, 6)
                Text("While a session is on, Verbose keeps the microphone open so dictation starts instantly, and the orange microphone dot stays on. Audio is only saved while you're dictating, and stays on this iPhone unless iCloud sync is on. Each dictation is saved in Library › Dictations; deleting it also removes it from the keyboard's recent dictations, which keep at most 10 from the last day.")
                    .font(.system(size: 15)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsPageLabel(text: "Why Full Access").padding(.top, 6)
                Text("Full Access lets the keyboard open Verbose to start a session and receive your words from it." + " Listening and transcription happen in the Verbose app on this iPhone; the keyboard never sends what you type or say anywhere else.")
                    .font(.system(size: 15)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.phonePrimaryLarge)
                .padding(.top, 8)
                .accessibilityHint("Opens Verbose's page in the Settings app")
            }
            .padding(.top, 10)
        }
    }
}

/// The session's state, End session, and the idle timeout.
private struct SessionCard: View {
    @ObservedObject var session: KeyboardSession
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(session.isOn ? AnyShapeStyle(.lookMark) : AnyShapeStyle(Ink.mute.opacity(0.4))).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.paused ? "Paused for a call" : session.isOn ? "Session on" : "No session").font(.system(size: 16, weight: .medium)).foregroundStyle(.lookInk)
                    if session.isOn {
                        if let ends = session.endsAt {
                            (Text("Ends in ") + Text(timerInterval: Date()...max(Date(), ends), countsDown: true))
                                .font(.system(size: 13)).monospacedDigit().foregroundStyle(.lookMute)
                        } else {
                            Text("Runs until you end it").font(.system(size: 13)).monospacedDigit().foregroundStyle(.lookMute)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if session.isOn {
                    Button("End session") { session.end(reason: nil) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.lookAccentText)
                        .accessibilityHint("Turns off the microphone")
                }
            }
            if !session.isOn {
                Button("Start keyboard session") { session.startFromOutside(.app) }
                    .buttonStyle(.phonePrimaryLarge)
                    .accessibilityHint("Turns on the microphone for the Verbose keyboard")
            }
            Divider()
            HStack {
                Text("End keyboard sessions after").font(.system(size: 16)).foregroundStyle(.lookInk)
                Spacer(minLength: 8)
                Picker("End keyboard sessions after", selection: $session.timeoutSeconds) {
                    ForEach(KeyboardSession.timeoutChoices, id: \.seconds) { c in
                        Text(c.seconds == 0 ? c.label : "\(c.label) idle").tag(c.seconds)
                    }
                }
                .labelsHidden()
                .tint(look.isNative ? NativeInk.accent : Ink.accentText)
            }
            Text("A call or Siri pauses the session; it picks up when the call ends. While a session is on, the orange microphone dot shows at the top of the screen.")
                .font(.system(size: 13)).foregroundStyle(.lookMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .cardSurface(radius: Radius.row)
    }
}

/// The first dictation note on Settings › Keyboard, until the first keyboard dictation succeeds.
private struct FirstDictationNoteRow: View {
    @ObservedObject var session: KeyboardSession
    var body: some View {
        if Ribbon.showsFirstDictationNote(done: session.firstDictationDone) { FirstDictationNote() }
    }
}

// MARK: - Session ended

/// Over the app after a call or another app's audio ended the session (the approved ribbon mockup, screen 7): why
/// it ended, the last take (here in Verbose only, never on the Lock Screen), and Restart session.
struct SessionEndedScreen: View {
    @ObservedObject var session: KeyboardSession
    var notice: KeyboardSession.EndedNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session ended")
                .lookSerif(34).foregroundStyle(.lookInk)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            Text(notice.reason + (notice.lastTake == nil ? "" : " Your last take is saved in Dictations."))
                .font(.system(size: 16)).foregroundStyle(.lookDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            if let take = notice.lastTake {
                HStack(spacing: 10) {
                    LookIcon(art: .iconRecent, symbol: "clock.arrow.circlepath", size: 20)
                    Text(take).font(.system(size: 16)).foregroundStyle(.lookInk).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let at = notice.lastTakeAt {
                        Text(at, style: .time).font(.system(size: 14)).monospacedDigit().foregroundStyle(.lookMute)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .cardSurface(radius: Radius.row)
                .padding(.top, 20)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Last take: " + take)
            }

            // Side by side, the same layout as the session's start screens.
            HStack(spacing: 12) {
                Button("Not now") { session.endedNotice = nil }
                    .buttonStyle(.phoneSecondaryLarge)
                Button("Restart session") {
                    session.endedNotice = nil
                    session.startFromOutside(.app)
                }
                .buttonStyle(.phonePrimaryLarge)
                .accessibilityHint("Turns the microphone back on")
            }
            .padding(.top, 20)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .phonePage()
    }
}

// brand: native begin
/// "Keyboard session" over the session screens: the diamond and the overline in Verbose style, a plain secondary line
/// in Native.
private struct SessionEyebrow: View {
    @Environment(\.look) private var look
    var body: some View {
        Group {
            if look.isNative {
                Text("Keyboard session").font(.subheadline.weight(.semibold)).foregroundStyle(NativeInk.secondary)
            } else {
                HStack(spacing: 8) {
                    Diamond().stroke(Ink.accentText, lineWidth: 1).frame(width: 7, height: 7)
                    Overline(text: "Keyboard session", color: Ink.dim)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The session's status card: the ink-outlined card in Verbose style, a grouped cell in Native.
private struct SessionStatusSurface: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.isNative {
            content.nativeCell()
        } else {
            content
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5))
        }
    }
}
// brand: native end

/// A quiet text button beside a pill on the session screens ("End session"): semibold dim text, no fill or outline,
/// a 44 pt target.
private struct SessionQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookDim)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
