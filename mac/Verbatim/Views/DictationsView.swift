import SwiftUI
import AppKit

// brand: web style
//
// Dictations in the website style (mac/DESIGN.md §11): a compact title with the count and the retention menu as a
// line pill, category chips, day headers, and flat rows that copy when clicked.

/// Every dictation, newest first, grouped by day: what you said, what was pasted, and where.
/// Copy any of them again, see the words before cleanup, redo the cleanup at another level, or open the
/// full transcript with its audio.
struct DictationsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var settings = FlowSettings.shared
    @State private var filter: AppCategory? = nil

    private var allDictations: [Transcript] {
        app.store.memo("dictations") { app.store.live.filter { $0.source == .dictation }.sorted { $0.createdAt > $1.createdAt } }
    }
    private func matching(_ all: [Transcript]) -> [Transcript] {
        let q = app.search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { t in
            if let f = filter, t.flow?.category != f { return false }
            guard !q.isEmpty else { return true }
            return (t.flow?.pasted ?? t.text).lowercased().contains(q) || (t.flow?.raw ?? "").lowercased().contains(q) || (t.flow?.app ?? "").lowercased().contains(q)
        }
    }
    /// "Today · Fri Oct 23", "Yesterday · Thu Oct 22", "Monday, Oct 19".
    private static func days(_ shown: [Transcript]) -> [(String, [Transcript])] {
        let cal = Calendar.current
        let f = Formats.pattern("EEEE, MMM d")
        let short = Formats.pattern("EEE MMM d")
        var out: [(String, [Transcript])] = []
        for t in shown {
            let label = cal.isDateInToday(t.createdAt) ? "Today · \(short.string(from: t.createdAt))"
                : cal.isDateInYesterday(t.createdAt) ? "Yesterday · \(short.string(from: t.createdAt))"
                : f.string(from: t.createdAt)
            if out.last?.0 == label { out[out.count - 1].1.append(t) } else { out.append((label, [t])) }
        }
        return out
    }

    private static let retention: [(Int, String)] = [(0, "Keep forever"), (30, "Keep 30 days"), (7, "Keep 7 days"), (1, "Keep 1 day")]
    private var retentionTitle: String { Self.retention.first { $0.0 == settings.keepDays }?.1 ?? "Keep \(settings.keepDays) days" }

    var body: some View {
        // Filtered and sorted once per render, not once per use.
        let all = allDictations
        let shown = matching(all)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Dictations", count: all.count == 1 ? "1 kept" : "\(all.count.formatted()) kept") {
                    retentionMenu
                }
                .staggerIn(0)
                DictationsLede(before: "Everything you dictated into other apps, with the audio. If a paste went missing, it's here.",
                               keys: "⌃⌘V", after: "pastes the last one again.")
                    .padding(.top, 12)
                FlowRow(spacing: 8, lineSpacing: 8) {
                    FilterChip(title: "All", selected: filter == nil) { filter = nil }
                    ForEach(AppCategory.allCases) { c in FilterChip(title: c.title, selected: filter == c) { filter = c } }
                }
                .padding(.top, 22).padding(.bottom, 6)
                .staggerIn(1)

                if shown.isEmpty {
                    emptyState(all.isEmpty).padding(.top, 20).staggerIn(1)
                } else {
                    // Lazy: only the dictations on screen are built (people keep hundreds).
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.days(shown), id: \.0) { day, items in
                            DayHeader(text: day).padding(.top, 14).padding(.bottom, 8)
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                                DictationRow(transcript: t).padding(.top, i == 0 ? 0 : 2)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }

    /// "Keep 30 days ⌄": the retention menu as a line pill.
    private var retentionMenu: some View {
        Menu {
            Picker("Keep", selection: $settings.keepDays) {
                ForEach(Self.retention, id: \.0) { item in Text(item.1).tag(item.0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            PillLabel(title: retentionTitle, kind: .line, size: .regular, trailing: .chevron)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("How long dictations are kept. Pinned ones stay.")
        .accessibilityLabel("Keep dictations")
        .accessibilityValue(retentionTitle)
        .onChange(of: settings.keepDays) { _, _ in app.dictation.purgeOldDictations() }
    }

    @ViewBuilder private func emptyState(_ none: Bool) -> some View {
        if none {
            EmptyStateCard(art: .iconDictations, title: "No dictations yet",
                           message: "Click \(DictationSurface.stored().clickHint), or press \(app.dictation.hotkey.shortTitle), and talk. The words land where your cursor is.")
        } else {
            EmptyStateCard(art: .search, title: "Nothing matches",
                           message: "No dictation in this category matches your search.", button: "Show all") {
                filter = nil
                app.search = ""
            }
        }
    }
}

/// The lede with the paste-last shortcut drawn as a key inside the sentence: the words wrap around the key.
private struct DictationsLede: View {
    var before: String
    var keys: String
    var after: String

    var body: some View {
        FlowRow(spacing: 4, lineSpacing: 1) {
            ForEach(Array(words(before).enumerated()), id: \.offset) { _, w in word(w) }
            Keycap(keys: keys, size: 12).foregroundStyle(Ink.dim).frame(height: 22).padding(.horizontal, 2)
            ForEach(Array(words(after).enumerated()), id: \.offset) { _, w in word(w) }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(before) \(Keycap.spoken(keys)) \(after)")
    }

    private func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
    private func word(_ w: String) -> some View {
        Text(w).font(.system(size: 14)).foregroundStyle(Ink.dim).frame(height: 22)
    }
}

/// One dictation as a flat row: the time and length in mono, the words, and a meta line (the app's icon, the app,
/// the cleanup level, "not pasted" in accent). Clicking the row copies what was pasted; the Copy pill turns into
/// "✓ Copied" for 1.6 s. The More menu redoes cleanup, runs an action, opens the transcript, pins, or deletes.
/// The row drags onto a project in the sidebar.
struct DictationRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var showRaw = false
    @State private var working = false
    @State private var running: FlowAction? = nil
    @State private var copied = false
    @State private var copies = 0
    @Environment(\.limitMotion) private var limitMotion

    /// The widest the controls get: the spinner, "✓ Copied", and the More button.
    private static let controlsWidth: CGFloat = 150

    private var info: FlowInfo? { transcript.flow }
    private var pasted: String { info?.pasted ?? transcript.text }
    private var raw: String { info?.raw ?? transcript.text }
    private var time: String { Formats.style(date: .none, time: .short).string(from: transcript.createdAt) }
    private var shownText: String { showRaw ? raw : pasted }
    private var canCopy: Bool { transcript.status != .failed && !shownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        FlatRowButton(dragPayload: { TranscriptDrag.payload([transcript.id]) }, action: { if canCopy { copyNow(shownText) } }) { lit in
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(time).font(Ink.mono(12, weight: .medium)).foregroundStyle(Ink.ink)
                    Text(WebFormat.clock(transcript.duration)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                }
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    if transcript.status == .failed {
                        Text(transcript.error ?? "Transcription failed").font(.system(size: 15)).foregroundStyle(Ink.danger)
                    } else if let instruction = info?.instruction {
                        Text("“\(instruction)”").font(Ink.serif(15).italic()).foregroundStyle(Ink.dim)
                        Text(lit ? pasted : HomeDictationText.oneLine(pasted)).font(.system(size: 15)).foregroundStyle(Ink.ink).lineSpacing(4).lineLimit(lit ? 12 : 3)
                    } else {
                        // At rest the words run on one line of text (a greeting's blank line doesn't take a row);
                        // under the pointer the row opens with the line breaks as pasted.
                        let words = showRaw ? raw : (pasted.isEmpty ? "(only filler words)" : pasted)
                        Text(lit ? words : HomeDictationText.oneLine(words))
                            .font(.system(size: 15)).foregroundStyle(showRaw ? Ink.dim : Ink.ink)
                            .lineSpacing(4).lineLimit(lit ? 12 : 3)
                    }
                    metaLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the Copy pill and the More menu, which sit above the row's click layer. (A hidden copy of
                // the controls built a second menu per row.)
                Color.clear.frame(width: Self.controlsWidth, height: 28)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        } accessory: { _ in
            controls.padding(.trailing, 16).padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .contextMenu {
            Button("Copy") { copyNow(pasted) }
            if transcript.status != .failed, !pasted.isEmpty { Menu("Run Action") { ActionsMenuItems { running = $0 } } }
            Button("Open transcript and audio") { app.go(.transcript(transcript.id)) }
        }
        .sheet(item: $running) { a in
            ActionSheet(action: a, source: pasted, sourceLabel: "a dictation into \(info?.app ?? "an app")") { text in
                app.store.addNote(Note(text: text, aiAction: a.name), to: transcript.id)
            }
            .environmentObject(app)
        }
    }

    /// "▢ Mail · Cleaned", "▢ Slack · Edited by voice", "▢ Messages · Literal · not pasted". The cleanup level is
    /// in the help when the status already says Cleaned (review M-23).
    private var metaLine: some View {
        HStack(spacing: 7) {
            if let info {
                AppIconView(bundleID: info.bundleID).frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(metaParts.joined(separator: " · "))
                if !info.pastedOK {
                    Text("·")
                    Text("not pasted").fontWeight(.semibold).foregroundStyle(Ink.accentText)
                }
            } else {
                Text(transcript.sourceLabel)
            }
            if transcript.pinned { IconGlyph(art: .iconPin, size: 12, color: Ink.mute).accessibilityLabel("Pinned") }
        }
        .font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
        .help(info.map { "Cleanup: \(CleanupLevel.title(stored: $0.level))" } ?? "")
    }

    private var metaParts: [String] {
        guard let info else { return [transcript.sourceLabel] }
        return DictationMeta.parts(app: info.app, level: CleanupLevel.title(stored: info.level), byVoice: info.instruction != nil,
                                   cleaned: info.pasted != info.raw)
    }

    /// The working spinner, the Copy pill, and the More menu.
    private var controls: some View {
        HStack(spacing: 4) {
            if working { ProgressView().controlSize(.small).padding(.horizontal, 4) }
            if canCopy {
                CopyPill(copied: copied, limitMotion: limitMotion)
                    .tapArea { copyNow(shownText) }
                    .help(showRaw ? "Copy what you said" : "Copy what was pasted")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(copied ? "Copied" : "Copy")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { copyNow(shownText) }
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if info != nil, info?.instruction == nil {
                Button(showRaw ? "Show what was pasted" : "Show what you said") { showRaw.toggle() }
                Button("Copy what you said") { Paster.copy(raw); app.toast = Toast("Copied what you said") }
                Divider()
                Section("Redo cleanup") {
                    ForEach(CleanupLevel.allCases) { l in
                        Button(l.title) { redo(l) }
                    }
                }
                Divider()
            }
            if transcript.status != .failed, !pasted.isEmpty {
                Menu("Run Action") { ActionsMenuItems { running = $0 } }
                Divider()
            }
            Button("Open transcript and audio") { app.go(.transcript(transcript.id)) }
            Button(transcript.pinned ? "Unpin" : "Pin (kept past the retention limit)") { app.store.update(transcript.id) { $0.pinned.toggle() } }
            Divider()
            Button("Delete", role: .destructive) { app.delete([transcript.id]) }
        } label: {
            MoreDots()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More")
        .accessibilityLabel("More actions for this dictation")
    }

    private func copyNow(_ text: String) {
        Paster.copy(text)
        copies += 1
        let token = copies
        withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = true }
        HomeAnnounce.say("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copies == token else { return }
            withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = false }
        }
    }

    private func redo(_ level: CleanupLevel) {
        working = true
        Task { @MainActor in
            if let text = await app.dictation.reclean(transcript.id, level: level) {
                Paster.copy(text)
                app.toast = Toast("Redone with \(level.title) cleanup and copied")
            }
            working = false; showRaw = false
        }
    }
}

/// "Copy" as a line pill that turns into a dark "✓ Copied" (a short crossfade and slide; a plain crossfade with
/// motion limited).
private struct CopyPill: View {
    var copied: Bool
    var limitMotion: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            PillLabel(title: "Copy", kind: .line, size: .mini, icon: .iconCopy)
                .opacity(copied ? 0 : 1)
                .offset(y: copied && !limitMotion ? -4 : 0)
            PillLabel(title: "Copied", kind: .dark, size: .mini, icon: .homeCheck)
                .opacity(copied ? 1 : 0)
                .offset(y: copied || limitMotion ? 0 : 4)
        }
        .contentShape(Capsule())
    }
}

/// "···": a row's More button (30 × 28), dim, with a soft wash under the pointer.
private struct MoreDots: View {
    @State private var hover = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in Circle().fill(Ink.dim).frame(width: 3.5, height: 3.5) }
        }
        .frame(width: 30, height: 28)
        .background(Capsule().fill(Ink.ink.opacity(hover ? 0.07 : 0)))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .accessibilityHidden(true)
    }
}

/// A dictation's meta line words: the app, then "Cleaned" when cleanup changed the words, else the cleanup level, or
/// "Edited by voice". Never the level and "cleaned" together ("Mail · Clean · cleaned" said it twice; review M-23).
enum DictationMeta {
    static func parts(app: String, level: String, byVoice: Bool, cleaned: Bool) -> [String] {
        if byVoice { return [app, "Edited by voice"] }
        return [app, cleaned ? "Cleaned" : level]
    }
}
