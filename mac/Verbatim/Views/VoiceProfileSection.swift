import SwiftUI
import AppKit
import Combine

// brand: web style

// Mac: the voice profile in Settings (`VoiceProfileSection`) and the enrollment sheet it opens
// (`VoiceEnrollmentSheet`). Shared pieces and the recording live in VoiceEnrollment.swift.

/// Your voice profile in Settings: how well Verbatim knows your voice (or what setting it up does), Set Up / Read
/// More, and, unless `showsControls` is false, the switches that use it and Delete voice profile.
/// Self-contained: no environment objects, so any Settings pane can host it. Website style (DESIGN.md §11): a card
/// with the 1.5 pt ink outline (`settingsCard`), a serif line, and mini pills, like the other Settings panes.
struct VoiceProfileSection: View {
    var showsControls = true
    @ObservedObject private var status = VoiceProfileStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if status.isEnrolled || status.isPartial {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 18) {
                        VoiceRingsMark(lineWidth: 1.5, color: Ink.ink).frame(width: 66, height: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(text: "How well it knows you")
                            Text(status.line).font(Ink.serif(24)).tracking(-0.3).foregroundStyle(Ink.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("How well Verbose knows your voice: \(status.line)")
                    }
                    HStack(spacing: 8) {
                        Button("Read More…") { VoiceEnrollmentSheet.present(readMore: true) }
                            .buttonStyle(.settingsPill)
                            .help("Read one more passage so Verbose knows your voice better.")
                        Button("Start Over…") { VoiceEnrollmentSheet.present() }
                            .buttonStyle(.settingsPill)
                            .help("Record your voice again from the beginning.")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsCard()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Your voice")
                    Text("Teach Verbose your voice.").font(Ink.serif(24)).tracking(-0.3).foregroundStyle(Ink.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Read three short passages aloud, about 30 seconds in all. Verbose can then keep only your voice in dictation and mark your lines as “You” in transcripts. Your voice profile stays on this Mac.")
                        .font(.system(size: 13.5)).lineSpacing(2).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Your Voice…") { VoiceEnrollmentSheet.present() }
                        .buttonStyle(.settingsPrimaryPill)
                        .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsCard()
            }
            if showsControls { VoiceProfileControls() }
        }
        .onAppear { status.refresh() }
    }
}

/// The switches that use the profile, and Delete voice profile with its confirmation in place: rows in a Settings
/// card (label and detail on the left, a standard switch or a mini pill on the right).
struct VoiceProfileControls: View {
    /// Called after the profile is deleted (the sheet closes itself).
    var onDelete: (() -> Void)? = nil
    @ObservedObject private var status = VoiceProfileStatus.shared
    @AppStorage(VoiceProfile.dictationFilterKey) private var onlyMyVoice = false
    @AppStorage(VoiceProfile.labelYouKey) private var labelYou = true
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            row(first: true) {
                SettingsRowText(label: "Only keep my voice in dictation",
                                detail: status.isEnrolled
                                    ? "When someone nearby talks while you dictate, Verbose pastes only your words."
                                    : "Available once Verbose knows your voice.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Only keep my voice in dictation", isOn: $onlyMyVoice)
                    .toggleStyle(.switch).labelsHidden().tint(Ink.switchOn)
                    .disabled(!status.isEnrolled)
            }
            row {
                SettingsRowText(label: "Label my lines as “You”", detail: "New transcripts name your speaker You.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Label my lines as “You”", isOn: $labelYou)
                    .toggleStyle(.switch).labelsHidden().tint(Ink.switchOn)
                    .disabled(!status.isEnrolled)
            }
            if status.isEnrolled || status.isPartial {
                if confirming {
                    row {
                        VStack(alignment: .leading, spacing: 10) {
                            SettingsRowText(label: "Delete your voice profile from this Mac?",
                                            detail: "Dictation keeps every voice and transcripts stop naming you You. You can set it up again any time.")
                            HStack(spacing: 8) {
                                Spacer()
                                Button("Cancel") { confirming = false }
                                    .keyboardShortcut(.cancelAction)
                                    .buttonStyle(.settingsPill)
                                Button("Delete", role: .destructive) {
                                    status.delete()
                                    confirming = false
                                    onDelete?()
                                }
                                .buttonStyle(SettingsDangerPillStyle())
                                .accessibilityLabel("Delete voice profile")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    row {
                        SettingsRowText(label: "Delete voice profile", detail: "Removes it from this Mac. Your transcripts stay.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Delete…", role: .destructive) { confirming = true }
                            .buttonStyle(SettingsDangerPillStyle())
                            .accessibilityLabel("Delete voice profile")
                    }
                }
            }
        }
        .settingsCard()
    }

    /// One row: content in an HStack, the Settings row's padding and height, and a hairline above all but the first.
    private func row<C: View>(first: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) { content() }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(minHeight: 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { if !first { RowRule() } }
    }
}

// MARK: - Sheet

/// The enrollment flow in a sheet on the Settings window.
@MainActor
enum VoiceEnrollmentSheet {
    private static var window: NSWindow?
    private static var model: VoiceEnrollment?
    private static var parentCloseObserver: NSObjectProtocol?
    /// Resizes the sheet to fit its content after the model changes (see `fit`).
    private static var sizeWatch: AnyCancellable?
    private static let width: CGFloat = 620

