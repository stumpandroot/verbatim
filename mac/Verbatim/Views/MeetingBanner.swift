import SwiftUI
import AppKit

// Meeting capture's floating surfaces (App/MeetingCoordinator.swift): the banner at the top right of the screen
// with the pointer (a call prompt, the silent-remote warning, the sleep note, short notices) and the consent
// sheet, on the refined kit (DESIGN.md §6.10, §13): the opaque card with a hairline (they float
// over other apps), the kit's ink and secondary text, and its quiet and strong actions; never text on glass. The
// buttons are direct gestures on a flat layer in a panel that takes the first click (`acceptsFirstMouse`), because
// SwiftUI Buttons lose clicks in non-activating panels on macOS 26 (see TapArea in Controls.swift).

// MARK: - Panel

/// A borderless floating panel for meeting surfaces that never activates Verbose, so the meeting app stays in
/// front with its windows. The banner never becomes key; the consent sheet does (Return records, Esc cancels),
/// the way Recent dictations takes keys without switching apps.
final class MeetingFloatingPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    static func make(keyable: Bool, level: NSWindow.Level) -> MeetingFloatingPanel {
        let p = MeetingFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                     styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
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

/// A button for meeting surfaces, drawn like the kit's actions (`RefinedActionStyle`): a direct click gesture on a flat
/// shape (no SwiftUI Button), 32 pt with an 8 pt radius. Primary is the strong action (ink with light text), secondary
/// the quiet one (the neutral wash), quiet bare until the pointer is on it. On the persimmon recording card
/// (`onFill`), the quiet wash is the ready chip's and the strong action's ink is the card's.
struct MeetingButton: View {
    enum Style { case primary, secondary, quiet }
    var title: String
    var style: Style = .secondary
    var icon: BrandArt? = nil
    /// The record dot before the title (the consent sheet's Record).
    var dot = false
    /// The red stop square before the title (Stop and save).
    var stopSquare = false
    var enabled = true
    var stretch = false
    /// The palette of the persimmon card it sits on, or nil on the card or paper.
    var onFill: AppPalette? = nil
    var target: String? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 6) {
            if dot { Circle().fill(Refined.recordRed).frame(width: 7, height: 7).accessibilityHidden(true) }
            if stopSquare { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Refined.recordRed).frame(width: 9, height: 9).accessibilityHidden(true) }
            if let icon { IconGlyph(art: icon, size: 13, color: text) }
            Text(title).lineLimit(1)
        }
        .refinedFont(.hint, weight: .semibold)
        .foregroundStyle(text)
        .padding(.horizontal, 14).frame(minHeight: 32)
        .frame(maxWidth: stretch ? .infinity : nil)
        .background(background, in: shape)
        .opacity(enabled ? (hover && style != .quiet ? 0.88 : 1) : 0.45)
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

    /// The ink where the button sits: the card's on the persimmon fill, the reading ink elsewhere.
    private var ink: Color { onFill.map { Refined.onFill(.persimmon, $0) } ?? Refined.ink }

    private var text: Color {
        guard style == .primary else { return ink }
        if let p = onFill { return p == .full ? Refined.lift : Refined.paper }
        return Refined.paper
    }

    private var background: Color {
        switch style {
        case .primary: return ink
        case .secondary: return onFill.map { Refined.readyChip($0) } ?? Refined.neutral
        case .quiet: return hover ? (onFill.map { Refined.readyChip($0) } ?? Refined.neutral) : Color.clear
        }
    }
}

/// A checkbox in the kit's ink: a box at the 4 pt radius with a check, the label beside it.
struct MeetingCheckbox: View {
    var title: String
    @Binding var isOn: Bool
    var target: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Refined.ink, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(isOn ? Refined.ink : Color.clear))
                .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Refined.paper) } }
                .frame(width: 15, height: 15)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(title).refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
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
    /// "Recording your Zoom call": a call you set up started recording with no prompt. Hides after 5 seconds.
    case started(app: String, title: String?, copied: Bool)
    /// "Zoom left the call": Keep recording or Stop now; it stops on its own 15 seconds later (Stop when the call ends).
    case callEnded(app: String, title: String?)

    var autoHide: Double? {
        switch self {
        case .call: return 20
        case .notice: return 7
        case .started: return 5
        case .silent, .slept, .callEnded: return nil
        }
    }

    var isCall: Bool { if case .call = self { return true }; return false }
}

