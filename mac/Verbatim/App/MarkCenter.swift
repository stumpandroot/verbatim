import AppKit
import SwiftUI
import Combine
import Carbon
import Carbon.HIToolbox

// Mark a moment on the Mac (mockup "Library features", section 3b): Mark on the recording bubble's card and on Home's
// record panel, and ⌃⌥B from any app while something records. The recording the mark goes to is whichever is running:
// a voice note (the app's recorder), a thought (ThoughtCapture), or app audio. Each mark is written beside its
// recording at once (Model/Marks.swift), so a recording Verbose didn't get to stop keeps its moments; on Stop the marks
// become bookmarks with their source. "Marked 4:12 · 3 moments" shows for two seconds where you marked.

@MainActor
final class MarkCenter: ObservableObject {
    static let shared = MarkCenter()

    /// The recording a mark goes to.
    enum Target: Equatable { case voiceNote, thought, appAudio }

    /// "Marked 4:12 · 3 moments" for two seconds after a mark.
    @Published private(set) var confirmation: MarkConfirmation?
    /// Whether something is recording that a mark could go to (the hotkey is registered only then).
    @Published private(set) var canMark = false

    private weak var app: AppState?
    private var marks: [Target: [RecordingMark]] = [:]
    private var bag = Set<AnyCancellable>()
    /// The self-test's stand-in for a running recording: its target and how far in it is.
    var simulated: (target: Target, elapsed: Double)?

    func attach(_ app: AppState) {
        guard self.app == nil else { return }
        self.app = app
        let thought = ThoughtCapture.shared
        // A recording starting or stopping: the hotkey follows, and a new recording starts with no marks.
        app.recorder.$isRecording.combineLatest(app.recorder.$isStarting, app.capture.$isCapturing, thought.$phase)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recordingChanged() }
            .store(in: &bag)
        MarkHotkey.shared.onPress = { [weak self] in
            guard let self else { return }
            self.mark(.macHotkey, keys: MarkHotkeyStore.current().title)
        }
    }

    /// What's recording now, if anything a mark can go to.
    var target: Target? {
        if let s = simulated { return s.target }
        guard let app else { return nil }
        if app.recorder.isRecording, !app.recorder.isStarting { return .voiceNote }
        if ThoughtCapture.shared.isRecording, !ThoughtCapture.shared.simulate { return .thought }
        if app.capture.isCapturing { return .appAudio }
        return nil
    }

    /// Marks in the recording `target` names, so far.
    func count(_ target: Target) -> Int { marks[target]?.count ?? 0 }

    private func place(for target: Target) -> (elapsed: Double, url: URL?)? {
        if let s = simulated, s.target == target { return (s.elapsed, nil) }
        guard let app else { return nil }
        switch target {
        case .voiceNote: return (app.recorder.elapsed, app.recorder.recordingURL)
        case .thought: return (ThoughtCapture.shared.recorder.elapsed, ThoughtCapture.shared.recorder.recordingURL)
        case .appAudio: return (app.capture.elapsed, app.capture.recordingURL)
        }
    }

    /// Marks a moment in whatever is recording, at its current time. A second mark within 3 seconds confirms the first.
    /// False (and nothing else happens) when nothing is recording.
    @discardableResult
    func mark(_ source: MarkSource, keys: String? = nil) -> Bool {
        guard let target, let spot = place(for: target) else { return false }
        let (list, confirmed) = Marks.adding(RecordingMark(at: spot.elapsed, source: source.rawValue, keys: keys), to: marks[target] ?? [])
        marks[target] = list
        if let url = spot.url { Marks.save(list, for: url) }
        let c = MarkConfirmation(at: confirmed.at, count: list.count)
        confirmation = c
        Log.note("marks: marked \(Marks.clock(confirmed.at)) from \(source.rawValue) (\(list.count) in this recording)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Marks.confirmSeconds) { [weak self] in
            if self?.confirmation?.id == c.id { self?.confirmation = nil }
        }
        return true
    }

    /// The marks of a recording that just stopped, for its transcript; they're gone from here after.
    func take(_ target: Target) -> [RecordingMark] {
        let list = marks.removeValue(forKey: target) ?? []
        if target == self.target || self.target == nil { confirmation = nil }
        return list
    }

    /// The recordings running, as of the last change.
    private var running: Set<Target> = []

    private func recordingChanged() {
        var now: Set<Target> = []
        if let app {
            if app.recorder.isRecording, !app.recorder.isStarting { now.insert(.voiceNote) }
            if app.capture.isCapturing { now.insert(.appAudio) }
        }
        if ThoughtCapture.shared.isRecording, !ThoughtCapture.shared.simulate { now.insert(.thought) }
        // A recording that starts has no marks yet (any left from one that ended without being taken go).
        for t in now.subtracting(running) { marks[t] = nil }
        running = now
        if now.isEmpty { confirmation = nil }
        let can = !now.isEmpty
        if canMark != can { canMark = can }
        MarkHotkey.shared.setActive(can)
    }
}

// MARK: - The hotkey

private let markSignature: OSType = 0x5642_4D4B   // "VBMK"

/// Carbon calls this on the main thread. Other Verbose hotkeys share the event target, so anything that isn't ours
/// passes through.
private func markHotkeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard err == noErr, id.signature == markSignature else { return OSStatus(eventNotHandledErr) }
    if GetEventKind(event) == UInt32(kEventHotKeyPressed) { MainActor.assumeIsolated { MarkHotkey.shared.fire() } }
    return noErr
}