    /// Opens the sheet on `parent` (the key window: Settings, or the main window from the You page). `readMore`
    /// goes straight to one more passage; `preview` (UI tour) shows step 2 with made-up progress and never records.
    static func present(readMore: Bool = false, preview: Bool = false, from parent: NSWindow? = nil) {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        // A sheet goes on a real document window: never on a panel (the Ribbon, a popover), or one that's closing.
        let candidates = [parent, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        guard let parent = candidates.first(where: { !($0 is NSPanel) && $0.isVisible }) else {
            Log.noteNow("voice enroll: no window to open the sheet on")
            return
        }
        VoiceEnrollment.trace("opening the sheet\(readMore ? " (read more)" : "")\(preview ? " (preview)" : "") on \(parent === NSApp.mainWindow ? "the main window" : "another window")")
        let m = VoiceEnrollment(preview: preview)
        let root = VoiceEnrollmentView(model: m, close: { dismiss() })
            .limitMotionRoot()
            .tint(Ink.switchOn)
        let host = NSHostingController(rootView: root)
        // No automatic sizing. With `.preferredContentSize`, AppKit asked SwiftUI for the size inside its own
        // Update Constraints pass, and the sheet's content changing as recording began (live words, the clock)
        // marked the window as needing another pass from inside that pass, which AppKit ends with an exception
        // (the crash in build 180: -[NSWindow _postWindowNeedsUpdateConstraints] under
        // NSHostingController.preferredContentSize). The sheet is now sized here, outside layout.
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled]
        // Kept alive by `window` (ARC); a window that also released itself on close would be freed twice.
        w.isReleasedWhenClosed = false
        w.title = "Your voice"
        w.backgroundColor = NSColor(Ink.paper)
        model = m
        window = w
        fit(w, host)
        // Content height changes with the step, the passage, and messages; refit a beat after each change, on
        // the main run loop and never inside a layout pass. Small changes (the clock ticking) are ignored.
        sizeWatch = m.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak w, weak host] _ in
                MainActor.assumeIsolated {
                    guard let w, let host else { return }
                    fit(w, host)
                }
            }
        // The window under the sheet closing (Settings closed with ⌘W) stops the recording with it.
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
            MainActor.assumeIsolated { dismiss() }
        }
        parent.beginSheet(w) { _ in
            m.cancel()
            // Released on the next turn of the run loop, never inside AppKit's own sheet callback.
            DispatchQueue.main.async { if window === w { cleanUp() } }
        }
        if readMore { m.readMore() }
    }

    /// Called from the sheet's own Done and Cancel buttons, so the window must outlive this call: the click that
    /// called it is still unwinding through the window's SwiftUI views. The sheet closes now; the last references
    /// (window, model) go on the next turn of the run loop. Releasing them inside the click could free the window
    /// mid-click, most likely with Reduce Motion or Limit animation on (no closing animation holds the window then).
    static func dismiss() {
        guard let w = window else { return }
        VoiceEnrollment.trace("closing the sheet")
        model?.cancel()
        if let o = parentCloseObserver { NotificationCenter.default.removeObserver(o) }
        parentCloseObserver = nil
        if let parent = w.sheetParent { parent.endSheet(w) } else { w.orderOut(nil) }
        DispatchQueue.main.async {
            if window === w { cleanUp() }
            VoiceEnrollment.trace("sheet released")
        }
    }

    /// Sizes the sheet to its content at the fixed width. Only called from the run loop (never from layout).
    private static func fit(_ w: NSWindow, _ host: NSHostingController<some View>) {
        let fitting = host.sizeThatFits(in: CGSize(width: width, height: 2000))
        let maxHeight = (w.sheetParent?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let size = CGSize(width: width, height: min(max(fitting.height.rounded(.up), 320), maxHeight - 80))
        guard abs(w.contentLayoutRect.height - size.height) > 1 || abs(w.contentLayoutRect.width - size.width) > 1 else { return }
        w.setContentSize(size)
    }

    private static func cleanUp() {
        sizeWatch?.cancel()
        sizeWatch = nil
        if let o = parentCloseObserver { NotificationCenter.default.removeObserver(o) }
        parentCloseObserver = nil
        window = nil
        model = nil
    }
}

