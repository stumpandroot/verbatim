import SwiftUI
import AppKit

// brand: native file
//
// The Native look's kit on the Mac (DESIGN.md §13.2; approved mockup "Verbose Native Redesign", October 27, 2026,
// sections 8 to 11). Apple took brand color out of its own apps' chrome in macOS 27, and Native follows: system
// surfaces (the window background, grouped sections, system separators and fills), SF Pro and SF Symbols, the system
// accent color for everything you click, and system red only for recording. No glows, gradient cards, tinted icon
// circles, custom shadows, or SF Pro Rounded numbers. The file keeps its name from Premium Native, which it replaces.

// MARK: - Colors

extension PremiumInk {
    /// The window: the system's window background (`NativeRole.window`, paper under Native, resolves to it too).
    static let window = Color(nsColor: .windowBackgroundColor)
    /// Content: tables, text views, and grouped sections in light.
    static let card = Color(nsColor: .controlBackgroundColor)
    /// Tinted text (links, "Cleaned", moment times): the system accent color, never persimmon.
    static let accentText = Color.accentColor
    /// Fills for tracks, chips, and fields.
    static let fill = Color.primary.opacity(0.07)
    static let fillStrong = Color.primary.opacity(0.12)
    static let separator = Color(nsColor: .separatorColor)
}

// MARK: - Grouped sections

/// A grouped section as System Settings and the grouped `Form` draw one: an optional bold header with a link on the
/// right (Home's "See all"), then the rows on the section's background with inset separators. No shadow, no outline
/// color, no gradient.
struct NativeSection<Content: View>: View {
    var title: String? = nil
    var link: String? = nil
    var linkHint: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || link != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: 8)
                    if let link, let action {
                        Button(link, action: action)
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(NativeInk.accent)
                            .accessibilityHint(linkHint ?? "")
                    }
                }
                .padding(.horizontal, 10)
            }
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nativeGroup()
        }
    }
}

/// The hairline between two rows of a grouped section, inset past the row's symbol.
struct NativeRowSeparator: View {
    var leading: CGFloat = 12
    var body: some View {
        Rectangle().fill(NativeInk.separator).frame(height: 0.5).padding(.leading, leading)
    }
}

