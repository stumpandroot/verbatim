import SwiftUI
import AppKit

// brand: native file
//
// Premium Native's Home sections that Edit Home added on the Mac (mockup "premium", section 03): This week and Stats as
// Compact strips, a slim recent row, Record (hidden by default: the floating record button stays either way), Last
// dictation, Projects, Moments, and Queue. White cards with a soft shadow and the persimmon accent, SF Pro throughout.
// Buttons own their whole face (macOS 26 click safety: no button sits inside another's gesture).

// MARK: - This week and Stats, Compact

/// A slim persimmon strip: the week's words and the seven days as small white bars, today solid.
struct NativeWeekStrip: View {
    var week: HomeWeek

    var body: some View {
        let shown = WeekBars.bars(words: week.days.map(\.words), future: week.days.map(\.isFuture), maxHeight: 30)
        HStack(spacing: 14) {
            Text(week.words.formatted()).font(PremiumType.number(32)).lineLimit(1).minimumScaleFactor(0.6)
            Text(week.words == 1 ? "word this week" : "words this week").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(week.days.enumerated()), id: \.offset) { i, day in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(day.isToday ? 1 : (shown[i].stub ? 0.18 : 0.36)))
                        .frame(width: 9, height: shown[i].height)
                }
            }
            .frame(height: 30, alignment: .bottom)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .leading)
        .gradientCard(.persimmon, radius: 20)
    }
}

/// Stats, Compact: recordings and time saved typing on one white strip.
struct NativeStatsStrip: View {
    var recordings: Int
    var saved: String

