import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Verbatim Flow: dictate into any app on the Mac.
///
/// Start with the hotkey (hold to talk, tap for hands-free, or both) or by clicking the floating button.
/// Verbatim transcribes on this Mac, cleans the words up for the app you're in (email, chat, code), pastes
/// them where your cursor is, and puts your clipboard back. Every dictation is kept, with its audio, in
/// Dictations, so a missed paste is never a lost thought.
///
/// Needs Accessibility access: to notice the hotkey, to read which app and field you're in (never password
/// fields), and to press ⌘V there. Nothing leaves the Mac.
@MainActor
final class DictationController: ObservableObject {
    enum Hotkey: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, fnGlobe, controlOptionSpace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rightOption: return "Right ⌥ Option"
            case .rightCommand: return "Right ⌘ Command"
            case .fnGlobe: return "🌐 Fn"
            case .controlOptionSpace: return "⌃⌥ Space"
            }
        }
        var shortTitle: String {
            switch self {
            case .rightOption: return "hold right ⌥"
            case .rightCommand: return "hold right ⌘"
            case .fnGlobe: return "hold Fn"
            case .controlOptionSpace: return "hold ⌃⌥ Space"
            }
        }
        var isModifierOnly: Bool { self != .controlOptionSpace }
    }

    @Published private(set) var isListening = false
    @Published private(set) var isWorking = false
    @Published private(set) var handsFree = false
    @Published private(set) var targetAppName = ""
    @Published private(set) var lastResult: String? = nil
    @Published var hotkey: Hotkey = Hotkey(rawValue: UserDefaults.standard.string(forKey: "dictateHotkey") ?? "") ?? .rightOption {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: "dictateHotkey"); bar?.refresh() }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "dictateEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "dictateEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "dictateEnabled"); refreshMonitors(); bar?.refresh() }
    }

    private weak var app: AppState?
    private let recorder = Recorder()
    private var monitors: [Any] = []
    private(set) var bar: FlowBarController?
    private let learner = AutoLearn()
    private var target: NSRunningApplication?
    private var context: AppContext?
    private var command = false
    private var keyDown = false
    private var pressedAt: Date?
    private var startedAt: Date?
    private var lastPress = Date.distantPast

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    var liveMeter: LiveMeter { recorder.live }

    func attach(_ app: AppState) {
        self.app = app
        learner.app = app
        bar = FlowBarController(dictation: self)
        refreshMonitors()
        purgeOldDictations()
        // Load the speech model now, so the first dictation doesn't wait for it.
        let choice = app.engineChoice
        if enabled, choice.engine == "fluid" { Task.detached(priority: .utility) { await FluidEngine.shared.warm(model: choice.model) } }
    }

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

    // MARK: Keys

    private func handle(_ e: NSEvent) {
        // Esc cancels a dictation in progress; ⌘⌃V pastes the last one again.
        if e.type == .keyDown {
            if e.keyCode == UInt16(kVK_Escape), isListening { cancel(); return }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == UInt16(kVK_ANSI_V), mods == [.command, .control] { pasteLast(); return }
        }
        switch hotkey {
        case .rightOption: modifier(e, code: 61, flag: .option)          // kVK_RightOption
        case .rightCommand: modifier(e, code: 54, flag: .command)        // kVK_RightCommand
        case .fnGlobe: modifier(e, code: 63, flag: .function)            // kVK_Function
        case .controlOptionSpace:
            if e.keyCode == 49 {                                          // kVK_Space
                let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if e.type == .keyDown, mods.contains([.control, .option]), !e.isARepeat { pressed(shift: mods.contains(.shift)) }
                if e.type == .keyUp, keyDown { released() }
            } else if e.type == .keyDown { otherKey() }
        }
    }

    private func modifier(_ e: NSEvent, code: UInt16, flag: NSEvent.ModifierFlags) {
        if e.type == .flagsChanged, e.keyCode == code {
            if e.modifierFlags.contains(flag) { if !keyDown { pressed(shift: e.modifierFlags.contains(.shift)) } }
            else if keyDown { released() }
        } else if e.type == .keyDown {
            otherKey()
        }
    }

    /// A letter pressed right after a modifier-only hotkey means a shortcut (⌥E, ⌘C), not dictation.
    private func otherKey() {
        guard keyDown, hotkey.isModifierOnly, isListening, !handsFree, let at = pressedAt, Date().timeIntervalSince(at) < 1.0 else { return }
        Log.note("dictation: chord detected, cancelled")
        cancel(quiet: true)
    }

    private func pressed(shift: Bool) {
        keyDown = true
        pressedAt = Date()
        guard Date().timeIntervalSince(lastPress) > 0.15 else { return }
        lastPress = Date()
        switch FlowSettings.shared.mode {
        case .hold:
            begin(handsFree: false, command: shift)
        case .toggle:
            if isListening { finish() } else { begin(handsFree: true, command: shift) }
        case .hybrid:
            if isListening && handsFree { finish() } else { begin(handsFree: false, command: shift) }
        }
    }

    private func released() {
        keyDown = false
        guard isListening, let at = pressedAt else { return }
        switch FlowSettings.shared.mode {
        case .hold: finish()
        case .toggle: break
        case .hybrid:
            // A quick tap keeps listening hands-free; a hold of half a second or more ends on release.
            if Date().timeIntervalSince(at) < 0.5 { handsFree = true; bar?.model.handsFree = true }
            else if !handsFree { finish() }
        }
    }

    // MARK: Floating button

    func barClicked() {
        if isListening { finish() } else if !isWorking { startFromBar(command: false) }
    }

    func startFromBar(command: Bool) {
        guard !isListening, !isWorking else { return }
        guard accessibilityTrusted else {
            bar?.flash("Allow Accessibility to dictate", action: "Open", seconds: 6) { [weak self] in self?.openAccessibilitySettings() }
            return
        }
        begin(handsFree: true, command: command)
    }

    // MARK: Session

    private func begin(handsFree: Bool, command wantCommand: Bool) {
        guard !isListening, !isWorking else { return }
        learner.check()   // Learn from any fixes to the last dictation before this one starts.
        target = NSWorkspace.shared.frontmostApplication
        let s = FlowSettings.shared
        let ctx = AppContext.capture(readText: s.useContext || wantCommand || s.autoLearn)
        context = ctx
        command = wantCommand && !ctx.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if wantCommand && !command { bar?.flash("Select some text first, then edit it by voice"); return }
        targetAppName = target?.localizedName ?? "the front app"
        do {
            try recorder.start(to: app?.store.newRecordingURL() ?? Paths.downloads.appendingPathComponent("dictation-\(Int(Date().timeIntervalSince1970)).wav"))
        } catch {
            Log.note("dictation start failed: \(error)")
            bar?.flash("Couldn't start the microphone")
            return
        }
        startedAt = Date()
        self.handsFree = handsFree
        isListening = true
        Sounds.start()
        if let m = bar?.model {
            m.handsFree = handsFree
            m.command = command
            m.warning = Self.bluetoothWarning()
        }
        bar?.setPhase(.listening)
        Cleanup.prewarm()
        Log.note("dictation begin -> \(targetAppName) [\(ctx.category.rawValue)] handsFree=\(handsFree) command=\(command)")
    }

    /// AirPods and other Bluetooth mics record in call quality and wake slowly (the first word gets lost).
    private static func bluetoothWarning() -> String {
        guard let d = AudioDevices.current(), d.transport == "Bluetooth" else { return "" }
        return "\(d.name) mic: lower quality. Pick another in Settings."
    }

    /// Stops listening without pasting. The recording is discarded.
    func cancel(quiet: Bool = false) {
        guard isListening, let stopped = recorder.stop() else { return }
        isListening = false; handsFree = false
        try? FileManager.default.removeItem(at: stopped.0)
        if quiet { bar?.setPhase(.idle) } else { bar?.flash("Cancelled", seconds: 1.5) }
    }

    private func finish() {
        guard isListening, let stopped = recorder.stop() else { return }
        let (url, duration, env) = stopped
        isListening = false; handsFree = false
        guard duration >= 0.4 else {                      // too short: discard, like Wispr Flow
            try? FileManager.default.removeItem(at: url); bar?.setPhase(.idle); return
        }
        // Nothing but silence: don't run the models (Whisper in particular invents words in silence).
        let loud = env.sorted(by: >).prefix(max(1, env.count / 10))
        if !env.isEmpty, (loud.reduce(0, +) / Float(loud.count)) < 0.05 {
            try? FileManager.default.removeItem(at: url)
            bar?.flash("Didn't hear anything. Check your mic in Settings.", seconds: 3)
            return
        }
        isWorking = true
        bar?.setPhase(.working)
        let s = FlowSettings.shared
        let (engineId, model) = app?.engineChoice ?? ("fluid", "v3")
        let dict = app?.store.dictionary ?? []
        let ctx = context
        let isCommand = command
        let targetName = targetAppName
        let category = ctx?.category ?? .other
        let style = s.style(for: category)
        let level = s.cleanup
        let snippets = s.snippets
        let useContext = s.useContext
        let boost = s.boostVocabulary
        let vocabulary = dict.filter(\.enabled).map(\.preferred)
        let terms = boost ? dict.filter(\.enabled).map { (text: $0.preferred, aliases: $0.heardAs) } : []
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r: EngineResult
                if engineId == "fluid" && !terms.isEmpty {
                    r = try await FluidEngine.shared.transcribeBoosted(url: url, model: model, terms: terms)
                } else {
                    r = try await Engines.engine(for: engineId).transcribe(url: url, model: model, progress: { _ in })
                }
                let original = r.segments
                var segs = r.segments
                let fixes = DictionaryApplier.apply(dict, to: &segs)
                let raw = segs.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                var final: String
                var note: String?
                var cleaned = false
                if isCommand, let selection = ctx?.selection {
                    if let edited = await Cleanup.transform(selection: selection, instruction: raw) { final = edited; cleaned = true }
                    else { final = selection; note = "Couldn't apply “\(raw)”. Editing by voice needs Apple Intelligence on macOS 26." }
                } else {
                    let out = await Cleanup.run(.init(raw: raw, level: level, style: style, category: category, context: ctx,
                                                      vocabulary: vocabulary, useContext: useContext, snippets: snippets))
                    final = out.text; note = out.note; cleaned = out.cleaned
                }
                let info = FlowInfo(app: targetName, bundleID: ctx?.bundleID, category: category, style: style, level: isCommand ? "Command" : level.rawValue,
                                    raw: raw, pasted: final, pastedOK: true, instruction: isCommand ? raw : nil, selection: isCommand ? ctx?.selection : nil)
                let keepNote = note
                let wasCleaned = cleaned
                await MainActor.run {
                    let id = self?.keep(url: url, duration: duration, env: env, original: original, segments: segs, fixes: fixes, result: r, info: info, cleaned: wasCleaned)
                    self?.deliver(final, transcriptID: id, note: isCommand ? keepNote : nil)
                }
            } catch {
                Log.note("dictation transcribe failed: \(error)")
                await MainActor.run {
                    self?.isWorking = false
                    self?.bar?.flash("Dictation failed. It's saved in Dictations.", seconds: 4)
                    self?.keepFailed(url: url, duration: duration, env: env, error: error.localizedDescription)
                }
            }
        }
    }

    private func keep(url: URL, duration: Double, env: [Float], original: [Segment], segments: [Segment], fixes: [Correction], result: EngineResult, info: FlowInfo, cleaned: Bool) -> UUID? {
        guard let app else { return nil }
        let name = app.store.adoptRecording(url) ?? url.lastPathComponent
        let titleSource = info.pasted.isEmpty ? segments : [Segment(start: 0, end: duration, text: info.pasted)]
        var t = Transcript(title: Transcript.titleFrom(titleSource) ?? "Dictation", source: .dictation, sourceLabel: "Dictation · \(info.app)", duration: duration, audioFileName: name, model: Engines.displayName(engine: result.engine, model: result.model))
        t.engine = result.engine; t.language = result.language
        t.original = original; t.segments = segments; t.corrections = fixes; t.waveform = env
        t.flow = info
        if cleaned, info.pasted != info.raw { t.document = info.pasted; t.documentLevel = info.level.capitalized }
        app.store.add(t)
        return t.id
    }

    private func keepFailed(url: URL, duration: Double, env: [Float], error: String) {
        guard let app else { return }
        let name = app.store.adoptRecording(url) ?? url.lastPathComponent
        var t = Transcript(title: "Dictation", source: .dictation, sourceLabel: "Dictation", duration: duration, audioFileName: name, model: "")
        t.waveform = env; t.status = .failed; t.error = error
        app.store.add(t)
    }

    private func deliver(_ text: String, transcriptID: UUID?, note: String?) {
        isWorking = false
        lastResult = text
        guard !text.isEmpty else { bar?.setPhase(.idle); return }
        let ctx = context
        let tgt = target
        let spaced = (ctx?.selection.isEmpty ?? true) && !(command) && needsLeadingSpace(ctx) ? " " + text : text
        Task { @MainActor in
            let outcome = await Paster.paste(spaced + (command ? "" : trailingSpace(text)), into: tgt, focusedField: ctx?.hasFocusedField ?? true)
            Sounds.done()
            switch outcome {
            case .pasted:
                if let note { bar?.flash(note, seconds: 4) } else { bar?.setPhase(.idle) }
                if !command { learner.watch(element: ctx?.element, cursor: ctx?.cursor, pasted: spaced.trimmingCharacters(in: .whitespaces), appName: ctx?.appName ?? "") }
            case .copiedOnly:
                bar?.flash("Copied. Click a text field and press ⌘V.", seconds: 5)
                if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
            }
            command = false
        }
        Log.note("dictation delivered \(text.count) chars")
    }

    /// Adds a space before the text when the cursor sits right after a word.
    private func needsLeadingSpace(_ ctx: AppContext?) -> Bool {
        guard let last = ctx?.before.last else { return false }
        return !last.isWhitespace && !"([{\"“‘/-".contains(last)
    }

    /// A space after a finished sentence, so the next dictation can follow straight on.
    private func trailingSpace(_ text: String) -> String {
        guard let last = text.last, !text.contains("\n") else { return "" }
        return ".!?:;,".contains(last) ? " " : ""
    }

    // MARK: History actions

    /// Puts the last dictation back on the clipboard (for a paste that went to the wrong place).
    func copyLast() {
        guard let last = lastResult ?? app?.store.live.first(where: { $0.source == .dictation })?.flow?.pasted, !last.isEmpty else { return }
        Paster.copy(last)
        app?.toast = Toast("Last dictation copied")
        bar?.flash("Last dictation copied", seconds: 1.8)
    }

    /// Pastes the last dictation again where the cursor is now (⌘⌃V).
    func pasteLast() {
        guard let last = lastResult ?? app?.store.live.first(where: { $0.source == .dictation })?.flow?.pasted, !last.isEmpty else { return }
        let ctx = AppContext.capture(readText: false)
        Task { @MainActor in _ = await Paster.paste(last, into: NSWorkspace.shared.frontmostApplication, focusedField: ctx.hasFocusedField) }
    }

    func openHistory() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        app?.go(.dictations)
    }

    /// Re-runs cleanup on a kept dictation at another level, and returns the new text (History's Redo).
    func reclean(_ id: UUID, level: CleanupLevel) async -> String? {
        guard let t = app?.store.transcript(id), let info = t.flow else { return nil }
        let raw = info.raw.isEmpty ? t.text : info.raw
        let out = await Cleanup.run(.init(raw: raw, level: level, style: info.style, category: info.category, context: nil,
                                          vocabulary: app?.store.dictionary.filter(\.enabled).map(\.preferred) ?? [], useContext: false, snippets: FlowSettings.shared.snippets))
        app?.store.update(id) { x in
            x.flow?.pasted = out.text; x.flow?.level = level.rawValue
            x.document = out.text == raw ? nil : out.text
        }
        return out.text
    }

    /// Moves dictations older than the retention setting to Recently Deleted.
    func purgeOldDictations() {
        let days = FlowSettings.shared.keepDays
        guard days > 0, let app else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = app.store.live.filter { $0.source == .dictation && $0.createdAt < cutoff && !$0.pinned }.map(\.id)
        if !old.isEmpty { app.delete(old) ; Log.note("dictation retention: moved \(old.count) to Recently Deleted") }
    }

    /// Shows the listening button without recording, for screenshots.
    func previewPill(seconds: Double) {
        targetAppName = "Mail"
        bar?.model.handsFree = true
        bar?.setPhase(.listening)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.bar?.setPhase(.idle) }
    }
}
