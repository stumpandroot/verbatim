import SwiftUI

// The watch's screens (mockup "Library features", section 4a; DESIGN.md §20). Always dark: the page is the app's dark
// paper, text is paper, and persimmon means record. Record is the one persimmon fill at rest; New thought is outlined,
// as on Home (§14.9). While recording, Stop is the fill and Mark is outlined.

struct WatchRoot: View {
    @ObservedObject var recorder: WatchRecorder
    @ObservedObject var link: WatchLink

    var body: some View {
        Group {
            switch recorder.phase {
            case .idle:
                NavigationStack { WatchHome(recorder: recorder, link: link) }
            case .recording:
                WatchRecording(recorder: recorder)
            case .sent(let t, let reachable, let note):
                WatchSent(transfer: t, reachable: reachable, note: note) { recorder.dismiss() }
            case .problem(let message):
                WatchProblem(message: message) { recorder.dismiss() }
            }
        }
        .background(WatchColor.page.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .limitMotionRoot()
        // The complications and the Smart Stack open the app to their recorder.
        .onOpenURL { url in
            guard let kind = WatchRules.kind(for: url) else { return }
            if !recorder.isRecording { recorder.start(kind) }
        }
    }
}

/// Record and New thought, today's count, and how many recordings wait for the iPhone.
struct WatchHome: View {
    @ObservedObject var recorder: WatchRecorder
    @ObservedObject var link: WatchLink

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button { recorder.start(.voiceNote) } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(WatchColor.onRecord)
                            IconGlyph(art: .capture, size: 22, color: WatchColor.record)
                        }
                        .frame(width: 42, height: 42)
                        Text("Record").font(.system(size: 20, weight: .semibold)).foregroundStyle(WatchColor.onRecord)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(WatchColor.record, in: RoundedRectangle(cornerRadius: Radius.watch, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.watch, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record a voice note")

                Button { recorder.start(.thought) } label: {
                    HStack(spacing: 10) {
                        IconGlyph(art: .iconThought, size: 22, color: WatchColor.text)
                        Text("New thought").font(.system(size: 16, weight: .semibold)).foregroundStyle(WatchColor.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .overlay(RoundedRectangle(cornerRadius: Radius.watch, style: .continuous).strokeBorder(WatchColor.hair, lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.watch, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New thought")

                Text(WatchRules.todayLine(link.thoughtsToday))
                    .font(.system(size: 12)).foregroundStyle(WatchColor.dim).monospacedDigit()
                    .padding(.top, 4)
                if let waiting = WatchRules.waitingLine(link.waiting) {
                    Text(waiting).font(.system(size: 12)).foregroundStyle(WatchColor.dim).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 2)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Refined.wordmark(17, color: WatchColor.text).accessibilityLabel("Verbose")
            }
        }
    }
}

/// The time, your level, Mark, and Stop. Lower your wrist and it keeps recording.
struct WatchRecording: View {
    @ObservedObject var recorder: WatchRecorder

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(WatchColor.record).frame(width: 8, height: 8)
                Text(recorder.kind == .thought ? "New thought" : "Recording")
            }
            .font(.system(size: 13)).foregroundStyle(WatchColor.dim)
            .accessibilityElement(children: .combine)

            TimelineView(.periodic(from: recorder.startedAt, by: 1)) { _ in
                Text(WatchRules.clock(recorder.elapsed))
                    .font(Refined.mono(40, weight: .medium)).foregroundStyle(WatchColor.text)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .accessibilityLabel("Recorded \(WatchRules.clock(recorder.elapsed))")
            }

            WatchVoiceBars(levels: recorder.levels).frame(height: 30)

            Spacer(minLength: 4)

            HStack {
                VStack(spacing: 4) {
                    Button { recorder.mark() } label: {
                        Circle().strokeBorder(WatchColor.hair, lineWidth: 1.5)
                            .background(Circle().fill(recorder.confirmed == nil ? Color.clear : WatchColor.pressed))
                            .overlay(IconGlyph(art: .iconMark, size: 24, color: WatchColor.text))
                            .frame(width: 58, height: 58)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    // Double-tap your fingers to mark, on a watch that supports it.
                    .handGestureShortcut(.primaryAction)
                    .accessibilityLabel("Mark a moment")
                    Text("Mark").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WatchColor.dim).accessibilityHidden(true)
                }
                Spacer()
                VStack(spacing: 4) {
                    Button { recorder.stop() } label: {
                        Circle().fill(WatchColor.record)
                            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(WatchColor.onRecord).frame(width: 18, height: 18))
                            .frame(width: 58, height: 58)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop and send to iPhone")
                    Text("Stop").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WatchColor.dim).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.top, 4)
        .overlay(alignment: .top) {
            if let at = recorder.confirmed {
                HStack(spacing: 7) {
                    IconGlyph(art: .iconMarked, size: 16, color: WatchColor.onToast)
                    Text("Marked \(Text(WatchRules.clock(at)).font(Refined.mono(15, weight: .medium)))")
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(WatchColor.onToast)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(WatchColor.toast, in: Capsule())
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(WatchRules.marked(at))
            }
        }
    }
}

/// Persimmon voice bars that follow your level, newest on the right. Still under Reduce Motion (DESIGN.md §7).
struct WatchVoiceBars: View {
    var levels: [Float]
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.isLuminanceReduced) private var dimmed
    /// The resting shape when bars hold still.
    private static let rest: [Float] = [0.3, 0.5, 0.4, 0.7, 0.55, 0.8, 0.6, 0.85, 0.5, 0.65, 0.4, 0.55, 0.3]

    var body: some View {
        let shown = (limitMotion || dimmed) ? Self.rest : levels
        Canvas { ctx, size in
            let n = max(1, shown.count)
            let bar: CGFloat = 4, gap: CGFloat = 3
            let total = CGFloat(n) * bar + CGFloat(n - 1) * gap
            var x = (size.width - total) / 2
            for v in shown {
                let h = max(bar, size.height * CGFloat(0.15 + 0.85 * Double(v)))
                let r = CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: bar / 2), with: .color(WatchColor.record))
                x += bar + gap
            }
        }
        .accessibilityHidden(true)
    }
}

