import SwiftUI

/// Home: the headline, a raised Record key with Import and Link beside it, the three method cards, and
/// recent work. Whatever you record here shows up on your Mac.
struct HomeScreen: View {
    @EnvironmentObject var app: PhoneState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Overline(text: "Verbatim", color: Ink.dim)
                    DottedRule().frame(height: 1)
                    SyncBadge()
                }
                .padding(.top, 8)
                Text("Words worth keeping.").font(Ink.serif(36)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
                Text("Capture what was said. Make it readable. Find what matters.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim).padding(.top, 6)

                capture.padding(.top, 22)

                VStack(alignment: .leading, spacing: 12) {
                    EditorialSectionHeader(index: "01", label: "Method")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) { cards }.padding(.horizontal, 20)
                    }
                    .padding(.horizontal, -20)
                }
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 12) {
                    EditorialSectionHeader(index: "02", label: "Recent", title: "Pick up where you left off.")
                    let items = Array(app.store.live.prefix(6))
                    if items.isEmpty {
                        HStack(spacing: 14) {
                            EmptyStateArt(art: .capture, tint: Ink.persimmonTint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Record something new.").font(Ink.serif(20)).foregroundStyle(Ink.ink)
                                Text("Recordings and imports land here, and on your Mac.").font(.system(size: 14)).foregroundStyle(Ink.dim)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.hairline))
                    } else {
                        ForEach(items) { t in
                            Button { app.open(t.id) } label: { PhoneRow(transcript: t) }.buttonStyle(.plain)
                                .contextMenu { RowActions(transcript: t) }
                        }
                        Button { app.tab = .library } label: { HStack { Text("View library"); Image(systemName: "arrow.right") }.font(.system(size: 15, weight: .medium)) }
                            .foregroundStyle(Ink.ink).padding(.top, 4)
                    }
                }
                .padding(.top, 28)
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .background(Ink.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var capture: some View {
        HStack(spacing: 14) {
            VStack(spacing: 8) {
                Button { app.requestRecord() } label: {
                    Circle().fill(Ink.readerFixed).frame(width: 24, height: 24).frame(width: 84, height: 84)
                }
                .buttonStyle(RaisedKeyStyle())
                .accessibilityLabel("Record")
                Text("Record").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
            }
            VStack(spacing: 10) {
                Button { app.showImporter = true } label: {
                    HStack(spacing: 10) {
                        BrandGlyph(art: .document, color: Ink.ink).frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Import").font(.system(size: 15, weight: .semibold))
                            Text("Audio or video files").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                }
                .buttonStyle(TactileButtonStyle())
                Button { app.showLinkSheet = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link").font(.system(size: 17, weight: .light)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Link").font(.system(size: 15, weight: .semibold))
                            Text("Your Mac fetches it").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                }
                .buttonStyle(TactileButtonStyle())
            }
        }
        .padding(14)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Ink.hairline))
    }

    @ViewBuilder private var cards: some View {
        let live = app.store.live
        let latest = live.first { $0.status == .ready && !$0.segments.isEmpty }
        let moments = live.reduce(0) { $0 + $1.notes.filter { $0.at != nil }.count }
        BrandFeatureCard(feature: .capture, line: "Record or import a file.", meta: live.count == 1 ? "1 transcript" : "\(live.count) transcripts") { app.requestRecord() }
            .frame(width: 236)
        BrandFeatureCard(feature: .refine, line: "Clean up a transcript. The original stays.", meta: latest.map { "Latest: \($0.title)" } ?? "Nothing to refine yet", enabled: latest != nil) {
            if let t = latest { app.focusSegment = nil; app.homePath.append(DocumentRoute(id: t.id)) }
        }
        .frame(width: 236)
        BrandFeatureCard(feature: .understand, line: "Find what matters: moments and search.", meta: moments == 1 ? "1 saved moment" : "\(moments) saved moments") { app.tab = .moments }
            .frame(width: 236)
    }
}

/// Opens a transcript straight into its Document view.
struct DocumentRoute: Hashable { let id: UUID }

