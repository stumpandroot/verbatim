import SwiftUI
import AppKit

/// Every dictation, newest first, grouped by day: what you said, what was pasted, and where.
/// Copy any of them again, see the words before cleanup, redo the cleanup at another level, or open the
/// full transcript with its audio.
struct DictationsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var settings = FlowSettings.shared
    @State private var filter: AppCategory? = nil

    private var all: [Transcript] { app.store.live.filter { $0.source == .dictation }.sorted { $0.createdAt > $1.createdAt } }
    private var shown: [Transcript] {
        let q = app.search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { t in
            if let f = filter, t.flow?.category != f { return false }
            guard !q.isEmpty else { return true }
            return (t.flow?.pasted ?? t.text).lowercased().contains(q) || (t.flow?.raw ?? "").lowercased().contains(q) || (t.flow?.app ?? "").lowercased().contains(q)
        }
    }
    private var days: [(String, [Transcript])] {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        var out: [(String, [Transcript])] = []
        for t in shown {
            let label = cal.isDateInToday(t.createdAt) ? "Today" : cal.isDateInYesterday(t.createdAt) ? "Yesterday" : f.string(from: t.createdAt)
            if out.last?.0 == label { out[out.count - 1].1.append(t) } else { out.append((label, [t])) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Dictations").font(Ink.serif(30, weight: .regular)).foregroundStyle(Ink.ink)
                    Text(all.count == 1 ? "1 kept" : "\(all.count) kept").font(.system(size: 13)).foregroundStyle(Ink.mute)
                    Spacer()
                    Picker("Keep", selection: $settings.keepDays) {
                        Text("Keep forever").tag(0)
                        Text("Keep 30 days").tag(30)
                        Text("Keep 7 days").tag(7)
                        Text("Keep 1 day").tag(1)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    .onChange(of: settings.keepDays) { _, _ in app.dictation.purgeOldDictations() }
                }
                Text("Everything you dictated into other apps, with the audio. If a paste went missing, it's here. ⌘⌃V pastes the last one again.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.top, 4)
                HStack(spacing: 6) {
                    SiteChip(label: "All", on: filter == nil) { filter = nil }
                    ForEach(AppCategory.allCases) { c in SiteChip(label: c.title, on: filter == c) { filter = c } }
                }
                .padding(.top, 14)

                if shown.isEmpty {
                    HStack(spacing: 16) {
                        EmptyStateArt(art: .capture, tint: Ink.persimmonTint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(all.isEmpty ? "No dictations yet" : "Nothing matches").font(Ink.serif(20, weight: .regular))
                            Text("Click the floating button at the edge of your screen, or \(app.dictation.hotkey.shortTitle), and talk. The words land where your cursor is.")
                                .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
                        }
                        Spacer()
                    }
                    .padding(20).background(NoteCardBackground(hover: false)).padding(.top, 20)
                } else {
                    ForEach(days, id: \.0) { day, items in
                        Overline(text: day, color: Ink.mute).padding(.top, 24).padding(.bottom, 8)
                        VStack(spacing: 6) {
                            ForEach(items) { t in DictationRow(transcript: t) }
                        }
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

struct DictationRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var hover = false
    @State private var showRaw = false
    @State private var working = false
    @State private var running: FlowAction? = nil

    private var info: FlowInfo? { transcript.flow }
    private var pasted: String { info?.pasted ?? transcript.text }
    private var raw: String { info?.raw ?? transcript.text }
    private var time: String { let f = DateFormatter(); f.timeStyle = .short; return f.string(from: transcript.createdAt) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time).font(Ink.mono(11.5)).foregroundStyle(Ink.mute)
                Text(transcript.duration.timecode).font(Ink.mono(11)).foregroundStyle(Ink.mute)
            }
            .frame(width: 64, alignment: .leading)
            .contentShape(Rectangle())
            // Drag by the time column (the text stays selectable) onto a project in the sidebar.
            .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
            .help("Drag onto a project")
            VStack(alignment: .leading, spacing: 6) {
                if transcript.status == .failed {
                    Text(transcript.error ?? "Transcription failed").font(.system(size: 14)).foregroundStyle(Ink.accentText)
                } else if let instruction = info?.instruction {
                    Text("“\(instruction)”").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
                    Text(pasted).font(.system(size: 14.5)).foregroundStyle(Ink.ink).lineLimit(hover ? 12 : 3).textSelection(.enabled)
                } else {
                    Text(showRaw ? raw : (pasted.isEmpty ? "(only filler words)" : pasted))
                        .font(.system(size: 14.5)).foregroundStyle(showRaw ? Ink.dim : Ink.ink)
                        .lineLimit(hover ? 12 : 3).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    if let info {
                        Text(info.app)
                        Text("·")
                        Text(info.instruction == nil ? "\(info.level.capitalized) cleanup" : "Edited by voice")
                        if info.pasted != info.raw, info.instruction == nil { Text("·"); Text("cleaned") }
                        if !info.pastedOK { Text("·"); Text("not pasted").foregroundStyle(Ink.accentText) }
                    } else {
                        Text(transcript.sourceLabel)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if working { ProgressView().controlSize(.small).padding(.horizontal, 6) }
                Button { Paster.copy(pasted); app.toast = Toast("Copied") } label: { ToolLabel(title: "Copy", symbol: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy what was pasted")
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
                } label: { ToolLabel(title: "More", symbol: "ellipsis", compact: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .opacity(hover || working ? 1 : 0.35)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(NoteCardBackground(hover: hover))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .contextMenu {
            Button("Copy") { Paster.copy(pasted) }
            if transcript.status != .failed, !pasted.isEmpty { Menu("Run Action") { ActionsMenuItems { running = $0 } } }
            Button("Open transcript and audio") { app.go(.transcript(transcript.id)) }
        }
        .sheet(item: $running) { a in
            ActionSheet(action: a, source: pasted, sourceLabel: "a dictation into \(info?.app ?? "an app")") { text in
                app.store.addNote(Note(text: "\(a.name):\n\(text)"), to: transcript.id)
            }
            .environmentObject(app)
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
