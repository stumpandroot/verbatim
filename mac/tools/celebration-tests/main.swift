import Foundation

// Celebrations (Verbatim/Model/CelebrationRules.swift, DESIGN.md §7): the rules (CelebrationChecks.swift, which both
// self-tests also run), then the sources that use them. Reads the Swift sources from the mac/ folder given as the
// first argument. Not part of any app target; run mac/tools/test-celebrations.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

CelebrationChecks.run { check($0, $1) }

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String { (try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8)) ?? "" }

/// Every Swift file under the given folders: (path relative to mac/, text).
func sources(_ dirs: [String]) -> [(String, String)] {
    var out: [(String, String)] = []
    for d in dirs {
        let root = mac.appendingPathComponent(d)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let u as URL in e where u.pathExtension == "swift" {
            let rel = d + "/" + u.path.dropFirst(root.path.count + 1)
            out.append((rel, (try? String(contentsOf: u, encoding: .utf8)) ?? ""))
        }
    }
    return out
}

/// The lines of code (not comments) in `text`.
func codeLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
}
func code(_ text: String) -> String { codeLines(text).joined(separator: "\n") }

/// The text of a declaration, from `start` to the next declaration at four spaces or less.
func body(_ text: String, _ start: String) -> String {
    guard let r = text.range(of: start) else { return "" }
    let rest = text[r.lowerBound...]
    let tail = rest.dropFirst(start.count)
    let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    @discardableResult", "\n    @MainActor", "\n    var ", "\n    private var ", "\n}\n"]
        .compactMap { tail.range(of: $0)?.lowerBound }
    return String(ends.min().map { rest[..<$0] } ?? rest)
}

/// A type's text, from `start` to the closing brace at the start of a line.
func typeBody(_ text: String, _ start: String) -> String {
    guard let r = text.range(of: start) else { return "" }
    let rest = text[r.lowerBound...]
    return String(rest.range(of: "\n}\n").map { rest[..<$0.lowerBound] } ?? rest)
}

