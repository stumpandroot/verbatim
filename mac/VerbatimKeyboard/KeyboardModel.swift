import UIKit
import Combine

/// The keyboard's state machine: idle → waiting for the app → listening → writing → inserted.
/// Reads and writes the App Group through `KeyboardBridge`; the app does the recording and transcription.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        /// The keyboard opened the app and is waiting for it to start recording.
        case waiting
        case listening
        /// Recording stopped; the app is transcribing.
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

    /// The cleanup level the app applies, for the top strip.
    var levelLabel: String { KeyboardBridge.defaults?.string(forKey: KeyboardBridge.Key.levelLabel) ?? "Polished" }

    private weak var controller: KeyboardViewController?
    private var session: UUID?
    private var timer: Timer?
    private var requestedAt = Date.distantPast
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

    /// The keyboard appeared. iOS often starts a fresh keyboard process after you come back from the app, so
    /// the session lives in the App Group, not only in memory.
    func resume() {
        visible = true
        if !observing {
            observing = true
            KeyboardBridge.observe(KeyboardBridge.Note.state) { [weak self] in self?.poll() }
        }
        if session == nil, let s = KeyboardBridge.currentSession, let p = KeyboardBridge.phase,
           [.requested, .listening, .transcribing, .done].contains(p),
           defaults?.string(forKey: KeyboardBridge.Key.insertedSession) != s.uuidString {
            session = s
            switch p {
            case .listening: stage = .listening
            case .requested: stage = .waiting
            default: stage = .writing
            }
            requestedAt = Date()
        }
        poll()
        if stage == .waiting || stage == .listening || stage == .writing { startTimer() }
    }

    func pause() { visible = false; stopTimer() }

    // MARK: Actions

    func record() {
        guard hasFullAccess, let defaults else {
            notice = "Turn on Allow Full Access for Verbatim in Settings › General › Keyboard › Keyboards."
            return
        }
        let s = UUID()
        session = s
        insertion = nil
        notice = nil
        defaults.set(s.uuidString, forKey: KeyboardBridge.Key.session)
        defaults.set(KeyboardBridge.Phase.requested.rawValue, forKey: KeyboardBridge.Key.phase)
        defaults.removeObject(forKey: KeyboardBridge.Key.command)
        defaults.removeObject(forKey: KeyboardBridge.Key.text)
        defaults.removeObject(forKey: KeyboardBridge.Key.raw)
        requestedAt = Date()
        stage = .waiting
        if controller?.openContainingApp(KeyboardBridge.dictateURL(session: s)) != true {
            notice = "Couldn't open Verbatim. Open it yourself to start dictating."
        }
        startTimer()
    }

    func done() { send(.done); stage = .writing; level = 0 }

    func cancel() {
        send(.cancel)
        session = nil
        stage = .idle
        level = 0
        stopTimer()
    }

    /// Removes the inserted text.
    func undo() {
        guard let ins = insertion else { return }
        deleteBackward(ins.inserted.count)
        insertion = nil
        stage = .idle
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

    func space() { proxy?.insertText(" ") }
    func newline() { proxy?.insertText("\n") }
    func deleteOne() { proxy?.deleteBackward() }

    // MARK: Polling

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard visible, let session, let defaults, KeyboardBridge.currentSession == session, let phase = KeyboardBridge.phase else { return }
        switch phase {
        case .requested:
            // The app never answered (it didn't open, or you came back before it started).
            if Date().timeIntervalSince(requestedAt) > 20, stage == .waiting {
                notice = "Verbatim didn't start. Tap to try again."
                reset()
            }
        case .listening:
            stage = .listening
            level = defaults.double(forKey: KeyboardBridge.Key.level)
            elapsed = defaults.double(forKey: KeyboardBridge.Key.elapsed)
            notice = nil
        case .transcribing:
            stage = .writing
            level = 0
        case .done:
            insertResult()
        case .failed:
            notice = defaults.string(forKey: KeyboardBridge.Key.message) ?? "Dictation didn't finish."
            reset()
        case .cancelled:
            reset()
        }
    }

    private func insertResult() {
        guard let session, let defaults else { return }
        // Another keyboard instance (or an earlier run of this one) already inserted it.
        if defaults.string(forKey: KeyboardBridge.Key.insertedSession) == session.uuidString { reset(); return }
        defaults.set(session.uuidString, forKey: KeyboardBridge.Key.insertedSession)
        let text = (defaults.string(forKey: KeyboardBridge.Key.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (defaults.string(forKey: KeyboardBridge.Key.raw) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        stopTimer()
        self.session = nil
        level = 0
        guard !text.isEmpty else {
            notice = "No words were heard."
            stage = .idle
            return
        }
        // A space between your earlier words and the new ones.
        let before = proxy?.documentContextBeforeInput ?? ""
        let lead = (before.last.map { !$0.isWhitespace } ?? false) ? " " : ""
        let inserted = lead + text
        proxy?.insertText(inserted)
        insertion = Insertion(inserted: inserted, text: text, raw: raw, words: Self.wordCount(text))
        stage = .inserted
        notice = nil
    }

    private func reset() {
        stopTimer()
        session = nil
        level = 0
        stage = .idle
    }

    private func send(_ c: KeyboardBridge.Command) {
        guard let defaults, let session else { return }
        defaults.set(c.rawValue, forKey: KeyboardBridge.Key.command)
        defaults.set(session.uuidString, forKey: KeyboardBridge.Key.commandSession)
        KeyboardBridge.post(KeyboardBridge.Note.command)
    }

    private func deleteBackward(_ n: Int) {
        guard let proxy else { return }
        for _ in 0..<max(0, n) { proxy.deleteBackward() }
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}
