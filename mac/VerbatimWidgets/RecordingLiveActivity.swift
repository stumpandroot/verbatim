import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// The recording's Live Activity (mockup "Library features", section 3a). Lock Screen, on paper: the bars mark,
/// "Recording · Voice note", a mono timer that runs on its own, your voice, "Marked 4:12 · 3 moments so far" once
/// you've marked one, and Mark, Pause or Resume, and Stop (the one persimmon fill). Dynamic Island compact: a persimmon
/// dot (a pause glyph while paused) and the timer, or "Marked 4:12" and the count for two seconds after a mark;
/// expanded: "Recording", the time, "Voice note", how many moments are marked, and Mark, Pause, and Stop. Mark runs
/// `MarkMomentIntent` in Verbose's process without opening it. Tapping anywhere else opens the recorder
/// (verbatim://record).
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
            .activityBackgroundTint(Ink.paperFixed)
            .activitySystemActionForegroundColor(Ink.inkFixed)
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
                        HStack(spacing: 7) {
                            if s.saved || s.isPaused {
                                RecordingDot(state: s).frame(width: 12, height: 12)
                            } else {
                                ThoughtVoiceBars(level: s.level ?? 0.5, color: Ink.persimmon, count: 5).frame(width: 22, height: 18)
                            }
                            Text(s.saved ? "Saved" : s.isPaused ? "Paused" : "Recording").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .lineLimit(1).fixedSize()
                        }
                        .padding(.leading, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !(thought && s.saved) {
                        RecordingTimer(state: s)
                            .font(Ink.mono(14, weight: .medium)).foregroundStyle(.white)
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.title).font(Ink.serif(18)).foregroundStyle(Ink.onBlack).lineLimit(1)
                            Text(islandLine(s)).font(.system(size: 13)).foregroundStyle(Ink.onBlackDim).lineLimit(2)
                            if !s.saved {
                                HStack(spacing: 8) {
                                    MarkButton(onDark: true, source: "island")
                                    PauseButton(state: s, onDark: true)
                                    Spacer(minLength: 6)
                                    StopButton(wide: false)
                                }
                                .padding(.top, 12)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                if let clock = s.markedClock {
                    MarkedCompact(clock: clock)
                } else if thought {
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
                if s.markedClock != nil {
                    Text(s.marksLabel).font(Ink.mono(12, weight: .medium)).foregroundStyle(Ink.onBlackDim)
                        .lineLimit(1).fixedSize()
                } else if thought, s.saved, let at = s.savedAt {
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
                if s.markedClock != nil {
                    Image("marked").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.butterFixed)
                        .accessibilityLabel("Marked")
                } else if thought {
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

/// The expanded Island's line under the title: the pause reason, how many moments are marked, or "Saved as you go".
private func islandLine(_ s: VerbatimRecordingAttributes.ContentState) -> String {
    if s.saved || s.isPaused { return s.status }
    return s.markCount > 0 ? "\(s.marksLabel) marked" : "Saved as you go"
}

/// A voice note on the Lock Screen, on paper (mockup "Library features", section 3a): the bars mark, "Recording ·
/// Voice note" and the time, your voice, the last mark and the count ("Marked 4:12 · 3 moments so far"), and Mark,
/// Pause, and Stop. Saved: a check and "Saved. Transcribing on this iPhone."
private struct RecordingLockScreen: View {
    var title: String
    var state: VerbatimRecordingAttributes.ContentState
    private let ink = Ink.inkFixed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.saved {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(ink).accessibilityHidden(true)
                    Text(state.status).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 8) {
                    BarsMark(color: Ink.persimmonFixed).frame(width: 18, height: 18)
                    Text(state.isPaused ? (state.pausedReason ?? "Paused") : "Recording · \(title)")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Spacer(minLength: 8)
                    RecordingTimer(state: state).font(Ink.mono(15, weight: .medium)).foregroundStyle(ink)
                        .frame(width: 70, alignment: .trailing)
                }
                ThoughtVoiceBars(level: state.level ?? 0.5, color: Ink.persimmonFixed, count: 34).frame(height: 22)
                if state.markCount > 0, let at = state.markedAt {
                    HStack(spacing: 6) {
                        Image("marked").font(.system(size: 13, weight: .medium)).accessibilityHidden(true)
                        Text("Marked").font(.system(size: 13, weight: .semibold))
                        Text(VerbatimRecordingAttributes.clock(at)).font(Ink.mono(13, weight: .medium))
                        Text("· \(state.marksLabel) so far").font(.system(size: 13)).foregroundStyle(ink.opacity(0.8))
                    }
                    .foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Saved as you go").font(.system(size: 13)).foregroundStyle(ink.opacity(0.8)).lineLimit(1)
                }
                HStack(spacing: 8) {
                    MarkButton(onDark: false, source: "lockScreen")
                    PauseButton(state: state, onDark: false)
                    StopButton(wide: true)
                }
            }
        }
        .padding(14)
    }
}

/// Mark: an outlined pill with the Mark symbol (exported from BrandArt's iconMark). Runs in Verbose's process.
private struct MarkButton: View {
    var onDark: Bool
    var source: String
    var body: some View {
        Button(intent: MarkMomentIntent(source: source)) {
            HStack(spacing: 7) {
                Image("mark").font(.system(size: 15, weight: .medium))
                Text("Mark").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(onDark ? Ink.onBlack : Ink.inkFixed)
            .padding(.horizontal, 15).frame(height: onDark ? 38 : 40)
            .overlay(Capsule().strokeBorder(onDark ? Ink.onBlackHair : Ink.inkFixed, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark a moment")
        .accessibilityHint("Saves this point in the recording as a moment")
    }
}

/// Pause or Resume: an outlined circle.
private struct PauseButton: View {
    var state: VerbatimRecordingAttributes.ContentState
    var onDark: Bool
    var body: some View {
        Button(intent: ToggleRecordingPauseIntent()) {
            Image(systemName: state.isPaused ? "play.fill" : "pause.fill").font(.system(size: 13, weight: .semibold))   // brand: system surface
                .foregroundStyle(onDark ? Ink.onBlack : Ink.inkFixed)
                .frame(width: onDark ? 38 : 40, height: onDark ? 38 : 40)
                .overlay(Circle().strokeBorder(onDark ? Ink.onBlackHair : Ink.inkFixed, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPaused ? "Resume" : "Pause")
    }
}

/// Stop: the one persimmon fill, with an ink square and "Stop" in ink.
private struct StopButton: View {
    var wide: Bool
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Ink.inkFixed).frame(width: 10, height: 10)
                Text("Stop").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.inkFixed).lineLimit(1)
            }
            .padding(.horizontal, wide ? 0 : 18)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: wide ? 40 : 38)
            .background(Ink.persimmonFixed, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
        .accessibilityHint("Saves the recording and transcribes it")
    }
}

/// The compact Island for two seconds after a mark: the Marked symbol in butter, "Marked", and the time.
private struct MarkedCompact: View {
    var clock: String
    var body: some View {
        HStack(spacing: 5) {
            Image("marked").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.butterFixed)
            Text("Marked").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.onBlack)
            Text(clock).font(Ink.mono(13, weight: .medium)).foregroundStyle(Ink.onBlack)
        }
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Marked \(clock)")
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
        // Whole words only: the longest end that fits in two lines, never cut mid-word (review P-23).
        TailWords(text: line, lines: 2, lineHeight: IslandWordsMetrics.lineHeight) { tail in
            let parts = Ribbon.splitWords(tail)
            Text("\(Text(parts.older).foregroundStyle(Color.white.opacity(0.5)))\(Text(parts.newest).foregroundStyle(Color.white))")
                .font(Ink.serif(16))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
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
