import SwiftUI
import UIKit
import WidgetKit
import ActivityKit
import AppIntents

/// The VerbatimWidgets extension: the keyboard session's and the recording's Live Activities (a thought's too), the
/// Lock Screen session widget, the Home Screen widgets (Record and dictate, Recent recordings, This week, New thought,
/// Today's thoughts; HomeWidgets.swift), the Lock Screen's Thoughts widget, and (iOS 18) the Control Center controls:
/// the session switch, the Action button's control, Record voice note, Dictate, and New thought.
@main
struct VerbatimWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        RecordingLiveActivity()
        StartSessionWidget()
        RecordDictateWidget()
        RecentRecordingsWidget()
        WeekWidget()
        QuickCaptureWidget()
        TodayThoughtsWidget()
        ThoughtsLockWidget()
        if #available(iOS 18.0, *) {
            StartSessionControl()
            ActionButtonControl()
            RecordVoiceNoteControl()
            DictateControl()
            NewThoughtControl()
        }
    }
}

/// The recording ribbon (the approved "iPhone recording ribbon" mockup, reworked by the notch mockup's section 02).
/// Dynamic Island compact: persimmon voice bars leading and the take's time trailing while listening; the bars mark
/// and a spinner while writing; a check and the word count after (Copied or Inserted), then the bars mark and a
/// persimmon dot (the session's microphone is on). Minimal: three voice bars while listening. Expanded while
/// listening: the voice bars, Listening, and the time; the live words line (only with Show words in the Dynamic
/// Island on); "Into Messages"; and Cancel and Done. Otherwise the state, and End session and Dictate. Lock Screen:
/// the same states on paper (the dark paper in dark, `ActivitySkin`), with "Into Messages · take 3 of this session"
/// while listening and never any words. Buttons are capsules, and each one's accessibility label starts with the
/// word it shows, so Voice Control's "Tap Done" finds it.
/// While a take listens before the speech model is ready: "Getting ready" in place of Listening. During a call:
/// Paused for a call. After a session ends by itself: Session ended with Restart (`RestartSessionIntent`) for 15
/// minutes; tapping anywhere else opens Verbose's confirmation, as before.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VerbatimSessionAttributes.self) { context in
            ActivityLockSurface { skin in RibbonLockScreen(state: context.state, skin: skin) }
                .widgetURL(context.state.shown == .ended ? restartLink : nil)
        } dynamicIsland: { context in
            let s = context.state
            let listening = s.shown == .listening
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if listening {
                        HStack(spacing: 7) {
                            LevelBars(level: s.level, color: Refined.persimmon, count: 5).frame(width: 22, height: 18)
                            Text(s.warming ? Ribbon.gettingReadyTitle : "Listening").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .lineLimit(1).fixedSize()
                        }
                        .padding(.leading, 4)
                        .accessibilityElement(children: .combine)
                    } else {
                        PhaseGlyph(phase: s.shown, onDark: true).frame(width: 22, height: 22).padding(.leading, 4)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if listening, let start = s.takeStartedAt {
                        TakeTimer(start: start).font(Refined.mono(14, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 56, alignment: .trailing).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if !listening {
                        Text(Ribbon.headline(s.shown, words: s.words, gettingReady: s.warming))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if listening {
                        VStack(alignment: .leading, spacing: 10) {
                            if s.warming {
                                Text(Ribbon.gettingReadyDetail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                            } else if let line = s.liveWords, !line.isEmpty { IslandWords(line: line) }
                            HStack(spacing: 8) {
                                TargetLabel(target: s.target)
                                Spacer(minLength: 6)
                                RibbonButton(title: "Cancel", primary: false, onDark: true, compact: true, intent: CancelTakeIntent())
                                    .accessibilityLabel("Cancel dictation").accessibilityHint(Ribbon.cancelHint)
                                RibbonButton(title: "Done", primary: true, onDark: true, compact: true, intent: FinishTakeIntent())
                                    .accessibilityHint(Ribbon.doneHint)
                            }
                        }
                        .padding(.horizontal, 4)
                    } else {
                        VStack(spacing: 10) {
                            Text(Ribbon.detail(s.shown, takes: s.takes, message: s.message))
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            RibbonButtons(phase: s.shown, onDark: true)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                CompactLeading(state: s)
            } compactTrailing: {
                CompactTrailing(state: s)
            } minimal: {
                if listening {
                    LevelBars(level: s.level, color: Refined.persimmon, count: 3).frame(width: 13, height: 13)
                } else {
                    BarsMark(color: Refined.persimmon).frame(width: 16, height: 16)
                }
            }
            .keylineTint(Refined.persimmon)
            .widgetURL(s.shown == .ended ? restartLink : nil)
        }
    }
}

/// Opens Verbose and starts a new session (the Lock Screen widget's link).
private let restartLink = URL(string: "verbatim://session?start=1&from=widget")!

/// Compact leading: your voice while listening, a check after, otherwise the bars mark.
private struct CompactLeading: View {
    var state: VerbatimSessionAttributes.ContentState
    var body: some View {
        switch state.shown {
        case .listening:
            LevelBars(level: state.level, color: Refined.persimmon, count: 5).frame(width: 22, height: 16)
                .accessibilityLabel("Listening")
        case .copied, .inserted:
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Refined.persimmon)
                .accessibilityLabel(state.shown == .copied ? "Copied" : "Inserted")
        default:
            BarsMark(color: Refined.persimmon).frame(width: 16, height: 16)
        }
    }
}

/// Compact trailing: the take's time while listening, a spinner while writing, the word count after, and a
/// persimmon dot between takes (the session's microphone is on).
private struct CompactTrailing: View {
    var state: VerbatimSessionAttributes.ContentState
    var body: some View {
        switch state.shown {
        case .listening:
            if let start = state.takeStartedAt {
                TakeTimer(start: start).font(Refined.mono(12, weight: .medium)).foregroundStyle(.white).frame(width: 36, alignment: .trailing)
            }
        case .copied, .inserted:
            Text(Ribbon.wordsLabel(state.words)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
        case .failed:
            PhaseGlyph(phase: .failed, onDark: true).frame(width: 16, height: 16)
        case .transcribing:
            WritingSpinner().frame(width: 15, height: 15)
        case .paused:
            Text("Paused").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                .accessibilityLabel("Paused for a call")
        case .ended:
            Text("Restart").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.persimmon).lineLimit(1)
                .accessibilityLabel("Session ended. Restart")
        default:
            Circle().fill(Refined.persimmon).frame(width: 8, height: 8)
                .accessibilityLabel("Session on")
        }
    }
}

private struct RibbonLockScreen: View {
    var state: VerbatimSessionAttributes.ContentState
    var skin: ActivitySkin
    private var ink: Color { skin.ink }

    var body: some View {
        // Never reads `state.liveWords`: anyone can read a Lock Screen.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PhaseGlyph(phase: state.shown, onDark: skin.dark).frame(width: 18, height: 18)
                Text(Ribbon.headline(state.shown, words: state.words, gettingReady: state.warming))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            if state.shown == .listening {
                LevelBars(level: state.level, color: Refined.persimmonFixed, count: 34).frame(height: 22)
                Text(state.warming ? Ribbon.gettingReadyLine : Ribbon.lockLine(target: state.target, take: state.takes))
                    .font(.system(size: 13)).foregroundStyle(skin.dim).lineLimit(1).minimumScaleFactor(0.85)
            } else {
                Text(Ribbon.detail(state.shown, takes: state.takes, message: state.message))
                    .font(.system(size: 13)).foregroundStyle(skin.dim).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RibbonButtons(phase: state.shown, onDark: skin.dark)
        }
        .padding(14)
    }

    @ViewBuilder private var trailing: some View {
        if state.shown == .listening, let start = state.takeStartedAt {
            TakeTimer(start: start).font(Refined.mono(15, weight: .medium)).foregroundStyle(ink).frame(width: 60, alignment: .trailing)
        } else if state.shown == .ready, let started = state.sessionStartedAt {
            Text(started, style: .relative).font(.system(size: 13)).monospacedDigit().foregroundStyle(skin.mute)
                .multilineTextAlignment(.trailing).frame(maxWidth: 110, alignment: .trailing)
        }
    }
}

/// The expanded Island's words line: two lines at most, older words dimmed and the newest three bright. The app
/// sends it only with Show words in the Dynamic Island on.
private struct IslandWords: View {
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

/// One line of the expanded Island's serif 16 words (New York), for `TailWords`.
enum IslandWordsMetrics {
    static let lineHeight: CGFloat = {
        let base = UIFont.systemFont(ofSize: 16)
        return UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 16).lineHeight
    }()
}

/// "Into Messages", or "Into the Verbose keyboard" when the app isn't known (always in App Store builds).
private struct TargetLabel: View {
    var target: String?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)
            Text(Ribbon.intoLine(target)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// While Verbose writes the words: a still arc (a Live Activity doesn't animate between updates).
private struct WritingSpinner: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25)
                .stroke(Refined.persimmon, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Writing your words")
    }
}

/// The take's timer: counts up on its own from `start`, so the app doesn't update it.
private struct TakeTimer: View {
    var start: Date
    var body: some View {
        Text(timerInterval: start...start.addingTimeInterval(KeyboardBridge.maxSeconds + 60), countsDown: false, showsHours: false)
            .monospacedDigit().lineLimit(1)
    }
}

/// One glyph per phase: the bars mark when ready or listening, the writing glyph, a check after.
private struct PhaseGlyph: View {
    var phase: Ribbon.Phase
    var onDark: Bool
    var body: some View {
        switch phase {
        case .listening:
            BarsMark(color: onDark ? Refined.persimmon : Refined.persimmonFixed).accessibilityLabel("Listening")
        case .transcribing:
            BrandGlyph(art: .iconTranscribing, color: onDark ? .white : Refined.inkFixed).accessibilityLabel("Writing")
        case .copied, .inserted:
            Image(systemName: "checkmark").resizable().scaledToFit().padding(2).foregroundStyle(onDark ? Refined.persimmon : Refined.inkFixed)
                .accessibilityLabel(phase == .copied ? "Copied" : "Inserted")
        case .failed:
            BrandGlyph(art: .iconAttention, color: onDark ? Refined.accentTextOnInk : Refined.accentTextOnPaper).accessibilityLabel("Didn't finish")
        case .ready, .ended:
            BarsMark(color: Refined.persimmon)
        case .paused:
            BarsMark(color: onDark ? Color.white.opacity(0.6) : Refined.inkFixed.opacity(0.6)).accessibilityLabel("Paused")
        }
    }
}

/// The level, about once a second while listening: fixed bar shapes scaled by the real microphone level.
private struct LevelBars: View {
    var level: Double
    var color: Color
    var count = 9
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
        .accessibilityLabel("Microphone level")
    }
}

/// Phase-dependent buttons: Cancel and Done while listening; End session and Dictate otherwise; End session while
/// the words are being written or a call has it paused; Restart after the session ended by itself.
private struct RibbonButtons: View {
    var phase: Ribbon.Phase
    var onDark: Bool

    var body: some View {
        switch phase {
        case .listening:
            HStack(spacing: 8) {
                RibbonButton(title: "Cancel", primary: false, onDark: onDark, intent: CancelTakeIntent())
                    .accessibilityLabel("Cancel dictation").accessibilityHint(Ribbon.cancelHint)
                RibbonButton(title: "Done", primary: true, onDark: onDark, intent: FinishTakeIntent())
                    .accessibilityHint(Ribbon.doneHint)
            }
        case .transcribing:
            HStack(spacing: 8) {
                RibbonButton(title: "End session", primary: false, onDark: onDark, intent: EndVerbatimSessionIntent())
                    .accessibilityHint("Turns off the microphone")
            }
        case .ended:
            RibbonButton(title: "Restart", primary: true, onDark: onDark, intent: RestartSessionIntent())
                .accessibilityLabel("Restart session")
                .accessibilityHint("Turns the microphone back on")
        case .paused:
            HStack(spacing: 8) {
                RibbonButton(title: "End session", primary: false, onDark: onDark, intent: EndVerbatimSessionIntent())
                    .accessibilityHint("Turns off the microphone")
            }
        default:
            HStack(spacing: 8) {
                RibbonButton(title: "End session", primary: false, onDark: onDark, intent: EndVerbatimSessionIntent())
                    .accessibilityHint("Turns off the microphone")
                RibbonButton(title: "Dictate", primary: true, onDark: onDark, intent: DictateIntent())
                    .accessibilityHint("Starts listening for a take")
            }
        }
    }
}

/// A full-width capsule (or one sized to its word, `compact`), like the recording's Mark, Pause, and Stop (DESIGN.md
/// §5.3). Primary: persimmon with ink text (semibold 14, which passes on persimmon). Secondary: a quiet wash. Opaque
/// fills only; no text on blur. With no label of its own, VoiceOver and Voice Control use the title.
private struct RibbonButton<I: AppIntent>: View {
    var title: String
    var primary: Bool
    var onDark: Bool
    /// The expanded Island's listening row: sized to the word, beside "Into Messages".
    var compact = false
    var intent: I

    var body: some View {
        Button(intent: intent) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary || !onDark ? Refined.inkFixed : Color.white)
                .lineLimit(1)
                .frame(maxWidth: compact ? nil : .infinity)
                .frame(minWidth: compact ? 72 : nil)
                .padding(.horizontal, compact ? 12 : 0)
                .padding(.vertical, 8)
                .background(primary ? Refined.persimmonFixed : (onDark ? Color.white.opacity(0.12) : Refined.inkFixed.opacity(0.08)),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
