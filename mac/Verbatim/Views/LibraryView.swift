import SwiftUI

/// Every transcript, grouped by day (pinned first), filtered by the sidebar project and the search field.
/// Select mode picks many at once to move, export, or delete; any row (or the selection) drags onto a project.
/// ⌘-click adds or removes a row and Shift-click selects a range, starting Select mode when it's off.
struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    /// Where a Shift-click range starts: the last row clicked or ⌘-clicked.
    @State private var anchor: UUID? = nil
    /// Library › kind chips (nil is All), kept on AppState so the screenshot tour can choose one.
    private var kind: RecordingKind? { app.libraryKind }
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this Mac.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }

    var body: some View {
        // `filtered` searches every transcript's text; work it out once per render.
        let base = app.filtered
        let searching = !app.search.trimmingCharacters(in: .whitespaces).isEmpty
        let typeFilter = app.libraryFilter
        // Dictations stay out unless you're searching or chose Dictations; they live in Dictations.
        let all = typeFilter.apply(base, searching: searching)
        let byKind = kind.map { k in base.filter { $0.kind == k } } ?? base
        let list = kind.map { k in all.filter { $0.kind == k } } ?? all
        let groups = Store.group(list, sort: sort)
        let order = groups.flatMap { $0.items.map(\.id) }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } ?? kind?.plural ?? "Library")
                            .font(Ink.serif(30, weight: .regular)).foregroundStyle(Ink.ink)
                        Text(list.count == 1 ? "1 transcript" : "\(list.count) transcripts").font(.system(size: 13)).foregroundStyle(Ink.mute)
                        Spacer()
                        Menu {
                            Picker("Sort by", selection: $sortRaw) {
                                ForEach(LibrarySort.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label(sort.title, systemImage: "arrow.up.arrow.down")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Sort the Library: newest, oldest, longest, or by title")
                        .accessibilityLabel("Sort by \(sort.title)")
                        if !list.isEmpty {
                            Button(selecting ? "Done" : "Select") {
                                withAnimation(Motion.snap) { selecting.toggle(); if !selecting { selection = []; anchor = nil } }
                            }
                            .buttonStyle(.bordered).keyboardShortcut(selecting ? .cancelAction : .init("s", modifiers: [.command, .shift]))
                        }
                        if let p = app.projectFilter {
                            Button { app.addFromLibrary = p } label: { Label("Add from Library…", systemImage: "tray.and.arrow.down") }
                                .buttonStyle(.bordered).keyboardShortcut("l", modifiers: [.command, .shift])
                                .help("Add transcripts you already have to this project (⇧⌘L)")
                                .uiTarget("add-from-library")
                        }
                        Button { app.chooseFiles() } label: { Label("Import", systemImage: "plus") }.buttonStyle(.bordered)
                            .help(app.projectFilter == nil ? "Import audio or video files" : "Import audio or video files into this project")
                    }
                    .staggerIn(0).padding(.bottom, 6)
                    if !selecting && !app.store.projects.isEmpty {
                        Text("Drag a transcript onto a project in the sidebar to file it.").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                    }
                    kindChips(all).padding(.top, 12).staggerIn(1)
                    LibraryFilterBar(filter: Binding(get: { app.libraryFilter }, set: { app.libraryFilter = $0 }),
                                     items: byKind, searching: searching, wraps: true, shortcuts: true) { selection = [] }
                        .padding(.top, 8).staggerIn(1)
                    if let k = kind {
                        KindHeroCard(kind: k, meta: heroMeta(k, list), compact: true).frame(maxWidth: 760).padding(.top, 16)
                    }
                    if app.search.trimmingCharacters(in: .whitespaces).count >= 2 {
                        PassageResults(query: app.search, list: list).padding(.top, 14)
                    }
                    if groups.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            if app.search.isEmpty { IconPlate(art: .iconLibrary, size: 96) } else { EmptyStateArt(art: .search, tint: Ink.butterTint) }
                            Text(!app.search.isEmpty ? "Nothing found for “\(app.search)”."
                                 : typeFilter != .all ? "Nothing here matches \(typeFilter.platform ?? typeFilter.source.label)."
                                 : app.projectFilter != nil ? "Nothing in this project yet. Add transcripts from your library or import files."
                                 : "Nothing in here yet.").font(.system(size: 14)).foregroundStyle(Ink.mute)
                            if app.search.isEmpty, typeFilter != .all {
                                Button("Show all") { app.libraryFilter = .all }.buttonStyle(.bordered)
                            }
                        }
                        .padding(.top, 30).staggerIn(1)
                    }
                    if kind == .journal && !selecting {
                        journal(list, order: order).padding(.top, 20)
                    } else {
                    ForEach(Array(groups.enumerated()), id: \.element.label) { gi, g in
                        HStack {
                            Text(g.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.mute)
                            Spacer()
                            if selecting {
                                let ids = Set(g.items.map(\.id))
                                Button(ids.isSubset(of: selection) ? "Deselect" : "Select all") {
                                    if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                                }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.iris)
                            }
                        }
                        .padding(.top, 22).padding(.bottom, 8).staggerIn(1 + gi * 2)
                        VStack(spacing: 8) {
                            ForEach(Array(g.items.enumerated()), id: \.element.id) { ii, t in
                                HistoryRow(transcript: t, selected: selecting ? selection.contains(t.id) : nil,
                                           dragIDs: { selection.contains(t.id) ? Array(selection) : [t.id] },
                                           open: { click(t.id, order: order) })
                                    .staggerIn(2 + gi * 2 + ii)
                                    .contextMenu { RowMenu(transcript: t) }
                            }
                        }
                    }
                    }
                }
                .frame(maxWidth: 1040)
                .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, selecting ? 90 : 40)
                .frame(maxWidth: .infinity)
            }
            .animation(Motion.settle, value: list.map(\.id))
        }
        .overlay(alignment: .bottom) {
            if selecting { actionBar.padding(.bottom, 18).transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity)) }
        }
        .onChange(of: app.projectFilter) { _, _ in selection = [] }
    }

    /// All, then each kind with its count, in the app's chip form.
    private func kindChips(_ all: [Transcript]) -> some View {
        let options: [RecordingKind?] = [nil] + RecordingKind.pickable.map { Optional($0) }
        return FlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(options, id: \.self) { k in
                let on = k == kind
                let n = k.map { kk in all.filter { $0.kind == kk }.count } ?? all.count
                Button { app.libraryKind = k; selection = [] } label: {
                    HStack(spacing: 6) {
                        Text(k?.plural ?? "All")
                        Text("\(n)").fontWeight(.regular).opacity(0.75)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Ink.onInteractive : Ink.ink)
                    .padding(.horizontal, 12).frame(minHeight: 30)
                    .background(on ? Ink.interactive : Ink.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Ink.hairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .uiTarget(k.map { "kind-\($0.rawValue)" } ?? "kind-all")
            }
        }
    }

    private func heroMeta(_ k: RecordingKind, _ list: [Transcript]) -> String {
        if k == .journal {
            let week = Date().addingTimeInterval(-7 * 86_400)
            let n = list.filter { $0.createdAt >= week }.count
            return "\(n) this week"
        }
        return list.count == 1 ? "1 saved" : "\(list.count) saved"
    }

    /// Journal reads by day: "◇ TODAY ···· SAT 17 OCT", then each entry's title, time, and opening lines.
    private func journal(_ list: [Transcript], order: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(JournalDays.group(list)) { day in
                VStack(alignment: .leading, spacing: 10) {
                    EditorialSectionHeader(index: day.date.uppercased(), label: day.label)
                    ForEach(day.entries) { t in
                        Button { click(t.id, order: order) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(t.title).font(Ink.serif(22)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text("\(Formats.pattern("h:mm a").string(from: t.createdAt)) · \(t.duration.timecode)")
                                        .font(Ink.mono(11.5)).foregroundStyle(Ink.mute)
                                    Spacer(minLength: 0)
                                }
                                Text(JournalDays.preview(t)).font(.system(size: 15)).foregroundStyle(Ink.dim).lineSpacing(3).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.hairline))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { RowMenu(transcript: t) }
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func toggle(_ id: UUID) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }

    /// A row click: ⌘ adds or removes it, Shift selects the range from the anchor (both start Select mode); a plain
    /// click toggles in Select mode and opens the transcript otherwise.
    private func click(_ id: UUID, order: [UUID]) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift), let a = anchor ?? (selecting ? selection.first : nil),
           let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            withAnimation(Motion.snap) { selecting = true }
            selection.formUnion(order[min(i, j)...max(i, j)])
        } else if flags.contains(.command) || flags.contains(.shift) {
            withAnimation(Motion.snap) { selecting = true }
            toggle(id); anchor = id
        } else if selecting {
            toggle(id); anchor = id
        } else {
            app.go(.transcript(id))
        }
    }

    private var chosen: [Transcript] { app.filtered.filter { selection.contains($0.id) } }

    private var exportTitle: String {
        let n = chosen.filter { $0.status == .ready }.count
        return n == 1 ? "Export 1 transcript" : "Export \(n) transcripts"
    }

    /// The export sheet for the selection, in Library order (transcripts still in progress are left out).
    private func openExport() {
        let ids = chosen.filter { $0.status == .ready }.map(\.id)
        guard !ids.isEmpty else { return }
        app.exportRequest = ExportRequest(ids: ids)
    }

    /// Glass action bar for the selection.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "Select transcripts" : "\(selection.count) selected").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                .frame(minWidth: 110, alignment: .leading)
            Button("Select all") { selection = Set(app.filtered.map(\.id)) }.buttonStyle(.plain).foregroundStyle(Ink.iris).font(.system(size: 13, weight: .medium))
            Divider().frame(height: 20)
            Menu {
                Button("No project") { app.move(Array(selection), to: nil) }
                if !app.store.projects.isEmpty { Divider() }
                ForEach(app.store.projects) { p in Button(p.name) { app.move(Array(selection), to: p.id) } }
            } label: { Label("Move to", systemImage: "folder") }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            Menu {
                Button(exportTitle + "…") { openExport() }
                Divider()
                Button("Copy all to clipboard") {
                    let text = Exporter.clipboard(chosen.filter { $0.status == .ready }, as: .txt, options: .saved)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    app.toast = Toast("Copied \(chosen.count) transcripts")
                }
            } label: { Label(exportTitle + "…", systemImage: "square.and.arrow.up") } primaryAction: { openExport() }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            .help("Choose a format and options, then a folder: one file per transcript")
            Button(role: .destructive) {
                app.delete(Array(selection)); selection = []
            } label: { Label("Delete", systemImage: "trash") }
            .help("Moves to Recently Deleted for 30 days")
            .buttonStyle(.plain).foregroundStyle(selection.isEmpty ? Ink.mute : Ink.coral).disabled(selection.isEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Ink.glassTint, in: Capsule())
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.ink.opacity(0.08)))
        .shadow(color: Ink.ink.opacity(0.12), radius: 16, y: 6)
    }
}

