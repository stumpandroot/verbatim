import Foundation
import Combine
import UserNotifications

/// Runs templates (Model/Templates.swift) on transcripts, for both apps: the ones you ask for (Run, Run again, Try on,
/// a kind-change offer's Run) and the ones Run automatically starts when a recording finishes.
///
/// Templates run like the transcript actions: on the Original text with corrections, on device with Apple Intelligence,
/// in parts that are merged for long recordings (TranscriptActions.run). One runs at a time. An automatic run waits
/// until the recording's kind is known (AutoLabel), its summary is written, and no transcription is running, so it
/// never slows transcription; each recording gets one (its `AutoRunMark`), never again on a relaunch or a sync. A run
/// iOS stopped before it finished picks up at the next launch on the device that started it.
@MainActor
final class TemplateCenter: ObservableObject {
    static let shared = TemplateCenter()

    /// "Mac" or "iPhone", for the result's footer ("on this Mac").
    #if os(macOS)
    static let here = "Mac"
    #else
    static let here = "iPhone"
    #endif

    struct Job: Equatable {
        var transcript: UUID
        var template: UUID
        var auto: Bool
        var kind: RecordingKind?
        /// A result this run replaces when it lands (a kind-change offer's old result).
        var replacing: UUID? = nil
    }

    /// The job running now, if any.
    @Published private(set) var current: Job? = nil
    /// "Part 2 of 3" while a long transcript runs.
    @Published private(set) var progress: [UUID: String] = [:]
    /// Why the last run you asked for on a transcript didn't finish, until the next one.
    @Published private(set) var failures: [UUID: String] = [:]
    @Published private(set) var queue: [Job] = []

    /// True while a transcription runs (set by TranscriptionCoordinator): automatic runs wait for it.
    var transcribing: () -> Bool = { false }
    /// A short message when an automatic run finishes (a toast on the Mac, a banner on the iPhone).
    var announce: ((String) -> Void)? = nil
    /// Off in the self-tests, which never post notifications or call the model on their own.
    var automatic = true

    private weak var store: Store?
    /// Recordings that just finished, waiting for their kind and summary before Run automatically decides.
    private var pending: [UUID: Date] = [:]
    private var driver: Task<Void, Never>? = nil
    private var work: Task<TranscriptActions.Output, Error>? = nil

    func isRunning(_ id: UUID) -> Bool { current?.transcript == id }
    /// A recording that just finished, waiting for Run automatically to decide (the kind-change offer waits too).
    func isPending(_ id: UUID) -> Bool { pending[id] != nil }
    /// Running or queued on this transcript: the template's ID.
    func busyTemplate(_ id: UUID) -> UUID? { current?.transcript == id ? current?.template : queue.first { $0.transcript == id }?.template }

    /// Apple Intelligence can't run here: why, for the result block and the editor.
    static var unavailableReason: String? { Polish.status.reason.map { "Templates need Apple Intelligence. " + $0 } }

    // MARK: Asking

