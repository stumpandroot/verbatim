import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Dictate mode: hold a key anywhere on the Mac, speak, release. Verbatim transcribes on this Mac and
/// pastes the text into whatever app was in front. Needs Accessibility access (to watch the key and to
/// press ⌘V in the other app); nothing is read from other apps.
@MainActor
final class DictationController: ObservableObject {
    enum Hotkey: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, fnGlobe, controlOptionSpace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rightOption: return "Hold right ⌥ Option"
            case .rightCommand: return "Hold right ⌘ Command"
            case .fnGlobe: return "Hold 🌐 Fn"
            case .controlOptionSpace: return "Hold ⌃⌥ Space"
            }
        }
    }

    @Published private(set) var isListening = false
    @Published private(set) var isWorking = false
    @Published private(set) var targetAppName = ""
    @Published private(set) var lastResult: String? = nil
    @Published var hotkey: Hotkey = Hotkey(rawValue: UserDefaults.standard.string(forKey: "dictateHotkey") ?? "") ?? .rightOption {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: "dictateHotkey") }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "dictateEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "dictateEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "dictateEnabled"); refreshMonitors() }
    }

    private weak var app: AppState?
    private let recorder = Recorder()
    private var monitors: [Any] = []
    private var panel: NSPanel?
    private var target: NSRunningApplication?
    private var spaceDown = false
    private var startedAt: Date?

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func attach(_ app: AppState) { self.app = app; refreshMonitors() }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshMonitors() }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func refreshMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard enabled, accessibilityTrusted else { return }
        // Global (other apps) and local (our own windows) so it works everywhere.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) { monitors.append(l) }
        Log.note("dictation monitors on, hotkey=\(hotkey.rawValue)")
    }

    private func handle(_ e: NSEvent) {
        switch hotkey {
        case .rightOption:
            guard e.type == .flagsChanged, e.keyCode == 61 else { return }   // kVK_RightOption
            e.modifierFlags.contains(.option) ? begin() : end()
        case .rightCommand:
            guard e.type == .flagsChanged, e.keyCode == 54 else { return }   // kVK_RightCommand
            e.modifierFlags.contains(.command) ? begin() : end()
        case .fnGlobe:
            guard e.type == .flagsChanged, e.keyCode == 63 else { return }   // kVK_Function
            e.modifierFlags.contains(.function) ? begin() : end()
        case .controlOptionSpace:
            guard e.keyCode == 49 else { return }                              // kVK_Space
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.type == .keyDown, mods.contains([.control, .option]), !e.isARepeat { begin() }
            if e.type == .keyUp { end() }
        }
    }

    // MARK: Session

    private func begin() {
        guard !isListening, !isWorking else { return }
        target = NSWorkspace.shared.frontmostApplication
        targetAppName = target?.localizedName ?? "the front app"
        do {
            try recorder.start(to: app?.store.newRecordingURL() ?? Paths.downloads.appendingPathComponent("dictation-\(Int(Date().timeIntervalSince1970)).wav"))
        } catch {
            Log.note("dictation start failed: \(error)"); return
        }
        startedAt = Date()
        isListening = true
        Sounds.start()
        showPanel()
        Log.note("dictation begin -> \(targetAppName)")
    }

    private func end() {
        guard isListening, let stopped = recorder.stop() else { return }
        let (url, duration, env) = stopped
        isListening = false
        guard duration >= 0.5 else {                      // too short: discard, like Wispr Flow
            try? FileManager.default.removeItem(at: url); hidePanel(); return
        }
        isWorking = true
        let (engineId, model) = app?.engineChoice ?? ("fluid", "v3")
        let dict = app?.store.dictionary ?? []
        let targetName = targetAppName
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try await Engines.engine(for: engineId).transcribe(url: url, model: model, progress: { _ in })
                let original = r.segments
                var segs = r.segments
                let fixes = DictionaryApplier.apply(dict, to: &segs)
                let text = segs.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    // Every dictation is kept, so a missed paste is never a lost thought.
                    self?.keep(url: url, duration: duration, env: env, original: original, segments: segs, fixes: fixes, result: r, target: targetName)
                    self?.deliver(text)
                }
            } catch {
                Log.note("dictation transcribe failed: \(error)")
                await MainActor.run {
                    self?.isWorking = false; self?.hidePanel()
                    self?.keepFailed(url: url, duration: duration, env: env, error: error.localizedDescription)
                    self?.app?.toast = Toast("Dictation failed: \(error.localizedDescription). The recording is in Library; choose Retry.")
                }
            }
        }
    }

    private func keep(url: URL, duration: Double, env: [Float], original: [Segment], segments: [Segment], fixes: [Correction], result: EngineResult, target: String) {
        guard let app else { return }
        let name = app.store.adoptRecording(url) ?? url.lastPathComponent
        var t = Transcript(title: Transcript.titleFrom(segments) ?? "Dictation", source: .dictation, sourceLabel: "Dictation · \(target)", duration: duration, audioFileName: name, model: Engines.displayName(engine: result.engine, model: result.model))
        t.engine = result.engine; t.language = result.language
        t.original = original; t.segments = segments; t.corrections = fixes; t.waveform = env
        app.store.add(t)
    }

    private func keepFailed(url: URL, duration: Double, env: [Float], error: String) {
        guard let app else { return }
        let name = app.store.adoptRecording(url) ?? url.lastPathComponent
        var t = Transcript(title: "Dictation", source: .dictation, sourceLabel: "Dictation", duration: duration, audioFileName: name, model: "")
        t.waveform = env; t.status = .failed; t.error = error
        app.store.add(t)
    }

    /// Puts the last dictation back on the clipboard (for a paste that went to the wrong place).
    func copyLast() {
        guard let last = lastResult, !last.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(last, forType: .string)
        app?.toast = Toast("Last dictation copied")
    }

    private func deliver(_ text: String) {
        isWorking = false
        lastResult = text
        guard !text.isEmpty else { hidePanel(); return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text + " ", forType: .string)
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Self.pressCommandV()
            Sounds.done()
            self?.hidePanel()
            // Give the paste a moment, then put the person's clipboard back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
            }
        }
        Log.note("dictation delivered \(text.count) chars")
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    /// Shows the pill without recording, for screenshots.
    func previewPill(seconds: Double) {
        targetAppName = "Mail"
        isListening = true
        showPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.isListening = false; self?.hidePanel() }
    }

    // MARK: Floating pill

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64), styleMask: [.nonactivatingPanel, .borderless, .hudWindow], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: DictationPill(controller: self, recorder: recorder))
            panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - 180, y: f.minY + 28))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; p.animator().alphaValue = 1 }
    }

    private func hidePanel() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

struct PillMeter: View {
    @ObservedObject var live: LiveMeter
    var body: some View { Meter(levels: live.levels, color: .white) }
}

/// The hold-to-talk pill: signal rings, live bars, and where the words will go. Always ink, both modes.
struct DictationPill: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var recorder: Recorder
    var body: some View {
        HStack(spacing: 12) {
            SignalRings(color: Ink.persimmon).frame(width: 30, height: 30)
            if controller.isWorking {
                Text("Writing into \(controller.targetAppName)…").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Spacer()
                ProgressView().controlSize(.small).tint(.white)
            } else {
                PillMeter(live: recorder.live).frame(width: 140, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Release to paste into \(controller.targetAppName)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 360, height: 64)
        .background(Ink.inkFixed.opacity(0.95), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}
