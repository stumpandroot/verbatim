import SwiftUI
import UniformTypeIdentifiers

/// Import › Multi-track recording: one file per mic, each a speaker. Lists the tracks with their speaker names,
/// how they line up, and the options, then hands them to `AppState.startMultitrack`. On the refined kit (DESIGN.md
/// §13): each track's number on its speaker's chip color, in the transcript's rotation, so a speaker keeps one color
/// from this sheet to the transcript (review M-30).
struct MultitrackSheet: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var draft: MultitrackDraft
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            trackList
            options
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
        .frame(width: 820)
        .frame(minHeight: 560)
        .background(Refined.paper)
        .tint(Refined.accentText)
        .uiTarget("multitrack-sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import · one file per mic").refinedFont(.meta).foregroundStyle(Refined.mute)
            Text("Each mic is one speaker").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
            Text("Verbose transcribes each track on its own and weaves them into one transcript by time. Speaker names come from the track names, and you can change them here.")
                .refinedFont(.body).foregroundStyle(Refined.dim)
                .frame(maxWidth: 540, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(draft.tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(index: i, track: t, speaker: speakerBinding(t.id), showOffset: draft.alignAutomatically,
                                 remove: { withAnimation(Motion.snap) { draft.remove(t.id) } })
                        PaperDivider(leading: 16, trailing: 16)
                    }
                }
            }
            .frame(maxHeight: 290)
            .fixedSize(horizontal: false, vertical: true)
            addRow
        }
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .overlay { if dropping { RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous).strokeBorder(Refined.accentText, lineWidth: 1.5) } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            let ps = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            guard !ps.isEmpty else { return false }
            let collector = URLCollector(expected: ps.count) { urls in Task { @MainActor in draft.add(urls) } }
            for p in ps {
                p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    collector.add(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
            return true
        }
    }

    private var addRow: some View {
        Button {
            if let urls = AppState.pickAudioFiles(prompt: "Add", message: "Add audio files, one per mic.") { draft.add(urls) }
        } label: {
            Text(draft.canAdd ? "+ Add a track, or drop files here" : "Eight tracks is the most Verbose can weave together")
                .refinedFont(.rowTitle, weight: .medium).foregroundStyle(draft.canAdd ? Refined.accentText : Refined.dim)
                .frame(maxWidth: .infinity).frame(height: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!draft.canAdd)
        .background(alignment: .top) {
            DashLine().stroke(Refined.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1)
        }
        .background(dropping ? Refined.persimmonTint : .clear)
    }

    private var options: some View {
        HStack(spacing: 12) {
            HStack {
                Text("Line up tracks")
                Spacer()
                Menu {
                    Button("Automatically (by sound)") { draft.setAlign(true) }
                    Button("Start together") { draft.setAlign(false) }
                } label: {
                    Text(draft.alignAutomatically ? "Automatically (by sound)" : "Start together").foregroundStyle(Refined.dim)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.visible).fixedSize()
            }
            .optionCard()
            .help("Automatically compares the first five minutes of each track to find where it starts. Choose Start together when every file began at the same moment.")
            HStack {
                Text("Ignore mic bleed")
                Spacer()
                Toggle("Ignore mic bleed", isOn: $draft.ignoreBleed).labelsHidden().toggleStyle(.switch).controlSize(.small).refinedSwitchTint()
            }
            .optionCard()
            .help("Drops words a mic picked up from someone else's voice, keeping them on the louder mic.")
        }
        .refinedFont(.rowTitle)
        .foregroundStyle(Refined.ink)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { app.multitrackDraft = nil }
                .keyboardShortcut(.cancelAction)
            Button(draft.tracks.count == 1 ? "Transcribe 1 track" : "Transcribe \(draft.tracks.count) tracks") { app.startMultitrack(draft) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!draft.canStart)
                .help(Text(draft.tracks.count < 2 ? "Add at least two tracks." : "Transcribes each track, then weaves them into one transcript."))
        }
        .controlSize(.large)
    }

    private func speakerBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { draft.tracks.first { $0.id == id }?.speaker ?? "" },
                set: { v in if let i = draft.tracks.firstIndex(where: { $0.id == id }) { draft.tracks[i].speaker = v } })
    }
}

private struct TrackRow: View {
    var index: Int
    var track: MultitrackDraft.Track
    @Binding var speaker: String
    var showOffset: Bool
    var remove: () -> Void

    var body: some View {
        let hue = RefinedRules.speakerHue(index)
        HStack(spacing: 12) {
            Text("\(index + 1)").refinedFont(.chip, weight: .semibold).monospacedDigit().foregroundStyle(Refined.onBadge(hue))
                .frame(width: 26, height: 26)
                .background(Refined.badge(hue), in: Circle())
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.fileName).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1).truncationMode(.middle)
                Text(meta).refinedFont(.meta, weight: track.problem == nil ? .regular : .semibold).monospacedDigit()
                    .foregroundStyle(track.problem == nil ? Refined.mute : Refined.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaker").refinedFont(.caption).foregroundStyle(Refined.mute)
                TextField("Speaker", text: $speaker)
                    .textFieldStyle(.plain).refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                    .padding(.horizontal, 8).frame(height: 28)
                    .refinedFieldBox()
                    .accessibilityLabel("Speaker for track \(index + 1)")
            }
            .frame(width: 150)
            TrackBars(values: track.wave, color: Refined.badge(hue))
                .frame(width: 190, height: 26)
                .accessibilityHidden(true)
            Button("Remove", action: remove)
                .buttonStyle(RefinedActionStyle())
            .accessibilityLabel("Remove track \(index + 1)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// "1:04:12 · 48 kHz · starts 0.4 s later"
    private var meta: String {
        if let p = track.problem { return p }
        guard let d = track.duration else { return "Reading…" }
        var parts = [d.timecode]
        if let r = track.sampleRate { parts.append(r.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(r / 1000)) kHz" : String(format: "%.1f kHz", r / 1000)) }
        if showOffset && index > 0 {
            if let o = track.offset { if let s = MultitrackMath.offsetText(o) { parts.append(s) } }
            else { parts.append("lining up…") }
        }
        return parts.joined(separator: " · ")
    }
}

/// The track's loudness as 3 pt bars, like the mockup.
private struct TrackBars: View {
    var values: [Float]
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let n = Int((size.width + 3) / 6)
            let v = values.isEmpty ? [Float](repeating: 0, count: n) : Waveform.resample(values, to: n)
            for i in 0..<min(n, v.count) {
                let h = max(2, CGFloat(v[i]) * size.height)
                let r = CGRect(x: CGFloat(i) * 6, y: (size.height - h) / 2, width: 3, height: h)
                ctx.fill(Path(r), with: .color(values.isEmpty ? Refined.waveRest : color))
            }
        }
    }
}

private struct DashLine: Shape {
    func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
}

private extension View {
    func optionCard() -> some View {
        padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }
}
