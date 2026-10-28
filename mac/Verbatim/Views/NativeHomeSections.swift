import SwiftUI
import AppKit

// brand: native file
//
// The Native look's Home sections on the Mac (mockup "Verbose Native Redesign", section 1): grouped sections of plain
// rows, system colors, SF Pro and SF Symbols. Symbols in rows take the accent; numbers are SF Pro with monospaced
// digits; the record dot is system red and flat. Each section's Large and Compact sizes (Edit Home) change how much it
// shows. Buttons own their whole face (macOS 26 click safety: no button sits inside another's gesture).

// MARK: - Rows

/// A quick action (one of Home's four tiles) as a row: the accent symbol, the name, and on Large its detail on the
/// right. The shortcut (Dictate's key) goes in the help.
struct NativeActionRow: View {
    var title: String
    var detail: String
    var badge: String?
    var symbol: String
    var hint: String
    var highlighted = false
    var large = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(NativeInk.accent)
                    .frame(width: 20)
                Text(title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                if large {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(highlighted ? NativeInk.accentSoft : Color.clear)
        }
        .buttonStyle(NativeRowButtonStyle())
        .help(badge.map { "\(title) · \($0)" } ?? detail)
        .accessibilityLabel(title)
        .accessibilityValue([detail, badge.map(Keycap.spoken)].compactMap { $0 }.joined(separator: " "))
        .accessibilityHint(hint)
    }
}