    var body: some View {
        HStack(spacing: 28) {
            stat(recordings.formatted(), recordings == 1 ? "recording this week" : "recordings this week")
            stat(saved, "saved typing")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .leading)
        .premiumCard(radius: 18)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(PremiumType.number(22)).foregroundStyle(.primary)
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

/// Recent recordings, Compact: the title, the date, and the length on one row; a click opens it.
struct NativeRecentLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var divider: Bool

    var body: some View {
        let t = transcript
        Button { app.go(.transcript(t.id)) } label: {
            HStack(spacing: 12) {
                NativeKindIcon(transcript: t, size: 26)
                Text(t.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                Text(PremiumDateLine.line(t.createdAt)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                LiveStage(t) { t in
                    Text(t.status == .ready ? HomeRecentStyle.length(t.duration) : t.stageText)
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .overlay(alignment: .bottom) {
                if divider { Rectangle().fill(PremiumInk.separator).frame(height: 0.5).padding(.leading, 48) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NativeCardButtonStyle(radius: 10))
        .contextMenu { RowMenu(transcript: t) }
        .accessibilityHint("Opens the transcript.")
    }
}

// MARK: - Record

/// The Record section: "Record" with the microphone's status and the persimmon disc; a click starts a voice note.
/// Compact is one slim row. Hidden by default in Native, where the floating record button is always on screen.
struct NativeHomeRecord: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var status: String
    var recording: Bool

    var body: some View {
        let compact = size == .compact
        Button { app.requestRecord() } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording ? "Recording" : "Record").font(.system(size: compact ? 16 : 22, weight: .bold)).foregroundStyle(.primary)
                    Text(status).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if !compact {
                        Text("Option Shift R from anywhere").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                Circle().fill(RadialGradient(colors: PremiumInk.discColors, center: UnitPoint(x: 0.34, y: 0.28), startRadius: 0, endRadius: compact ? 22 : 34))
                    .frame(width: compact ? 34 : 52, height: compact ? 34 : 52)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18).padding(.vertical, compact ? 10 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard(radius: 22)
        }
        .buttonStyle(PremiumCardPress(radius: 22))
        .disabled(recording)
        .accessibilityLabel(recording ? "Recording" : "Record")
        .accessibilityValue(status)
        .accessibilityHint("Starts a voice note. Shortcut: Option Shift R.")
    }
}

// MARK: - Last dictation

/// The newest dictation with a Copy button. Compact: one row with where it went and its length. Large: the words too.
/// A click anywhere copies; the button reads "Copied" for a moment.
struct NativeHomeLastDictation: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var sites = SiteLog.shared
    var size: HomeCardSize
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        let last = app.store.transcripts.lazy.filter { $0.deletedAt == nil && $0.source == .dictation }.max { $0.createdAt < $1.createdAt }
        VStack(alignment: .leading, spacing: 8) {
            if size == .large {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last dictation").font(.system(size: 20, weight: .bold)).tracking(-0.3).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button("All") { app.go(.dictations) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(PremiumInk.accentText)
                        .accessibilityLabel("All dictations")
                }
            }
            Button { if let last { copy(last) } else { app.go(.dictations) } } label: { face(last) }
                .buttonStyle(PremiumCardPress(radius: 18))
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
        HStack(alignment: size == .large ? .top : .center, spacing: 12) {
            AppIconView(bundleID: last?.flow?.bundleID).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                if size == .compact {
                    Text("Last dictation").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(last.map(head) ?? "Dictate in any app; what you say shows up here.").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                } else if let last {
                    Text(head(last)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Text(HomeDictationText.body(last)).font(.system(size: 14.5)).foregroundStyle(last.status == .failed ? NativeInk.danger : .primary)
                        .lineSpacing(3).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Dictate in any app, and what you say shows up here.").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if last != nil {
                Text(copied ? "Copied" : "Copy").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(PremiumInk.accentText)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(PremiumInk.accentSoft))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, size == .large ? 14 : 10)
        .frame(maxWidth: .infinity, minHeight: size == .large ? 96 : 60, alignment: .leading)
        .premiumCard(radius: 18)
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

/// Projects: Compact is a row of capsules with each project's count; Large lists the first six on a card.
struct NativeHomeProjects: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var counts: [UUID: Int]

    var body: some View {
        let projects = app.store.projects
        VStack(alignment: .leading, spacing: 8) {
            if size == .large { NativeHomeHeading(title: "Projects", link: "Library") { app.projectFilter = nil; app.go(.library) } }
            if projects.isEmpty {
                Text("Projects group recordings. Make one from the sidebar or a recording's menu.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .premiumCard()
            } else if size == .compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(projects) { p in
                            Button { open(p) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(PremiumInk.accentText)
                                    Text(p.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                                    Text((counts[p.id] ?? 0).formatted()).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Capsule().fill(PremiumInk.card).shadow(color: PremiumInk.shadow, radius: 5, y: 2))
                            }
                            .buttonStyle(PremiumCardPress(radius: 18))
                            .accessibilityHint("Opens the project in your library.")
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(projects.prefix(6).enumerated()), id: \.element.id) { i, p in
                        Button { open(p) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(PremiumInk.accentText).frame(width: 22)
                                Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).frame(height: 44)
                            .overlay(alignment: .bottom) {
                                if i < min(projects.count, 6) - 1 { Rectangle().fill(PremiumInk.separator).frame(height: 0.5).padding(.leading, 44) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(NativeCardButtonStyle(radius: 10))
                        .accessibilityHint("Opens the project in your library.")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .premiumCard()
            }
        }
    }

    private func open(_ p: Project) { app.projectFilter = p.id; app.go(.library) }
}

/// Moments: the newest saved moment. Large: an ink green gradient card with the quote. Compact: one white row.
struct NativeHomeMoments: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var latest: (t: Transcript, n: Note)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if size == .large { NativeHomeHeading(title: "Saved moments", link: "All") { app.go(.moments) } }
            Button { if let latest { HomeMomentPick.open(app, latest.t, latest.n) } else { app.go(.moments) } } label: {
                if size == .large { card } else { row }
            }
            .buttonStyle(PremiumCardPress(radius: size == .large ? 22 : 18))
            .accessibilityLabel(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "No moments yet")
            .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: latest?.n.isBookmark == false ? "note.text" : "bookmark.fill").font(.system(size: 12, weight: .semibold))
                Text(latest.map { "\($0.t.title) · \(($0.n.at ?? 0).timecode)" } ?? "Moments").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            .opacity(0.9)
            Text(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "Bookmark a moment while a transcript plays, and the newest shows here.")
                .font(.system(size: 17, weight: .bold)).lineSpacing(2).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gradientCard(.ink, radius: 22)
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark").font(.system(size: 14)).foregroundStyle(PremiumInk.accentText).frame(width: 22)
            Text(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "Bookmark a moment while a transcript plays.")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 8)
            if let latest {
                Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
        .premiumCard()
    }
}

/// Queue: what's transcribing. Compact: the first, with how many wait behind it. Large: up to three on a card.
struct NativeHomeQueue: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    var items: [Transcript]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if size == .large { NativeHomeHeading(title: "Queue", link: "Open Queue") { app.go(.queue) } }
                Button { app.go(.queue) } label: {
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(size == .large ? 3 : 1).enumerated()), id: \.element.id) { i, t in
                            HStack(spacing: 12) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                                    LiveStage(t) { t in
                                        Text(size == .compact && items.count > 1 ? "\(t.stageText) · \((items.count - 1).formatted()) more" : t.stageText)
                                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).frame(height: 56)
                            .overlay(alignment: .bottom) {
                                if size == .large && i < min(items.count, 3) - 1 { Rectangle().fill(PremiumInk.separator).frame(height: 0.5).padding(.leading, 48) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .premiumCard()
                }
                .buttonStyle(PremiumCardPress(radius: 18))
                .accessibilityHint("Opens the Queue.")
            }
        }
    }
}

/// A Native section heading on Home: bold title, an accent link on the right.
struct NativeHomeHeading: View {
    var title: String
    var link: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.3).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(link, action: action).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(PremiumInk.accentText)
        }
    }
}