/// True when `a` appears in `text` and before `b`.
func before(_ a: String, _ b: String, in text: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

// The shared component.
let kit = read("Verbatim/Views/Celebration.swift")
let kitCode = code(kit)
check("sources: Celebration.swift is there", kit.contains("struct CelebrationBurst<Content: View>: View"))
check("component: the word and the fill never take a tap, and the milestone never does either",
      body(kit, "    @MainActor func celebrationWord(").contains(".allowsHitTesting(false)") && body(kit, "    @MainActor func celebrationSweep(").contains(".allowsHitTesting(false)")
      && typeBody(kit, "struct MilestoneBurst").contains(".allowsHitTesting(false)"))
check("component: the fill sits behind (background) and the word over (overlay), so nothing changes size",
      body(kit, "    @MainActor func celebrationSweep(").contains("background {") && body(kit, "    @MainActor func celebrationWord(").contains("overlay(alignment: alignment)"))
check("component: no .animation modifier and nothing repeats (explicit transactions only)",
      !kitCode.contains(".animation(") && !kitCode.contains("repeatForever") && !kitCode.contains("PhaseAnimator(") == true)
check("component: the fill, bounce, and word use the approved curves",
      kitCode.contains(".timingCurve(T.fillCurve.x1, T.fillCurve.y1, T.fillCurve.x2, T.fillCurve.y2, duration: T.fill)")
      && kitCode.contains(".spring(duration: T.bounceDuration, bounce: T.bounceBounce)") && kitCode.contains(".spring(duration: T.riseDuration, bounce: T.riseBounce)")
      && kitCode.contains("T.bounceTarget(peak: script.size.peak)"))
check("component: Limit animation (and Reduce Motion) crossfades over 0.2 s, with no scale or offset",
      kitCode.contains("CelebrationMotion.of(limited: limited)") && kitCode.contains("withAnimation(.easeOut(duration: T.reduced)) { state.fill = 1")
      && kitCode.contains("@Environment(\\.limitMotion) private var limited"))
check("component: a tap during the burst jumps to the end, alongside the host's own taps",
      kitCode.contains("CelebrationCenter.shared.skip(t.id)") && kitCode.contains(".simultaneousGesture(state.active ?")
      && kitCode.contains("t.disablesAnimations = true"))
check("component: every hold ends early on a tap (no hold waits on a plain sleep)",
      kitCode.contains("_ = await celebrationWait(hold, ticket.id)") && kitCode.contains("_ = await celebrationWait(T.milestoneHold, id)")
      && !kitCode.contains("Task.sleep(nanoseconds: UInt64(hold *") && !kitCode.contains("Task.sleep(nanoseconds: UInt64(T.milestoneHold"))
check("component: the open transcript's Ready is an overlay that never takes a tap",
      typeBody(kit, "struct ReadyOverlay").contains("CelebrationBurst(ticket: ticket, script: .transcript)")
      && typeBody(kit, "struct ReadyOverlay").contains(".allowsHitTesting(false)"))
check("component: VoiceOver hears the word once, when it shows",
      kitCode.components(separatedBy: "AccessibilityNotification.Announcement(").count == 3 && typeBody(kit, "struct CelebrationPill").contains(".accessibilityHidden(true)"))
check("component: each burst is keyed to its ticket (its transcript)", kitCode.contains(".task(id: ticket?.id) { await play() }") && kitCode.contains(".task(id: ticket.id) { await play() }"))
check("component: the word is an ink pill in the serif face", typeBody(kit, "struct CelebrationPill").contains("design: .serif")
      && typeBody(kit, "struct CelebrationPill").contains(".background(Refined.onFill, in: Capsule())") && typeBody(kit, "struct CelebrationPill").contains(".foregroundStyle(Refined.lift)"))
check("component: a row waits for a swipe to settle", kitCode.contains("SwipeSettle.wait(sinceSwipe: center.sinceSwipe)") && kitCode.contains("waitsForSwipe: true"))
check("component: the haptic and sound are never lost when no surface starts", kitCode.contains("ReadyCelebration.startWithin") && kitCode.contains("self.didFill(t.id)"))
check("component: the milestone's digits change in place", typeBody(kit, "struct MilestoneBurst").contains(".contentTransition(.numericText(value: Double(total)))"))

// Targets.
let project = read("project.yml")
check("targets: Celebration.swift is in the iPhone app (the Mac takes all of Verbatim/)", project.contains("      - Verbatim/Views/Celebration.swift"))
check("targets: the watch has the rules (and SoundRules, which they read)",
      project.contains("      - Verbatim/Model/CelebrationRules.swift") && project.contains("      - Verbatim/Model/SoundRules.swift"))
let keyboardTarget = project.components(separatedBy: "  VerbatimKeyboard:").dropFirst().first?.components(separatedBy: "    info:").first ?? ""
check("targets: the keyboard extension has no celebrations", !keyboardTarget.contains("Celebration") && !keyboardTarget.isEmpty)

// Nowhere they shouldn't be.
let keyboard = sources(["VerbatimKeyboard"]).filter { $0.1.contains("Celebration") }.map(\.0)
check("nowhere: no celebration in the keyboard extension", keyboard.isEmpty, "\(keyboard)")
let panels = ["Verbatim/Flow/FlowBarView.swift", "Verbatim/Flow/FlowBar.swift", "Verbatim/Flow/Notch.swift", "Verbatim/Flow/Recall.swift", "Verbatim/Flow/SurfaceParts.swift"]
    .filter { read($0).contains("Celebration") }
check("nowhere: no celebration in the Mac's status-bar panels (the Ribbon, the notch, Recall)", panels.isEmpty, "\(panels)")

// iPhone.
let phone = read("VerbatimPhone/PhoneState.swift")
check("iPhone: Transcript ready offers Open, its fill sweeps the toast only when the toast is the surface, and it stays away otherwise",
      phone.contains("say(\"Transcript ready\", action: \"Open\", celebration: celebration?.surface == .toast ? celebration : nil)")
      && phone.contains("if ReadyCelebration.toastShows(queueEmpty: queueEmpty, surface: celebration?.surface) {"))
let ready = body(phone, "    private func playReady(")
check("iPhone: the surface comes from ReadyCelebration, once per recording (ReadyOnce), with the sound's rule; a row counts only with the Library tab showing",
      ready.contains("ReadyCelebration.surface(") && ready.contains("first: first") && ready.contains("!readyOnce.played.contains(id)")
      && ready.contains("SoundRules.transcriptDone(isDictation:") && ready.contains("rowOnScreen: tab == .library && center.rowOnScreen(id)") && ready.contains("transcriptOpen: center.isOpen(id)"), ready)
check("iPhone: a recording added to a transcript keeps its old haptic and message, with no celebration",
      body(phone, "    func appendReady(").contains("playReady(id, queueEmpty: queueEmpty)"))
let finish = body(phone, "    private func finishRecording(")
check("iPhone: the stop ring and Saved follow RecordingFinish, with Home under the recorder",
      finish.contains("RecordingFinish.phone(source: source, discard: discard, thought: thoughtStart != nil, homeUnderneath: tab == .home && homePath.isEmpty)")
      && finish.contains("if plan.savedChip { CelebrationCenter.shared.showSaved(after: CelebrationTiming.afterSheet) }")
      && before("savingRecording = true", "await recorder.stopAndSave(", in: finish) && before("await finishRing(", "showRecorder = false", in: finish))
let library = read("VerbatimPhone/LibraryScreen.swift")
check("iPhone: a transcribing row's badge is pale until it's ready", library.contains("static func badgeFill(_ t: Transcript) -> CGFloat { t.status == .processing ? 0 : 1 }")
      && library.contains("badgeFill: LibraryScreen.badgeFill(t), celebration: burst.active ? burst : nil"))
check("iPhone: rows say when they're on screen, and swipes tell the celebrations to wait",
      library.contains(".onAppear { celebrations.rowAppeared(transcript.id) }") && library.contains(".onDisappear { celebrations.rowLeft(transcript.id) }")
      && library.contains("CelebrationCenter.shared.swiped(); app.delete([t.id])"))
let refined = read("Verbatim/Views/RefinedKit.swift")
let paperRow = typeBody(refined, "struct PaperRow<Trailing: View>: View")
check("iPhone: a row's Ready and its disc are overlays and opacities; the row's frame is unchanged",
      paperRow.contains(".celebrationWord(burst == nil ? nil : CelebrationWord.ready") && paperRow.contains("trailing.opacity(burst?.old ?? 1)")
      && paperRow.contains(".frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)"))
check("iPhone: the pale badge is the kind's tint with an ink glyph, the disc growing from the center",
      typeBody(refined, "struct KindBadge: View").contains("Circle().fill(KindBadge.tint(hue))") && typeBody(refined, "struct KindBadge: View").contains(".scaleEffect(max(0.0001, fill))")
      && typeBody(refined, "struct KindBadge: View").contains("color: Refined.ink).opacity(Double(1 - fill))"))
let screen = read("VerbatimPhone/TranscriptScreen.swift")
check("iPhone: a transcript that finishes while open shows its text and tabs at once, with Ready over them",
      screen.contains("if ReadyReveal.showsProcessingCard(processing: t.status == .processing, celebrating: readyTicket != nil) {")
      && screen.contains("if ReadyReveal.showsContent(ready: t.status == .ready, celebrating: readyTicket != nil) {")
      && !screen.contains("readyTicket == nil") && !screen.contains("|| readyTicket != nil")
      && screen.contains(".overlay(alignment: .top) { ReadyOverlay(ticket: readyTicket") && screen.contains(".celebrationTapSkips(readyTicket?.id)")
      && screen.contains("celebrations.transcriptAppeared(id)") && screen.contains("celebrations.transcriptLeft(id)"))
check("iPhone: the recorder closes once the recording is saved, never waiting on the ring",
      body(phone, "    private func finishRing(").contains("RecordingFinish.closeDelay(saved: saved)")
      && !body(phone, "    private func finishRing(").contains("hapticDelay"))
let home = read("VerbatimPhone/HomeScreen.swift")
check("iPhone: Home shows a waiting milestone when it appears or comes back, never from the tally",
      home.contains("showMilestone()\n        }") && home.contains("if phase == .active { showMilestone() }")
      && read("VerbatimPhone/DictationTally.swift").contains("MilestoneStore.shared.note(old: allTime.words, new: totals.0.words)")
      && !read("VerbatimPhone/DictationTally.swift").contains("showMilestone"))
check("iPhone: Saved is on the Record card, the milestone on This week", home.contains("CelebrationBurst(ticket: celebrations.saved, script: .saved)")
      && home.contains(".milestoneOverlay(celebrations.milestone, radius: RefinedPlatform.radius(.card))"))
let recorder = read("VerbatimPhone/RecorderSheet.swift")
check("iPhone: the stop ring fills on the recorder, and a tap anywhere on it skips", recorder.contains("CelebrationBurst(ticket: celebrations.ring, script: .ring")
      && recorder.contains(".celebrationTapSkips(celebrations.ring?.id)"))
let toast = read("VerbatimPhone/PhoneApp.swift")
check("iPhone: the toast's fill sweeps behind its words", toast.contains("CelebrationBurst(ticket: t.celebration, script: .toast") && toast.contains("Capsule().fill(c.tone.fill)"))

// Mac.
let pipeline = read("Verbatim/App/AppState+Pipeline.swift")
let macReady = body(pipeline, "    func transcriptReady(")
check("Mac: a transcript celebrates only with Verbose in front, on the open transcript or the toast",
      macReady.contains("foreground: NSApp.isActive") && macReady.contains("rowOnScreen: false") && macReady.contains("phone: false")
      && macReady.contains("center.firstReady(id)") && macReady.contains("if ReadyCelebration.toastShows(queueEmpty: queueEmpty, surface: celebration?.surface) {"), macReady)
check("Mac: a thought fills in its words quietly, before any celebration", before("t.kind == .idea, t.sourceLabel == Thoughts.macSource", "ReadyCelebration.surface(", in: macReady))
let homeMac = read("Verbatim/Views/HomeView.swift")
check("Mac: Saved follows only a click on Home's recording card", homeMac.contains("app.stopRecording(from: AppState.clickedNow ? .homeCardClick : .keyboard)")
      && read("Verbatim/App/AppState+Capture.swift").contains("RecordingFinish.mac(source: source, thought: false, homeOnScreen: screen == .home, appActive: NSApp.isActive)"))
check("Mac: the milestone shows on This week when Home appears or comes to the front", homeMac.contains("checkWhatsNew(); showMilestone() }")
      && homeMac.contains("now = Date(); showMilestone() }") && read("Verbatim/Flow/Activity.swift").contains("MilestoneStore.shared.note(old: before, new: totalWords)"))
check("Mac: a reset of the numbers leaves the celebrated milestones alone", !body(read("Verbatim/Flow/Activity.swift"), "    func reset()").contains("MilestoneStore"))
let transcriptMac = read("Verbatim/Views/TranscriptView.swift")
check("Mac: a transcript that finishes while open shows its text and tabs at once, with Ready over them",
      transcriptMac.contains("if ReadyReveal.showsProcessingCard(processing: t.status == .processing, celebrating: readyTicket != nil) { processing(t)")
      && !transcriptMac.contains("|| readyTicket != nil") && transcriptMac.contains(".overlay(alignment: .top) { ReadyOverlay(ticket: readyTicket")
      && transcriptMac.contains(".celebrationTapSkips(readyTicket?.id)") && transcriptMac.contains("celebrations.transcriptAppeared(id)"))
let bubble = read("Verbatim/Flow/ThoughtBubble.swift")
check("Mac: a thought's check fills once after a click on the bubble, never from the hotkey",
      bubble.contains("capture?.toggle(source: .bubbleClick)") && bubble.components(separatedBy: ".modifier(CheckFill(fills: capture.checkFills, key: at))").count == 3
      && read("Verbatim/Flow/Thoughts.swift").contains("RecordingFinish.mac(source: source, thought: true"))

// Watch.
let watch = read("VerbatimWatch/WatchScreens.swift")
check("watch: the ring trims and the check pops when you stopped it, held still with the wrist down",
      watch.contains("WatchSentMotion.of(stoppedByYou: note == nil, luminanceReduced: dimmed, limited: limitMotion)")
      && watch.contains("@Environment(\\.isLuminanceReduced) private var dimmed") && watch.contains(".onChange(of: dimmed)"))

// Self-tests and the spec.
check("self-tests: both run CelebrationChecks and take the stills",
      read("VerbatimPhone/PhoneUITest.swift").contains("CelebrationChecks.run") && read("Verbatim/App/UITest.swift").contains("CelebrationChecks.run")
      && read("VerbatimPhone/PhoneUITest.swift").contains("p16f-home-milestone") && read("Verbatim/App/UITest.swift").contains("02j-home-week-milestone"))
let design = read("DESIGN.md")
check("spec: DESIGN.md §7 records the celebrations, the haptic, and the pale badge",
      design.contains("**Celebrations**") && design.contains("`recordingSaved`") && design.contains("pale"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
