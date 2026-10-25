import SwiftUI
import AppKit

// brand: native file
//
// Home in the Native look (mockup section 03, "Mac Home"): a bold content title, "Good afternoon, Tim", as Music and
// the App Store set theirs, the date under it, then plain group boxes. Record with its level and a persimmon
// Start Recording button, the four start tiles, This week, Recent recordings, and Last dictation. No grain, panel art,
// tilt, or hard shadow; keycaps become secondary shortcut text, as menus show them. Same state and actions as the
// Verbose style Home (HomeView.swift).

extension HomeView {
    /// The grid's width for `available` points, and its 7 / 5 split.
    private static func nativeColumns(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let left = ((total - 12) * 7 / 12).rounded(.down)
        return (left, total - 12 - left)
    }

    var nativeBody: some View {
        GeometryReader { geo in
            let width = min(1040, max(300, geo.size.width - 56))
            let wide = width >= 680
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nativeHeader
                    if app.recorder.isRecording { RecordPanel().padding(.top, 14) }
                    else if app.capture.isCapturing { CapturePanel().padding(.top, 14) }
                    nativeStart(width, wide: wide).padding(.top, 18)
                    if app.showsHomeWeek { nativeWeek.padding(.top, 12) }
                    nativeRecent(width, wide: wide).padding(.top, 26)
                }
                .animation(Motion.settle, value: app.recorder.isRecording)
                .animation(Motion.settle, value: app.capture.isCapturing)
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.chooseFiles() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import audio or video files (⌘O)")
                Button { app.requestRecord() } label: { Label("Record", systemImage: "mic") }
                    .help("Record a voice note (⌥⇧R)")
                Button { app.toggleLiveCaptions() } label: { Label("Live Captions", systemImage: "captions.bubble") }
                    .help("Live captions (⌥⌘C)")
            }
        }
    }

    // MARK: Header

    private var nativeHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The greeting without its period, as a content title.
            Text(greeting.hasSuffix(".") ? String(greeting.dropLast()) : greeting)
                .font(.system(size: 26, weight: .bold)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(Formats.pattern("EEEE, MMMM d").string(from: now)).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Record and tiles

    @ViewBuilder private func nativeStart(_ width: CGFloat, wide: Bool) -> some View {
        if wide {
            let cols = Self.nativeColumns(width)
            HStack(alignment: .top, spacing: 12) {
                nativeRecord.frame(width: cols.0, height: 184)
                nativeTiles.frame(width: cols.1, height: 184)
            }
        } else {
            VStack(spacing: 12) {
                nativeRecord.frame(height: 184)
                nativeTiles.frame(height: 184)
            }
        }
    }

    /// Record: the status, a persimmon disc (the brand color, carrying no text), the level, and Start Recording.
    private var nativeRecord: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording ? "Recording" : "Record").font(.system(size: 15, weight: .semibold))
                    Text(recordStatus).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { monitor.stop(); app.requestRecord() } label: {
                    Circle().fill(Ink.persimmonFixed)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2).padding(5))
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(recording)
                .accessibilityLabel("Record")
                .help("Start recording")
            }
            Spacer(minLength: 8)
            Group {
                let live = Ink.nativeAccent
                if app.recorder.isRecording { LiveHomeMeter(live: app.recorder.live, barWidth: 4, gap: 4, heights: HomeMeter.macHeights, color: live) }
                else if app.capture.isCapturing { LiveHomeMeter(live: app.capture.live, barWidth: 4, gap: 4, heights: HomeMeter.macHeights, color: live) }
                else if monitor.listening { LiveHomeMeter(live: monitor.live, barWidth: 4, gap: 4, heights: HomeMeter.macHeights, color: live) }
                else { BreathingHomeMeter(barWidth: 4, gap: 4, heights: HomeMeter.macHeights, color: Color.secondary.opacity(0.6)) }
            }
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if !recording {
                    Button("Start Recording") { monitor.stop(); app.requestRecord() }
                        .buttonStyle(.borderedProminent)
                    Text("⌥⇧R").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityLabel(Keycap.spoken("⌥⇧R"))
                } else {
                    Text("Pause or stop from the bar above.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nativeBox()
        .onHover { h in
            if h { if !recording { monitor.listen(after: 0.12) } } else { monitor.stop(after: 0.4) }
        }
        .contextMenu { RecordMenu(onChange: { mics.refresh() }) }
        .help("Recording from \(micName). Right-click to change the microphone.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recording ? "Recording" : "Record")
        .accessibilityValue(recording ? "" : "Microphone: \(micName)")
        .uiTarget("tile-record")
    }

    /// Four start tiles, two by two, as tall together as Record.
    private var nativeTiles: some View {
        let key = dictateKey
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                NativeTile(title: "Dictate", detail: key.0, shortcut: key.1.map { $0.prefix(1).uppercased() + String($0.dropFirst()) },
                           symbol: "mic", hint: "Shows your dictation key and your last dictation.") {
                    app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate"
                }
                .popover(isPresented: dictateOpen, arrowEdge: .bottom) { DictateControls().padding(16).environmentObject(app) }
                .contextMenu { DictateMenu() }
                .uiTarget("mode-dictate")
                NativeTile(title: "Import", detail: fileOver ? "Drop to transcribe" : "A file or a link", shortcut: "⌘O",
                           symbol: "square.and.arrow.down", hint: "Choose files, or paste a link to transcribe.") {
                    importOpen = true
                }
                .popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }).environmentObject(app) }
                .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
                .uiTarget("tile-import")
            }
            HStack(spacing: 10) {
                NativeTile(title: "App audio", detail: "Another app's sound", shortcut: nil,
                           symbol: "speaker.wave.2", hint: "Choose an app to record its sound, like a call or a video.") {
                    app.pickApp()
                }
                .contextMenu {
                    Button("Choose an App…") { app.pickApp() }
                    Divider()
                    Button("Screen & System Audio Recording Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                .uiTarget("tile-app")
                NativeTile(title: "Live captions", detail: captions.isOpen ? "On screen now" : "Words as they're said", shortcut: "⌥⌘C",
                           symbol: "captions.bubble", hint: "Shows captions in a floating panel, from your microphone or an app's sound.") {
                    app.toggleLiveCaptions()
                }
                .uiTarget("tile-captions")
            }
        }
    }

    // MARK: This week

    private var nativeWeek: some View {
        let week = HomeWeek(log.events.map { HomeWordEntry(date: $0.date, words: $0.words, seconds: $0.seconds) }, now: now)
        let n = weekNumbers(week)
        let saved = WebFormat.compactDuration(n.saved)
        return Button { app.go(.activity) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    nativeWeekLead(week)
                    Spacer(minLength: 12)
                    nativeWeekStats(n.recordings, saved, n.moments)
                }
                .padding(.horizontal, 16).frame(height: 66)
                VStack(alignment: .leading, spacing: 10) {
                    nativeWeekLead(week)
                    nativeWeekStats(n.recordings, saved, n.moments)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativeBox()
        }
        .buttonStyle(NativeCardButtonStyle())
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")), \(HomeCounts.countLabel(n.recordings, "recording", "recordings")), \(saved) saved typing, \(HomeCounts.countLabel(n.moments, "moment", "moments")).")
        .accessibilityHint("Opens You: your week, cleanup, and where you dictate.")
        .uiTarget("home-week")
    }

    private func nativeWeekLead(_ week: HomeWeek) -> some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 1) {
                Text("This week").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(HomeCounts.countLabel(week.words, "word", "words")).font(.system(size: 19, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.primary).lineLimit(1).fixedSize()
            }
            let peak = max(1, week.peak)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(day.isToday ? AnyShapeStyle(Ink.nativeAccent) : AnyShapeStyle(Color.secondary.opacity(day.isFuture ? 0.25 : 0.55)))
                            .frame(width: 7, height: day.isFuture || day.words == 0 ? 2 : max(3, 26 * CGFloat(day.words) / CGFloat(peak)))
                        Text(Formats.pattern("EEEEE").string(from: day.start))
                            .font(.system(size: 10, weight: day.isToday ? .semibold : .regular)).foregroundStyle(.secondary)
                    }
                    .frame(width: 11)
                }
            }
            .frame(height: 42, alignment: .bottom)
            .accessibilityHidden(true)
        }
    }

    private func nativeWeekStats(_ recordings: Int, _ saved: String, _ moments: Int) -> some View {
        HStack(spacing: 22) {
            stat("\(recordings.formatted())", recordings == 1 ? "recording" : "recordings")
            stat(saved, "saved typing")
            stat("\(moments.formatted())", moments == 1 ? "moment" : "moments")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.primary)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .lineLimit(1).fixedSize()
    }

    // MARK: Recent recordings and Last dictation

    @ViewBuilder private func nativeRecent(_ width: CGFloat, wide: Bool) -> some View {
        if wide {
            let cols = Self.nativeColumns(width)
            HStack(alignment: .top, spacing: 12) {
                nativeRecordings.frame(width: cols.0)
                nativeLastDictation.frame(width: cols.1)
            }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                nativeRecordings
                nativeLastDictation
            }
        }
    }

    private func listHeader(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button("Show All", action: action)
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.nativeAccent)
                .accessibilityHint(hint)
        }
    }

    private var nativeRecordings: some View {
        let items = Array(app.archive.prefix(2))
        return VStack(alignment: .leading, spacing: 8) {
            listHeader("Recent recordings", hint: "Opens your library.") { app.go(.library) }
            if items.isEmpty && app.search.isEmpty {
                NativeEmptyState(art: .iconLibrary, title: "Record something new", message: "Recordings and imports land here, ready to review.",
                                 button: "Start recording", action: { app.requestRecord() })
                    .nativeBox()
            } else if items.isEmpty {
                NativeEmptyState(art: .search, title: "Nothing found", message: "Nothing matches “\(app.search)”. Search looks at titles and every transcript's text.")
                    .nativeBox()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        let fillers = WebStatus.cachedFillers(t)
                        NativeRecentRow(transcript: t, fillers: fillers, open: { app.go(.transcript(t.id)) }, cleanUp: { openCleaned(t) })
                            .contextMenu { RowMenu(transcript: t) }
                            .uiTarget("row-\(i)")
                        if i < items.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
                .nativeBox()
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    private var nativeLastDictation: some View {
        let last = app.store.transcripts.lazy.filter { $0.deletedAt == nil && $0.source == .dictation }.max { $0.createdAt < $1.createdAt }
        let key = app.dictation.hotkey.shortTitle
        return VStack(alignment: .leading, spacing: 8) {
            listHeader("Last dictation", hint: "Opens every dictation.") { app.go(.dictations) }
            if let t = last {
                NativeLastDictation(transcript: t, place: sites.hosts[t.id] ?? t.flow?.app, copy: { Paster.copy($0) })
                    .uiTarget("home-dictation-0")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.bubble").foregroundStyle(Ink.nativeAccent)
                    Text("\(key.prefix(1).uppercased() + String(key.dropFirst())) in any app and speak. What you say shows up here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .nativeBox()
            }
        }
        .animation(Motion.settle, value: last?.id)
        .uiTarget("home-dictations")
    }
}

// MARK: - Pieces

/// A clickable box: a soft wash under the pointer and while pressed, as a list row highlights.
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

/// A start tile: the symbol on a persimmon disc, the shortcut as secondary text, the name and one line of detail.
private struct NativeTile: View {
    var title: String
    var detail: String
    var shortcut: String?
    var symbol: String
    var hint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Circle().fill(Ink.nativeAccent))
                    Spacer(minLength: 4)
                    if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).padding(.top, 1)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .nativeBox()
        }
        .buttonStyle(NativeCardButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue([detail, shortcut.map(Keycap.spoken)].compactMap { $0 }.joined(separator: " "))
        .accessibilityHint(hint)
    }
}

