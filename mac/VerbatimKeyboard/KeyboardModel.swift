import UIKit
import Combine

/// The keyboard's state machine. With a session on: idle → listening → writing → inserted, all inside the
/// keyboard. Without one: idle → starting (Verbatim opens for a moment and comes back) → listening, when Start
/// dictating when you come back is on (the app began the dictation already), or idle with a session when it's off.
/// Reads and writes the App Group through `KeyboardBridge`; the app does the listening and transcription.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        /// The keyboard opened Verbatim to start a session and is waiting for it.
        case starting
        case listening
        /// Capture stopped; the app is transcribing.
        case writing
        case inserted
    }

    struct Insertion: Equatable {
        /// Exactly what went into the field (including a leading space), so Undo removes only that.
        var inserted: String
        var text: String
        var raw: String
        var words: Int
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var insertion: Insertion? = nil
    /// A short line shown under the record card (a failure, or how to turn on Full Access).
    @Published private(set) var notice: String? = nil
    @Published var showsGlobe = true
    @Published var hasFullAccess = true
    /// Whether the app holds a session (heartbeat fresh), and when its idle timeout ends it (nil: until you end it).
    @Published private(set) var sessionLive = false
    @Published private(set) var sessionEndsAt: Date? = nil
    @Published private(set) var micName = "iPhone Microphone"
    /// Ticks once a second while idle, so the session countdown moves.
    @Published private(set) var now = Date()
    /// Your snippets (synced with the Mac; the app writes them to the App Group), and whether the top strip shows them.
    @Published private(set) var snippets: [KeyboardBridge.Snippet] = []
    @Published private(set) var showingSnippets = false

    /// The cleanup level the app applies, for the top strip.
    var levelLabel: String { KeyboardBridge.defaults?.string(forKey: KeyboardBridge.Key.levelLabel) ?? "Polished" }

    private weak var controller: KeyboardViewController?
    /// The dictation this keyboard started, or the session request it sent.
    private var dictation: UUID?
    private var request: UUID?
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var stageSince = Date.distantPast
    private var observing = false
    /// Text goes in only while the keyboard is on screen, so it lands in the field you're looking at.
    private var visible = false

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    var controllerForGlobe: UIInputViewController? { controller }
    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    private var defaults: UserDefaults? { KeyboardBridge.defaults }

    // MARK: Lifecycle

    /// The keyboard appeared. iOS often starts a fresh keyboard process after you come back from the app, so the
    /// session and the dictation live in the App Group, not only in memory.
    func resume() {
        visible = true
        reloadSnippets()
        if !observing {
            observing = true
            KeyboardBridge.observe(KeyboardBridge.Note.state) { [weak self] in self?.poll() }
        }
        // A fresh keyboard process: pick up a dictation that's still running or waiting to be inserted (including
        // one the app began from the first tap while Verbatim was in front).
        if dictation == nil, let running = KeyboardBridge.currentRunningDictation {
            dictation = running.id
            set(running.phase == .listening ? .listening : .writing)
        }
        // A session request sent by an earlier keyboard process.
        if request == nil, stage == .idle, let r = KeyboardBridge.uuid(KeyboardBridge.Key.request),
           KeyboardBridge.uuid(KeyboardBridge.Key.requestDone) != r, KeyboardBridge.uuid(KeyboardBridge.Key.requestFailed) != r,
           !KeyboardBridge.sessionLive {
            request = r
            set(.starting)
        }
        poll()
        retime()
    }

    func pause() { visible = false; stopTimer() }

    // MARK: Actions

    /// The record button: dictates at once while a session is on; otherwise starts one.
    func record() {
        guard hasFullAccess, let defaults else {
            notice = "Turn on Allow Full Access for Verbatim in Settings › General › Keyboard › Keyboards."
            return
        }
        insertion = nil
        notice = nil
        showingSnippets = false
        if KeyboardBridge.sessionLive { startDictation(defaults) } else { startSession(defaults) }
    }

    /// Step 1: a session request, then Verbatim opens for a moment and switches back here. With Start dictating
    /// when you come back on, the request also names a dictation, which the app begins as soon as the microphone
    /// is on, so you can talk the moment you're back.
    private func startSession(_ defaults: UserDefaults) {
        let r = UUID()
        request = r
        defaults.set(r.uuidString, forKey: KeyboardBridge.Key.request)
        var d: UUID? = nil
        if KeyboardBridge.autoStart {
            let id = UUID()
            d = id
            dictation = id
            level = 0
            elapsed = 0
            defaults.set(id.uuidString, forKey: KeyboardBridge.Key.startID)
        }
        set(.starting)
        let host = controller?.hostBundleID()
        if controller?.openContainingApp(KeyboardBridge.sessionURL(request: r, host: host, dictation: d)) != true {
            notice = "Couldn't open Verbatim. Open it yourself to start a session."
            request = nil
            dropDictation()
            set(.idle)
        }
        retime()
    }

    /// Forgets a dictation this keyboard asked for, and tells the app not to start or keep it.
    private func dropDictation() {
        if let d = dictation {
            defaults?.set(d.uuidString, forKey: KeyboardBridge.Key.cancelID)
            KeyboardBridge.post(KeyboardBridge.Note.command)
        }
        dictation = nil
        level = 0
    }

    /// Step 3: the app is already listening to the microphone, so this only marks where your words start.
    private func startDictation(_ defaults: UserDefaults) {
        let d = UUID()
        dictation = d
        level = 0
        elapsed = 0
        defaults.set(d.uuidString, forKey: KeyboardBridge.Key.startID)
        KeyboardBridge.post(KeyboardBridge.Note.command)
        set(.listening)
        retime()
    }

    func done() {
        guard let d = dictation, stage == .listening else { return }
        defaults?.set(d.uuidString, forKey: KeyboardBridge.Key.doneID)
        KeyboardBridge.post(KeyboardBridge.Note.command)
        level = 0
        set(.writing)
    }

    func cancel() {
        if let d = dictation {
            defaults?.set(d.uuidString, forKey: KeyboardBridge.Key.cancelID)
            KeyboardBridge.post(KeyboardBridge.Note.command)
        }
        dictation = nil
        request = nil
        level = 0
        set(.idle)
        retime()
    }

    /// Removes the inserted text.
    func undo() {
        guard let ins = insertion else { return }
        deleteBackward(ins.inserted.count)
        insertion = nil
        set(.idle)
    }

    /// Replaces the cleaned text with the transcript as spoken.
    func useAsSpoken() {
        guard var ins = insertion, ins.raw != ins.text, !ins.raw.isEmpty else { return }
        let lead = ins.inserted.hasPrefix(" ") && !ins.text.hasPrefix(" ") ? " " : ""
        deleteBackward(ins.inserted.count)
        let new = lead + ins.raw
        proxy?.insertText(new)
        ins.inserted = new; ins.text = ins.raw; ins.words = Self.wordCount(ins.raw)
        insertion = ins
    }

    // MARK: Snippets

    /// Shows or hides the snippet row. From the inserted state, the row replaces Undo.
    func toggleSnippets() {
        reloadSnippets()
        if showingSnippets || snippets.isEmpty { showingSnippets = false; return }
        if stage == .inserted { insertion = nil; set(.idle) }
        guard stage == .idle else { return }
        notice = nil
        showingSnippets = true
    }

    /// Inserts a snippet's text, with a space before it after a word, and offers Undo.
    func insertSnippet(_ s: KeyboardBridge.Snippet) {
        guard stage == .idle else { return }
        let before = proxy?.documentContextBeforeInput ?? ""
        let lead = (before.last.map { !$0.isWhitespace } ?? false) ? " " : ""
        let inserted = lead + s.expansion
        proxy?.insertText(inserted)
        showingSnippets = false
        insertion = Insertion(inserted: inserted, text: s.expansion, raw: s.expansion, words: Self.wordCount(s.expansion))
        set(.inserted)
    }

    private func reloadSnippets() {
        let list = KeyboardBridge.readSnippets()
        if list != snippets { snippets = list }
        if list.isEmpty { showingSnippets = false }
    }

    func space() { proxy?.insertText(" ") }
    func newline() { proxy?.insertText("\n") }
    func deleteOne() { proxy?.deleteBackward() }

    // MARK: Polling

    /// 10 times a second while something is happening; once a second otherwise (for the session countdown).
    private func retime() {
        guard visible else { return }
        let want: TimeInterval = (stage == .listening || stage == .writing || stage == .starting) ? 0.1 : 1.0
        guard timer == nil || timerInterval != want else { return }
        stopTimer()
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerInterval = want
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func set(_ s: Stage) {
        if s != stage { stage = s; stageSince = Date() }
    }

    private func poll() {
        guard visible, let defaults else { return }
        now = Date()
        readSession(defaults)
        switch stage {
        case .starting: pollStarting(defaults)
        case .listening, .writing: pollDictation(defaults)
        case .idle, .inserted: break
        }
        retime()
    }

    private func readSession(_ defaults: UserDefaults) {
        let live = KeyboardBridge.sessionLive
        if live != sessionLive { sessionLive = live }
        let ends = defaults.double(forKey: KeyboardBridge.Key.endsAt)
        let endsAt = live && ends > 0 ? Date(timeIntervalSince1970: ends) : nil
        if endsAt != sessionEndsAt { sessionEndsAt = endsAt }
        if let m = defaults.string(forKey: KeyboardBridge.Key.micName), !m.isEmpty, m != micName { micName = m }
    }

    private func pollStarting(_ defaults: UserDefaults) {
        guard let r = request else { set(.idle); return }
        if KeyboardBridge.uuid(KeyboardBridge.Key.requestFailed) == r {
            notice = defaults.string(forKey: KeyboardBridge.Key.requestMessage) ?? "Verbatim couldn't start a session."
            request = nil
            dropDictation()
            set(.idle)
        } else if KeyboardBridge.uuid(KeyboardBridge.Key.requestDone) == r, sessionLive {
            request = nil
            notice = nil
            // The app began the dictation from this tap (or, in a fresh keyboard process, one is already running):
            // show it as listening at once, so the next tap ends it.
            if dictation == nil, let running = KeyboardBridge.currentRunningDictation { dictation = running.id }
            if dictation != nil {
                set(.listening)
                pollDictation(defaults)
            } else {
                set(.idle)
            }
        } else if Date().timeIntervalSince(stageSince) > 20 {
            notice = "Verbatim didn't start. Tap to try again."
            request = nil
            dropDictation()
            set(.idle)
        }
    }

    private func pollDictation(_ defaults: UserDefaults) {
        guard let d = dictation else { set(.idle); return }
        // The app hasn't picked this dictation up yet.
        guard KeyboardBridge.uuid(KeyboardBridge.Key.dictation) == d, let phase = KeyboardBridge.phase else {
            if !sessionLive || Date().timeIntervalSince(stageSince) > 3 {
                // The app is gone (closed, or the session just ended). The next tap starts a new session.
                dictation = nil
                level = 0
                set(.idle)
                notice = defaults.string(forKey: KeyboardBridge.Key.endReason) ?? "The session ended. Tap to start a new one."
            }
            return
        }
        switch phase {
        case .listening:
            if stage != .writing { set(.listening) }
            // Tells the app a keyboard is showing this dictation (it stops a first-tap dictation nobody came back to).
            if visible, defaults.string(forKey: KeyboardBridge.Key.seenID) != d.uuidString {
                defaults.set(d.uuidString, forKey: KeyboardBridge.Key.seenID)
            }
            level = defaults.double(forKey: KeyboardBridge.Key.level)
            elapsed = defaults.double(forKey: KeyboardBridge.Key.elapsed)
            notice = nil
        case .transcribing:
            set(.writing)
            level = 0
        case .done:
            insertResult(d, defaults)
        case .failed:
            notice = defaults.string(forKey: KeyboardBridge.Key.message) ?? "Dictation didn't finish."
            dictation = nil
            level = 0
            set(.idle)
        case .cancelled:
            dictation = nil
            level = 0
            set(.idle)
        }
    }

    private func insertResult(_ d: UUID, _ defaults: UserDefaults) {
        // Another keyboard instance (or an earlier run of this one) already inserted it.
        if defaults.string(forKey: KeyboardBridge.Key.insertedID) == d.uuidString { dictation = nil; set(.idle); return }
        defaults.set(d.uuidString, forKey: KeyboardBridge.Key.insertedID)
        let text = (defaults.string(forKey: KeyboardBridge.Key.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (defaults.string(forKey: KeyboardBridge.Key.raw) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        dictation = nil
        level = 0
        guard !text.isEmpty else {
            notice = "No words were heard."
            set(.idle)
            return
        }
        // A space between your earlier words and the new ones.
        let before = proxy?.documentContextBeforeInput ?? ""
        let lead = (before.last.map { !$0.isWhitespace } ?? false) ? " " : ""
        let inserted = lead + text
        proxy?.insertText(inserted)
        insertion = Insertion(inserted: inserted, text: text, raw: raw, words: Self.wordCount(text))
        set(.inserted)
        notice = nil
    }

    private func deleteBackward(_ n: Int) {
        guard let proxy else { return }
        for _ in 0..<max(0, n) { proxy.deleteBackward() }
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}
