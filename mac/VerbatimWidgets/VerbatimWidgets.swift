import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// The VerbatimWidgets extension: the keyboard session's and the recording's Live Activities, the Lock Screen
/// widget, and (iOS 18) the Control Center control that start a keyboard session.
@main
struct VerbatimWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        RecordingLiveActivity()
        StartSessionWidget()
        if #available(iOS 18.0, *) {
            StartSessionControl()
        }
    }
}

/// Dynamic Island: the bars mark in persimmon and a state icon (a check when ready, three bars while listening).
/// Expanded and on the Lock Screen: "Verbatim is ready" or "Listening…", and End session.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VerbatimSessionAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Ink.inkFixed)
                .activitySystemActionForegroundColor(Ink.paperFixed)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BarsMark(color: Ink.persimmon).frame(width: 26, height: 26).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StateIcon(listening: context.state.listening).frame(width: 22, height: 22).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.listening ? "Listening…" : "Verbose is ready")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(subtitle(context.state)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Spacer(minLength: 8)
                        EndButton()
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                BarsMark(color: Ink.persimmon).frame(width: 16, height: 16)
            } compactTrailing: {
                StateIcon(listening: context.state.listening).frame(width: 16, height: 16)
            } minimal: {
                BarsMark(color: Ink.persimmon).frame(width: 16, height: 16)
            }
            .keylineTint(Ink.persimmon)
        }
    }
}

private func subtitle(_ s: VerbatimSessionAttributes.ContentState) -> String {
    s.listening ? "Tap ✓ on the keyboard when you're done" : "Tap the record button on the Verbose keyboard"
}

private struct LockScreenView: View {
    var state: VerbatimSessionAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            BarsMark(color: Ink.persimmon).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.listening ? "Listening…" : "Verbose is ready")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.paperFixed)
                if let ends = state.endsAt, !state.listening {
                    (Text("Ends in ") + Text(timerInterval: Date()...max(Date(), ends), countsDown: true))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(Ink.paperFixed.opacity(0.7))
                } else {
                    Text("Microphone on for the keyboard")
                        .font(.system(size: 13)).foregroundStyle(Ink.paperFixed.opacity(0.7))
                }
            }
            Spacer(minLength: 8)
            EndButton()
        }
        .padding(16)
    }
}

/// A check when the session is ready; three butter bars while listening (butter means Dictate).
private struct StateIcon: View {
    var listening: Bool
    var body: some View {
        if listening {
            HStack(spacing: 2) {
                ForEach([0.6, 1.0, 0.8], id: \.self) { h in
                    Capsule().fill(Ink.butter).frame(width: 3.5).frame(maxHeight: .infinity).scaleEffect(y: h)
                }
            }
            .accessibilityLabel("Listening")
        } else {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.butter)
                .accessibilityLabel("Ready")
        }
    }
}

private struct EndButton: View {
    var body: some View {
        Button(intent: EndVerbatimSessionIntent()) {
            Text("End session").font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(Ink.persimmon)
        .accessibilityHint("Turns off the microphone")
    }
}
