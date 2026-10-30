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
/// on), "Into Thoughts · Mon, Oct 26", and Stop (with Resume while an interruption has it paused); saved, "Added to
/// Thoughts" and the time for two seconds. Its Lock Screen has the time, your voice, and Stop (and Resume while
/// paused), and never shows your words.
///
/// The Lock Screen is paper in light and the dark paper in dark (`ActivitySkin`). Every button is a capsule, and the
/// timers' frames hold "0:00:00", so a recording past an hour never clips (`Ribbon.timerWidth`).
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VerbatimRecordingAttributes.self) { context in
            ActivityLockSurface { skin in
                if context.attributes.isThought {
                    ThoughtLockScreen(page: context.attributes.page, state: context.state, skin: skin)
                } else {
                    RecordingLockScreen(title: context.attributes.title, state: context.state, skin: skin)
                }
            }
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
                                ThoughtVoiceBars(level: s.level ?? 0, color: Refined.persimmon, count: 5).frame(width: 22, height: 18)
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
                                ThoughtVoiceBars(level: s.level ?? 0.5, color: Refined.persimmon, count: 5).frame(width: 22, height: 18)
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
                            .font(Refined.mono(14, weight: .medium)).foregroundStyle(.white)
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
                                    if s.isPaused { PauseButton(state: s, tone: .island) }
                                    StopButton(wide: false, hint: thoughtStopHint)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.title).font(Refined.serif(18)).foregroundStyle(Refined.onBlack).lineLimit(1)
                            Text(islandLine(s)).font(.system(size: 13)).foregroundStyle(Refined.onBlackDim).lineLimit(2)
                            if !s.saved {
                                HStack(spacing: 8) {
                                    MarkButton(tone: .island, source: "island")
                                    PauseButton(state: s, tone: .island)
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
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Refined.persimmon)
                            .accessibilityLabel(ThoughtRules.savedTitle)
                    } else {
                        ThoughtVoiceBars(level: s.level ?? 0, color: Refined.persimmon, count: 5).frame(width: 22, height: 16)
                    }
                } else {
                    RecordingDot(state: s).frame(width: 10, height: 10)
                }
            } compactTrailing: {
                if s.markedClock != nil {
                    Text(s.marksLabel).font(Refined.mono(12, weight: .medium)).foregroundStyle(Refined.onBlackDim)
                        .lineLimit(1).fixedSize()
                } else if thought, s.saved, let at = s.savedAt {
                    Text(at, format: .dateTime.hour().minute()).font(Refined.mono(12, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).frame(width: 52, alignment: .trailing)
                } else {
                    let size: CGFloat = thought ? 12 : 13
                    RecordingTimer(state: s)
                        .font(Refined.mono(size, weight: .medium))
                        .foregroundStyle(thought ? Color.white : (s.isPaused ? Color.white.opacity(0.7) : Refined.persimmon))
                        .multilineTextAlignment(.trailing)
                        .frame(width: RecordingTimer.width(size), alignment: .trailing)
                }
            } minimal: {
                if s.markedClock != nil {
                    Image("marked").font(.system(size: 13, weight: .medium)).foregroundStyle(Refined.butterFixed)
                        .accessibilityLabel("Marked")
                } else if thought {
                    Image("thought").font(.system(size: 13, weight: .medium)).foregroundStyle(Refined.persimmon)
                        .accessibilityLabel(s.saved ? ThoughtRules.savedTitle : ThoughtRules.activityTitle)
                } else {
                    RecordingDot(state: s).frame(width: 10, height: 10)
                }
            }
            .keylineTint(Refined.persimmon)
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

/// A voice note on the Lock Screen (mockup "Library features", section 3a), on paper or the dark paper: the bars mark,
/// "Recording · Voice note" and the time, your voice, the last mark and the count ("Marked 4:12 · 3 moments so far"),
/// and Mark, Pause, and Stop. Saved: a check and "Saved. Transcribing on this iPhone."
private struct RecordingLockScreen: View {
    var title: String
    var state: VerbatimRecordingAttributes.ContentState
    var skin: ActivitySkin
    private var ink: Color { skin.ink }

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
                    BarsMark(color: Refined.persimmonFixed).frame(width: 18, height: 18)
                    Text(state.isPaused ? (state.pausedReason ?? "Paused") : "Recording · \(title)")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Spacer(minLength: 8)
                    RecordingTimer(state: state).font(Refined.mono(15, weight: .medium)).foregroundStyle(ink)
                        .frame(width: RecordingTimer.width(15), alignment: .trailing)
                }
                ThoughtVoiceBars(level: state.level ?? 0.5, color: Refined.persimmonFixed, count: 34).frame(height: 22)
                if state.markCount > 0, let at = state.markedAt {
                    HStack(spacing: 6) {
                        Image("marked").font(.system(size: 13, weight: .medium)).accessibilityHidden(true)
                        Text("Marked").font(.system(size: 13, weight: .semibold))
                        Text(VerbatimRecordingAttributes.clock(at)).font(Refined.mono(13, weight: .medium))
                        Text("· \(state.marksLabel) so far").font(.system(size: 13)).foregroundStyle(skin.dim)
                    }
                    .foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Saved as you go").font(.system(size: 13)).foregroundStyle(skin.dim).lineLimit(1)
                }
                HStack(spacing: 8) {
                    MarkButton(tone: .lock(skin), source: "lockScreen")
                    PauseButton(state: state, tone: .lock(skin))
                    StopButton(wide: true)
                }
            }
        }
        .padding(14)
    }
}

