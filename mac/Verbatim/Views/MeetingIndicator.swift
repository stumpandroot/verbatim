import SwiftUI
import AppKit

// The recording indicator (approved mockup "Verbose meeting recording", November 18, 2026; DESIGN.md §6.10): a small
// card at the top right of the display the recording started on, on screen for the whole recording. It shows the
// state and the time, your mic and the call's sound each with its own words and bars, and Stop. When the call's sound
// is missing it grows a warning with the fix (Record <App>, Record everything this Mac plays); no button on it drops
// the call's track. The menu bar item stays as a second sign: macOS can hide a menu bar item behind the notch.
//
// Its window is exactly the card's size and always takes clicks, so there's no pointer-driven click-through to get
// stuck, and nothing outside the card's edges is ever covered.

/// A source the warning offers for the call track.
struct MeetingSourceOffer: Equatable {
    /// `MeetingAppInfo.key`, or "system" for everything this Mac plays.
    var key: String
    var title: String
}

/// What the indicator shows, sampled once a second (and ten times a second for the bars).
@MainActor
final class MeetingIndicatorModel: ObservableObject {
    static let bars = 5
    @Published var elapsed: Double = 0
    @Published var mic: [Float] = Array(repeating: 0, count: bars)
    @Published var call: [Float] = Array(repeating: 0, count: bars)
    /// Sources to offer while the call's sound is missing and none was recorded yet.
    @Published var offers: [MeetingSourceOffer] = []
}

/// The words for each track, in one place.
enum MeetingIndicatorCopy {
    static func headline(_ phase: MeetingSession.Phase) -> String {
        switch phase {
        case .idle, .starting: return "Starting"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving"
        }
    }

    static func micState(_ phase: MeetingSession.Phase, level: Float) -> String {
        switch phase {
        case .idle, .starting: return "ready"
        case .paused: return "paused"
        case .stopping: return "saved"
        case .recording: return level >= 0.02 ? "hearing" : "quiet"
        }
    }

    /// `warning`: the call's sound is missing (never arrived, or stopped arriving).
    static func callState(_ phase: MeetingSession.Phase, health: RemoteHealth, micOnly: Bool, warning: Bool) -> String {
        switch phase {
        case .idle, .starting: return "connecting"
        case .paused: return "paused"
        case .stopping: return "saved"
        case .recording:
            if micOnly { return "not recording" }
            if warning { return "no sound" }
            switch health {
            case .starting: return "connecting"
            case .hearing: return "hearing"
            case .quiet: return "no sound yet"
            case .noBuffers, .stalled: return "reconnecting"
            }
        }
    }

    static let warningTitle = "Verbose isn't hearing the call"
    static func warningDetail(source: String?, micOnly: Bool, canChange: Bool) -> String {
        if micOnly { return "Your mic is still recording. The call's sound isn't being recorded." }
        let from = source.map { "\($0) isn't playing any sound." } ?? "Nothing on this Mac is playing sound."
        if canChange { return "Your mic is still recording. \(from)" }
        return "Your mic is still recording. \(from) Verbose adds the call's sound when it hears it."
    }
    static let everything = "Record everything this Mac plays"
    static func record(_ app: String) -> String { "Record \(app)" }
}

@MainActor
final class MeetingIndicatorController {
    static let width: CGFloat = 430
    let model = MeetingIndicatorModel()
    /// The warning's source buttons: the offer's key.
    var onChangeSource: ((String) -> Void)?
    /// The sources to offer right now (the coordinator knows which call app is on the microphone).
    var offers: (() -> [MeetingSourceOffer])?
    private var panel: MeetingFloatingPanel?
    private var host: MeetingHostingView<AnyView>?
    private var timer: Timer?
    private var ticks = 0
    /// The top right corner the card hangs from, kept so a taller card grows downward and a dragged card stays put.
    private var anchor: NSPoint?

    var isShowing: Bool { panel?.isVisible == true }
    /// For the self-test.
    var window: NSWindow? { panel }
    /// The card's frame on screen, so a banner can sit below it.
    var frame: NSRect? { isShowing ? panel?.frame : nil }

