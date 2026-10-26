import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// The recording's Live Activity. Lock Screen: the bars mark, "Voice note" in the serif, a mono timer that runs
/// on its own, the state, and Pause or Resume and Stop. Dynamic Island compact: a persimmon dot (a pause glyph
/// while paused) and the timer. Tapping anywhere else opens the recorder (verbatim://record).
///
/// A thought (mockup "Thoughts", section 06) draws its own: compact, persimmon voice bars and the time in mono;
/// expanded, "New thought", the time, your last words (older ones dimmed; only with Show words in the Dynamic Island
/// on), "Into Thoughts · Mon, Oct 26", and Stop; saved, "Added to Thoughts" and the time for two seconds. Its Lock
/// Screen is on paper with the time, your voice, and Stop, and never shows your words.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VerbatimRecordingAttributes.self) { context in
            Group {
                if context.attributes.isThought {
                    ThoughtLockScreen(page: context.attributes.page, state: context.state)
                } else {
                    RecordingLockScreen(title: context.attributes.title, state: context.state)
                }
            }
            .activityBackgroundTint(context.attributes.isThought ? Ink.paperFixed : Color(hex: Ink.inkHex))
            .activitySystemActionForegroundColor(context.attributes.isThought ? Ink.inkFixed : Color(hex: Ink.paperHex))
            .widgetURL(recordLink)
        } dynamicIsland: { context in
            let thought = context.attributes.isThought
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if thought {
                        if s.saved {
                            ThoughtSavedLine(state: s).padding(.leading, 4)
                        } else {
                            HStack(spacing: 7) {
                                ThoughtVoiceBars(level: s.level ?? 0, color: Ink.persimmon, count: 5).frame(width: 22, height: 18)
                                Text(ThoughtRules.activityTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .lineLimit(1).fixedSize()
                            }
                            .padding(.leading, 4)
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        HStack(spacing: 8) {
                            RecordingDot(state: s).frame(width: 12, height: 12)
                            Text(context.attributes.title).font(Ink.serif(17)).foregroundStyle(.white).lineLimit(1)
                        }
                        .padding(.leading, 4)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !(thought && s.saved) {
                        RecordingTimer(state: s)
                            .font(Ink.mono(thought ? 14 : 17, weight: .medium)).foregroundStyle(.white)
                            .frame(maxWidth: 90, alignment: .trailing)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if thought {
                        if !s.saved {
                            VStack(alignment: .leading, spacing: 10) {
                                if let line = s.words, !line.isEmpty { ThoughtIslandWords(line: line) }
                                HStack(spacing: 8) {
                                    ThoughtIntoLabel(page: context.attributes.page)
                                    Spacer(minLength: 6)
                                    ThoughtStopButton(onDark: true, compact: true)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    } else {
                        HStack(spacing: 10) {
                            Text(s.status).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                            Spacer(minLength: 8)
                            if !s.saved { RecordingButtons(state: s) }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                if thought {
                    if s.saved {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.persimmon)
                            .accessibilityLabel(ThoughtRules.savedTitle)
                    } else {
                        ThoughtVoiceBars(level: s.level ?? 0, color: Ink.persimmon, count: 5).frame(width: 22, height: 16)
                    }
                } else {
                    RecordingDot(state: s).frame(width: 10, height: 10)
                }
            } compactTrailing: {
                if thought, s.saved, let at = s.savedAt {
                    Text(at, format: .dateTime.hour().minute()).font(Ink.mono(12, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).frame(width: 52, alignment: .trailing)
                } else {
                    RecordingTimer(state: s)
                        .font(Ink.mono(thought ? 12 : 13, weight: .medium))
                        .foregroundStyle(thought ? Color.white : (s.isPaused ? Color.white.opacity(0.7) : Ink.persimmon))
                        .multilineTextAlignment(.trailing)
                        .frame(width: thought ? 40 : 52, alignment: .trailing)
                }
            } minimal: {
                if thought {
                    Image("thought").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.persimmon)
                        .accessibilityLabel(s.saved ? ThoughtRules.savedTitle : ThoughtRules.activityTitle)
                } else {
                    RecordingDot(state: s).frame(width: 10, height: 10)
                }
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
            Image(systemName: "pause.fill").resizable().scaledToFit().foregroundStyle(.white.opacity(0.8)).accessibilityLabel("Paused")   // brand: system surface
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
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill").font(.system(size: 15, weight: .semibold))   // brand: system surface
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .tint(Color(hex: Ink.paperHex))
            .accessibilityLabel(state.isPaused ? "Resume" : "Pause")
            Button(intent: StopRecordingIntent()) {
                Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))   // brand: system surface
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.persimmon)
            .accessibilityLabel("Stop")
            .accessibilityHint("Saves the recording and transcribes it")
        }
    }
}

// MARK: - A thought

/// A thought on the Lock Screen, on paper: the bars mark, "Recording a thought", the time, your voice, where it goes,
/// and Stop. Never reads `state.words`: anyone can read a Lock Screen. Saved: a check and "Added to Thoughts · 9:41".
private struct ThoughtLockScreen: View {
    var page: String?
    var state: VerbatimRecordingAttributes.ContentState
    private let ink = Ink.inkFixed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.saved {
                ThoughtSavedLine(state: state, onPaper: true)
            } else {
                HStack(spacing: 8) {
                    BarsMark(color: Ink.persimmonFixed).frame(width: 18, height: 18)
                    Text(state.isPaused ? (state.pausedReason ?? "Paused") : ThoughtRules.lockTitle)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Spacer(minLength: 8)
                    RecordingTimer(state: state).font(Ink.mono(15, weight: .medium)).foregroundStyle(ink)
                        .frame(width: 60, alignment: .trailing)
                }
                ThoughtVoiceBars(level: state.level ?? 0, color: Ink.persimmonFixed, count: 34).frame(height: 22)
                Text(ThoughtRules.intoLine(page ?? "Thoughts")).font(.system(size: 13)).foregroundStyle(ink.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.85)
                ThoughtStopButton(onDark: false, compact: false)
            }
        }
        .padding(14)
    }
}

/// "Added to Thoughts" and the time it was saved, with a check.
private struct ThoughtSavedLine: View {
    var state: VerbatimRecordingAttributes.ContentState
    var onPaper = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(onPaper ? Ink.inkFixed : Ink.persimmon)
                .accessibilityHidden(true)
            Text(ThoughtRules.savedTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(onPaper ? Ink.inkFixed : .white)
                .lineLimit(1).fixedSize()
            if let at = state.savedAt {
                Text(at, format: .dateTime.hour().minute()).font(Ink.mono(14, weight: .medium))
                    .foregroundStyle(onPaper ? Ink.muteOnPaper : Color.white.opacity(0.7)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The expanded Island's words line: two lines at most, older words dimmed and the newest three bright. The app sends
/// it only with Show words in the Dynamic Island on.
private struct ThoughtIslandWords: View {
    var line: String
    var body: some View {
        let parts = Ribbon.splitWords(line)
        Text("\(Text(parts.older).foregroundStyle(Color.white.opacity(0.5)))\(Text(parts.newest).foregroundStyle(Color.white))")
            .font(Ink.serif(16)).lineLimit(2).truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line)
    }
}

/// "Into Thoughts · Mon, Oct 26" with the Thoughts symbol.
private struct ThoughtIntoLabel: View {
    var page: String?
    var body: some View {
        HStack(spacing: 6) {
            Image("thought").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                .accessibilityHidden(true)
            Text(ThoughtRules.intoLine(page ?? "Thoughts")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// Stop: saves the thought to today's page (`StopRecordingIntent`). Persimmon with ink text; opaque, no blur.
private struct ThoughtStopButton: View {
    var onDark: Bool
    var compact: Bool
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Ink.inkFixed).frame(width: 9, height: 9)
                Text("Stop").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.inkFixed).lineLimit(1)
            }
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(minWidth: compact ? 72 : nil)
            .padding(.horizontal, compact ? 12 : 0)
            .padding(.vertical, 8)
            .background(Ink.persimmonFixed, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
        .accessibilityHint("Adds the thought to today's page")
    }
}

/// The level, about once a second: fixed bar shapes scaled by the real microphone level (as the session's ribbon).
private struct ThoughtVoiceBars: View {
    var level: Double
    var color: Color
    var count = 5
    private static let shape: [Double] = [0.45, 0.7, 0.55, 0.9, 1.0, 0.8, 0.6, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: count > 5 ? 3 : 2) {
            ForEach(0..<count, id: \.self) { i in
                let base = Self.shape[(i * Self.shape.count) / max(1, count)]
                Capsule().fill(color)
                    .frame(width: count > 5 ? 3 : 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: max(0.15, base * (0.2 + 0.8 * min(1, max(0, level)))), anchor: .center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your voice")
    }
}