/// Recent recordings, Compact: the kind's symbol, the title, the time, and the length on one row; a click opens it.
struct NativeRecentLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var divider: Bool

    var body: some View {
        let t = transcript
        Button { app.go(.transcript(t.id)) } label: {
            HStack(spacing: 10) {
                NativeKindIcon(transcript: t, size: 20)
                Text(t.title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                Text(NativeDateCell.text(t.createdAt)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                LiveStage(t) { t in
                    Text(t.status == .ready ? (WebStatus.isTextOnly(t) ? "" : HomeRecentStyle.length(t.duration)) : t.stageText)
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .overlay(alignment: .bottom) { if divider { NativeRowSeparator(leading: 42) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(NativeRowButtonStyle())
        .contextMenu { RowMenu(transcript: t) }
        .accessibilityHint("Opens the transcript.")
    }
}

// MARK: - Record

/// The Record section (hidden by default: Record is always in the toolbar): "Record" with the microphone's status and
/// the red record dot, flat; a click starts a voice note, and right-click has the other kinds.
struct NativeHomeRecord: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var status: String
    var recording: Bool

    var body: some View {
        NativeSection {
            Button { app.requestRecord() } label: {
                HStack(spacing: 12) {
                    Circle().fill(NativeInk.record).frame(width: size == .compact ? 12 : 16, height: size == .compact ? 12 : 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(recording ? "Recording" : "Record").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary)
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if size == .large { Text("⌥⇧R from anywhere").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 14).frame(minHeight: size == .compact ? 40 : 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(NativeRowButtonStyle())
            .disabled(recording)
        }
        // Right-click: the other kinds and the microphone (CaptureBar.swift).
        .contextMenu { RecordMenu(onChange: {}) }
        .accessibilityLabel(recording ? "Recording" : "Record")
        .accessibilityValue(status)
        .accessibilityHint("Starts a voice note. Shortcut: Option Shift R.")
    }
}

// MARK: - Today's thoughts and Journal

/// Today's thoughts. Large: the latest four, each with its time, and New Thought under them. Compact: one row with the
/// count and the latest, New Thought beside it. A click opens today's page; New Thought records in place (⌃⌥P).
struct NativeHomeThoughts: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var page: [Transcript]
    @ObservedObject private var capture = ThoughtCapture.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeSection(title: "Today's thoughts", link: "Today's Page", linkHint: "Opens today's Thoughts page.", action: { HomeDayPages.openToday(app) }) {
                if size == .large {
                    Button { HomeDayPages.openToday(app) } label: { list }
                        .buttonStyle(NativeRowButtonStyle())
                        .accessibilityHint("Opens today's Thoughts page.")
                } else {
                    HStack(spacing: 8) {
                        Button { HomeDayPages.openToday(app) } label: { row }
                            .buttonStyle(NativeRowButtonStyle())
                            .accessibilityHint("Opens today's Thoughts page.")
                        newThought.padding(.trailing, 10)
                    }
                }
            }
            if size == .large { newThought.padding(.horizontal, 10) }
        }
        .uiTarget("home-thoughts")
    }

    private func words(_ t: Transcript) -> String {
        switch t.status {
        case .processing: return "Saved as audio. Transcribing…"
        case .failed: return "Couldn't transcribe it. The audio is kept."
        case .ready: let w = Thoughts.words(t); return w.isEmpty ? "Nothing heard" : w
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if page.isEmpty {
                Text("No thoughts yet today. \(Thoughts.hotkey) starts one from any app.").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 12)
            }
            let shown = HomeThoughts.latest(page)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Thoughts.time(t.createdAt, native: true)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    Text(words(t)).font(.system(size: 13.5)).foregroundStyle(t.status == .ready ? Color.primary : Color.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .overlay(alignment: .bottom) { if i < shown.count - 1 { NativeRowSeparator(leading: 86) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb").font(.system(size: 14)).foregroundStyle(NativeInk.accent).frame(width: 20)
            Text(HomeThoughts.countLine(page.count)).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1).fixedSize()
            if let last = page.last { Text(words(last)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var newThought: some View {
        Button { capture.toggle() } label: {
            Label { Text(capture.isRecording ? "Stop" : "New Thought") } icon: { Image(systemName: capture.isRecording ? "stop.fill" : "lightbulb") }
        }
        // Bordered, never a second accent fill beside Record (DESIGN.md §14.9).
        .buttonStyle(.bordered)
        .help("New thought (\(Thoughts.hotkey))")
        .uiTarget("home-thoughts-new")
    }
}

/// Journal: the newest entry (date, title, two lines) and this week's days as accent dots; a play button with the
/// length beside the row (Large). Compact: one row with the title and the dots. A click opens Journal By day.
struct NativeHomeJournal: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var latest: Transcript?
    var week: [HomeJournalWeek.Day]

    var body: some View {
        NativeSection(title: "Journal", link: "By Day", linkHint: "Opens Journal by day.", action: { HomeDayPages.openJournal(app) }) {
            // The play button sits beside the row's button, not inside it (macOS 26 click safety).
            HStack(alignment: .bottom, spacing: 8) {
                Button { HomeDayPages.openJournal(app) } label: { size == .large ? AnyView(card) : AnyView(row) }
                    .buttonStyle(NativeRowButtonStyle())
                    .accessibilityValue(HomeJournalWeek.countLine(week))
                    .accessibilityHint("Opens Journal by day.")
                if size == .large { play.padding(.trailing, 12).padding(.bottom, 10) }
            }
        }
        .uiTarget("home-journal")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = latest {
                Text(PremiumDateLine.line(t.createdAt)).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(t.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(PremiumPreview.text(t)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("Record with the Journal kind, and your newest entry shows here.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HomeWeekDots(week: week, size: 8, letters: true).padding(.top, 6)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: "book").font(.system(size: 14)).foregroundStyle(NativeInk.accent).frame(width: 20)
            Text("Journal").font(.system(size: 13.5)).foregroundStyle(.primary).fixedSize()
            Text(latest?.title ?? "No entries yet").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            HomeWeekDots(week: week, size: 7)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var play: some View {
        if let t = latest, t.audioFileName != nil, t.status == .ready {
            Button { NativeNav.shared.play(t, app: app) } label: {
                Label { Text(HomeRecentStyle.length(t.duration)).monospacedDigit() } icon: { Image(systemName: "play.fill") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
        }
    }
}
