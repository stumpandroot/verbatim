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

/// A number in a row: the name on the left, the value (SF Pro, monospaced digits) and its period on the right.
struct NativeStatRow: View {
    var title: String
    var value: String
    var detail: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13.5))
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13.5, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 14).frame(minHeight: 34)
        .accessibilityElement(children: .combine)
    }
}

/// Stats, Compact: recordings and time saved typing on one line.
struct NativeStatsStrip: View {
    var recordings: Int
    var saved: String

    var body: some View {
        HStack(spacing: 24) {
            stat(recordings.formatted(), recordings == 1 ? "recording this week" : "recordings this week")
            stat(saved, "saved typing")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 13.5, weight: .semibold).monospacedDigit()).foregroundStyle(.primary)
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
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

// MARK: - Last dictation

/// The newest dictation with Copy. Compact: one row with where it went. Large: the words too. A click anywhere copies;
/// Copy reads "Copied" for a moment.
struct NativeHomeLastDictation: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var sites = SiteLog.shared
    var size: HomeCardSize
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        let last = app.store.lastDictation
        NativeSection(title: "Last dictation", link: "All", linkHint: "Opens your dictations.", action: { app.go(.dictations) }) {
            Button { if let last { copy(last) } else { app.go(.dictations) } } label: { face(last) }
                .buttonStyle(NativeRowButtonStyle())
                .accessibilityLabel(last.map { HomeDictationText.body($0) } ?? "No dictations yet")
                .accessibilityValue(copied ? "Copied" : last.map(head) ?? "")
                .accessibilityHint(last == nil ? "Opens your dictations." : "Copies the dictation.")
                .uiTarget(last == nil ? "home-dictations-empty" : "home-dictation-0")
        }
        .uiTarget("home-dictations")
    }

    private func head(_ t: Transcript) -> String {
        let words = HomeCounts.countLabel(HomeCounts.words(t), "word", "words")
        let d = t.createdAt
        let when = Calendar.current.isDateInToday(d) ? Formats.style(date: .none, time: .short).string(from: d) : HomeRecentStyle.day(d)
        if let place = sites.hosts[t.id] ?? t.flow?.app, !place.isEmpty { return "\(words) in \(place) · \(when)" }
        return "\(words) · \(when)"
    }

    @ViewBuilder private func face(_ last: Transcript?) -> some View {
        HStack(alignment: size == .large ? .top : .center, spacing: 10) {
            AppIconView(bundleID: last?.flow?.bundleID).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                if let last {
                    if size == .large {
                        Text(HomeDictationText.body(last)).font(.system(size: 13.5)).foregroundStyle(last.status == .failed ? NativeInk.danger : .primary)
                            .lineSpacing(2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(head(last)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Dictate in any app, and what you say shows up here.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if last != nil {
                Text(copied ? "Copied" : "Copy").font(.system(size: 13)).foregroundStyle(NativeInk.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, size == .large ? 10 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func copy(_ t: Transcript) {
        Paster.copy(HomeDictationText.pasted(t))
        copies += 1
        let token = copies
        copied = true
        HomeAnnounce.say("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copies == token { copied = false } }
    }
}

// MARK: - Projects, Moments, Queue

/// Projects: Compact lists the first three, Large the first six, each with how many recordings it has.
struct NativeHomeProjects: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var counts: [UUID: Int]

    var body: some View {
        let projects = Array(app.store.projects.prefix(size == .large ? 6 : 3))
        NativeSection(title: "Projects", link: "Library", linkHint: "Opens your library.", action: { app.projectFilter = nil; app.go(.library) }) {
            if projects.isEmpty {
                Text("Projects group recordings. Make one from the sidebar or a recording's menu.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                ForEach(Array(projects.enumerated()), id: \.element.id) { i, p in
                    Button { app.projectFilter = p.id; app.go(.library) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(NativeInk.accent).frame(width: 20)
                            Text(p.name).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text((counts[p.id] ?? 0).formatted()).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NativeRowButtonStyle())
                    .accessibilityValue(HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings"))
                    .accessibilityHint("Opens the project in your library.")
                    if i < projects.count - 1 { NativeRowSeparator(leading: 44) }
                }
            }
        }
    }
}

/// Moments: the newest saved moment, its quote (Large) or one line (Compact), with the recording and the time.
struct NativeHomeMoments: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var latest: (t: Transcript, n: Note)?

    var body: some View {
        NativeSection(title: "Saved moments", link: "All", linkHint: "Opens Moments.", action: { app.go(.moments) }) {
            Button { if let latest { HomeMomentPick.open(app, latest.t, latest.n) } else { app.go(.moments) } } label: {
                HStack(alignment: size == .large ? .top : .center, spacing: 12) {
                    Image(systemName: latest?.n.isBookmark == false ? "note.text" : "bookmark.fill").font(.system(size: 13))
                        .foregroundStyle(NativeInk.accent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "Bookmark a moment while a transcript plays, and the newest shows here.")
                            .font(.system(size: 13.5)).foregroundStyle(.primary)
                            .lineLimit(size == .large ? 4 : 1).fixedSize(horizontal: false, vertical: true)
                        if let latest {
                            Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(NativeRowButtonStyle())
            .accessibilityLabel(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "No moments yet")
            .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
        }
    }
}

/// Queue: what's transcribing. Compact: the first, with how many wait behind it. Large: up to three.
struct NativeHomeQueue: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var items: [Transcript]

    var body: some View {
        if !items.isEmpty {
            let shown = Array(items.prefix(size == .large ? 3 : 1))
            NativeSection(title: "Queue", link: "Open Queue", linkHint: "Opens the Queue.", action: { app.go(.queue) }) {
                Button { app.go(.queue) } label: {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                            HStack(spacing: 12) {
                                ProgressView().controlSize(.small).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1)
                                    LiveStage(t) { t in
                                        Text(size == .compact && items.count > 1 ? "\(t.stageText) · \((items.count - 1).formatted()) more" : t.stageText)
                                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .overlay(alignment: .bottom) { if i < shown.count - 1 { NativeRowSeparator(leading: 44) } }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NativeRowButtonStyle())
                .accessibilityHint("Opens the Queue.")
            }
        }
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
