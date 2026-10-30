import SwiftUI
import AppKit

// Dictations on the refined kit (DESIGN.md §13) in both look settings: the large serif title with the count and the
// retention menu, category chips, serif day titles over cards of rows that copy when clicked.

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
            VStack(alignment: .leading, spacing: 18) {
                RefinedPageHeader(title: "Dictations", count: all.count == 1 ? "1 kept" : "\(all.count.formatted()) kept",
                                  lede: "Everything you dictated into other apps, with the audio. If a paste went missing, it's here. \u{2303}\u{2318}V pastes the last one again.") {
                    retentionMenu
                }
                RefinedChipRow(label: "Filter") {
                    RefinedChip(title: "All", selected: filter == nil) { filter = nil }
                    ForEach(AppCategory.allCases) { c in RefinedChip(title: c.title, selected: filter == c) { filter = filter == c ? nil : c } }
                }

                if shown.isEmpty {
                    emptyState(all.isEmpty)
                } else {
                    // Lazy: only the dictations on screen are built (people keep hundreds).
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Self.days(shown), id: \.0) { day, items in
                            VStack(alignment: .leading, spacing: 8) {
                                SerifSectionTitle(day)
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                                        if i > 0 { PaperDivider(leading: 16, trailing: 16) }
                                        DictationRow(transcript: t)
                                    }
                                }
                                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 18).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges(.top)
        .background(Refined.paper)
    }

    /// "Keep 30 days ⌄": the retention menu.
    private var retentionMenu: some View {
        Menu {
            Picker("Keep", selection: $settings.keepDays) {
                ForEach(Self.retention, id: \.0) { item in Text(item.1).tag(item.0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            RefinedMenuLabel(title: retentionTitle)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("How long dictations are kept. Pinned ones stay.")
        .accessibilityLabel("Keep dictations")
        .accessibilityValue(retentionTitle)
        .onChange(of: settings.keepDays) { _, _ in app.dictation.purgeOldDictations() }
    }

    @ViewBuilder private func emptyState(_ none: Bool) -> some View {
        if none {
            RefinedEmptyState(art: .iconDictations, hue: .butter, title: "No dictations yet",
                              message: "Click \(DictationSurface.stored().clickHint), or press \(app.dictation.hotkey.shortTitle), and talk. The words land where your cursor is.")
        } else {
            RefinedEmptyState(art: .search, title: "Nothing matches",
                              message: "No dictation in this category matches your search.", action: "Show all") {
                filter = nil
                app.search = ""
            }
        }
    }
}

/// One dictation as a row in its day's card: the time and length, the words, and a meta line (the app's icon, the app,
/// the cleanup level, "not pasted" in the accent). Clicking the row copies what was pasted; Copy turns into "✓ Copied"
/// for 1.6 s. The More menu redoes cleanup, runs an action, opens the transcript, pins, or deletes. The row drags onto
/// a project in the sidebar. The words and the controls are side by side, so no button sits under the row's gestures
/// (macOS 26 click safety).
struct DictationRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var showRaw = false
    @State private var working = false
    @State private var running: FlowAction? = nil
    @State private var copied = false
    @State private var copies = 0
    @State private var hover = false
    @Environment(\.limitMotion) private var limitMotion

    private var info: FlowInfo? { transcript.flow }
    private var pasted: String { info?.pasted ?? transcript.text }
    private var raw: String { info?.raw ?? transcript.text }
    private var time: String { Formats.style(date: .none, time: .short).string(from: transcript.createdAt) }
    private var shownText: String { showRaw ? raw : pasted }
    private var canCopy: Bool { transcript.status != .failed && !shownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            words
                .contentShape(Rectangle())
                .onTapGesture { if canCopy { copyNow(shownText) } }
                .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(canCopy ? "Copies it" : "")
                .accessibilityAction { if canCopy { copyNow(shownText) } }
            controls.padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hover ? Refined.stripe : Color.clear)
        .onHover { hover = $0 }
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

    private var words: some View {
        let lit = hover
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time).refinedFont(.meta, weight: .semibold).monospacedDigit().foregroundStyle(Refined.ink)
                Text(HomeRecentStyle.length(transcript.duration)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
            }
            .lineLimit(1)
            .frame(width: 70, alignment: .leading)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                if transcript.status == .failed {
                    Text(transcript.error ?? "Transcription failed").refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                } else if let instruction = info?.instruction {
                    Text("\u{201C}\(instruction)\u{201D}").font(.system(size: 15, design: .serif).italic()).foregroundStyle(Refined.dim)
                    Text(lit ? pasted : HomeDictationText.oneLine(pasted)).font(.system(size: 15)).foregroundStyle(Refined.ink).lineSpacing(4).lineLimit(lit ? 12 : 3)
                } else {
                    // At rest the words run on one line of text (a greeting's blank line doesn't take a row); under
                    // the pointer the row opens with the line breaks as pasted.
                    let w = showRaw ? raw : (pasted.isEmpty ? "(only filler words)" : pasted)
                    Text(lit ? w : HomeDictationText.oneLine(w))
                        .font(.system(size: 15)).foregroundStyle(showRaw ? Refined.dim : Refined.ink)
                        .lineSpacing(4).lineLimit(lit ? 12 : 3)
                }
                metaLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "▢ Mail · Cleaned", "▢ Slack · Edited by voice", "▢ Messages · Literal · not pasted". The cleanup level is
    /// in the help when the status already says Cleaned (review M-23).
    private var metaLine: some View {
        HStack(spacing: 7) {
            if let info {
                DictationAppIcon(bundleID: info.bundleID).frame(width: 14, height: 14)
                Text(metaParts.joined(separator: " · "))
                if !info.pastedOK {
                    Text("·")
                    Text("not pasted").fontWeight(.semibold).foregroundStyle(Refined.accentText)
                }
            } else {
                Text(transcript.sourceLabel)
            }
            if transcript.pinned { IconGlyph(art: .iconPin, size: 12, color: Refined.mute).accessibilityLabel("Pinned") }
        }
        .refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
        .help(info.map { "Cleanup: \(CleanupLevel.title(stored: $0.level))" } ?? "")
    }

    private var metaParts: [String] {
        guard let info else { return [transcript.sourceLabel] }
        return DictationMeta.parts(app: info.app, level: CleanupLevel.title(stored: info.level), byVoice: info.instruction != nil,
                                   cleaned: info.pasted != info.raw)
    }

    /// The working spinner, Copy, and the More menu.
    private var controls: some View {
        HStack(spacing: 6) {
            if working { ProgressView().controlSize(.small).padding(.horizontal, 4) }
            if canCopy {
                Button { copyNow(shownText) } label: {
                    HStack(spacing: 6) {
                        IconGlyph(art: copied ? .homeCheck : .iconCopy, size: 13, color: Refined.ink)
                        Text(copied ? "Copied" : "Copy")
                    }
                }
                .buttonStyle(RefinedActionStyle())
                .help(showRaw ? "Copy what you said" : "Copy what was pasted")
                .accessibilityLabel(copied ? "Copied" : "Copy")
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
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.dim)
                .frame(width: 30, height: 30)
                .background(Refined.neutral, in: Circle())
                .contentShape(Circle())
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

/// The app a dictation went into, as its icon; an app that can't be found gets the neutral square with an app glyph,
/// never an empty square (review M-23).
private struct DictationAppIcon: View {
    var bundleID: String?
    var body: some View {
        AppIcon(key: bundleID.flatMap { $0.isEmpty ? nil : .bundleID($0) }) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Refined.neutralSquare)
                .overlay {
                    GeometryReader { g in
                        IconGlyph(art: .iconWidgets, size: g.size.width * 0.7, color: Refined.dim)
                            .frame(width: g.size.width, height: g.size.height)
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