    /// Runs a template on a transcript now (Run, Run again, Run another template). Jumps ahead of automatic runs.
    func run(_ template: UUID, on id: UUID, store: Store, replacing: UUID? = nil, kind: RecordingKind? = nil) {
        self.store = store
        // A retired template runs what replaced it (TemplateLibrary.retired); a cut one has nothing to run.
        guard let template = TemplateLibrary.current(template) else { return }
        // Verbose Unlock on iPhone: templates other than Plan my day open the unlock sheet while locked (FeatureGate,
        // Model/Entitlement.swift). The Mac never enforces it.
        guard FeatureGate.allowsTemplate(template, ask: true) else { return }
        failures[id] = nil
        if let why = Self.unavailableReason { failures[id] = why; return }
        queue.removeAll { $0.transcript == id && $0.template == template && !$0.auto }
        let job = Job(transcript: id, template: template, auto: false, kind: kind, replacing: replacing)
        let firstAuto = queue.firstIndex { $0.auto } ?? queue.count
        queue.insert(job, at: firstAuto)
        kick()
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0.transcript == id && !$0.auto }
        if current?.transcript == id, current?.auto == false { work?.cancel() }
    }

    // MARK: Run automatically

    /// A recording finished transcribing (TranscriptionCoordinator, after its speakers): Run automatically decides
    /// once its kind and summary are in.
    func recordingFinished(_ id: UUID, store: Store) {
        self.store = store
        guard automatic, let t = store.transcript(id), t.autoRun == nil, !t.isDictation else { return }
        pending[id] = Date()
        kick()
    }

    /// At launch, once the library has loaded: runs this device's automatic runs that hadn't finished (iOS suspended
    /// the app, or it quit).
    func resumeWaiting(store: Store) {
        self.store = store
        guard automatic else { return }
        for t in store.transcripts where AutoRunRules.resumes(t, device: Device.id) {
            guard let m = t.autoRun, !queue.contains(where: { $0.transcript == t.id && $0.auto }),
                  let template = TemplateLibrary.current(m.templateId), FeatureGate.allowsTemplate(template) else { continue }
            queue.append(Job(transcript: t.id, template: template, auto: true, kind: m.kind))
        }
        if !queue.isEmpty { Log.note("templates: picking up \(queue.count) automatic run(s) from before") }
        kick()
    }

    /// Settings now, with assignments to templates that no longer exist turned Off.
    func autoSettings(_ store: Store) -> AutoRunSettings {
        AutoRunSettings.load().pruned(existing: Set(store.allTemplates.map(\.id)))
    }

    private func evaluatePending() {
        guard let store else { return }
        let settings = autoSettings(store)
        let templates = store.allTemplates
        for (id, since) in pending {
            guard let t = store.transcript(id) else { pending[id] = nil; continue }
            let waited = Date().timeIntervalSince(since)
            let labelPending = AutoLabel.enabled && t.wantsSuggestedKind && waited < AutoRunRules.labelWait
            switch AutoRunRules.decide(t, settings: settings, templates: templates, labelPending: labelPending) {
            case .waitForKind:
                continue
            case .run(let template, let kind):
                // Verbose Unlock on iPhone: while locked, only Plan my day runs on its own (Brain dump's plan stays free).
                guard FeatureGate.allowsTemplate(template) else {
                    pending[id] = nil
                    Log.note("templates: an automatic run waits for Verbose Unlock")
                    continue
                }
                // After the summary (while it's queued or running, and for at most ten minutes).
                if SummaryCenter.shared.isRunning(id), waited < 600 { continue }
                pending[id] = nil
                let name = templates.first { $0.id == template }?.name ?? "Template"
                store.update(id) { x in
                    guard x.autoRun == nil else { return }
                    x.autoRun = AutoRunMark(templateId: template, name: name, kind: kind, state: .waiting, device: Device.id)
                }
                queue.append(Job(transcript: id, template: template, auto: true, kind: kind))
                Log.note("templates: \(name) will run automatically for a \(kind.rawValue)")
            case .short:
                pending[id] = nil
                if let tid = settings.template(for: t.kind ?? .note) {
                    let name = templates.first { $0.id == tid }?.name ?? "Template"
                    store.update(id) { x in
                        guard x.autoRun == nil else { return }
                        x.autoRun = AutoRunMark(templateId: tid, name: name, kind: x.kind, state: .skipped, device: Device.id)
                    }
                }
                Log.note("templates: skipped a short recording")
            case .off, .alreadyRan, .notEligible:
                pending[id] = nil
            }
        }
    }

    // MARK: The queue

    private func kick() {
        guard driver == nil else { return }
        driver = Task { [weak self] in
            await self?.drive()
            self?.driver = nil
        }
    }

    /// One job at a time. Automatic runs wait while a transcription or a summary runs; the ones you ask for don't.
    private func drive() async {
        while true {
            evaluatePending()
            if let i = nextJob() {
                let job = queue.remove(at: i)
                await execute(job)
                continue
            }
            if pending.isEmpty && queue.isEmpty { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func nextJob() -> Int? {
        if let i = queue.firstIndex(where: { !$0.auto }) { return i }
        guard !queue.isEmpty, !transcribing(), SummaryCenter.shared.running.isEmpty else { return nil }
        return queue.firstIndex { !SummaryCenter.shared.isRunning($0.transcript) }
    }

    private func execute(_ job: Job) async {
        guard let store, let t = store.transcript(job.transcript), t.deletedAt == nil else { return }
        guard let tpl = TemplateLibrary.template(job.template, yours: store.templates) else {
            finishFailed(job, why: "This template was deleted.")
            return
        }
        if let why = Self.unavailableReason {
            finishFailed(job, why: why)
            return
        }
        current = job
        progress[job.transcript] = nil
        let instruction = TemplatePrompt.instruction(tpl), extracts = tpl.extracts, timestamps = tpl.usesTimestamps
        let id = job.transcript
        let task = Task.detached(priority: job.auto ? .utility : .userInitiated) { () throws -> TranscriptActions.Output in
            try await TranscriptActions.run(instruction: instruction, extracts: extracts, timestamps: timestamps, on: t) { i, n in
                Task { @MainActor in TemplateCenter.shared.progress[id] = n > 1 ? "Part \(i) of \(n)" : nil }
            }
        }
        work = task
        do {
            let out = try await task.value
            var r = TemplateResult(templateId: tpl.id, name: tpl.name, text: out.text, auto: job.auto, kind: job.auto ? job.kind : nil,
                                   madeOn: Self.here, skippedParts: out.skippedParts, totalParts: out.totalParts)
            // A kind-change offer's run takes the old automatic result's place, for the new kind.
            if job.replacing != nil, let k = job.kind { r.auto = true; r.kind = k }
            store.update(id) { x in
                x.addTemplateResult(r, replacing: job.replacing)
                if job.auto, x.autoRun?.templateId == tpl.id { x.autoRun?.state = .done; x.autoRun?.at = Date(); x.autoRun?.note = nil }
            }
            failures[id] = nil
            Log.note("templates: \(job.auto ? "ran automatically" : "ran") (\(out.totalParts) part(s), \(out.skippedParts) declined)")
            if job.auto { announceDone(tpl.name, transcript: id) }
        } catch is CancellationError {
            if job.auto { store.update(id) { $0.autoRun?.state = .failed; $0.autoRun?.note = "Stopped before it finished." } }
        } catch {
            finishFailed(job, why: (error as? LocalizedError)?.errorDescription ?? "Apple's on-device model didn't answer. Try again.")
        }
        work = nil
        current = nil
        progress[id] = nil
    }

    private func finishFailed(_ job: Job, why: String) {
        if job.auto {
            store?.update(job.transcript) { x in
                guard x.autoRun?.templateId == job.template else { return }
                x.autoRun?.state = .failed; x.autoRun?.note = why
            }
            Log.note("templates: an automatic run didn't finish")
        } else {
            failures[job.transcript] = why
        }
    }

    /// Notify me when it's done: a notification for recordings over 20 minutes, and a short message in the app.
    private func announceDone(_ name: String, transcript id: UUID) {
        guard let store, let t = store.transcript(id) else { return }
        announce?("\(name) is ready for \u{201C}\(t.title)\u{201D}")
        guard automatic, AutoRunRules.notifies(t, settings: AutoRunSettings.load()), Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let title = t.title
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = name
            c.body = "Ready for \u{201C}\(title)\u{201D}. Made on this \(TemplateCenter.here) by Apple Intelligence."
            c.userInfo = ["transcript": id.uuidString]
            center.add(UNNotificationRequest(identifier: "template-\(id.uuidString)", content: c, trigger: nil))
        }
    }
}

/// Run automatically's choices for the screens, saved per device as they change (AutoRunSettings).
@MainActor
final class TemplateSettingsModel: ObservableObject {
    static let shared = TemplateSettingsModel()
    @Published var settings = AutoRunSettings.load() {
        didSet { if settings != oldValue { settings.save() } }
    }

    /// The kind's template, or nil for Off.
    func binding(for kind: RecordingKind) -> UUID? { settings.template(for: kind) }

    func set(_ template: UUID?, for kind: RecordingKind) {
        var s = settings
        s.set(template, for: kind)
        settings = s
    }

    /// A template's chip for a kind: on runs it for that kind, off turns the kind Off (when it was this template's).
    func toggle(_ template: UUID, for kind: RecordingKind) {
        set(settings.template(for: kind) == template ? nil : template, for: kind)
    }

    /// A template of yours was deleted: its kinds go Off.
    func removed(_ template: UUID) {
        var s = settings
        for k in AutoRunSettings.kinds where s.template(for: k) == template { s.set(nil, for: k) }
        settings = s
    }
}

/// Try on: runs a template (saved or not) on a recording and shows the result, without saving anything.
@MainActor
final class TemplatePreview: ObservableObject {
    enum Phase: Equatable { case running, done, failed }
    @Published private(set) var phase: Phase = .running
    @Published private(set) var text = ""
    @Published private(set) var part = ""
    @Published private(set) var failure: String? = nil
    private var job: Task<Void, Never>? = nil
    private var runID = 0

    func start(_ template: TranscriptTemplate, on t: Transcript) {
        stop()
        let id = runID
        phase = .running; text = ""; part = ""; failure = nil
        if let why = TemplateCenter.unavailableReason { failure = why; phase = .failed; return }
        let instruction = TemplatePrompt.instruction(template), extracts = template.extracts, timestamps = template.usesTimestamps
        job = Task { @MainActor in
            do {
                let out = try await TranscriptActions.run(instruction: instruction, extracts: extracts, timestamps: timestamps, on: t) { i, n in
                    Task { @MainActor in if id == self.runID { self.part = n > 1 ? "Part \(i) of \(n)" : "" } }
                }
                guard id == self.runID else { return }
                self.text = out.text
                self.phase = .done
            } catch {
                guard id == self.runID, !(error is CancellationError) else { return }
                self.failure = (error as? LocalizedError)?.errorDescription
                self.phase = .failed
            }
        }
    }

    func stop() { runID += 1; job?.cancel(); job = nil }
}