/// A recent recording: its kind symbol, title, meta line, and status, with Clean Up beside it when the Original still
/// has filler words. Clean Up sits above the row's button, never inside it.
private struct NativeRecentRow: View {
    var transcript: Transcript
    var fillers: Int
    var open: () -> Void
    var cleanUp: () -> Void

    var body: some View {
        let moments = WebStatus.moments(transcript)
        Button(action: open) {
            HStack(spacing: 10) {
                NativeKindIcon(transcript: transcript, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transcript.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    meta.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if fillers > 0 {
                    Text(HomeCounts.countLabel(fillers, "filler word", "filler words")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Color.clear.frame(width: 76, height: 1)   // room for Clean Up
                } else if moments > 0 {
                    Text(HomeCounts.countLabel(moments, "moment", "moments")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(NativeCardButtonStyle(radius: 6))
        .overlay(alignment: .trailing) {
            if fillers > 0 {
                Button("Clean Up", action: cleanUp)
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Opens the transcript's Cleaned tab.")
                    .padding(.trailing, 12)
            }
        }
        .accessibilityHint("Opens the transcript.")
    }

    private var meta: Text {
        let parts = HomeRecentStyle.metaParts(transcript, style: HomeRecentStyle(transcript), compact: false)
        var out = Text(verbatim: "")
        for (i, part) in parts.enumerated() {
            let piece = part.failed ? Text(part.text).foregroundStyle(NativeInk.danger) : Text(part.text)
            out = Text("\(out)\(i > 0 ? " · " : "")\(piece)")
        }
        return out
    }
}

/// The last dictation: where it went and when, the word count, the words (three lines at most), what cleanup did,
/// and Copy. A click anywhere copies; Copy turns into Copied for 1.6 s, and VoiceOver hears "Copied".
private struct NativeLastDictation: View {
    var transcript: Transcript
    var place: String?
    var copy: (String) -> Void
    @Environment(\.limitMotion) private var limitMotion
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        let failed = transcript.status == .failed
        let text = HomeDictationText.pasted(transcript)
        let canCopy = !failed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button { if canCopy { copyNow(text) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    AppIconView(bundleID: transcript.flow?.bundleID).frame(width: 14, height: 14)
                    Text(head).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(HomeCounts.countLabel(HomeCounts.words(transcript), "word", "words")).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(HomeDictationText.body(transcript)).font(.system(size: 13)).lineSpacing(2)
                    .foregroundStyle(failed ? AnyShapeStyle(NativeInk.danger) : AnyShapeStyle(.primary))
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let status = WebStatus.dictationCleanup(transcript) {
                        Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if canCopy {
                        NativeButtonFace(title: copied ? "Copied" : "Copy", prominent: false, size: .mini)
                            .animation(limitMotion ? nil : Motion.fade, value: copied)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(12)
            .nativeBox()
        }
        .buttonStyle(NativeCardButtonStyle())
        .disabled(!canCopy)
        .accessibilityLabel(HomeDictationText.body(transcript))
        .accessibilityValue(copied ? "Copied" : head)
        .accessibilityHint(canCopy ? "Copies the dictation." : "")
    }

    /// "Mail · 10:16 AM": where it went, then when.
    private var head: String {
        let d = transcript.createdAt
        let when = Calendar.current.isDateInToday(d) ? Formats.style(date: .none, time: .short).string(from: d) : HomeRecentStyle.day(d)
        guard let place, !place.isEmpty else { return when }
        return "\(place) · \(when)"
    }

    private func copyNow(_ text: String) {
        copy(text)
        copies += 1
        let token = copies
        copied = true
        HomeAnnounce.say("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copies == token else { return }
            copied = false
        }
    }
}