/// A row's press and hover: the system's faint wash, flat, with no tilt or lift.
struct NativeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : (hover ? 0.035 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

// MARK: - This week

/// This week as one stat cell, like Screen Time's: "This week", the words in SF Pro bold with monospaced digits, the
/// recordings and time saved, and the seven days as small bars with today the one mark in the accent. Compact drops
/// the bars' letters and sits on one line.
struct NativeWeekCell: View {
    var week: HomeWeek
    var recordings: Int
    var saved: String
    var large = true

    var body: some View {
        let words = HomeCounts.countLabel(week.words, "word", "words")
        let line = "\(HomeCounts.countLabel(recordings, "recording", "recordings")) · \(saved) saved"
        Group {
            if large {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This week").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(words).font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(.primary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(line).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    bars(maxHeight: 44, letters: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                HStack(spacing: 12) {
                    Text("This week").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(words).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.primary)
                    Text(line).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    bars(maxHeight: 18, letters: false)
                }
                .padding(.horizontal, 14).frame(minHeight: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func bars(maxHeight: Double, letters: Bool) -> some View {
        let shown = WeekBars.bars(words: week.days.map(\.words), future: week.days.map(\.isFuture), maxHeight: maxHeight, minHeight: 4, stubHeight: 3)
        return HStack(alignment: .bottom, spacing: letters ? 7 : 4) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { i, day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(day.isToday ? AnyShapeStyle(NativeInk.accent) : AnyShapeStyle(Color.primary.opacity(shown[i].stub ? 0.1 : 0.22)))
                        .frame(width: letters ? 10 : 6, height: shown[i].height)
                    if letters {
                        Text(Formats.pattern("EEEEE").string(from: day.start)).font(.system(size: 10))
                            .foregroundStyle(day.isToday ? AnyShapeStyle(NativeInk.accent) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
        .frame(height: maxHeight + (letters ? 16 : 0), alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Summary

/// A transcript's summary as plain text, the way the inspector lists everything else: the overview, the key points,
/// and "Made by Apple Intelligence" in secondary. `onEdit` and `onRegenerate` add a ⋯ menu beside the heading.
struct NativeSummaryText: View {
    var summary: TranscriptSummary
    var byModel: Bool
    var compact = false
    var heading = true
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if heading {
                HStack(spacing: 6) {
                    Text("Summary").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if onEdit != nil || onRegenerate != nil {
                        Menu {
                            if let onEdit { Button("Edit Summary", action: onEdit) }
                            if let onRegenerate { Button("Regenerate", action: onRegenerate) }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(width: 22, height: 18).contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Summary options")
                    }
                }
            }
            if !summary.overview.isEmpty {
                Text(summary.overview).font(.system(size: compact ? 13 : 13.5)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, heading ? 6 : 0)
            }
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.keyPoints.prefix(compact ? 3 : 6).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(p).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Key points")
            }
            if byModel {
                Text(AIGeneratedNote.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recording

/// Home while you record or capture an app's audio: one grouped section with the red record dot (the one place
/// Verbose draws red), "Recording" and the time in tabular digits, the level in label color, your words as they're
/// heard, and Mark, Pause, and Stop. Stop carries the red stop square; the buttons are the system's.
struct NativeRecordingSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var marks = MarkCenter.shared

    var body: some View {
        let capturing = app.capture.isCapturing && !app.recorder.isRecording
        let starting = app.recorder.isStarting
        NativeSection(title: capturing ? "Capturing" : "Recording") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Circle().fill(NativeInk.record).frame(width: 10, height: 10)
                        .opacity(app.recorder.isPaused ? 0.4 : 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(capturing: capturing, starting: starting)).font(.system(size: 13.5, weight: .semibold))
                        if let id = app.continuing, let t = app.store.transcript(id) {
                            Text("Adding to “\(t.title)”").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let c = marks.confirmation, !starting {
                            Label { Text("Marked \(Marks.clock(c.at)) · \(Marks.count(c.count))").monospacedDigit() } icon: {
                                Image(systemName: "bookmark.fill").foregroundStyle(NativeInk.accent)
                            }
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityLabel(Marks.confirmation(c))
                            .uiTarget("record-panel-marked")
                        }
                        if let w = app.recorder.micWarning, !starting, !app.recorder.isPaused, !capturing {
                            Label("\(w.title). \(w.detail).", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 190, alignment: .leading)
                    LiveReadout(live: capturing ? app.capture.live : app.recorder.live, color: .labelColor, frozen: app.recorder.isPaused)
                    controls(capturing: capturing, starting: starting)
                }
                if !capturing {
                    RecordingWordsLine(words: app.recordingWords, insets: EdgeInsets(top: 0, leading: 22, bottom: 2, trailing: 4))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(starting ? "Starting the microphone" : app.recorder.isPaused ? "Recording paused" : capturing ? "Capturing \(app.capture.appName)" : "Recording")
        .uiTarget("native-recording")
    }

    private func title(capturing: Bool, starting: Bool) -> String {
        if capturing { return app.capture.appName }
        if starting { return "Starting…" }
        if app.recorder.isPaused { return "Paused" }
        // The kind you picked ("Meeting", "Journal entry"), or "Voice note" for a plain Record.
        return (app.recordKind.map { RecordChoice.kind($0) } ?? .voiceNote).name
    }

    @ViewBuilder private func controls(capturing: Bool, starting: Bool) -> some View {
        HStack(spacing: 8) {
            if !capturing {
                Button { marks.mark(.macApp) } label: { Label("Mark", systemImage: "bookmark") }
                    .disabled(starting)
                    .help("Mark this moment (\(MarkHotkeyStore.current().title) from any app while you record)")
                    .accessibilityLabel("Mark a moment")
                    .uiTarget("record-panel-mark")
                Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.disabled(starting)
            }
            Button {
                if capturing { app.stopCapture() } else { app.stopRecording() }
            } label: {
                Label { Text(starting ? "Cancel" : "Stop") } icon: {
                    Image(systemName: "stop.fill").foregroundStyle(NativeInk.record)
                }
            }
            .keyboardShortcut(".", modifiers: [.option, .shift])
            .accessibilityLabel(starting ? "Cancel" : "Stop")
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }
}