/// "Synced", "iCloud off": the state of sync, in one small label.
struct SyncBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Cloud.enabled ? "icloud" : "icloud.slash").font(.system(size: 11))
            Text(Cloud.enabled ? "iCloud" : "On this iPhone").font(Ink.mono(10.5, weight: .medium)).textCase(.uppercase)
        }
        .foregroundStyle(Ink.mute)
        .accessibilityLabel(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off; saved on this iPhone")
    }
}

/// Long-press actions shared by every list.
struct RowActions: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var body: some View {
        Button { app.togglePin(transcript.id) } label: { Label(transcript.pinned ? "Unpin" : "Pin", systemImage: transcript.pinned ? "pin.slash" : "pin") }
        Menu {
            if !app.store.projects.isEmpty {
                Button("No project") { app.move(transcript.id, to: nil) }
                ForEach(app.store.projects) { p in Button(p.name) { app.move(transcript.id, to: p.id) } }
                Divider()
            }
            Button { app.newProjectFor = transcript.id } label: { Label("New project…", systemImage: "folder.badge.plus") }
        } label: { Label("Move to project", systemImage: "folder") }
        if transcript.status == .ready { Button { app.copyText(transcript) } label: { Label("Copy text", systemImage: "doc.on.doc") } }
        if transcript.status == .failed { Button { app.retry(transcript) } label: { Label("Retry", systemImage: "arrow.clockwise") } }
        if transcript.status == .processing, transcript.processingDevice == Device.id { Button { app.cancel(transcript.id) } label: { Label("Cancel transcription", systemImage: "xmark") } }
        Divider()
        Button(role: .destructive) { app.delete([transcript.id]) } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - Recording

struct RecordScreen: View {
    @EnvironmentObject var app: PhoneState
    private var paused: Bool { app.recorder.isPaused }
    private var adding: Transcript? { app.continuing.flatMap { app.store.transcript($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                Overline(text: adding == nil ? "New recording" : "Continue recording", color: Ink.dim)
                DottedRule().frame(height: 1)
                Overline(text: adding == nil ? "Voice note" : "Adds to \(adding!.duration.timecode)", color: Ink.mute)
            }
            .padding(.top, 14)

            Text(headline)
                .font(Ink.serif(30)).foregroundStyle(Ink.ink).lineLimit(2).minimumScaleFactor(0.8)
                .padding(.top, 14)
                .contentTransition(.opacity)
                .animation(Motion.settle, value: paused)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Circle().fill(paused ? Ink.mute : Ink.persimmon).frame(width: 8, height: 8)
                            Overline(text: paused ? "Paused" : "Recording", color: paused ? Ink.mute : Ink.accentText)
                        }
                        ElapsedLabel(live: app.recorder.live, size: 54)
                    }
                    Spacer(minLength: 8)
                    LiveCaptureMark(live: app.recorder.live, paused: paused).frame(width: 78, height: 100)
                }
                RecordWave(live: app.recorder.live, paused: paused).frame(height: 84).padding(.top, 14)
                Overline(text: "Transcribed on this iPhone", color: Ink.mute).padding(.top, 10)
            }
            .padding(20)
            .background(Ink.reader, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Ink.hairline))
            .padding(.top, 20)

            Overline(text: "Keeps recording with the screen locked", color: Ink.mute)
                .frame(maxWidth: .infinity).padding(.top, 14)

            Spacer(minLength: 20)

            // Centered: the Record button you tapped is now Stop, with Discard and Pause on either side.
            HStack(alignment: .top, spacing: 0) {
                RoundControl(label: "Discard", size: 62) {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.dim)
                } action: { app.discardRecording() }
                .frame(maxWidth: .infinity)
                RoundControl(label: adding == nil ? "Stop & transcribe" : "Stop & add", size: 100, primary: true) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.readerFixed).frame(width: 32, height: 32)
                } action: { app.stopRecording() }
                .frame(maxWidth: .infinity)
                RoundControl(label: paused ? "Resume" : "Pause", size: 62) {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 20)).foregroundStyle(Ink.ink)
                } action: { app.recorder.togglePause() }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 20)
        .background(Ink.paper.ignoresSafeArea())
        .interactiveDismissDisabled()
        .sensoryFeedback(.impact(weight: .light), trigger: paused)
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        if paused { return "Paused. Pick up when you're ready." }
        if let t = adding { return "Keep going. This adds to “\(t.title)”." }
        return "Go ahead, I'm listening."
    }
}

