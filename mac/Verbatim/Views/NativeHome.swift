import SwiftUI
import AppKit

// brand: native file
//
// Home in Premium Native (mockup "Premium Native", Mac Home): the bold greeting (SF Pro) and the date, then This week as
// a wide persimmon gradient card beside two stacked stat cards (recordings in ink green, typing saved in sage), the
// four start tiles as white cards with a tinted symbol, and Recent recordings as two columns of Voicenotes items. The
// floating record button sits at the bottom right of the window (ContentView). Same state and actions as the Verbose
// style Home (HomeView.swift); while you record, the recording panel shows above the cards.

extension HomeView {
    var nativeBody: some View {
        GeometryReader { geo in
            let width = min(1080, max(320, geo.size.width - 64))
            let wide = width >= 700
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nativeHeader
                    WhatsNewHomeLine(top: 14) { app.dictation.openSettings(tab: .whatsNew) }
                    if app.recorder.isRecording { RecordPanel().padding(.top, 14) }
                    else if app.capture.isCapturing { CapturePanel().padding(.top, 14) }
                    if app.showsHomeWeek { nativeCards(width, wide: wide).padding(.top, 18) }
                    nativeTiles(wide: wide).padding(.top, 14)
                    nativeRecent(wide: wide).padding(.top, 24)
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

    // MARK: This week and the stats

    @ViewBuilder private func nativeCards(_ width: CGFloat, wide: Bool) -> some View {
        let week = HomeWeek(log.events.map { HomeWordEntry(date: $0.date, words: $0.words, seconds: $0.seconds) }, now: now)
        let n = weekNumbers(week)
        let saved = WebFormat.compactDuration(n.saved)
        let weekCard = Button { app.go(.activity) } label: { PremiumWeekCard(week: week) }
            .buttonStyle(PremiumCardPress(radius: 26))
            .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated, \(HomeCounts.countLabel(n.recordings, "recording", "recordings")), \(saved) saved typing, \(HomeCounts.countLabel(n.moments, "moment", "moments")).")
            .accessibilityHint("Opens You: your week, cleanup, and where you dictate.")
            .uiTarget("home-week")
        let stats = VStack(spacing: 14) {
            PremiumStatCard(card: .ink, value: n.recordings.formatted(), title: n.recordings == 1 ? "Recording" : "Recordings", detail: "This week")
            PremiumStatCard(card: .sage, value: saved, title: "Saved", detail: "Typing")
        }
        if wide {
            // The mockup's 1.55 : 1 split.
            let weekWidth = ((width - 14) * 1.55 / 2.55).rounded(.down)
            HStack(spacing: 14) {
                weekCard.frame(width: weekWidth)
                stats.frame(width: width - 14 - weekWidth)
            }
            .frame(height: 208)
        } else {
            VStack(spacing: 14) {
                weekCard
                stats.frame(height: 168)
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder private func nativeTiles(wide: Bool) -> some View {
        let key = dictateKey
        let dictate = PremiumTile(title: "Dictate", detail: key.0, badge: key.1.map { $0.prefix(1).uppercased() + String($0.dropFirst()) },
                                  symbol: "mic", hint: "Shows your dictation key and your last dictation.") {
            app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate"
        }
        .popover(isPresented: dictateOpen, arrowEdge: .bottom) { DictateControls().padding(16).environmentObject(app) }
        .contextMenu { DictateMenu() }
        .uiTarget("mode-dictate")
        let importTile = PremiumTile(title: "Import", detail: fileOver ? "Drop to transcribe" : "A file or a link", badge: nil,
                                     symbol: "square.and.arrow.down", hint: "Choose files, or paste a link to transcribe.", highlighted: fileOver) {
            importOpen = true
        }
        .popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }).environmentObject(app) }
        .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
        .uiTarget("tile-import")
        let appAudio = PremiumTile(title: "App audio", detail: "Another app's sound", badge: nil,
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
        let captionsTile = PremiumTile(title: "Live captions", detail: captions.isOpen ? "On screen now" : "Words as they're said", badge: nil,
                                       symbol: "captions.bubble", hint: "Shows captions in a floating panel, from your microphone or an app's sound.") {
            app.toggleLiveCaptions()
        }
        .uiTarget("tile-captions")
        if wide {
            HStack(spacing: 12) { dictate; importTile; appAudio; captionsTile }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) { dictate; importTile }
                HStack(spacing: 12) { appAudio; captionsTile }
            }
        }
    }

    // MARK: Recent recordings

    private func nativeRecent(wide: Bool) -> some View {
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
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(PremiumInk.accentText)
                    .frame(width: 40, height: 40).background(Circle().fill(PremiumInk.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
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
}