/// Search that finds the moment, not just the file: each matching line with its speaker and time, grouped by
/// transcript. Click a line to open the transcript there.
struct PassageResults: View {
    var query: String
    /// The library's filtered transcripts, worked out once by the caller.
    var list: [Transcript]

    /// Per transcript: up to six matching lines to show, and how many lines match in all.
    private var hits: [(Transcript, [Segment], Int)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [(Transcript, [Segment], Int)] = []
        var total = 0
        for t in list where t.status == .ready {
            let segs = t.segments.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            guard !segs.isEmpty else { continue }
            // The count is matched against the query as typed (untrimmed), as it always was.
            let matches = q == query ? segs.count : t.segments.filter { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.count
            out.append((t, Array(segs.prefix(6)), matches))
            total += segs.count
            if total > 300 { break }
        }
        return out
    }

    var body: some View {
        let results = hits
        VStack(alignment: .leading, spacing: 10) {
            Text(results.isEmpty ? "No passages match “\(query)”" : "Passages")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.mute)
            ForEach(results, id: \.0.id) { t, segs, n in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(t.title).font(Ink.serif(16, weight: .regular)).foregroundStyle(Ink.ink).lineLimit(1)
                        if let site = t.linkInfo?.site { Text(site).font(.system(size: 11.5)).foregroundStyle(Ink.mute) }
                        Spacer()
                        Text("\(n) match\(n == 1 ? "" : "es")").font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                    ForEach(segs) { s in PassageLine(transcript: t, segment: s, query: query) }
                }
                .padding(.bottom, 6)
                .background(NoteCardBackground(hover: false))
            }
        }
    }
}

struct PassageLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var segment: Segment
    var query: String
    @State private var hover = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(segment.start.timecode).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Ink.iris).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if transcript.speakers.count >= 2, let sp = transcript.speakerName(segment.speaker) {
                    Text(sp).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ink.mute)
                }
                Text(marked).font(.system(size: 14)).foregroundStyle(Ink.ink).lineLimit(3)
            }
            Spacer(minLength: 8)
            if let info = transcript.linkInfo, info.supportsTimestamps, hover {
                Button { if let u = info.url(at: segment.start) { NSWorkspace.shared.open(u) } } label: { Image(systemName: "play.rectangle") }
                    .buttonStyle(.plain).foregroundStyle(Ink.iris).help("Open the video at \(segment.start.timecode)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hover ? Ink.iris.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.focusSegment = segment.id; app.go(.transcript(transcript.id)) }
    }

    private var marked: AttributedString {
        var a = AttributedString(segment.text)
        var start = a.startIndex
        while start < a.endIndex, let r = a[start...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Ink.coral.opacity(0.28); a[r].font = .system(size: 14, weight: .semibold)
            start = r.upperBound
        }
        return a
    }
}
