import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// The recording's Live Activity. Lock Screen: the bars mark, "Voice note" in the serif, a mono timer that runs
/// on its own, the state, and Pause or Resume and Stop. Dynamic Island compact: a persimmon dot (a pause glyph
/// while paused) and the timer. Tapping anywhere else opens the recorder (verbatim://record).
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VerbatimRecordingAttributes.self) { context in
            RecordingLockScreen(title: context.attributes.title, state: context.state)
                .activityBackgroundTint(Color(hex: Ink.inkHex))
                .activitySystemActionForegroundColor(Color(hex: Ink.paperHex))
                .widgetURL(recordLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        RecordingDot(state: context.state).frame(width: 12, height: 12)
                        Text(context.attributes.title).font(Ink.serif(17)).foregroundStyle(.white).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: context.state)
                        .font(Ink.mono(17, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: 90, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Text(context.state.status).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                        Spacer(minLength: 8)
                        if !context.state.saved { RecordingButtons(state: context.state) }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                RecordingDot(state: context.state).frame(width: 10, height: 10)
            } compactTrailing: {
                RecordingTimer(state: context.state)
                    .font(Ink.mono(13, weight: .medium)).foregroundStyle(context.state.isPaused ? Color.white.opacity(0.7) : Ink.persimmon)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
            } minimal: {
                RecordingDot(state: context.state).frame(width: 10, height: 10)
            }
            .keylineTint(Ink.persimmon)
            .widgetURL(recordLink)
        }
    }
}

private let recordLink = URL(string: "verbatim://record")!

private struct RecordingLockScreen: View {
    var title: String
    var state: VerbatimRecordingAttributes.ContentState
    private let paper = Color(hex: Ink.paperHex)

    var body: some View {
        HStack(spacing: 12) {
            BarsMark(color: Ink.persimmon).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    RecordingDot(state: state).frame(width: 8, height: 8)
                    Text(title).font(Ink.serif(17)).foregroundStyle(paper).lineLimit(1)
                }
                RecordingTimer(state: state)
                    .font(Ink.mono(26, weight: .medium)).foregroundStyle(paper)
                Text(state.status).font(.system(size: 13)).foregroundStyle(paper.opacity(0.75)).lineLimit(2)
            }
            Spacer(minLength: 8)
            if state.saved {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(Ink.persimmon)
                    .accessibilityLabel("Saved")
            } else {
                RecordingButtons(state: state)
            }
        }
        .padding(16)
    }
}

/// Persimmon dot while recording; a pause glyph while paused; a check once saved.
private struct RecordingDot: View {
    var state: VerbatimRecordingAttributes.ContentState
    var body: some View {
        if state.saved {
            Image(systemName: "checkmark").resizable().scaledToFit().foregroundStyle(Ink.persimmon).accessibilityLabel("Saved")
        } else if state.isPaused {
            Image(systemName: "pause.fill").resizable().scaledToFit().foregroundStyle(.white.opacity(0.8)).accessibilityLabel("Paused")
        } else {
            Circle().fill(Ink.persimmon).accessibilityLabel("Recording")
        }
    }
}

/// Counts up on its own while recording; holds still at the recorded length while paused.
private struct RecordingTimer: View {
    var state: VerbatimRecordingAttributes.ContentState
    var body: some View {
        Text(timerInterval: state.startDate...state.startDate.addingTimeInterval(60 * 60 * 24), pauseTime: state.pauseTime, countsDown: false, showsHours: true)
            .monospacedDigit()
            .lineLimit(1)
    }
}

private struct RecordingButtons: View {
    var state: VerbatimRecordingAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleRecordingPauseIntent()) {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill").font(.system(size: 15, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .tint(Color(hex: Ink.paperHex))
            .accessibilityLabel(state.isPaused ? "Resume" : "Pause")
            Button(intent: StopRecordingIntent()) {
                Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.persimmon)
            .accessibilityLabel("Stop")
            .accessibilityHint("Saves the recording and transcribes it")
        }
    }
}
