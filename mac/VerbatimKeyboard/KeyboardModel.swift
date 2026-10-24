import UIKit
import Combine
import os

/// The keyboard's state machine. With a session on: idle → listening → writing → inserted, all inside the
/// keyboard. Without one: idle → starting (Verbatim opens for a moment and comes back) → listening, when Start
/// dictating when you come back is on (the app began the dictation already), or idle with a session when it's off.
/// Reads and writes the App Group through `KeyboardBridge`; the app does the listening and transcription.
///
/// What shows (`mode`): Home (your numbers and Tap to talk) or Typing (the full keyboard with Start) at rest, and
/// Listening while a dictation starts, runs, is written down, or is polished. Words that go in land back in Typing.
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
        /// The dictation it came from (nil for a snippet), the field it went into, and when.
        var dictation: UUID? = nil
        var document: UUID? = nil
        var at = Date()
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var insertion: Insertion? = nil
    /// True while Verbatim polishes the text just inserted (Polish after inserting); the strip shows it.
    @Published private(set) var polishing = false
    /// Live words while listening: the settled part, and the newest words that may still change.
    @Published private(set) var liveSettled = ""
    @Published private(set) var liveVolatile = ""
    /// A short line shown under the record card (a failure, or how to turn on Full Access).
    @Published private(set) var notice: String? = nil
    @Published var showsGlobe = true
    /// Allow Full Access. Off until the controller reads it: nothing touches the App Group without it.
    @Published var hasFullAccess = false {
        didSet { typing.hasFullAccess = hasFullAccess }
    }
    /// The resting view: Home or Typing (`KeyboardSurface.opening` picks it on each appearance). Typing works
    /// without Full Access; Home explains why dictation needs it.
    @Published private(set) var surface: KeyboardSurface = .typing
    /// The Typing bar's menu card (Cleanup, Snippets, Recent dictations, Open Verbose).
    @Published private(set) var showingMenu = false
    /// Home's stats pages (from the app's `KeyboardBridge.Stats`), and the one showing. Empty before the first
    /// dictation, when Home shows its welcome line instead.
    @Published private(set) var statsPages: [KeyboardStatPage] = []
    @Published private(set) var statsPage = 0
    /// The letter keys.
    let typing = TypingModel()
    /// Whether the app holds a session (heartbeat fresh), and when its idle timeout ends it (nil: until you end it).
    @Published private(set) var sessionLive = false
    @Published private(set) var sessionEndsAt: Date? = nil
    @Published private(set) var micName = "iPhone Microphone"
    /// Ticks once a second while idle, so the session countdown moves.
    @Published private(set) var now = Date()
    /// Your snippets (synced with the Mac; the app writes them to the App Group), and whether the top strip shows them.
    @Published private(set) var snippets: [KeyboardBridge.Snippet] = []
    @Published private(set) var showingSnippets = false
    /// Your last few dictations (the app writes them to the App Group), and whether the top strip shows them.
    @Published private(set) var recent: [KeyboardBridge.Recent] = []
    @Published private(set) var showingRecent = false
    /// A short confirmation under the card ("Copied."), cleared after a moment.
    @Published private(set) var info: String? = nil
    /// What a spoken correction changed in the words just inserted ("Removed “meet at 2”"), with Use as spoken
    /// and Turn off. Cleared when the inserted state ends.
    @Published private(set) var correction: String? = nil

    /// The format chip: your choice for this session (Auto unless you change it), what the chip says ("Auto ·
    /// Mail", "Email"), and the cleanup category it sends with each dictation.
    @Published private(set) var format: KeyboardFormat = .auto
    @Published private(set) var formatLabel = "Auto"
    private var formatCategory = "personal"
    /// The app you're typing in, when the build can read it (never in App Store builds). Set on each appearance.
    var host: String?

    /// True when there's no session and this build's keyboard can't open Verbatim to start one (App Store
    /// builds): the card says how to start one instead of offering a record button.
    var needsSessionCard: Bool { !sessionLive && !Distribution.current.keyboardOpensVerbatim }

    /// The cleanup level the app applies, for the top strip.
    var levelLabel: String { defaults?.string(forKey: KeyboardBridge.Key.levelLabel) ?? "Polished" }

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
    /// When the Typing bar started showing "✓ Inserted", so it goes back to the plain bar after a few seconds.
    private var insertedBarSince: Date?
    /// The stats record last read, so an unchanged record isn't decoded again.
    private var statsData: Data?
    private var stats: KeyboardBridge.Stats?
    private static let log = Logger(subsystem: "co.stumpandroot.verbatim.keyboard", category: "polish")

    init(controller: KeyboardViewController) {
        self.controller = controller
        typing.controller = controller
        typing.onEdit = { [weak self] in self?.didType() }
    }

    var controllerForGlobe: UIInputViewController? { controller }
    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    /// The App Group, only with Allow Full Access. Without it the keyboard never reads or writes the shared
    /// container (App Store guideline 4.4.1: typing must work without Full Access).
    private var defaults: UserDefaults? { hasFullAccess ? KeyboardBridge.defaults : nil }

    // MARK: Modes

    /// A dictation in progress, or the polish of one just inserted: the keyboard shows Listening.
    var dictating: Bool {
        stage == .starting || stage == .listening || stage == .writing || (stage == .inserted && polishing)
    }

    var mode: KeyboardMode { KeyboardMode.current(surface: surface, dictating: dictating) }

    /// Picks the resting view for this appearance (`KeyboardSurface.opening`): Typing for number, email, link, and
    /// password fields, without Full Access, and after a dictation went in; Home otherwise. The last insertion time
    /// lives in the extension's own defaults, which need no Full Access and outlive a fresh keyboard process.
    func chooseSurface() {
        let last = UserDefaults.standard.double(forKey: KeyboardSurface.lastInsertedKey)
        let s = KeyboardSurface.opening(field: typing.field, secure: controller?.fieldIsSecure() ?? false,
                                        dictationAvailable: hasFullAccess,
                                        lastInsertedAt: last > 0 ? Date(timeIntervalSince1970: last) : nil, now: Date())
        if s != surface { surface = s }
        closePanels()
    }

    /// Home's close and ABC buttons.
    func showTyping() {
        surface = .typing
        notice = nil
        closePanels()
    }

    /// Shows Home: where Start goes when dictation can't start from here (no Full Access, or no session in a build
    /// that can't open Verbose), so its card can say why.
    func showHome() {
        surface = .home
        closePanels()
    }

    private func closePanels() {
        showingMenu = false
        showingSnippets = false
        showingRecent = false
    }

    /// The Typing bar's Start pill: dictates like Home's Tap to talk. When dictation can't start here, Home
    /// explains (Full Access, or how to start a session).
    func start() {
        guard hasFullAccess else { showHome(); return }
        if needsSessionCard && !KeyboardBridge.sessionLive { showHome(); return }
        record()
    }

    func toggleMenu() {
        showingMenu.toggle()
        if showingMenu { showingSnippets = false; showingRecent = false }
    }

    func closeMenu() { if showingMenu { showingMenu = false } }

    /// Home's Settings button and the menu's Open Verbose: opens the app with the keyboard's link mechanism
    /// (`openContainingApp`). Without Full Access, Home's card shows where to turn it on instead; in builds that
    /// can't open Verbose, a line says to open it yourself.
    func openVerbose() {
        showingMenu = false
        guard hasFullAccess else { showHome(); return }
        guard let url = URL(string: "\(KeyboardBridge.scheme)://open"),
              controller?.openContainingApp(url) == true else {
            flashInfo("Open Verbose from your Home Screen.")
            return
        }
    }

    // MARK: Home stats

    /// Tap or swipe left: the next page (wrapping). Swipe right: the one before.
    func nextStatsPage() { pageBy(1) }
    func previousStatsPage() { pageBy(-1) }

    private func pageBy(_ d: Int) {
        let n = statsPages.count
        guard n > 1 else { return }
        statsPage = (statsPage + d + n) % n
    }

    /// Re-reads the app's stats record (decoding it only when it changed) and works out the pages again, so a week
    /// that ended reads 0. Without Full Access there's no record.
    private func reloadStats() {
        let data = hasFullAccess ? KeyboardBridge.defaults?.data(forKey: KeyboardBridge.statsKey) : nil
        if data != statsData {
            statsData = data
            stats = data.flatMap { try? JSONDecoder().decode(KeyboardBridge.Stats.self, from: $0) }
        }
        var pages: [KeyboardStatPage] = []
        if let s = stats {
            pages = KeyboardStatsCopy.pages(KeyboardStatNumbers(
                weekWords: s.weekWords, weekSecondsSaved: s.weekSecondsSaved, weekCurrent: Date() < s.weekEnds,
                totalWords: s.totalWords, paceWords: s.paceWords, paceSeconds: s.paceSeconds, typingWPM: s.typingWPM))
        }
        if pages != statsPages { statsPages = pages }
        if statsPage >= max(1, pages.count) { statsPage = 0 }
    }

    /// A key in the typing view changed the text: an Undo for words inserted earlier no longer lines up.
    private func didType() {
        guard stage == .inserted else { return }
        insertion = nil
        polishing = false
        set(.idle)
    }

    // MARK: Lifecycle

    /// The keyboard appeared. iOS often starts a fresh keyboard process after you come back from the app, so the
    /// session and the dictation live in the App Group, not only in memory.
    func resume() {
        visible = true
        // Without Full Access there's no App Group: no session, no snippets, no recent dictations.
        guard hasFullAccess else {
            snippets = []
            recent = []
            showingSnippets = false
            showingRecent = false
            sessionLive = false
            reloadStats()
            return
        }
        reloadSnippets()
        reloadRecent()
        reloadStats()
        refreshFormat()
        markVisible()
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

    func pause() {
        visible = false
        closeMenu()
        stopTimer()
        // Gone from the screen: a take from the Action button now goes to the clipboard instead.
        defaults?.set(0.0, forKey: KeyboardBridge.Key.keyboardVisibleAt)
    }

    /// Tells the app this keyboard is on screen (written with every poll, at least once a second), so a take from
    /// the Action button, Control Center, or the Dynamic Island goes straight into this field instead of the
    /// clipboard (`Ribbon.route`). Only with Full Access: without it there's no App Group.
    private func markVisible() {
        defaults?.set(Date().timeIntervalSince1970, forKey: KeyboardBridge.Key.keyboardVisibleAt)
    }

    /// A take the app started from the Action button, Control Center, or the Dynamic Island while this keyboard is
    /// on screen: show it as listening, so its words go into this field when it's done.
    private func adoptRibbonTake() {
        guard visible, dictation == nil, request == nil, stage == .idle || stage == .inserted,
              let take = KeyboardBridge.ribbonTakeToAdopt(ribbonID: KeyboardBridge.uuid(KeyboardBridge.Key.ribbonID),
                                                          running: KeyboardBridge.currentRunningDictation) else { return }
        insertion = nil
        polishing = false
        notice = nil
        showingSnippets = false
        showingRecent = false
        clearLive()
        dictation = take.id
        level = 0
        elapsed = 0
        closePanels()
        set(take.phase == .listening ? .listening : .writing)
    }

    // MARK: Actions

    /// The record button: dictates at once while a session is on; otherwise starts one.
    func record() {
        guard hasFullAccess, let defaults else {
            notice = "Dictation needs Full Access. Turn it on in Settings › Verbose › Keyboards › Allow Full Access."
            return
        }
        insertion = nil
        polishing = false
        notice = nil
        closePanels()
        clearLive()
        if KeyboardBridge.sessionLive { startDictation(defaults) }
        else if needsSessionCard { return }   // The card shows the ways to start one.
        else { startSession(defaults) }
    }

    // MARK: Format chip

    /// Tapping the chip moves to the next format: Auto, Email, Message, Note. Kept for the session. While you
    /// talk it also applies to this dictation: the app reads the category when the dictation finishes.
    func cycleFormat() {
        guard hasFullAccess else { return }
        KeyboardBridge.format = format.next
        refreshFormat()
        if stage == .listening, let d = dictation { KeyboardBridge.writeCategory(formatCategory, for: d) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Re-reads the choice (the app resets it to Auto when a session ends) and works out Auto again from the
    /// host and the field.
    func refreshFormat() {
        guard hasFullAccess else { return }
        let choice = KeyboardBridge.format
        let traits = controller?.fieldTraits() ?? KeyboardFormat.FieldTraits()
        let resolved = KeyboardFormat.resolve(choice, host: host, traits: traits)
        if choice != format { format = choice }
        if resolved.label != formatLabel { formatLabel = resolved.label }
        formatCategory = resolved.category
    }

    /// Tells the app which cleanup category this dictation is for. Written before the start command.
    private func sendCategory(for d: UUID) {
        refreshFormat()
        KeyboardBridge.writeCategory(formatCategory, for: d)
    }

    // MARK: Haptics

    /// A tap you can feel when dictation starts and when you tap Done. Keyboards can play haptics only with
    /// Allow Full Access; without it, nothing plays.
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard hasFullAccess else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Step 1: a session request, then Verbatim opens for a moment and switches back here. With Start dictating
    /// when you come back on, the request also names a dictation, which the app begins as soon as the microphone
    /// is on, so you can talk the moment you're back.
    private func startSession(_ defaults: UserDefaults) {
        let r = UUID()
        request = r
        // The app starts the microphone from the link only when its request matches this one, written just now,
        // and switches back only to the app named here (BridgeTrust.decide).
        defaults.set(Date().timeIntervalSince1970, forKey: KeyboardBridge.Key.requestAt)
        if let host, !host.isEmpty { defaults.set(host, forKey: KeyboardBridge.Key.requestHost) }
        else { defaults.removeObject(forKey: KeyboardBridge.Key.requestHost) }
        defaults.set(r.uuidString, forKey: KeyboardBridge.Key.request)
        var d: UUID? = nil
        if KeyboardBridge.autoStart {
            let id = UUID()
            d = id
            dictation = id
            level = 0
            elapsed = 0
            sendCategory(for: id)
            defaults.set(id.uuidString, forKey: KeyboardBridge.Key.startID)
        }
        set(.starting)
        if controller?.openContainingApp(KeyboardBridge.sessionURL(request: r, host: host, dictation: d)) != true {
            notice = "Couldn't open Verbose. Open it yourself to start a session."
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
        sendCategory(for: d)
        defaults.set(d.uuidString, forKey: KeyboardBridge.Key.startID)
        KeyboardBridge.post(KeyboardBridge.Note.command)
        set(.listening)
        haptic(.medium)
        retime()
    }

    func done() {
        guard let d = dictation, stage == .listening else { return }
        defaults?.set(d.uuidString, forKey: KeyboardBridge.Key.doneID)
        KeyboardBridge.post(KeyboardBridge.Note.command)
        haptic(.light)
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
        clearLive()
        set(.idle)
        retime()
    }

    /// Listening's done button while polishing: stop waiting and keep the words as they went in.
    func skipPolish() {
        guard polishing else { return }
        polishing = false
        if let d = insertion?.dictation { report(d, "kept: you tapped done before the polished text arrived") }
        retime()
    }

    /// Removes the inserted text.
    func undo() {
        guard let ins = insertion else { return }
        deleteBackward(ins.inserted.count)
        insertion = nil
        polishing = false
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
        // You chose your own words: a polished version arriving later doesn't replace them.
        polishing = false
        correction = nil
    }

    // MARK: Snippets

    /// Shows or hides the snippet row. From the inserted state, the row replaces Undo.
    func toggleSnippets() {
        reloadSnippets()
        showingMenu = false
        if showingSnippets || snippets.isEmpty { showingSnippets = false; return }
        if stage == .inserted { insertion = nil; polishing = false; set(.idle) }
        guard stage == .idle else { return }
        notice = nil
        showingRecent = false
        showingSnippets = true
    }

    // MARK: Recent dictations

    /// Shows or hides the Recent row (the clock button). From the inserted state, the row replaces Undo.
    func toggleRecent() {
        reloadRecent()
        showingMenu = false
        if showingRecent { showingRecent = false; return }
        if recent.isEmpty { showingRecent = false; flashInfo("No dictations yet."); return }
        if stage == .inserted { insertion = nil; polishing = false; set(.idle) }
        guard stage == .idle else { return }
        notice = nil
        showingSnippets = false
        showingRecent = true
    }

    /// Inserts a recent dictation where the cursor is, with a space before it after a word, and offers Undo.
    func insertRecent(_ r: KeyboardBridge.Recent) {
        guard stage == .idle else { return }
        let before = proxy?.documentContextBeforeInput ?? ""
        let lead = (before.last.map { !$0.isWhitespace } ?? false) ? " " : ""
        let inserted = lead + r.text
        proxy?.insertText(inserted)
        showingRecent = false
        insertion = Insertion(inserted: inserted, text: r.text, raw: r.text, words: Self.wordCount(r.text))
        set(.inserted)
    }

    /// Copies a recent dictation (touch and hold). Writing the clipboard needs Full Access; without it, tap inserts.
    func copyRecent(_ r: KeyboardBridge.Recent) {
        guard hasFullAccess else {
            notice = "To copy, turn on Allow Full Access. Tap a dictation to insert it."
            return
        }
        UIPasteboard.general.string = r.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        flashInfo("Copied.")
    }

    func flashInfo(_ text: String) {
        notice = nil
        info = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.info == text { self?.info = nil }
        }
    }

    private func reloadRecent() {
        let list = hasFullAccess ? KeyboardBridge.readRecent() : []
        if list != recent { recent = list }
        if list.isEmpty { showingRecent = false }
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
        let list = hasFullAccess ? KeyboardBridge.readSnippets() : []
        if list != snippets { snippets = list }
        if list.isEmpty { showingSnippets = false }
    }

    func space() { proxy?.insertText(" ") }
    func newline() { proxy?.insertText("\n") }

    // MARK: Polling

    /// 10 times a second while something is happening; once a second otherwise (for the session countdown).
    private func retime() {
        guard visible else { return }
        let want: TimeInterval = (stage == .listening || stage == .writing || stage == .starting || polishing) ? 0.1 : 1.0
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
        if s != .inserted, correction != nil { correction = nil }
        if s != .inserted { insertedBarSince = nil }
    }

    /// "✓ Inserted" in the Typing bar goes back to the plain bar after a few seconds (`InsertedBar`); Undo goes
    /// with it. The clock starts once polishing is over, when the bar first shows.
    private func expireInsertedBar() {
        guard stage == .inserted, !polishing else { return }
        guard let since = insertedBarSince else { insertedBarSince = Date(); return }
        if InsertedBar.expired(shownFor: Date().timeIntervalSince(since), hasCorrection: correction != nil) {
            insertion = nil
            set(.idle)
        }
    }

    // MARK: Spoken corrections

    /// Live words strike out spoken corrections when Understand spoken corrections is on and cleanup isn't Literal.
    var liveCorrections: Bool { hasFullAccess && SpokenCorrections.enabled && levelLabel != "Literal" }

    /// After inserting: says what a spoken correction changed, so you learn it and can opt out. Start over and
    /// multi-sentence deletions always; small fixes the first few times (`SpokenCorrections.takeNotice`).
    private func noticeCorrections(raw: String, inserted text: String) {
        guard liveCorrections, !raw.isEmpty, raw != text else { return }
        let found = SpokenCorrections.apply(raw).corrections
        guard SpokenCorrections.takeNotice(for: found) else { return }
        correction = SpokenCorrections.summary(found)
    }

    /// The strip's Turn off: Settings › Understand spoken corrections off, in the App Group the app reads.
    func turnOffSpokenCorrections() {
        SpokenCorrections.enabled = false
        correction = nil
        flashInfo("Spoken corrections are off. Turn them back on in Settings.")
    }

    private func poll() {
        guard visible, let defaults else { return }
        now = Date()
        markVisible()
        readSession(defaults)
        adoptRibbonTake()
        switch stage {
        case .starting: pollStarting(defaults)
        case .listening, .writing: pollDictation(defaults)
        case .idle, .inserted: break
        }
        if polishing { pollPolish(defaults) }
        expireInsertedBar()
        if stage == .idle { reloadStats() }
        retime()
    }

    private func readSession(_ defaults: UserDefaults) {
        let live = hasFullAccess && KeyboardBridge.sessionLive
        if live != sessionLive {
            sessionLive = live
            // A session that ended reset the format chip to Auto.
            refreshFormat()
        }
        let ends = defaults.double(forKey: KeyboardBridge.Key.endsAt)
        let endsAt = live && ends > 0 ? Date(timeIntervalSince1970: ends) : nil
        if endsAt != sessionEndsAt { sessionEndsAt = endsAt }
        if let m = defaults.string(forKey: KeyboardBridge.Key.micName), !m.isEmpty, m != micName { micName = m }
    }

    private func pollStarting(_ defaults: UserDefaults) {
        guard let r = request else { set(.idle); return }
        if KeyboardBridge.uuid(KeyboardBridge.Key.requestFailed) == r {
            notice = defaults.string(forKey: KeyboardBridge.Key.requestMessage) ?? "Verbose couldn't start a session."
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
                haptic(.medium)
                pollDictation(defaults)
            } else {
                set(.idle)
            }
        } else if Date().timeIntervalSince(stageSince) > 20 {
            notice = "Verbose didn't start. Tap to try again."
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
            let settled = defaults.string(forKey: KeyboardBridge.Key.liveSettled) ?? ""
            let volatile = defaults.string(forKey: KeyboardBridge.Key.liveVolatile) ?? ""
            if settled != liveSettled { liveSettled = settled }
            if volatile != liveVolatile { liveVolatile = volatile }
            notice = nil
        case .transcribing:
            set(.writing)
            level = 0
            clearLive()
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
        // A take from the Action button that finished while this keyboard was away went to the clipboard instead.
        if defaults.string(forKey: KeyboardBridge.Key.routedAway) == d.uuidString {
            dictation = nil
            level = 0
            clearLive()
            set(.idle)
            reloadRecent()
            flashInfo("Copied. Paste it, or tap it in Recent.")
            return
        }
        defaults.set(d.uuidString, forKey: KeyboardBridge.Key.insertedID)
        let text = (defaults.string(forKey: KeyboardBridge.Key.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (defaults.string(forKey: KeyboardBridge.Key.raw) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        dictation = nil
        level = 0
        clearLive()
        guard !text.isEmpty else {
            notice = "No words were heard."
            set(.idle)
            return
        }
        // The polished text already arrived (the keyboard was away while it was made): insert that instead.
        var final = text
        if defaults.string(forKey: KeyboardBridge.Key.polishedID) == d.uuidString,
           defaults.string(forKey: KeyboardBridge.Key.polishedInserted)?.trimmingCharacters(in: .whitespacesAndNewlines) == text,
           let p = defaults.string(forKey: KeyboardBridge.Key.polishedText)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            final = p
            report(d, "inserted the polished text directly")
        }
        // A space between your earlier words and the new ones.
        let before = proxy?.documentContextBeforeInput ?? ""
        let lead = (before.last.map { !$0.isWhitespace } ?? false) ? " " : ""
        let inserted = lead + final
        proxy?.insertText(inserted)
        insertion = Insertion(inserted: inserted, text: final, raw: raw, words: Self.wordCount(final),
                              dictation: d, document: proxy?.safeDocumentIdentifier, at: Date())
        // Back to Typing with "✓ Inserted", and Typing again the next time the keyboard opens this session.
        surface = .typing
        closePanels()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: KeyboardSurface.lastInsertedKey)
        polishing = final == text && defaults.string(forKey: KeyboardBridge.Key.polishing) == d.uuidString
        set(.inserted)
        notice = nil
        noticeCorrections(raw: raw, inserted: final)
        reloadRecent()
        // Also copy each dictation: the app copies it; when it couldn't, the keyboard does (Full Access only).
        if KeyboardBridge.alwaysCopy, hasFullAccess, defaults.string(forKey: KeyboardBridge.copiedKey) != d.uuidString {
            KeyboardBridge.copyDictation(final)
            defaults.set(d.uuidString, forKey: KeyboardBridge.copiedKey)
        }
    }

    // MARK: Polish after inserting

    /// While polishing: swaps in the polished text when it arrives, or stops waiting when the app says none is
    /// coming, a new dictation starts, or the window passes.
    private func pollPolish(_ defaults: UserDefaults) {
        guard let ins = insertion, let d = ins.dictation else { polishing = false; return }
        if defaults.string(forKey: KeyboardBridge.Key.polishedID) == d.uuidString {
            polishing = false
            let sent = (defaults.string(forKey: KeyboardBridge.Key.polishedInserted) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let polished = (defaults.string(forKey: KeyboardBridge.Key.polishedText) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard sent == ins.text else { report(d, "kept: the inserted text isn't the text the polish started from"); return }
            swapPolished(ins, polished: polished)
        } else if defaults.string(forKey: KeyboardBridge.Key.polishing) != d.uuidString {
            // The app finished without a better version (or a newer dictation took over).
            polishing = false
        } else if Date().timeIntervalSince(ins.at) > KeyboardBridge.polishWindow {
            polishing = false
            report(d, "kept: no polished text within \(Int(KeyboardBridge.polishWindow)) s")
        }
    }

    /// Replaces exactly the inserted text with the polished text, only when the field still ends with it at the
    /// cursor (`KeyboardBridge.polishSwap`). Otherwise your text stays as it is.
    private func swapPolished(_ ins: Insertion, polished: String) {
        guard let d = ins.dictation else { return }
        guard visible, let proxy else { report(d, "kept: the keyboard isn't on screen"); return }
        let lead = ins.inserted.hasPrefix(" ") && !ins.text.hasPrefix(" ") ? " " : ""
        let decision = KeyboardBridge.polishSwap(inserted: ins.inserted, polished: lead + polished,
                                                 before: proxy.documentContextBeforeInput,
                                                 sameField: ins.document == proxy.safeDocumentIdentifier,
                                                 age: Date().timeIntervalSince(ins.at))
        switch decision {
        case .keep(let why):
            report(d, "kept: " + why)
        case .replace:
            deleteBackward(ins.inserted.count)
            let new = lead + polished
            proxy.insertText(new)
            var updated = ins
            updated.inserted = new
            updated.text = polished
            updated.words = Self.wordCount(polished)
            insertion = updated
            UISelectionFeedbackGenerator().selectionChanged()
            report(d, "swapped")
        }
    }

    /// Logs what happened to a polished text, here and (through the App Group) in Verbatim's log.
    private func report(_ d: UUID, _ outcome: String) {
        Self.log.notice("polish \(d.uuidString, privacy: .public): \(outcome, privacy: .public)")
        defaults?.set("\(d.uuidString.prefix(8)) " + outcome, forKey: KeyboardBridge.Key.polishOutcome)
        KeyboardBridge.post(KeyboardBridge.Note.command)
    }

    private func clearLive() {
        if !liveSettled.isEmpty { liveSettled = "" }
        if !liveVolatile.isEmpty { liveVolatile = "" }
    }

    private func deleteBackward(_ n: Int) {
        guard let proxy else { return }
        for _ in 0..<max(0, n) { proxy.deleteBackward() }
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}
