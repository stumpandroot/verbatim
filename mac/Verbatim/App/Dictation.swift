import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

extension Notification.Name {
    static let verbatimOpenSettings = Notification.Name("verbatimOpenSettings")
}

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
    /// When the hotkey went down, from the event itself (handling can lag while the mic starts).
    private var pressedTS: TimeInterval?
    private var session = 0
    private var startedAt: Date?
    private var lastPressTS: TimeInterval = 0
    private var lastTrusted = false
    private var trustTimer: Timer?

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    var liveMeter: LiveMeter { recorder.live }

    func attach(_ app: AppState) {
        self.app = app
        learner.app = app
        bar = FlowBarController(dictation: self)
        refreshMonitors()
        purgeOldDictations()
        // Turning on Accessibility in System Settings doesn't tell the app. Watch for it, and start listening for
        // the hotkey the moment it's allowed (key monitors added before that never receive anything).
        lastTrusted = accessibilityTrusted
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = self.accessibilityTrusted
                if now != self.lastTrusted {
                    self.lastTrusted = now
                    Log.note("accessibility trusted=\(now)")
                    self.refreshMonitors(); self.bar?.refresh()
                    if now { self.bar?.flash("Ready. \(self.hotkey.shortTitle.prefix(1).uppercased() + self.hotkey.shortTitle.dropFirst()) to dictate.", seconds: 4) }
                }
            }
        }
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
        // Asking first puts Verbatim in the Accessibility list, so you only have to switch it on.
        if !accessibilityTrusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        Self.openPrivacy("Privacy_Accessibility")
    }

    /// Opens System Settings › Privacy & Security at a section. macOS 13 and later use the new address; the old
    /// one is the fallback.
    static func openPrivacy(_ anchor: String) {
        let addresses = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
                         "x-apple.systempreferences:com.apple.preference.security?\(anchor)"]
        for a in addresses {
            if let u = URL(string: a), NSWorkspace.shared.open(u) { Log.note("opened settings \(anchor)"); return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func refreshMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard enabled, accessibilityTrusted else {
            if enabled { Log.note("dictation hotkey off: Accessibility not allowed") }
            return
        }
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
                if e.type == .keyDown, mods.contains([.control, .option]), !e.isARepeat { pressed(shift: mods.contains(.shift), at: e.timestamp) }
                if e.type == .keyUp, keyDown { released(at: e.timestamp) }
            } else if e.type == .keyDown { otherKey(at: e.timestamp) }
        }
    }

    private func modifier(_ e: NSEvent, code: UInt16, flag: NSEvent.ModifierFlags) {
        if e.type == .flagsChanged, e.keyCode == code {
            if e.modifierFlags.contains(flag) { if !keyDown { pressed(shift: e.modifierFlags.contains(.shift), at: e.timestamp) } }
            else if keyDown { released(at: e.timestamp) }
        } else if e.type == .keyDown {
            otherKey(at: e.timestamp)
        }
    }

    /// A letter pressed right after a modifier-only hotkey means a shortcut (⌥E, ⌘C), not dictation.
    private func otherKey(at ts: TimeInterval) {
        guard keyDown, hotkey.isModifierOnly, isListening, !handsFree, let at = pressedTS, ts - at < 1.0 else { return }
        Log.note("dictation: chord detected, cancelled")
        cancel(quiet: true)
    }

    private func pressed(shift: Bool, at ts: TimeInterval) {
        keyDown = true
        pressedTS = ts
        guard ts - lastPressTS > 0.15 else { return }
        lastPressTS = ts
        switch FlowSettings.shared.mode {
        case .hold:
            begin(handsFree: false, command: shift)
        case .toggle:
            if isListening { finish() } else { begin(handsFree: true, command: shift) }
        case .hybrid:
            if isListening && handsFree { finish() } else { begin(handsFree: false, command: shift) }
        }
    }

    private func released(at ts: TimeInterval) {
        keyDown = false
        guard isListening, let at = pressedTS else { return }
        switch FlowSettings.shared.mode {
        case .hold: finish()
        case .toggle: break
        case .hybrid:
            // A quick tap keeps listening hands-free; a hold of half a second or more ends on release.
            if ts - at < 0.5 { handsFree = true; bar?.model.handsFree = true }
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
        // Ask for the microphone once, the first time; if it's off, say where to turn it on.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                Task { @MainActor in
                    // The key was let go during the permission dialog, so listen hands-free; click or tap to stop.
                    if ok { self?.begin(handsFree: true, command: wantCommand) }
                    else { self?.bar?.flash("Verbatim can't hear you: microphone access is off", action: "Open", seconds: 6) { Self.openMicrophoneSettings() } }
                }
            }
            return
        default:
            bar?.flash("Verbatim can't hear you: microphone access is off", action: "Open", seconds: 6) { Self.openMicrophoneSettings() }
            return
        }
        target = NSWorkspace.shared.frontmostApplication
        targetAppName = target?.localizedName ?? "the front app"
        // The mic starts first: reading the app's text through Accessibility can take a moment, and the
        // first word must not be lost to it.
        do {
            try recorder.start(to: app?.store.newRecordingURL() ?? Paths.downloads.appendingPathComponent("dictation-\(Int(Date().timeIntervalSince1970)).wav"))
        } catch {
            Log.note("dictation start failed: \(error)")
            bar?.flash("Couldn't start the microphone. Check Settings › Dictate.")
            return
        }
        startedAt = Date()
        session += 1
        self.handsFree = handsFree
        isListening = true
        learner.check()   // Learn from any fixes to the last dictation before this one is pasted.
        let s = FlowSettings.shared
        let ctx = AppContext.capture(readText: s.useContext || wantCommand || s.autoLearn)
        context = ctx
        command = wantCommand && !ctx.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ctx.selectionClipped
        if wantCommand && ctx.selectionClipped {
            cancel(quiet: true)
            bar?.flash("That selection is too long to edit here. Select less than about 6,000 characters.", seconds: 4)
            return
        }
        if wantCommand && !command {
            cancel(quiet: true)
            bar?.flash("Select some text first, then edit it by voice")
            return
        }
        Sounds.start()
        if let m = bar?.model {
            m.handsFree = handsFree
            m.command = command
            m.warning = Self.bluetoothWarning()
            m.appLabel = Self.label(for: targetAppName)
        }
        bar?.setPhase(.listening)
        FlowCleanup.prewarm()
        Log.note("dictation begin -> \(targetAppName) [\(ctx.category.rawValue)] handsFree=\(handsFree) command=\(command)")
    }

    /// "MAIL", "SLACK": the app's name as the Ribbon shows it while writing.
    private static func label(for app: String) -> String {
        let short = app.count > 12 ? String(app.prefix(11)) + "…" : app
        return short.uppercased()
    }

    /// AirPods and other Bluetooth mics record in call quality and wake slowly (the first word gets lost).
    private static func bluetoothWarning() -> String {
        guard let d = AudioDevices.current(), d.transport == "Bluetooth" else { return "" }
        return "\(d.name) mic: lower quality. Pick another in Settings."
    }

    /// Stops listening without pasting. The recording is discarded.
    func cancel(quiet: Bool = false) {
        guard isListening, let stopped = recorder.stop() else { return }
        isListening = false; handsFree = false; command = false
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
        let saved = s.actions
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let t0 = Date()
                let r: EngineResult
                if engineId == "fluid" && !terms.isEmpty {
                    r = try await FluidEngine.shared.transcribeBoosted(url: url, model: model, terms: terms)
                } else {
                    r = try await Engines.engine(for: engineId).transcribe(url: url, model: model, progress: { _ in })
                }
                let transcribeTime = Date().timeIntervalSince(t0)
                let t1 = Date()
                let original = r.segments
                var segs = r.segments
                let fixes = DictionaryApplier.apply(dict, to: &segs)
                let raw = segs.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                var final: String
                var note: String?
                var cleaned = false
                if isCommand, let selection = ctx?.selection {
                    // Saying a saved action's name ("client email") runs that action.
                    let n = FlowAction.norm(raw)
                    let named = saved.first { a in let an = FlowAction.norm(a.name); return n == an || ["run", "use", "do", "apply"].contains { n == "\($0) \(an)" } }
                    if let edited = await FlowCleanup.apply(instruction: named?.instruction ?? raw, to: selection, kind: named?.kind ?? .rewrite) {
                        final = Self.keepingEdges(of: selection, edited); cleaned = true
                        if let named { note = "“\(named.name)” applied. Press ⌘Z to undo." }
                    }
                    else { final = selection; note = "Couldn't apply “\(named?.name ?? raw)”. Editing by voice needs Apple Intelligence on macOS 26." }
                } else {
                    let out = await FlowCleanup.run(.init(raw: raw, level: level, style: style, category: category, context: ctx,
                                                      vocabulary: vocabulary, useContext: useContext, snippets: snippets))
                    final = out.text; note = out.note; cleaned = out.cleaned
                }
                let info = FlowInfo(app: targetName, bundleID: ctx?.bundleID, category: category, style: style, level: isCommand ? "Command" : level.rawValue,
                                    raw: raw, pasted: final, pastedOK: true, instruction: isCommand ? raw : nil, selection: isCommand ? ctx?.selection : nil)
                let keepNote = note, wasCleaned = cleaned, finalText = final, keptSegs = segs
                let cleanupTime = Date().timeIntervalSince(t1)
                await MainActor.run {
                    let id = self?.keep(url: url, duration: duration, env: env, original: original, segments: keptSegs, fixes: fixes, result: r, info: info, cleaned: wasCleaned)
                    if let id, !isCommand, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ActivityLog.shared.add(ActivityLog.event(id: id, date: Date(), info: info, seconds: duration, fixes: fixes.count, transcribe: transcribeTime, cleanup: cleanupTime))
                    }
                    self?.deliver(finalText, transcriptID: id, note: isCommand ? keepNote : nil, raw: raw)
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

    private func deliver(_ text: String, transcriptID: UUID?, note: String?, raw: String = "") {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isWorking = false
            mistake(raw: raw, transcriptID: transcriptID)
            return
        }
        lastResult = text
        let ctx = context, tgt = target
        let wasCommand = command
        command = false
        let spaced = (ctx?.selection.isEmpty ?? true) && !wasCommand && needsLeadingSpace(ctx) ? " " + text : text
        // Stays "working" until the paste and clipboard restore finish (up to a few seconds for slow apps),
        // so a new dictation can't start mid-paste and have this one's result land on top of it.
        Task { @MainActor in
            let outcome = await Paster.paste(spaced + (wasCommand ? "" : trailingSpace(text)), into: tgt, focusedField: ctx?.hasFocusedField ?? true)
            isWorking = false
            Sounds.done()
            switch outcome {
            case .pasted:
                if let note { bar?.flash(note, seconds: 4) } else { bar?.setPhase(.idle) }
                if !wasCommand { learner.watch(element: ctx?.element, cursor: ctx?.cursor, pasted: spaced.trimmingCharacters(in: .whitespaces), appName: ctx?.appName ?? "") }
            case .copiedOnly:
                bar?.flash("Copied. Click a text field and press ⌘V.", seconds: 5)
                if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
            }
        }
        Log.note("dictation delivered \(text.count) chars")
    }

    /// "Started by mistake?": nothing usable came out (only filler words, or nothing transcribed).
    /// Discard removes it from Dictations; Paste anyway pastes what was heard; doing nothing keeps it in
    /// Dictations, marked as not pasted.
    private func mistake(raw: String, transcriptID: UUID?) {
        command = false
        if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
        let heard = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = context, tgt = target
        bar?.ask(.init(
            title: "Started by mistake?",
            body: heard.isEmpty ? "No words were heard, so nothing was pasted." : "Only ",
            quote: heard.isEmpty ? nil : String(heard.prefix(60)) + (heard.count > 60 ? "…" : ""),
            after: heard.isEmpty ? "" : " was heard, so nothing was pasted.",
            primary: heard.isEmpty ? nil : "Paste anyway",
            secondary: "Discard",
            seconds: 7,
            onPrimary: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let out = await Paster.paste(heard, into: tgt, focusedField: ctx?.hasFocusedField ?? true)
                    if out == .copiedOnly { self.bar?.flash("Copied. Click a text field and press ⌘V.", seconds: 5) }
                    if let id = transcriptID { self.app?.store.update(id) { $0.flow?.pasted = heard; $0.flow?.pastedOK = out == .pasted } }
                    self.lastResult = heard
                }
            },
            onSecondary: { [weak self] in
                if let id = transcriptID { self?.app?.store.moveToTrash(id) }
            }
        ))
    }

    static func openMicrophoneSettings() { openPrivacy("Privacy_Microphone") }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's openSettings is the reliable route on macOS 14+; ContentView listens for this.
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NotificationCenter.default.post(name: .verbatimOpenSettings, object: nil)
            return
        }
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
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

    // MARK: Saved actions on a selection

    /// Runs a saved action on the text selected in the app you're using, and puts the result in its place.
    /// The app's own Undo (⌘Z) brings the original back.
    func apply(_ action: FlowAction) {
        guard !isListening, !isWorking else { return }
        guard accessibilityTrusted else {
            bar?.flash("Allow Accessibility to use actions", action: "Open", seconds: 6) { [weak self] in self?.openAccessibilitySettings() }
            return
        }
        let ctx = AppContext.capture(readText: true)
        let selection = ctx.selection
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            bar?.flash("Select some text first, then pick “\(action.name)”", seconds: 3)
            return
        }
        guard !ctx.selectionClipped else {
            bar?.flash("That selection is too long to replace here. Copy it into a transcript, or select less.", seconds: 4)
            return
        }
        let tgt = NSWorkspace.shared.frontmostApplication
        isWorking = true
        bar?.model.appLabel = Self.label(for: action.name)
        bar?.setPhase(.working)
        Task { @MainActor in
            guard let out = await FlowCleanup.apply(instruction: action.instruction, to: selection, kind: action.kind) else {
                isWorking = false
                bar?.flash(FlowCleanup.available ? "Couldn't run “\(action.name)”. Try a shorter selection." : "Actions need Apple Intelligence on macOS 26.", seconds: 4)
                return
            }
            let result = Self.keepingEdges(of: selection, out)
            // A long action can take a while: if you clicked elsewhere or changed the selection meanwhile,
            // don't replace whatever is selected now. Copy the result instead.
            let now = AppContext.capture(readText: true)
            let same = NSWorkspace.shared.frontmostApplication?.processIdentifier == tgt?.processIdentifier && now.selection == selection
            let outcome: Paster.Outcome
            if same { outcome = await Paster.paste(result, into: tgt, focusedField: ctx.hasFocusedField) }
            else { Paster.copy(result); outcome = .copiedOnly }
            isWorking = false
            lastResult = result
            Sounds.done()
            bar?.flash(outcome == .pasted ? "“\(action.name)” applied. Press ⌘Z to undo."
                       : same ? "Copied. Click a text field and press ⌘V." : "The selection changed, so the result is on your clipboard.", seconds: 4)
            Log.note("action \(action.name) applied, \(out.count) chars")
        }
    }

    /// Puts the selection's leading and trailing spaces and line breaks back around a result, so replacing a
    /// paragraph doesn't join it to the next one.
    nonisolated static func keepingEdges(of original: String, _ result: String) -> String {
        let lead = original.prefix { $0.isWhitespace }, trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        guard lead.count < original.count else { return result }
        return String(lead) + result.trimmingCharacters(in: .whitespacesAndNewlines) + trail
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
        let out = await FlowCleanup.run(.init(raw: raw, level: level, style: info.style, category: info.category, context: nil,
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
        // Straight to Recently Deleted, quietly: this runs at launch, when a toast would only confuse.
        for id in old { app.store.moveToTrash(id) }
        if !old.isEmpty { Log.note("dictation retention: moved \(old.count) to Recently Deleted") }
    }

    /// Shows the listening button without recording, for screenshots.
    func previewPill(seconds: Double) {
        targetAppName = "Mail"
        bar?.model.handsFree = true
        bar?.setPhase(.listening)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.bar?.setPhase(.idle) }
    }
}
