import SwiftUI
import AppKit

// MARK: - Player dock (Soft Instrument)

struct PlayerDock: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock

    var body: some View {
        let total = max(app.player.duration, transcript.duration)
        HStack(spacing: 12) {
            Button { app.player.toggle() } label: {
                ZStack {
                    Circle().fill(Ink.interactive)
                        .shadow(color: Ink.inkFixed.opacity(0.12), radius: 6, y: 2)
                    ArtIcon(art: app.player.isPlaying ? .iconPause : .iconPlay, size: 20, lineWidth: 2).foregroundStyle(Ink.onInteractive).offset(x: app.player.isPlaying ? 0 : 1.5)
                }
                .frame(width: 50, height: 50)
            }
            .buttonStyle(PressStyle(scale: 0.94)).help("Play or pause (Space)")

            skip(.iconBack5, -5, "Back 5 seconds (←)")
            HStack(spacing: 4) {
                Text(app.player.time.timecode).font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.ink)
                Text("/").foregroundStyle(Ink.mute)
                Text(total.timecode).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Ink.mute)
            }
            .fixedSize()

            WaveTrack(values: transcript.waveform, progress: total > 0 ? app.player.time / total : 0,
                      marks: transcript.notes.filter(\.isBookmark).compactMap { $0.at }.map { $0 / max(total, 1) }) { p in
                app.player.seek(to: p * total)
            }
            .frame(height: 36)
            skip(.iconForward5, 5, "Forward 5 seconds (→)")

            Menu { ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(String(format: "%g", r))×") { app.player.setRate(Float(r)) } } } label: {
                Text("\(String(format: "%g", app.player.rate))×").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton).fixedSize()

            Button {
                let at = app.player.time
                let seg = transcript.segments.first(where: { at >= $0.start && at < $0.end })
                app.addNote(transcript: transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
            } label: {
                IconGlyph(art: .bookmark, size: 17, color: Ink.butterText)
                    .frame(width: 38, height: 38).background(Ink.butterTint, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            }
            .buttonStyle(PressStyle(scale: 0.94)).help("Bookmark this moment (B)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // Opaque: text never sits on a blur (DESIGN.md §5.1).
        .background(Ink.bar, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline))
        .frame(maxWidth: 760)
    }

    private func skip(_ art: BrandArt, _ by: Double, _ help: String) -> some View {
        Button { app.player.seek(to: app.player.time + by) } label: {
            IconGlyph(art: art, size: 21, color: Ink.ink).frame(width: 32, height: 32)
        }
        .buttonStyle(PressStyle(scale: 0.92)).help(help)
    }
}

struct WaveTrack: View {
    var values: [Float]
    var progress: Double
    var marks: [Double] = []
    var onSeek: (Double) -> Void
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let vals = values.isEmpty ? Array(repeating: Float(0.15), count: 96) : Waveform.resample(values, to: 96)
            ZStack(alignment: .leading) {
                WaveformThumb(values: vals).fill(Ink.track)
                WaveformThumb(values: vals).fill(Ink.iris)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * progress)) }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    Capsule().fill(Ink.butter).frame(width: 3, height: g.size.height).offset(x: w * m - 1.5)
                }
                Rectangle().fill(Ink.ink).frame(width: 2, height: g.size.height + 6).offset(x: max(0, min(w - 2, w * progress - 1)), y: -3)
                if let hx = hoverX { Rectangle().fill(Ink.iris.opacity(0.25)).frame(width: 1).offset(x: hx) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { ph in if case .active(let p) = ph { hoverX = p.x } else { hoverX = nil } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in onSeek(max(0, min(1, v.location.x / w))) })
        }
    }
}