/// Mark: an outlined pill with the Mark symbol (exported from BrandArt's iconMark). Runs in Verbose's process.
private struct MarkButton: View {
    var tone: ActivityButtonTone
    var source: String
    var body: some View {
        Button(intent: MarkMomentIntent(source: source)) {
            HStack(spacing: 7) {
                Image("mark").font(.system(size: 15, weight: .medium))
                Text("Mark").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 15).frame(height: tone.height)
            .overlay(Capsule().strokeBorder(tone.outline, lineWidth: 1.5))
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
    var tone: ActivityButtonTone
    var body: some View {
        Button(intent: ToggleRecordingPauseIntent()) {
            Image(systemName: state.isPaused ? "play.fill" : "pause.fill").font(.system(size: 13, weight: .semibold))   // brand: system surface
                .foregroundStyle(tone.foreground)
                .frame(width: tone.height, height: tone.height)
                .overlay(Circle().strokeBorder(tone.outline, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPaused ? "Resume" : "Pause")
    }
}

/// Stop: the one persimmon fill, with an ink square and "Stop" in ink, in a capsule (a voice note's and a thought's).
private struct StopButton: View {
    var wide: Bool
    var hint = "Saves the recording and transcribes it"
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Refined.inkFixed).frame(width: 10, height: 10)
                Text("Stop").font(.system(size: 15, weight: .bold)).foregroundStyle(Refined.inkFixed).lineLimit(1)
            }
            .padding(.horizontal, wide ? 0 : 18)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: wide ? 40 : 38)
            .background(Refined.persimmonFixed, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
        .accessibilityHint(hint)
    }
}

/// A thought's Stop adds it to today's page.
private let thoughtStopHint = "Adds the thought to today's page"

/// The compact Island for two seconds after a mark: the Marked symbol in butter, "Marked", and the time.
private struct MarkedCompact: View {
    var clock: String
    var body: some View {
        HStack(spacing: 5) {
            Image("marked").font(.system(size: 13, weight: .medium)).foregroundStyle(Refined.butterFixed)
            Text("Marked").font(.system(size: 13, weight: .semibold)).foregroundStyle(Refined.onBlack)
            Text(clock).font(Refined.mono(13, weight: .medium)).foregroundStyle(Refined.onBlack)
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
            Image(systemName: "checkmark").resizable().scaledToFit().foregroundStyle(Refined.persimmon).accessibilityLabel("Saved")
        } else if state.isPaused {
            Image(systemName: "pause.fill").resizable().scaledToFit().foregroundStyle(.white.opacity(0.8)).accessibilityLabel("Paused")   // brand: system surface
        } else {
            Circle().fill(Refined.persimmon).accessibilityLabel("Recording")
        }
    }
}

/// Counts up on its own while recording; holds still at the recorded length while paused. Hours show past an hour
/// ("1:02:03"), so every frame around it is `width(_:)` wide for its font size.
private struct RecordingTimer: View {
    var state: VerbatimRecordingAttributes.ContentState
    static func width(_ size: CGFloat) -> CGFloat { CGFloat(Ribbon.timerWidth(size: Double(size), showsHours: true)) }
    var body: some View {
        Text(timerInterval: state.startDate...state.startDate.addingTimeInterval(60 * 60 * 24), pauseTime: state.pauseTime, countsDown: false, showsHours: true)
            .monospacedDigit()
            .lineLimit(1)
    }
}

// MARK: - A thought

/// A thought on the Lock Screen, on paper or the dark paper: the bars mark, "Recording a thought" (or why it paused),
/// the time, your voice, where it goes, and Stop, with Resume beside it while paused. Never reads `state.words`:
/// anyone can read a Lock Screen. Saved: a check and "Added to Thoughts · 9:41".
private struct ThoughtLockScreen: View {
    var page: String?
    var state: VerbatimRecordingAttributes.ContentState
    var skin: ActivitySkin
    private var ink: Color { skin.ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.saved {
                ThoughtSavedLine(state: state, skin: skin)
            } else {
                HStack(spacing: 8) {
                    BarsMark(color: Refined.persimmonFixed).frame(width: 18, height: 18)
                    Text(state.isPaused ? (state.pausedReason ?? "Paused") : ThoughtRules.lockTitle)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Spacer(minLength: 8)
                    RecordingTimer(state: state).font(Refined.mono(15, weight: .medium)).foregroundStyle(ink)
                        .frame(width: RecordingTimer.width(15), alignment: .trailing)
                }
                ThoughtVoiceBars(level: state.level ?? 0, color: Refined.persimmonFixed, count: 34).frame(height: 22)
                Text(ThoughtRules.intoLine(page ?? "Thoughts")).font(.system(size: 13)).foregroundStyle(skin.dim)
                    .lineLimit(1).minimumScaleFactor(0.85)
                HStack(spacing: 8) {
                    // An interruption (a call, another app's audio) paused it: Resume, as the voice note offers.
                    if state.isPaused { PauseButton(state: state, tone: .lock(skin)) }
                    StopButton(wide: true, hint: thoughtStopHint)
                }
            }
        }
        .padding(14)
    }
}

/// "Added to Thoughts" and the time it was saved, with a check: in the Island (no skin) or on the Lock Screen.
private struct ThoughtSavedLine: View {
    var state: VerbatimRecordingAttributes.ContentState
    var skin: ActivitySkin? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(skin?.ink ?? Refined.persimmon)
                .accessibilityHidden(true)
            Text(ThoughtRules.savedTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(skin?.ink ?? .white)
                .lineLimit(1).fixedSize()
            if let at = state.savedAt {
                Text(at, format: .dateTime.hour().minute()).font(Refined.mono(14, weight: .medium))
                    .foregroundStyle(skin?.mute ?? Color.white.opacity(0.7)).lineLimit(1)
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
                .font(Refined.serif(16))
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
