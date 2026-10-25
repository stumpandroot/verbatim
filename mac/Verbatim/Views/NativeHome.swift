import SwiftUI
import AppKit

// brand: native file
//
// Home in Premium Native (mockup "Premium Native", Mac Home): the bold greeting (SF Pro) and the date, then the sections
// Edit Home lists for Native (HomeLayout.swift), in its order and sizes. By default: This week as a wide persimmon
// gradient card beside two stacked stat cards (recordings in ink green, typing saved in sage), the four start tiles as
// white cards with a tinted symbol, and Recent recordings as two columns of Voicenotes items. The floating record button
// sits at the bottom right of the window (ContentView) whether or not the Record section is shown. Same state and
// actions as the Verbose style Home (HomeView.swift); while you record, the recording panel shows above the cards.

extension HomeView {
    var nativeBody: some View {
        GeometryReader { geo in
            let width = min(1080, max(320, geo.size.width - 64))
            let wide = width >= 700
            let layout = layouts.layout(.native)
            let rows = HomeRows.rows(drawn(layout), wide: wide)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nativeHeader
                        .background { popoverAnchors(layout) }
                    WhatsNewHomeLine(top: 14) { app.dictation.openSettings(tab: .whatsNew) }
                    if app.recorder.isRecording { RecordPanel().padding(.top, 14) }
                    else if app.capture.isCapturing { CapturePanel().padding(.top, 14) }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        nativeRow(row, width: width, wide: wide, layout: layout)
                            .padding(.top, Self.rowGap(row, after: i > 0 ? rows[i - 1] : nil, native: true))
                    }
                    editHomeButton.padding(.top, 32)
                }
                .animation(Motion.settle, value: app.recorder.isRecording)
                .animation(Motion.settle, value: app.capture.isCapturing)
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 110)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Header

    private var nativeHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The greeting without its period, as a content title. SF Pro, never the serif.
            Text(greeting.hasSuffix(".") ? String(greeting.dropLast()) : greeting)
                .font(.system(size: 30, weight: .bold)).tracking(-0.5).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(Formats.pattern("EEEE, MMMM d").string(from: now)).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Bands

    /// Two sections side by side: This week and Stats at the mockup's 1.55 : 1, 208 pt tall; any other pair at 7 / 5.
    @ViewBuilder private func nativeRow(_ row: HomeRow, width: CGFloat, wide: Bool, layout: HomeLayout) -> some View {
        if row.items.count == 2 {
            let split = row.items[0].section == .week && row.items[1].section == .stats
            let left = split ? ((width - 14) * 1.55 / 2.55).rounded(.down) : ((width - 14) * 7 / 12).rounded(.down)
            HStack(alignment: .top, spacing: 14) {
                nativeSection(row.items[0], width: left, wide: wide, paired: true, layout: layout).frame(width: left)
                nativeSection(row.items[1], width: width - 14 - left, wide: wide, paired: true, layout: layout).frame(width: width - 14 - left)
            }
            .frame(height: split ? 208 : nil)
        } else {
            nativeSection(row.items[0], width: width, wide: wide, paired: false, layout: layout)
        }
    }

    private func nativeSection(_ item: HomeLayout.Item, width: CGFloat, wide: Bool, paired: Bool, layout: HomeLayout) -> some View {
        nativeContent(item, width: width, wide: wide, paired: paired, layout: layout)
            .homeEditFrame(item, editing: edit.editing)
            .homeProbe(item)
    }

    @ViewBuilder private func nativeContent(_ item: HomeLayout.Item, width: CGFloat, wide: Bool, paired: Bool, layout: HomeLayout) -> some View {
        switch item.section {
        case .week: nativeWeek(large: item.size == .large)
        case .stats: nativeStats(large: item.size == .large, paired: paired, wide: wide)
        case .tiles: nativeTiles(layout.tiles, wide: wide && !paired, large: item.size == .large)
        case .recent: nativeRecent(wide: width >= 700, compact: item.size == .compact)
        case .record: NativeHomeRecord(size: item.size, status: recordStatus, recording: recording)
        case .lastDictation: NativeHomeLastDictation(size: item.size)
        case .projects: HomeProjectsMac(size: item.size)
        case .moments: HomeMomentsMac(size: item.size)
        case .queue: HomeQueueMac(size: item.size)
        }
    }

    // MARK: This week and the stats

    private var nativeWeekData: HomeWeek {
        HomeWeek(log.events.map { HomeWordEntry(date: $0.date, words: $0.words, seconds: $0.seconds) }, now: now)
    }

    /// Large: the persimmon card. Compact: a slim persimmon strip with the words and the days.
    private func nativeWeek(large: Bool) -> some View {
        let week = nativeWeekData
        let n = weekNumbers(week)
        let saved = WebFormat.compactDuration(n.saved)
        return Button { app.go(.activity) } label: {
            if large { PremiumWeekCard(week: week) } else { NativeWeekStrip(week: week) }
        }
        .buttonStyle(PremiumCardPress(radius: large ? 26 : 20))
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated, \(HomeCounts.countLabel(n.recordings, "recording", "recordings")), \(saved) saved typing, \(HomeCounts.countLabel(n.moments, "moment", "moments")).")
        .accessibilityHint("Opens You: your week, cleanup, and where you dictate.")
        .uiTarget("home-week")
    }

    /// Large: the two stat cards (stacked beside This week, side by side on their own in a wide window). Compact: one
    /// strip with both numbers.
    @ViewBuilder private func nativeStats(large: Bool, paired: Bool, wide: Bool) -> some View {
        let n = weekNumbers(nativeWeekData)
        let saved = WebFormat.compactDuration(n.saved)
        let recordings = PremiumStatCard(card: .ink, value: n.recordings.formatted(), title: n.recordings == 1 ? "Recording" : "Recordings", detail: "This week")
        let typing = PremiumStatCard(card: .sage, value: saved, title: "Saved", detail: "Typing")
        if !large {
            NativeStatsStrip(recordings: n.recordings, saved: saved)
        } else if paired {
            VStack(spacing: 14) { recordings; typing }.frame(maxHeight: .infinity)
        } else if wide {
            HStack(spacing: 14) { recordings; typing }.frame(height: 96)
        } else {
            VStack(spacing: 14) { recordings; typing }.frame(height: 168)
        }
    }

    // MARK: Tiles

    /// The four tiles you picked. Compact: one row of four (two by two in a narrow window). Large: two by two, taller.
    @ViewBuilder private func nativeTiles(_ picks: [HomeTile], wide: Bool, large: Bool) -> some View {
        if wide && !large {
            HStack(spacing: 12) { nativeTileViews(picks, 0..<4, tall: false) }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) { nativeTileViews(picks, 0..<2, tall: large) }
                HStack(spacing: 12) { nativeTileViews(picks, 2..<4, tall: large) }
            }
        }
    }

    private func nativeTileViews(_ picks: [HomeTile], _ slots: Range<Int>, tall: Bool) -> some View {
        let anchor = importAnchor(picks)
        return ForEach(HomeTileSlot.slots(picks, slots), id: \.tile) { s in premiumTile(s.tile, tall: tall, importAnchor: anchor == s.tile) }
    }

    @ViewBuilder private func premiumTile(_ t: HomeTile, tall: Bool, importAnchor: Bool) -> some View {
        let badge: String? = t == .dictate ? dictateKey.1.map { $0.prefix(1).uppercased() + String($0.dropFirst()) } : nil
        let base = PremiumTile(title: t.title, detail: tileDetail(t), badge: badge, symbol: t.symbol, hint: Self.tileHint(t),
                               highlighted: t == .importMedia && fileOver, tall: tall) { runTile(t) }
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

    /// Large: the four newest as Voicenotes items, in two columns when wide. Compact: the four newest as slim rows.
    private func nativeRecent(wide: Bool, compact: Bool) -> some View {
        let items = Array(app.archive.prefix(4))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent recordings").font(.system(size: 20, weight: .bold)).tracking(-0.3).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Library") { app.go(.library) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(PremiumInk.accentText)
                    .accessibilityHint("Opens your library.")
            }
            if items.isEmpty && app.search.isEmpty {
                NativeEmptyState(art: .iconLibrary, title: "Record something new", message: "Recordings and imports land here, ready to review.",
                                 button: "Start recording", action: { app.requestRecord() })
                    .premiumCard()
                    .padding(.top, 8)
            } else if items.isEmpty {
                NativeEmptyState(art: .search, title: "Nothing found", message: "Nothing matches “\(app.search)”. Search looks at titles and every transcript's text.")
                    .premiumCard()
                    .padding(.top, 8)
            } else if compact {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        NativeRecentLine(transcript: t, divider: i < items.count - 1)
                            .uiTarget("row-\(i)")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .premiumCard()
                .padding(.top, 8)
            } else if wide {
                // Two columns, filled across: 1 and 3 on the left, 2 and 4 on the right.
                HStack(alignment: .top, spacing: 34) {
                    recentColumn(items, start: 0)
                    recentColumn(items, start: 1)
                }
            } else {
                recentColumn(items, start: 0, step: 1)
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    private func recentColumn(_ items: [Transcript], start: Int, step: Int = 2) -> some View {
        let picked = Array(stride(from: start, to: items.count, by: step))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(picked, id: \.self) { i in
                PremiumRecordingItem(transcript: items[i])
                    .uiTarget("row-\(i)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Pieces

/// A soft press for a whole card (This week): a slight dim while pressed and a lift under the pointer.
struct PremiumCardPress: ButtonStyle {
    var radius: CGFloat = 22
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, radius: radius) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        var radius: CGFloat
        @State private var hover = false
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .brightness(configuration.isPressed ? -0.04 : (hover ? 0.02 : 0))
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.99 : 1)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hover = $0 }
                .animation(Motion.touch, value: hover)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Kept for the Native kit's other clickable boxes: a soft wash under the pointer and while pressed.
struct NativeCardButtonStyle: ButtonStyle {
    var radius: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, radius: radius) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        var radius: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : (hover ? 0.035 : 0)))
                        .allowsHitTesting(false)
                }
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hover = $0 }
                .animation(Motion.touch, value: hover)
        }
    }
}

