import SwiftUI
import AppKit

// brand: native file
//
// Home in the Native look (mockup "Verbose Native Redesign", section 1, drawn for the Mac): grouped sections under a
// bold "Home" with the date, in the order and sizes Edit Home sets (HomeLayout.swift). By default: the quick actions
// as plain rows with accent symbols (the way Mail lists its mailboxes), This week as one stat cell, and Recent
// recordings in Voice Memos' rhythm. One column, as wide as a reading column. Record lives in the window's toolbar;
// while you record, the recording section leads Home. Same state and actions as the Verbose style Home (HomeView.swift).

extension HomeView {
    var nativeBody: some View {
        GeometryReader { geo in
            let _ = LookSwitch.mark("home-layout")
            let width = min(Self.nativeColumn, max(320, geo.size.width - 48))
            let layout = layouts.layout(.native)
            let shown = drawn(layout)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nativeHeader
                        .background { popoverAnchors(layout) }
                    WhatsNewHomeLine(top: 12) { app.dictation.openSettings(tab: .whatsNew) }
                    if app.recorder.isRecording || app.capture.isCapturing { NativeRecordingSection().padding(.top, 18) }
                    ForEach(shown, id: \.section) { item in
                        nativeSection(item, layout: layout).padding(.top, 22)
                    }
                    editHomeButton.padding(.top, 28)
                }
                .animation(limitMotionAnimation, value: app.recorder.isRecording)
                .animation(limitMotionAnimation, value: app.capture.isCapturing)
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
                // Back and Forward bring Home back where you left it; the sidebar opens it at the top (App/NavTrail.swift).
                .scrollPlace(ScreenPlaces.scrollKey("home", look: .native), restore: NavTrail.shared.movingThroughHistory)
            }
            // The title fades under the toolbar's glass instead of running into it (review M-05).
            .softScrollEdges(.top)
        }
    }

    /// Home's column: one reading width, like Settings' grouped form.
    static let nativeColumn: CGFloat = 760

    /// The recording section arrives with a quick fade, never a slide.
    private var limitMotionAnimation: Animation { .easeOut(duration: 0.15) }

    // MARK: Header

    /// "Home", bold, with the date under it, as the iPhone's large title and its navigation subtitle.
    private var nativeHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Home").font(.system(size: 26, weight: .bold)).foregroundStyle(.primary)
            Text(Formats.pattern("EEEE, MMMM d").string(from: now)).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Sections

    private func nativeSection(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        nativeContent(item, layout: layout)
            .homeEditFrame(item, editing: edit.editing)
            .homeProbe(item)
    }

    @ViewBuilder private func nativeContent(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        switch item.section {
        case .week: nativeWeek(large: item.size == .large)
        case .stats: nativeStats(large: item.size == .large)
        case .tiles: nativeTiles(layout.tiles, large: item.size == .large)
        case .recent: nativeRecent(compact: item.size == .compact)
        case .record: NativeHomeRecord(size: item.size, status: recordStatus, recording: recording)
        case .lastDictation: NativeHomeLastDictation(size: item.size)
        case .projects: HomeProjectsMac(size: item.size)
        case .moments: HomeMomentsMac(size: item.size)
        case .queue: HomeQueueMac(size: item.size)
        case .thoughts: HomeThoughtsMac(size: item.size)
        case .journal: HomeJournalMac(size: item.size)
        }
    }

    // MARK: This week and the stats

    private var nativeWeekData: HomeWeek {
        log.week(now: now)
    }

    /// This week as one stat cell: a click anywhere opens You.
    private func nativeWeek(large: Bool) -> some View {
        let week = nativeWeekData
        let n = weekNumbers(week)
        let saved = WebFormat.compactDuration(n.saved)
        return NativeSection {
            Button { app.go(.activity) } label: {
                NativeWeekCell(week: week, recordings: n.recordings, saved: saved, large: large)
            }
            .buttonStyle(NativeRowButtonStyle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated, \(HomeCounts.countLabel(n.recordings, "recording", "recordings")), \(saved) saved typing, \(HomeCounts.countLabel(n.moments, "moment", "moments")).")
        .accessibilityHint("Opens You: your week, cleanup, and where you dictate.")
        .accessibilityAddTraits(.isButton)
        .uiTarget("home-week")
    }

    /// Stats: recordings, time saved typing, and moments this week, as plain rows (This week already leads with
    /// words). Compact puts them on one line.
    @ViewBuilder private func nativeStats(large: Bool) -> some View {
        let n = weekNumbers(nativeWeekData)
        let saved = WebFormat.compactDuration(n.saved)
        NativeSection(title: "Stats") {
            if large {
                NativeStatRow(title: "Recordings", value: n.recordings.formatted(), detail: "This week")
                NativeRowSeparator(leading: 14)
                NativeStatRow(title: "Saved typing", value: saved, detail: "This week")
                NativeRowSeparator(leading: 14)
                NativeStatRow(title: "Moments", value: n.moments.formatted(), detail: "This week")
            } else {
                NativeStatsStrip(recordings: n.recordings, saved: saved)
            }
        }
    }

    // MARK: Quick actions

    /// The four tiles you picked, as rows: the accent symbol, the name, and (Large) its detail on the right.
    private func nativeTiles(_ picks: [HomeTile], large: Bool) -> some View {
        let anchor = importAnchor(picks)
        let slots = HomeTileSlot.slots(picks, 0..<HomeLayout.tileCount)
        return NativeSection {
            ForEach(Array(slots.enumerated()), id: \.element.tile) { i, s in
                nativeTile(s.tile, large: large, importAnchor: anchor == s.tile)
                if i < slots.count - 1 { NativeRowSeparator(leading: 42) }
            }
        }
    }

    @ViewBuilder private func nativeTile(_ t: HomeTile, large: Bool, importAnchor: Bool) -> some View {
        let badge: String? = t == .dictate ? dictateKey.1.map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
            : t == .newThought ? Thoughts.hotkey : nil
        let base = NativeActionRow(title: t.title, detail: tileDetail(t), badge: badge, symbol: t.symbol, hint: Self.tileHint(t),
                                   highlighted: t == .importMedia && fileOver, large: large) { runTile(t) }
        switch t {
        case .dictate:
            base.popover(isPresented: dictateOpen, arrowEdge: .bottom) { DictateControls().padding(16).environmentObject(app) }
                .contextMenu { DictateMenu() }
                .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
        case .appAudio:
            base.contextMenu {
                Button("Choose an App…") { app.pickApp() }
                Divider()
                Button("Screen & System Audio Recording Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
        case .importMedia, .pasteLink:
            if importAnchor {
                base.popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }).environmentObject(app) }
                    .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                    .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
            } else {
                base.contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                    .uiTarget(Self.tileTarget(t)).homeTileProbe(t)
            }
        default:
            base.uiTarget(Self.tileTarget(t)).homeTileProbe(t)
        }
    }

    // MARK: Recent recordings

    /// The four newest, in Voice Memos' rhythm: the title, what was said, then the kind, time, and length. Compact:
    /// one line each.
    private func nativeRecent(compact: Bool) -> some View {
        let items = Array(app.archive.prefix(4))
        return NativeSection(title: "Recent recordings", link: "See All", linkHint: "Opens your library.", action: { app.go(.library) }) {
            if items.isEmpty && app.search.isEmpty {
                ContentUnavailableView {
                    Label("No recordings yet", systemImage: "waveform")
                } description: {
                    Text("Click Record in the toolbar to start one.")
                }
                .padding(.vertical, 18)
            } else if items.isEmpty {
                ContentUnavailableView.search(text: app.search).padding(.vertical, 18)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    Group {
                        if compact {
                            NativeRecentLine(transcript: t, divider: i < items.count - 1)
                        } else {
                            NativeRecordingRow(transcript: t, style: .home, divider: i < items.count - 1)
                        }
                    }
                    .uiTarget("row-\(i)")
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: items.map(\.id))
    }
}
