import SwiftUI
import AppKit

// Mac: the voice profile in Settings (`VoiceProfileSection`) and the enrollment sheet it opens
// (`VoiceEnrollmentSheet`). Shared pieces and the recording live in VoiceEnrollment.swift.

/// Your voice profile in Settings: how well Verbatim knows your voice (or what setting it up does), Set Up / Read
/// More, and, unless `showsControls` is false, the switches that use it and Delete voice profile.
/// Self-contained: no environment objects, so any Settings pane can host it.
struct VoiceProfileSection: View {
    var showsControls = true
    @ObservedObject private var status = VoiceProfileStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if status.isEnrolled || status.isPartial {
                VoiceQualityPanel(line: status.line)
                HStack(spacing: 10) {
                    Button("Read More…") { VoiceEnrollmentSheet.present(readMore: true) }
                        .buttonStyle(.brandSecondary)
                        .help("Read one more passage so Verbatim knows your voice better.")
                    Button("Start Over…") { VoiceEnrollmentSheet.present() }
                        .buttonStyle(.brandSecondary)
                        .help("Record your voice again from the beginning.")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Teach Verbatim your voice.").font(Ink.serif(22)).foregroundStyle(Ink.ink)
                    Text("Read three short passages aloud, about 30 seconds in all. Verbatim can then keep only your voice in dictation and mark your lines as “You” in transcripts. Your voice profile stays on this Mac.")
                        .font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Your Voice…") { VoiceEnrollmentSheet.present() }
                        .buttonStyle(.brandPrimary)
                        .padding(.top, 2)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(radius: Radius.tile)
            }
            if showsControls { VoiceProfileControls() }
        }
        .onAppear { status.refresh() }
    }
}

/// The switches that use the profile, and Delete voice profile with its confirmation in place.
struct VoiceProfileControls: View {
    /// Called after the profile is deleted (the sheet closes itself).
    var onDelete: (() -> Void)? = nil
    @ObservedObject private var status = VoiceProfileStatus.shared
    @AppStorage(VoiceProfile.dictationFilterKey) private var onlyMyVoice = false
    @AppStorage(VoiceProfile.labelYouKey) private var labelYou = true
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            row {
                Toggle(isOn: $onlyMyVoice) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only keep my voice in dictation")
                        Text(status.isEnrolled
                             ? "When someone nearby talks while you dictate, Verbatim pastes only your words."
                             : "Available once Verbatim knows your voice.")
                            .font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                    }
                }
                .disabled(!status.isEnrolled)
            }
            Divider().overlay(Ink.hairline)
            row {
                Toggle(isOn: $labelYou) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Label my lines as “You”")
                        Text("New transcripts name your speaker You.")
                            .font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                    }
                }
                .disabled(!status.isEnrolled)
            }
            if status.isEnrolled || status.isPartial {
                Divider().overlay(Ink.hairline)
                if confirming {
                    row {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Delete your voice profile from this Mac?").fontWeight(.medium)
                            Text("Dictation keeps every voice and transcripts stop naming you You. You can set it up again any time.")
                                .font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                                Button("Delete", role: .destructive) {
                                    status.delete()
                                    confirming = false
                                    onDelete?()
                                }
                                .foregroundStyle(Ink.accentText)
                            }
                        }
                    }
                } else {
                    row {
                        HStack {
                            Text("Delete voice profile")
                            Spacer()
                            Button("Delete…") { confirming = true }
                                .buttonStyle(.plain).foregroundStyle(Ink.accentText)
                                .accessibilityLabel("Delete voice profile")
                        }
                    }
                }
            }
        }
        .font(.system(size: 13.5))
        .toggleStyle(.switch)
        .tint(Ink.switchOn)
        .cardSurface(radius: Radius.tile)
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sheet

/// The enrollment flow in a sheet on the Settings window.
@MainActor
enum VoiceEnrollmentSheet {
    private static var window: NSWindow?
    private static var model: VoiceEnrollment?
    private static var parentCloseObserver: NSObjectProtocol?

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
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled]
        // Kept alive by `window` (ARC); a window that also released itself on close would be freed twice.
        w.isReleasedWhenClosed = false
        w.title = "Your voice"
        w.backgroundColor = NSColor(Ink.paper)
        model = m
        window = w
        // The window under the sheet closing (Settings closed with ⌘W) stops the recording with it.
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
            MainActor.assumeIsolated { dismiss() }
        }
        parent.beginSheet(w) { _ in
            m.cancel()
            if window === w { cleanUp() }
        }
        if readMore { m.readMore() }
    }

    static func dismiss() {
        guard let w = window else { return }
        VoiceEnrollment.trace("closing the sheet")
        model?.cancel()
        cleanUp()
        if let parent = w.sheetParent { parent.endSheet(w) } else { w.orderOut(nil) }
    }

    private static func cleanUp() {
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
        case .intro: return "Teach Verbatim your voice."
        case .reading: return "Read this aloud."
        case .analyzing: return "Listening back…"
        case .result(let r): return r.hint == .good ? "All set." : (r.isEnrolled ? "Nearly there." : "Read a little more.")
        case .failed: return "That didn't work."
        }
    }

    private var detail: String? {
        switch model.step {
        case .intro:
            return "Verbatim learns how you sound so it can keep only your voice in dictation and mark your lines as “You” in transcripts. You'll read three short passages, about 30 seconds in all."
        case .reading:
            return "Read at your normal pace, as if you were dictating. The words darken as you go."
        case .analyzing:
            return "Verbatim is learning your voice on this Mac. The first time, a small model downloads."
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
