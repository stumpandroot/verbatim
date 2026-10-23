import SwiftUI
import AppKit

// Meeting capture's floating surfaces (App/MeetingCoordinator.swift): the banner at the top right of the screen
// with the pointer (a call prompt, the silent-remote warning, the sleep note, short notices) and the consent
// sheet. Opaque `Ink.card` with a hairline, never text on glass (mac/DESIGN.md §5). The buttons are direct
// gestures on a flat layer in a panel that takes the first click (`acceptsFirstMouse`), because SwiftUI Buttons
// lose clicks in non-activating panels on macOS 26 (see TapArea and CardButton in Theme.swift).

// MARK: - Panel

/// A borderless floating panel for meeting surfaces. The banner never becomes key, so the meeting app keeps the
/// keyboard; the consent sheet does (Return records, Esc cancels).
final class MeetingFloatingPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    static func make(keyable: Bool, level: NSWindow.Level) -> MeetingFloatingPanel {
        let p = MeetingFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                     styleMask: keyable ? [.borderless] : [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.keyable = keyable
        p.level = level
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = !keyable
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.animationBehavior = .none
        return p
    }

    /// The screen with the pointer.
    static func pointerScreen() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// Takes the first click even though the panel isn't key, and reports the pointer entering and leaving (any app
/// active), so a banner's timer can pause while you read it.
final class MeetingHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
}

// MARK: - Controls

/// A button for meeting surfaces: a direct click gesture on a flat shape (no SwiftUI Button), hover tint, and the
/// brand's ink (primary), card (secondary), or bare (quiet) look at the button radius.
struct MeetingButton: View {
    enum Style { case primary, secondary, quiet }
    var title: String
    var style: Style = .secondary
    var icon: BrandArt? = nil
    /// The record dot before the title (the consent sheet's Record).
    var dot = false
    var enabled = true
    var stretch = false
    var target: String? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
        HStack(spacing: 6) {
            if dot { Circle().fill(Ink.persimmon).frame(width: 7, height: 7) }
            if let icon { ArtIcon(art: icon, size: 13) }
            Text(title).lineLimit(1)
        }
        .font(.system(size: 13, weight: style == .primary ? .semibold : .medium))
        .foregroundStyle(style == .primary ? Ink.onInteractive : Ink.ink)
        .padding(.horizontal, 12).frame(minHeight: 28)
        .frame(maxWidth: stretch ? .infinity : nil)
        .background(background, in: shape)
        .overlay(shape.strokeBorder(style == .secondary ? (hover ? Ink.outlineStrong : Ink.hairline) : Color.clear))
        .opacity(enabled ? 1 : 0.45)
        .contentShape(shape)
        .onHover { hover = enabled && $0 }
        .animation(Motion.touch, value: hover)
        .tapArea { if enabled { action() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { action() } }
        .modifier(MeetingTarget(id: target))
    }

    private var background: Color {
        switch style {
        case .primary: return Ink.interactive.opacity(hover ? 0.92 : 1)
        case .secondary: return hover ? Ink.cardHover : Ink.card
        case .quiet: return Ink.ink.opacity(hover ? 0.07 : 0)
        }
    }
}

/// A checkbox drawn in the brand: an ink box at the button radius with a check, the label beside it.
struct MeetingCheckbox: View {
    var title: String
    @Binding var isOn: Bool
    var target: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .strokeBorder(Ink.ink, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(isOn ? Ink.ink : Color.clear))
                .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.onInteractive) } }
                .frame(width: 15, height: 15)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(title).font(.system(size: 13.5)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .tapArea { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
        .modifier(MeetingTarget(id: target))
    }
}

/// `uiTarget` when there's an identifier (the self-test clicks these), plus the accessibility identifier.
struct MeetingTarget: ViewModifier {
    var id: String?
    func body(content: Content) -> some View {
        if let id { content.uiTarget(id).accessibilityIdentifier(id) } else { content }
    }
}

// MARK: - Banner

enum MeetingBannerKind: Equatable {
    /// "Zoom is using your microphone": Not now or Record…. Hides after 20 seconds.
    case call(app: String)
    /// "Verbose isn't hearing anything from Zoom": Open Settings or Keep my mic only.
    case silent(app: String)
    /// "Your Mac went to sleep, so the recording paused": Resume or Stop and save.
    case slept
    /// A short message (a failed start, a saved meeting, the notice copied). Hides after a few seconds.
    case notice(String)

    var autoHide: Double? {
        switch self {
        case .call: return 20
        case .notice: return 7
        case .silent, .slept: return nil
        }
    }

    var isCall: Bool { if case .call = self { return true }; return false }
}

enum MeetingBannerAction { case notNow, record, openSettings, keepMicOnly, resume, stopAndSave, dismiss }

@MainActor
final class MeetingBannerModel: ObservableObject {
    @Published var kind: MeetingBannerKind?
}