/// ⌃⌥B (Settings › Dictation › Other shortcuts › Mark a moment), registered with Carbon only while something records:
/// then it works in every app, with secure input on too, and the keystroke goes only to Verbose. With nothing
/// recording it isn't registered, so other apps get the keys. Needs no Accessibility access.
@MainActor
final class MarkHotkey: ObservableObject {
    static let shared = MarkHotkey()
    /// macOS refused the shortcut (another app holds it) the last time it was registered.
    @Published private(set) var unavailable = false
    var onPress: (() -> Void)?
    /// Settings is recording a new shortcut: the hotkey stays off meanwhile.
    var suspended = false { didSet { apply() } }
    private var active = false
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        apply()
    }

    /// Registers the stored shortcut while something records (and Settings isn't recording one); otherwise none.
    func apply() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        guard active, !suspended else { return }
        if handler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
            let status = InstallEventHandler(GetApplicationEventTarget(), markHotkeyHandler, 1, &types, nil, &handler)
            guard status == noErr else {
                handler = nil
                unavailable = true
                Log.note("marks: hotkey handler not installed (\(status))")
                return
            }
        }
        let c = MarkHotkeyStore.current()
        var r: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(c.keyCode), UInt32(Self.carbonMods(c.mods)), EventHotKeyID(signature: markSignature, id: 1),
                                         GetApplicationEventTarget(), 0, &r)
        if status == noErr, let r {
            ref = r
            if unavailable { unavailable = false }
        } else {
            unavailable = true
            Log.note("marks: hotkey \(c.title) not registered (\(status))")
        }
    }

    fileprivate func fire() { onPress?() }

    private static func carbonMods(_ m: KeyMods) -> Int {
        var r = 0
        if m.contains(.control) { r |= controlKey }
        if m.contains(.option) { r |= optionKey }
        if m.contains(.shift) { r |= shiftKey }
        if m.contains(.command) { r |= cmdKey }
        return r
    }
}

// MARK: - Settings

/// Settings › Dictation › Other shortcuts › Mark a moment: the hotkey as keycaps, Change (press the keys you want; Esc
/// stops), and Use ⌃⌥B once it's something else. A shortcut that's taken says by what. While it records, the dictation
/// hotkey and this one are off.
struct MarkHotkeyRow: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject private var hotkey = MarkHotkey.shared
    @AppStorage(MarkHotkeyStore.key) private var stored = ""
    @State private var recording = false
    @State private var problem: String? = nil
    @State private var monitor: Any? = nil

    private var combo: KeyCombo { KeyCombo(stored: stored) ?? MarkHotkeyStore.standard }

    var body: some View {
        SettingsRow("dictate.markHotkey", detail: detail, detailColor: problem == nil && !hotkey.unavailable ? Refined.mute : Refined.accentText) {
            HStack(spacing: 6) {
                if recording {
                    Text("Type a shortcut").font(.system(size: 12.5)).foregroundStyle(Refined.mute)
                    Button("Cancel") { stop() }.buttonStyle(.settingsPill)
                } else {
                    ForEach(Array(combo.keycaps.enumerated()), id: \.offset) { _, k in KeyChip(text: k) }
                    Button("Change") { start() }.buttonStyle(.settingsPill)
                    if combo != MarkHotkeyStore.standard {
                        Button("Use \(MarkHotkeyStore.standard.title)") { save(MarkHotkeyStore.standard) }.buttonStyle(.settingsPill)
                    }
                }
            }
            .uiTarget("mark-hotkey")
        }
        .onDisappear { stop() }
    }

    private var detail: String? {
        if let problem { return problem }
        if recording { return "Press the keys you want, such as ⌃⌥B. Esc stops." }
        if hotkey.unavailable { return "Another app holds \(combo.title), so it may not mark. Choose another shortcut." }
        return nil
    }

    private func start() {
        stop()
        problem = nil
        recording = true
        dictation.hotkeySuspended = true
        MarkHotkey.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            let mods = DictationController.keyMods(e.modifierFlags)
            if e.keyCode == KeyNames.escape && mods.isEmpty { stop(); return nil }
            if e.isARepeat { return nil }
            let c = KeyCombo(keyCode: e.keyCode, mods: mods)
            var others: [ShortcutCheck.Known] = []
            if let d = HotkeyStore.custom() { others.append(ShortcutCheck.Known(combo: d, owner: "Verbose", does: "starts dictation")) }
            switch RecallShortcut.current {
            case .optionCommandV: others.append(ShortcutCheck.Known(combo: KeyCombo(keyCode: 9, mods: [.option, .command]), owner: "Verbose", does: "opens Recent dictations"))
            case .controlOptionV: others.append(ShortcutCheck.Known(combo: KeyCombo(keyCode: 9, mods: [.control, .option]), owner: "Verbose", does: "opens Recent dictations"))
            case .off: break
            }
            switch ShortcutCheck.check(c, also: others) {
            case .ok: save(c); stop()
            case .needsModifier: problem = "Add ⌃, ⌥, or ⌘, or use a function key on its own."
            case .escape: stop()
            case .taken(_, let sentence): problem = "\(sentence) Choose another shortcut."
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard recording else { return }
        recording = false
        dictation.hotkeySuspended = false
        MarkHotkey.shared.suspended = false
    }

    private func save(_ c: KeyCombo) {
        problem = nil
        stored = c == MarkHotkeyStore.standard ? "" : c.stored
        MarkHotkey.shared.apply()
        Log.note("marks: hotkey is \(c.title)")
    }
}