    func show() {
        let p = panel ?? make()
        if !p.isVisible {
            anchor = nil
            sample(full: true)
            fit(p)
            p.alphaValue = 1
            p.orderFrontRegardless()
            Log.note("meeting: recording indicator shown")
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard let p = panel, p.isVisible else { return }
        // Out at once: a hidden card must never be left on screen taking clicks.
        p.orderOut(nil)
        Log.note("meeting: recording indicator hidden")
    }

    private func tick() {
        ticks += 1
        sample(full: ticks % 5 == 0)
        if ticks % 5 == 0, let p = panel, p.isVisible { fit(p) }
    }

    private func sample(full: Bool) {
        let s = MeetingSession.shared
        let l = s.levels()
        model.mic = Array(model.mic.dropFirst()) + [min(1, max(0, l.mic))]
        model.call = Array(model.call.dropFirst()) + [s.micOnly ? 0 : min(1, max(0, l.system))]
        guard full else { return }
        model.elapsed = s.elapsed
        let next = (s.remoteSilent || s.micOnly) && s.canChangeSource ? (offers?() ?? []) : []
        if next != model.offers { model.offers = next }
    }

    private func make() -> MeetingFloatingPanel {
        let p = MeetingFloatingPanel.make(keyable: false, level: .statusBar)
        p.setAccessibilityTitle("Verbose recording")
        p.isMovableByWindowBackground = true
        let view = MeetingIndicatorView(session: MeetingSession.shared, model: model,
                                        stop: { MeetingSession.shared.stop() },
                                        change: { [weak self] key in self?.onChangeSource?(key) }).limitMotionRoot()
        let h = MeetingHostingView(rootView: AnyView(view))
        h.sizingOptions = []
        p.contentView = h
        panel = p; host = h
        return p
    }

    /// Sizes the window to the card and hangs it from its top right corner: the top right of the screen with the
    /// pointer when it first shows, and wherever it was dragged after that.
    private func fit(_ p: MeetingFloatingPanel) {
        guard let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: max(56, ceil(host.fittingSize.height)))
        if p.isVisible, let a = anchor, abs(p.frame.maxX - a.x) > 1 || abs(p.frame.maxY - a.y) > 1 {
            anchor = NSPoint(x: p.frame.maxX, y: p.frame.maxY)   // dragged
        }
        if anchor == nil, let screen = MeetingFloatingPanel.pointerScreen() {
            let f = screen.visibleFrame
            anchor = NSPoint(x: f.maxX - 14, y: f.maxY - 12)
        }
        guard let a = anchor else { return }
        let frame = NSRect(x: a.x - size.width, y: a.y - size.height, width: size.width, height: size.height)
        if p.frame != frame {
            p.setFrame(frame, display: true)
            host.frame = NSRect(origin: .zero, size: size)
            p.invalidateShadow()
        }
    }
}

struct MeetingIndicatorView: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var model: MeetingIndicatorModel
    var stop: () -> Void
    var change: (String) -> Void

    var body: some View {
        let phase = session.phase
        let warning = phase == .recording && (session.remoteSilent || session.micOnly)
        let app = MeetingStatusController.appName(session)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Circle().fill(dotColor(phase, warning: warning)).frame(width: 10, height: 10).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(MeetingIndicatorCopy.headline(phase)).refinedFont(.body, weight: .semibold)
                        Text(MeetingCopy.clock(model.elapsed)).refinedFont(.body).monospacedDigit().foregroundStyle(Refined.dim)
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 14) {
                        track(name: "Mic", state: MeetingIndicatorCopy.micState(phase, level: model.mic.max() ?? 0),
                              levels: model.mic, live: phase == .recording, alert: false)
                        track(name: session.micOnly ? "Call" : (app ?? "Call"),
                              state: MeetingIndicatorCopy.callState(phase, health: session.remoteHealth, micOnly: session.micOnly, warning: warning),
                              levels: model.call, live: phase == .recording && !warning, alert: warning)
                    }
                }
                Spacer(minLength: 8)
                if phase == .paused {
                    MeetingButton(title: "Resume", target: "meeting-indicator-resume") { session.togglePause() }
                }
                MeetingButton(title: "Stop", style: .primary, stopSquare: true, enabled: phase == .recording || phase == .paused,
                              target: "meeting-indicator-stop", action: stop)
            }
            if warning {
                Rectangle().fill(Refined.separator).frame(height: 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(MeetingIndicatorCopy.warningTitle).refinedFont(.body, weight: .semibold)
                    Text(MeetingIndicatorCopy.warningDetail(source: app, micOnly: session.micOnly, canChange: !model.offers.isEmpty))
                        .refinedFont(.hint).foregroundStyle(Refined.dim).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if !model.offers.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(model.offers.enumerated()), id: \.element.key) { i, offer in
                            MeetingButton(title: offer.title, style: i == 0 ? .primary : .secondary,
                                          target: "meeting-indicator-source-\(offer.key == "system" ? "system" : "app")") { change(offer.key) }
                        }
                    }
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 12)
        .frame(width: MeetingIndicatorController.width, alignment: .leading)
        .foregroundStyle(Refined.ink)
        .modifier(FloatingCard())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Verbose recording")
    }

    private func dotColor(_ phase: MeetingSession.Phase, warning: Bool) -> Color {
        switch phase {
        case .recording: return warning ? Refined.accentText : Refined.recordRed
        default: return Refined.faint
        }
    }

    /// One track: bars, its name, and its state in words (the state never depends on color alone).
    private func track(name: String, state: String, levels: [Float], live: Bool, alert: Bool) -> some View {
        HStack(spacing: 6) {
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                    Capsule().fill(alert ? Refined.accentText : (live ? Refined.ink : Refined.faint))
                        .frame(width: 2.5, height: live ? 3 + CGFloat(min(1, v * 3)) * 10 : 3)
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            Text(name).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(1)
            Text(state).refinedFont(.hint, weight: alert ? .semibold : .medium).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(state)")
    }
}