enum MeetingBannerAction { case notNow, record, openSettings, keepMicOnly, resume, stopAndSave, dismiss, keepRecording, stopNow }

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
        case .started(let app, let title, let copied): return MeetingCopy.startedTitle(app) + ". " + MeetingCopy.startedDetail(app: app, title: title, copied: copied)
        case .callEnded(let app, let title): return MeetingCopy.leftTitle(app) + ". " + MeetingCopy.leftDetail(title: title, seconds: Int(CallEndWatch.grace))
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
                    .modifier(FloatingCard())
            } else {
                Color.clear.frame(width: MeetingBannerController.width, height: 60)
            }
        }
        .foregroundStyle(Refined.ink)
    }

    @ViewBuilder private func content(_ kind: MeetingBannerKind) -> some View {
        switch kind {
        case .call(let app):
            row(icon: .iconSpeakers, title: MeetingCopy.promptTitle(app), detail: MeetingCopy.promptDetail) {
                MeetingButton(title: "Not now", target: "meeting-prompt-notnow") { act(.notNow) }
                MeetingButton(title: "Record…", style: .primary, target: "meeting-prompt-record") { act(.record) }
            }
        case .silent(let app):
            row(icon: .iconAttention, iconColor: Refined.accentText, title: MeetingCopy.silentTitle(app), detail: MeetingCopy.silentDetail) {
                MeetingButton(title: "Open Settings", target: "meeting-silent-settings") { act(.openSettings) }
                MeetingButton(title: "Keep my mic only", style: .quiet, target: "meeting-silent-miconly") { act(.keepMicOnly) }
            }
        case .slept:
            row(icon: .iconPause, title: MeetingCopy.sleptTitle, detail: MeetingCopy.sleptDetail) {
                MeetingButton(title: "Resume", icon: .iconPlay, target: "meeting-slept-resume") { act(.resume) }
                MeetingButton(title: "Stop and save", style: .primary, stopSquare: true, target: "meeting-slept-stop") { act(.stopAndSave) }
            }
        case .notice(let text):
            row(icon: .iconDetails, title: text, detail: nil) {
                MeetingButton(title: "OK", style: .quiet, target: "meeting-notice-ok") { act(.dismiss) }
            }
        case .callEnded(let app, let title):
            row(icon: .iconSpeakers, title: MeetingCopy.leftTitle(app), detail: MeetingCopy.leftDetail(title: title, seconds: Int(CallEndWatch.grace))) {
                MeetingButton(title: "Keep recording", target: "meeting-ended-keep") { act(.keepRecording) }
                MeetingButton(title: "Stop now", style: .primary, stopSquare: true, target: "meeting-ended-stop") { act(.stopNow) }
            }
        case .started(let app, let title, let copied):
            // No buttons: Stop and Pause stay in the meeting's menu bar item, as for any meeting.
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(Refined.recordRed).frame(width: 9, height: 9).padding(.top, 5).padding(.horizontal, 6.5).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MeetingCopy.startedTitle(app)).refinedFont(.rowTitle, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(MeetingCopy.startedDetail(app: app, title: title, copied: copied)).refinedFont(.meta).foregroundStyle(Refined.dim)
                        .lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row<Buttons: View>(icon: BrandArt, iconColor: Color = Refined.ink, title: String, detail: String?, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconGlyph(art: icon, size: 22, color: iconColor).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).refinedFont(.rowTitle, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).refinedFont(.meta).foregroundStyle(Refined.dim).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
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
    /// Setting up a wait for a call that isn't on yet (Record a call, Record when it starts): the sheet asks which app
    /// to wait for, and Record becomes Wait for the call. Nil to record now.
    var wait: CallWaitSetup? = nil
    /// Stills of shared screens are on (Settings › Meetings): the sheet says so.
    var stills = false
}

/// The wait's setup in the consent sheet: the app picker's choices and the one chosen, and the event it's for.
struct CallWaitSetup: Equatable {
    var choices: [CallWaitChoice]
    var selected: String
    /// The calendar event's title, when it's for one.
    var title: String?
}

struct MeetingConsentResult: Equatable {
    var copyNotice: Bool
    var dontAskAgain: Bool
    /// The app picker's choice (`CallWaitChoice.id`), when setting up a wait.
    var choiceID: String? = nil
}

@MainActor
final class MeetingConsentModel: ObservableObject {
    @Published var request: MeetingConsentRequest?
    @Published var copyNotice = true
    @Published var dontAskAgain = false
    @Published var choiceID = "any"
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
        model.choiceID = request.wait?.selected ?? "any"
        self.completion = completion
        let p = panel ?? make()
        place(p)
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
        let result = record ? MeetingConsentResult(copyNotice: model.copyNotice, dontAskAgain: model.dontAskAgain && (model.request?.offerSkip ?? false),
                                                   choiceID: model.request?.wait == nil ? nil : model.choiceID) : nil
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
            if let wait = model.request?.wait {
                waitSetup(wait)
            } else {
                Text(MeetingCopy.consentTitle).font(.system(size: 26, design: .serif)).accessibilityAddTraits(.isHeader)
                Text(MeetingCopy.consentBody(model.request?.appName)).modifier(ConsentText())
                if model.request?.stills == true { Text(MeetingCopy.stillsOn).modifier(ConsentText()) }
                Text(MeetingCopy.consentLaw).modifier(ConsentText())
                MeetingCheckbox(title: MeetingCopy.tellEveryone, isOn: $model.copyNotice, target: "meeting-consent-notice")
                if model.request?.offerSkip == true, let app = model.request?.appName {
                    MeetingCheckbox(title: MeetingCopy.dontAskAgain(app), isOn: $model.dontAskAgain, target: "meeting-consent-skip")
                }
            }
            HStack(spacing: 8) {
                Spacer()
                MeetingButton(title: "Cancel", target: "meeting-consent-cancel", action: cancel)
                if model.request?.wait != nil {
                    MeetingButton(title: "Wait for the call", style: .primary, target: "meeting-consent-wait", action: record)
                } else {
                    MeetingButton(title: "Record", style: .primary, dot: true, target: "meeting-consent-record", action: record)
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: MeetingConsentController.width, alignment: .leading)
        .foregroundStyle(Refined.ink)
        .modifier(FloatingCard())
    }

    /// "Record your next call" (mockup board 3): what happens, which app to wait for, the consent words (you say yes
    /// here, not when the call starts), and the chat notice.
    @ViewBuilder private func waitSetup(_ wait: CallWaitSetup) -> some View {
        Text(MeetingCopy.waitTitle).font(.system(size: 26, design: .serif)).accessibilityAddTraits(.isHeader)
        if let title = wait.title {
            Text(title).refinedFont(.rowTitle, weight: .semibold).fixedSize(horizontal: false, vertical: true)
        }
        Text(wait.title == nil ? MeetingCopy.waitBodyNoCall : MeetingCopy.waitBody).modifier(ConsentText())
        HStack(spacing: 10) {
            Text("Wait for").refinedFont(.body).foregroundStyle(Refined.ink)
            CallChoicePopUp(choices: wait.choices, selection: $model.choiceID)
                .fixedSize()
                .accessibilityLabel("Wait for")
                .modifier(MeetingTarget(id: "meeting-consent-app"))
            Spacer(minLength: 0)
        }
        if model.request?.stills == true { Text(MeetingCopy.stillsOn).modifier(ConsentText()) }
        Text(MeetingCopy.consentLaw).modifier(ConsentText())
        MeetingCheckbox(title: MeetingCopy.copyOnStart, isOn: $model.copyNotice, target: "meeting-consent-notice")
    }

    private struct ConsentText: ViewModifier {
        func body(content: Content) -> some View {
            content.refinedFont(.body).foregroundStyle(Refined.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A card that floats over other apps (the meeting banner, the consent sheet, the Thought bubble's cards): the kit's
/// card at the Mac's card radius with a hairline edge in every mode, since what's behind it could be anything.
struct FloatingCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous)
        content
            .background(Refined.card, in: shape)
            .overlay(shape.strokeBorder(Refined.separator, lineWidth: 1))
    }
}

/// The wait's app picker ("Any call app ⌄"): an AppKit pop-up button, which takes clicks in the consent panel
/// (SwiftUI's menus and pickers can miss them in a non-activating panel, as its buttons do; see TapArea in
/// Controls.swift). A separator before Google Meet sets the browsers apart.
struct CallChoicePopUp: NSViewRepresentable {
    var choices: [CallWaitChoice]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.controlSize = .regular
        b.target = context.coordinator
        b.action = #selector(Coordinator.picked(_:))
        return b
    }

    func updateNSView(_ b: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let ids = choices.map(\.id)
        if context.coordinator.ids != ids {
            b.removeAllItems()
            for c in choices {
                if c.id == CallWaitChoices.meet.id { b.menu?.addItem(.separator()) }
                let item = NSMenuItem(title: c.name, action: nil, keyEquivalent: "")
                item.representedObject = c.id
                b.menu?.addItem(item)
            }
            context.coordinator.ids = ids
        }
        if let item = b.itemArray.first(where: { ($0.representedObject as? String) == selection }) { b.select(item) }
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var ids: [String] = []
        init(selection: Binding<String>) { self.selection = selection }
        @objc func picked(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String { selection.wrappedValue = id }
        }
    }
}