/// A round control with its label underneath. Small ones sit on the card color; the primary one is persimmon.
struct RoundControl<Icon: View>: View {
    var label: String
    var size: CGFloat
    var primary = false
    @ViewBuilder var icon: () -> Icon
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(primary ? Ink.persimmon : Ink.reader)
                    if !primary { Circle().strokeBorder(Ink.hairline) }
                    icon()
                }
                .frame(width: size, height: size)
                .shadow(color: primary ? Ink.persimmon.opacity(0.32) : .clear, radius: 12, y: 6)
                .frame(height: 100)   // labels line up whatever the circle size
                Text(label).font(.system(size: 14, weight: primary ? .semibold : .regular)).foregroundStyle(Ink.ink).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.06 : 0.14), value: configuration.isPressed)
    }
}

/// The brand's Capture diagram, listening: the rings swell with your voice; the dot is the recording light.
struct LiveCaptureMark: View {
    @ObservedObject var live: LiveMeter
    var paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let level = paused || reduceMotion ? 0 : CGFloat(live.level)
        Canvas { ctx, size in
            // Diagram space: circles touch at the bottom, an axis runs through them (diagram_capture).
            let box = CGRect(x: 168, y: 88, width: 264, height: 342)
            let s = min(size.width / box.width, size.height / box.height)
            let ox = (size.width - box.width * s) / 2 - box.minX * s, oy = (size.height - box.height * s) / 2 - box.minY * s
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            let base: CGFloat = 383   // where the circles meet
            let radii: [CGFloat] = [124, 102, 80, 58]
            for (i, r0) in radii.enumerated() {
                let grow = 1 + level * (0.10 - CGFloat(i) * 0.02)
                let r = r0 * grow
                let c = pt(300, base - r)
                let rect = CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s)
                ctx.stroke(Path(ellipseIn: rect), with: .color(Ink.ink.opacity([0.22, 0.42, 0.7, 1][i])), lineWidth: 1.6)
            }
            var axis = Path(); axis.move(to: pt(300, 96)); axis.addLine(to: pt(300, 421))
            axis.move(to: pt(280, 93)); axis.addLine(to: pt(320, 93)); axis.move(to: pt(282, 425)); axis.addLine(to: pt(318, 425))
            ctx.stroke(axis, with: .color(Ink.ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            let d = 15 * s * (1 + level * 0.4)
            let dc = pt(300, base)
            ctx.fill(Path(ellipseIn: CGRect(x: dc.x - d, y: dc.y - d, width: 2 * d, height: 2 * d)), with: .color(paused ? Ink.mute : Ink.persimmon))
        }
        .animation(.easeOut(duration: 0.12), value: live.level)
        .accessibilityHidden(true)
    }
}

/// The live waveform: newest on the right, the latest few bars in persimmon.
struct RecordWave: View {
    @ObservedObject var live: LiveMeter
    var paused: Bool
    var body: some View {
        GeometryReader { g in
            let n = live.levels.count
            let gap: CGFloat = 3
            let w = max(2, (g.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(live.levels.enumerated()), id: \.offset) { i, v in
                    Capsule()
                        .fill(paused ? Ink.track : (i >= n - 4 ? Ink.persimmon : Ink.ink))
                        .frame(width: w, height: max(4, CGFloat(v) * g.size.height))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeOut(duration: 0.12), value: live.levels)
        .accessibilityHidden(true)
    }
}

struct LinkSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste a YouTube, Vimeo, or podcast link. Your Mac fetches the audio and transcribes it; the transcript appears here when it's done.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(Ink.mute)
                    TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused)
                }
                .padding(12)
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.hairline))
                .shadow(color: Ink.inkFixed.opacity(0.06), radius: 1, y: 1)
                PasteButton(payloadType: String.self) { strings in link = strings.first ?? link }
                    .buttonBorderShape(.capsule).labelStyle(.titleAndIcon)
                if !Cloud.enabled {
                    Label("iCloud is off, so your Mac won't see this until you turn it on.", systemImage: "icloud.slash").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                Spacer()
            }
            .padding(20)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("Add a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send to Mac") { app.addLink(link); dismiss() }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