/// Sent to iPhone: the audio stays on the watch until the iPhone has it.
struct WatchSent: View {
    var transfer: WatchTransfer
    var reachable: Bool
    var note: String?
    var done: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Circle().strokeBorder(WatchColor.hair, lineWidth: 1.5)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 24, weight: .semibold)).foregroundStyle(WatchColor.record))
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
                Text("Sent to iPhone").font(.system(size: 17, weight: .semibold)).foregroundStyle(WatchColor.text).padding(.top, 10)
                Text(WatchRules.sentDetail(transfer.kind, reachable: reachable))
                    .font(.system(size: 13)).foregroundStyle(WatchColor.dim).multilineTextAlignment(.center).padding(.top, 3)
                if let note {
                    Text(note).font(.system(size: 13)).foregroundStyle(WatchColor.dim).multilineTextAlignment(.center).padding(.top, 6)
                }
                Text(WatchRules.sentLine(transfer)).font(Refined.mono(12)).foregroundStyle(WatchColor.dim).padding(.top, 10)
                Button("Done", action: done).padding(.top, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
        }
        .task {
            // Back to Record and New thought after a few seconds.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            done()
        }
    }
}

/// The microphone is off, the watch is full, or recording couldn't start.
struct WatchProblem: View {
    var message: String
    var done: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                IconGlyph(art: .iconAttention, size: 28, color: WatchColor.text)
                Text(message).font(.system(size: 15)).foregroundStyle(WatchColor.text).multilineTextAlignment(.center)
                Button("OK", action: done)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
        }
    }
}