/// One banner at a time at the top right of the screen with the pointer. It never takes the keyboard, fades in
/// and out (a fade is all Limit Motion allows, and all it needs), and a call prompt hides itself after 20 seconds
/// unless the pointer is on it.
@MainActor
final class MeetingBannerController {
    static let width: CGFloat = 360
    let model = MeetingBannerModel()
    var onAction: ((MeetingBannerAction) -> Void)?
    private var panel: MeetingFloatingPanel?
    private var host: MeetingHostingView<AnyView>?
    private var timer: Timer?
    private var remaining: Double = 0
    private var hovering = false
    private var generation = 0

    var kind: MeetingBannerKind? { model.kind }
    var isShowing: Bool { model.kind != nil && panel?.isVisible == true }
    /// For the self-test.
    var window: NSWindow? { panel }

    func show(_ kind: MeetingBannerKind) {
        generation += 1
        model.kind = kind
        let p = panel ?? make()
        place(p)
        if !p.isVisible || p.alphaValue < 1 {
            if !p.isVisible { p.alphaValue = 0 }
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; c.timingFunction = CAMediaTimingFunction(name: .easeOut); p.animator().alphaValue = 1 }
        }
        timer?.invalidate(); timer = nil
        if let t = kind.autoHide {
            remaining = t
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: Self.spoken(kind), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard let p = panel, model.kind != nil else { return }
        generation += 1
        let g = generation
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.18; p.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == g else { return }
                p.orderOut(nil)
                self.model.kind = nil
            }
        })
    }

    /// Hides the banner only if it's showing this kind of thing.
    func hide(where match: (MeetingBannerKind) -> Bool) {
        if let k = model.kind, match(k) { hide() }
    }

    private func act(_ a: MeetingBannerAction) { onAction?(a) }

    private func tick() {
        guard !hovering else { return }
        remaining -= 0.5
        if remaining <= 0 {
            if case .call(let app) = model.kind { Log.note("meeting: the prompt for \(app) timed out") }
            hide()
        }
    }

    private func make() -> MeetingFloatingPanel {
        let p = MeetingFloatingPanel.make(keyable: false, level: .statusBar)
        p.setAccessibilityTitle("Verbose meeting")
        let view = MeetingBannerView(model: model) { [weak self] a in self?.act(a) }.limitMotionRoot()
        let h = MeetingHostingView(rootView: AnyView(view))
        h.sizingOptions = []
        h.onHover = { [weak self] on in self?.hovering = on }
        p.contentView = h
        panel = p; host = h
        return p
    }

    private func place(_ p: MeetingFloatingPanel) {
        guard let host, let screen = MeetingFloatingPanel.pointerScreen() else { return }
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: max(60, ceil(host.fittingSize.height)))
        let f = screen.visibleFrame
        let origin = NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 12)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        host.frame = NSRect(origin: .zero, size: size)
        p.invalidateShadow()
    }

    private static func spoken(_ k: MeetingBannerKind) -> String {
        switch k {
        case .call(let app): return MeetingCopy.promptTitle(app) + ". " + MeetingCopy.promptDetail
        case .silent(let app): return MeetingCopy.silentTitle(app)
        case .slept: return MeetingCopy.sleptTitle
        case .notice(let s): return s
        }
    }
}

struct MeetingBannerView: View {
    @ObservedObject var model: MeetingBannerModel
    var act: (MeetingBannerAction) -> Void

    var body: some View {
        Group {
            if let kind = model.kind {
                content(kind)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(width: MeetingBannerController.width, alignment: .leading)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline))
            } else {
                Color.clear.frame(width: MeetingBannerController.width, height: 60)
            }
        }
        .foregroundStyle(Ink.ink)
    }

    @ViewBuilder private func content(_ kind: MeetingBannerKind) -> some View {
        switch kind {
        case .call(let app):
            row(icon: .iconSpeakers, title: MeetingCopy.promptTitle(app), detail: MeetingCopy.promptDetail) {
                MeetingButton(title: "Not now", target: "meeting-prompt-notnow") { act(.notNow) }
                MeetingButton(title: "Record…", style: .primary, target: "meeting-prompt-record") { act(.record) }
            }
        case .silent(let app):
            row(icon: .iconAttention, iconColor: Ink.danger, title: MeetingCopy.silentTitle(app), detail: MeetingCopy.silentDetail) {
                MeetingButton(title: "Open Settings", target: "meeting-silent-settings") { act(.openSettings) }
                MeetingButton(title: "Keep my mic only", style: .quiet, target: "meeting-silent-miconly") { act(.keepMicOnly) }
            }
        case .slept:
            row(icon: .iconPause, title: MeetingCopy.sleptTitle, detail: MeetingCopy.sleptDetail) {
                MeetingButton(title: "Resume", icon: .iconPlay, target: "meeting-slept-resume") { act(.resume) }
                MeetingButton(title: "Stop and save", style: .primary, icon: .iconStop, target: "meeting-slept-stop") { act(.stopAndSave) }
            }
        case .notice(let text):
            row(icon: .iconDetails, title: text, detail: nil) {
                MeetingButton(title: "OK", style: .quiet, target: "meeting-notice-ok") { act(.dismiss) }
            }
        }
    }

    private func row<Buttons: View>(icon: BrandArt, iconColor: Color = Ink.ink, title: String, detail: String?, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconGlyph(art: icon, size: 22, color: iconColor).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) { buttons() }.padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Consent sheet