/// The three steps, laid out for the sheet.
struct VoiceEnrollmentView: View {
    @ObservedObject var model: VoiceEnrollment
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your voice · step \(model.step.number) of 3")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.mute)
                Text(title).font(Ink.serif(40)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.system(size: 14)).foregroundStyle(Ink.dim)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
            content
        }
        .padding(.horizontal, 40).padding(.vertical, 34)
        .frame(width: 620, alignment: .topLeading)
        .background(Ink.paper)
    }

    private var title: String {
        switch model.step {
        case .intro: return "Teach Verbose your voice."
        case .reading: return "Read this aloud."
        case .analyzing: return "Listening back…"
        case .result(let r): return r.hint == .good ? "All set." : (r.isEnrolled ? "Nearly there." : "Read a little more.")
        case .failed: return "That didn't work."
        }
    }

    private var detail: String? {
        switch model.step {
        case .intro:
            return "Verbose learns how you sound so it can keep only your voice in dictation and mark your lines as “You” in transcripts. You'll read three short passages, about 30 seconds in all."
        case .reading:
            return "Read at your normal pace, as if you were dictating. The words darken as you go."
        case .analyzing:
            return "Verbose is learning your voice on this Mac. The first time, a small model downloads."
        case .result:
            return nil
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .intro: intro
        case .reading: reading
        case .analyzing: analyzing
        case .result(let r): result(r)
        case .failed: failed
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VoiceRingsMark(color: Ink.ink).frame(width: 54, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stays on this Mac").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text("Your voice profile is saved only on this Mac. It isn't synced to iCloud or sent anywhere, and you can delete it in Settings.")
                        .font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: Radius.tile)
            if !model.micName.isEmpty {
                Text("Microphone · \(model.micName)")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).buttonStyle(.brandSecondary)
                Button("Start") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.brandPrimary)
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 18) {
            VoicePassageCard(model: model, size: 23)
            HStack(spacing: 14) {
                VoiceRecordButton(model: model, size: 52)
                VoiceProgress(model: model)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).buttonStyle(.brandSecondary)
                if model.isPaused {
                    Button("Finish Now") { model.finishNow() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.brandPrimary)
                }
            }
        }
    }

    private var analyzing: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Learning your voice…").font(.system(size: 13)).foregroundStyle(Ink.mute)
            Spacer()
            Button("Cancel") { close() }.keyboardShortcut(.cancelAction).buttonStyle(.brandSecondary)
        }
        .frame(minHeight: 120, alignment: .top)
    }

    private func result(_ r: VoiceProfile.Enrollment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VoiceQualityPanel(line: VoiceEnrollment.line(for: r))
            HStack {
                Spacer()
                Button("Read More") { model.readMore() }.buttonStyle(.brandSecondary)
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.brandPrimary)
            }
            VoiceProfileControls(onDelete: { close() })
        }
    }

    private var failed: some View {
        HStack {
            Spacer()
            Button("Cancel") { close() }.keyboardShortcut(.cancelAction).buttonStyle(.brandSecondary)
            Button("Try Again") { model.start() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.brandPrimary)
        }
    }
}