/// A start tile: a white card with the symbol on a soft accent disc, the name and one line of detail, and the
/// shortcut as a small badge (Dictate's key).
private struct PremiumTile: View {
    var title: String
    var detail: String
    var badge: String?
    var symbol: String
    var hint: String
    var highlighted = false
    /// Large tiles: the symbol over the name and detail, 112 pt tall.
    var tall = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if tall {
                    VStack(alignment: .leading, spacing: 0) {
                        symbolDisc
                        Spacer(minLength: 8)
                        Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(.primary).lineLimit(1)
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).padding(.top, 1)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
                } else {
                    HStack(spacing: 12) {
                        symbolDisc
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(PremiumInk.separator, lineWidth: 1))
                        .padding(.top, 10).padding(.trailing, 12)
                }
            }
            .premiumCard()
            .overlay {
                if highlighted { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.nativeAccent, lineWidth: 2) }
            }
        }
        .buttonStyle(PremiumCardPress(radius: 18))
        .accessibilityLabel(title)
        .accessibilityValue([detail, badge.map(Keycap.spoken)].compactMap { $0 }.joined(separator: " "))
        .accessibilityHint(hint)
    }

    private var symbolDisc: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(PremiumInk.accentText)
            .frame(width: 40, height: 40).background(Circle().fill(PremiumInk.accentSoft))
    }
}
