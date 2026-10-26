import SwiftUI
import AppKit

// brand: web style

// MARK: - Player dock

/// The player at the bottom of the transcript (the website's dock): a dark capsule in fixed ink with a hard offset
/// shadow; the Record-colored play button, back and forward 5 s, the time in mono, the waveform (played part in
/// butter, bookmarks as butter marks; click or drag to seek), the speed, and Bookmark as a paper pill.
struct PlayerDock: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock

    var body: some View {
        let total = max(app.player.duration, transcript.duration)
        HStack(spacing: 12) {
            Button { app.player.toggle() } label: {
                ZStack {
                    Circle().fill(Ink.panelRecord)
                    ArtIcon(art: app.player.isPlaying ? .iconPause : .iconPlay, size: 16, lineWidth: 2).foregroundStyle(Ink.inkFixed)
                        .offset(x: app.player.isPlaying ? 0 : 1.5)
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
            }
            .buttonStyle(PressStyle(scale: 0.94)).help("Play or pause (Space)")
            .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")

            skip(.iconBack5, -5, "Back 5 seconds (←)")
            if let note = clock.note {
                // Where the time is, for a moment after playback jumps past a sponsor read.
                SkippedSponsorNote(text: note)
            } else {
                HStack(spacing: 4) {
                    Text(app.player.time.timecode).foregroundStyle(Ink.paperFixed)
                    Text("/").foregroundStyle(Ink.paperFixed.opacity(0.55))
                    Text(total.timecode).foregroundStyle(Ink.paperFixed.opacity(0.75))
                }
                .font(Ink.mono(12))
                .fixedSize()
            }

            WaveTrack(values: transcript.waveform, progress: total > 0 ? app.player.time / total : 0,
                      marks: transcript.notes.filter(\.isBookmark).compactMap { $0.at }.map { $0 / max(total, 1) },
                      track: Ink.paperFixed.opacity(0.35), played: Ink.panelButter, mark: Ink.panelButter, head: Ink.paperFixed) { p in
                app.player.seek(to: p * total)
            }
            .frame(height: 30)
            skip(.iconForward5, 5, "Forward 5 seconds (→)")

            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(String(format: "%g", r))×") { app.player.setRate(Float(r)) } }
                Divider()
                ReduceNoiseToggle(player: app.player)
            } label: {
                Text("\(String(format: "%g", app.player.rate))×").font(Ink.mono(12)).foregroundStyle(Ink.paperFixed)
                    .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Playback speed, and Reduce background noise")
            .accessibilityLabel("Playback speed and noise")

            Button {
                let at = app.player.time
                let seg = transcript.segments.first(where: { at >= $0.start && at < $0.end })
                app.addNote(transcript: transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
            } label: {
                HStack(spacing: 6) {
                    ArtIcon(art: .bookmark, size: 15)
                    Text("Bookmark")
                }
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                .padding(.horizontal, 16).frame(height: 38)
                .background(Ink.paperFixed, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.96)).help("Bookmark this moment (B)")
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        // Opaque: text never sits on a blur (DESIGN.md §5.1).
        .background(Ink.inkFixed, in: Capsule())
        .background { Capsule().fill(Ink.hard.opacity(0.25)).offset(x: 5, y: 6) }
        .frame(maxWidth: 760)
    }

    private func skip(_ art: BrandArt, _ by: Double, _ help: String) -> some View {
        Button { app.player.seek(to: app.player.time + by) } label: {
            IconGlyph(art: art, size: 19, color: Ink.paperFixed).frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.92)).help(help)
        .accessibilityLabel(by < 0 ? "Back 5 seconds" : "Forward 5 seconds")
    }
}

struct WaveTrack: View {
    var values: [Float]
    var progress: Double
    var marks: [Double] = []
    var track: Color = Ink.track
    var played: Color = Ink.iris
    var mark: Color = Ink.butter
    var head: Color = Ink.ink
    var onSeek: (Double) -> Void
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let vals = values.isEmpty ? Array(repeating: Float(0.15), count: 96) : Waveform.resample(values, to: 96)
            ZStack(alignment: .leading) {
                WaveformThumb(values: vals).fill(track)
                WaveformThumb(values: vals).fill(played)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * progress)) }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    Capsule().fill(mark).frame(width: 3, height: g.size.height).offset(x: w * m - 1.5)
                }
                Rectangle().fill(head).frame(width: 2, height: g.size.height + 6).offset(x: max(0, min(w - 2, w * progress - 1)), y: -3)
                if let hx = hoverX { Rectangle().fill(head.opacity(0.3)).frame(width: 1).offset(x: hx) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { ph in if case .active(let p) = ph { hoverX = p.x } else { hoverX = nil } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in onSeek(max(0, min(1, v.location.x / w))) })
        }
    }
}
