import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var app: AppState
    var id: UUID
    @State private var titleDraft = ""

    private var transcript: Transcript? { app.store.transcript(id) }

    var body: some View {
        if let t = transcript {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    header(t)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if t.status == .processing {
                                    processing
                                } else if t.status == .failed {
                                    failed(t)
                                } else {
                                    ForEach(t.segments) { s in
                                        line(s, current: isCurrent(s, in: t)).id(s.id)
                                    }
                                }
                            }
                            .frame(maxWidth: 560, alignment: .leading)
                            .padding(.bottom, 24)
                        }
                        .onChange(of: app.player.time) { _, now in
                            if app.player.isPlaying, let s = t.segments.first(where: { now >= $0.start && now < $0.end }) {
                                withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                            }
                        }
                    }
                    if t.audioFileName != nil { playbar(t) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                inspector(t)
                    .frame(width: 280)
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 16)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .onAppear { if let u = app.store.audioURL(for: t) { app.player.load(u) } }
            .onDisappear { app.player.stop() }
        } else {
            Text("This transcript was deleted.").foregroundStyle(Ink.mute)
        }
    }

    private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: Binding(get: { t.title }, set: { v in app.store.update(t.id) { $0.title = v } }))
                .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold)).foregroundStyle(Ink.ink)
            HStack(spacing: 12) {
                Text(t.sourceLabel); Text(t.duration.timecode)
                Text(t.createdAt, style: .date)
            }
            .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
        }
        .padding(.bottom, 16)
    }

    private func isCurrent(_ s: Segment, in t: Transcript) -> Bool {
        let now = app.player.time
        return now >= s.start && now < s.end && (app.player.isPlaying || now > 0)
    }

    private func line(_ s: Segment, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button(s.start.timecode) { app.player.seek(to: s.start) }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: 0x948C80))
                .frame(width: 52, alignment: .leading).padding(.top, 6)
            Text(s.text)
                .font(.system(size: 16)).lineSpacing(6).foregroundStyle(Ink.ink)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(current ? Ink.irisTint : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
        .animation(Motion.settle, value: current)
    }

    private var processing: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProcessingDots()
                Text("Transcribing on this Mac. The first time a model is used it downloads once; after that it is quick.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.06)).frame(width: CGFloat([480, 420, 500, 300][i]), height: 14).padding(.vertical, 6)
            }
        }
        .padding(.top, 8)
    }

    private func failed(_ t: Transcript) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VerbieView(pose: .interrupted).frame(width: 60, height: 70)
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription did not finish").font(.system(size: 14, weight: .semibold))
                Text(t.error ?? "Try again from Home by opening the file.").font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
        }
        .padding(.top, 8)
    }

    private func playbar(_ t: Transcript) -> some View {
        HStack(spacing: 12) {
            Button { app.player.toggle() } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white).frame(width: 30, height: 30).background(Ink.ink, in: Circle())
            }
            .buttonStyle(.plain).pressable().keyboardShortcut(.space, modifiers: [])
            Text("\(app.player.time.timecode) / \(max(app.player.duration, t.duration).timecode)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim).frame(minWidth: 92, alignment: .leading)
            Scrubber(progress: app.player.duration > 0 ? app.player.time / app.player.duration : 0) { p in
                app.player.seek(to: p * app.player.duration)
            }
        }
        .padding(.top, 12).padding(.bottom, 4)
        .frame(maxWidth: 560)
        .background(Ink.paper.opacity(0.92))
    }

    private func inspector(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details").font(.system(size: 12, weight: .semibold)).padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Source", t.sourceLabel)
                row("Model", t.model)
                row("Segments", "\(t.segments.count)")
                row("Words", "\(t.text.split(separator: " ").count)")
                row("Kept", "On this Mac")
            }
            .font(.system(size: 12.5))
            Divider().padding(.vertical, 18)
            Text("Notes").font(.system(size: 12, weight: .semibold)).padding(.bottom, 8)
            Text("Notes with photos and links arrive in a later build.").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            Spacer()
            Button(role: .destructive) {
                app.go(.home)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { withAnimation(Motion.settle) { app.store.delete(t) } }
            } label: { Label("Delete transcript", systemImage: "trash") }
            .buttonStyle(.plain).foregroundStyle(Ink.mute).font(.system(size: 12.5))
        }
        .padding(.leading, 22)
        .overlay(alignment: .leading) { Ink.hairline.frame(width: 1) }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Ink.mute)
            Text(v).foregroundStyle(Ink.ink).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The playback track: iris fill, white thumb, click or drag to seek.
struct Scrubber: View {
    var progress: Double
    var onSeek: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xE8E2D8)).frame(height: 6)
                Capsule().fill(Ink.iris).frame(width: max(6, w * progress), height: 6)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.1)))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: max(0, min(w - 12, w * progress - 6)))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in onSeek(max(0, min(1, v.location.x / w))) })
        }
        .frame(height: 28)
    }
}