struct MeetingConsentRequest: Equatable {
    /// The app's key for counts (`MeetingAppInfo.key`), or "system" for all system audio.
    var key: String
    /// Named in the body; nil when the system track is everything the Mac plays.
    var appName: String?
    /// "Don't ask again for <App>" appears (after five recordings with this app).
    var offerSkip: Bool
}

struct MeetingConsentResult: Equatable {
    var copyNotice: Bool
    var dontAskAgain: Bool
}

@MainActor
final class MeetingConsentModel: ObservableObject {
    @Published var request: MeetingConsentRequest?
    @Published var copyNotice = true
    @Published var dontAskAgain = false
}

/// "Record this meeting?" in its own small window near the top of the screen with the pointer, in front of the
/// meeting app. It shows the first time for each app and on every start after; "Don't ask again for <App>"
/// appears only after five recorded calls with that app.
@MainActor
final class MeetingConsentController {
    static let width: CGFloat = 460
    let model = MeetingConsentModel()
    private var panel: MeetingFloatingPanel?
    private var host: MeetingHostingView<AnyView>?
    private var monitor: Any?
    private var completion: ((MeetingConsentResult?) -> Void)?

    var isShowing: Bool { panel?.isVisible == true && model.request != nil }
    /// For the self-test.
    var window: NSWindow? { panel }

    func show(_ request: MeetingConsentRequest, copyDefault: Bool, completion: @escaping (MeetingConsentResult?) -> Void) {
        if isShowing { finish(record: false) }
        model.request = request
        model.copyNotice = copyDefault
        model.dontAskAgain = false
        self.completion = completion
        let p = panel ?? make()
        place(p)
        NSApp.activate(ignoringOtherApps: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; p.animator().alphaValue = 1 }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                MainActor.assumeIsolated { () -> NSEvent? in
                    guard let self, let p = self.panel, e.window === p, self.isShowing else { return e }
                    switch e.keyCode {
                    case 36, 76: self.finish(record: true); return nil      // Return, Enter
                    case 53: self.finish(record: false); return nil         // Esc
                    default: return e
                    }
                }
            }
        }
        Log.note("meeting: consent sheet for \(request.appName ?? "all system audio")")
    }

    func finish(record: Bool) {
        guard model.request != nil else { return }
        let result = record ? MeetingConsentResult(copyNotice: model.copyNotice, dontAskAgain: model.dontAskAgain && (model.request?.offerSkip ?? false)) : nil
        let done = completion
        completion = nil
        model.request = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        panel?.orderOut(nil)
        Log.note("meeting: consent sheet \(record ? "Record" : "Cancel")")
        done?(result)
    }

    private func make() -> MeetingFloatingPanel {
        let p = MeetingFloatingPanel.make(keyable: true, level: .floating)
        p.setAccessibilityTitle(MeetingCopy.consentTitle)
        let view = MeetingConsentView(model: model, record: { [weak self] in self?.finish(record: true) },
                                      cancel: { [weak self] in self?.finish(record: false) }).limitMotionRoot()
        let h = MeetingHostingView(rootView: AnyView(view))
        h.sizingOptions = []
        p.contentView = h
        panel = p; host = h
        return p
    }

    private func place(_ p: MeetingFloatingPanel) {
        guard let host, let screen = MeetingFloatingPanel.pointerScreen() else { return }
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: max(120, ceil(host.fittingSize.height)))
        let f = screen.visibleFrame
        let origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - min(160, f.height * 0.16))
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        host.frame = NSRect(origin: .zero, size: size)
        p.invalidateShadow()
    }
}

struct MeetingConsentView: View {
    @ObservedObject var model: MeetingConsentModel
    var record: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MeetingCopy.consentTitle).font(Ink.serif(26)).accessibilityAddTraits(.isHeader)
            Text(MeetingCopy.consentBody(model.request?.appName)).modifier(ConsentText())
            Text(MeetingCopy.consentLaw).modifier(ConsentText())
            MeetingCheckbox(title: MeetingCopy.tellEveryone, isOn: $model.copyNotice, target: "meeting-consent-notice")
            if model.request?.offerSkip == true, let app = model.request?.appName {
                MeetingCheckbox(title: MeetingCopy.dontAskAgain(app), isOn: $model.dontAskAgain, target: "meeting-consent-skip")
            }
            HStack(spacing: 8) {
                Spacer()
                MeetingButton(title: "Cancel", target: "meeting-consent-cancel", action: cancel)
                MeetingButton(title: "Record", style: .primary, dot: true, target: "meeting-consent-record", action: record)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: MeetingConsentController.width, alignment: .leading)
        .foregroundStyle(Ink.ink)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline))
    }

    private struct ConsentText: ViewModifier {
        func body(content: Content) -> some View {
            content.font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
