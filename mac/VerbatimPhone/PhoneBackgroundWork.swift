import UIKit
import BackgroundTasks

/// Keeps transcription going after you leave the app: a classic background task for each run, and on
/// iOS 26 one continued-processing task (with the system's progress banner) for the whole queue.
@MainActor
final class PhoneBackgroundWork {
    /// Whether a job is running or waiting. Checked when iOS hands over the continued-processing task.
    private let isBusy: @MainActor () -> Bool
    private var background: UIBackgroundTaskIdentifier = .invalid

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
    }

    /// Asks iOS for extra time so a transcript can finish after you leave the app. Long jobs pause when
    /// iOS suspends Verbatim and pick up again the next time it opens, after the last finished section.
    func begin() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Transcribe") { [weak self] in self?.end() }
    }

    func end() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background); background = .invalid
    }

    // MARK: Keep transcribing after you leave the app (iOS 26)

    /// iOS 26 lets work you started keep going after you lock the phone or switch apps, with a progress
    /// banner from the system. One task covers the whole queue and ends when the queue is empty.
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    private static let bgIdentifier = "co.stumpandroot.verbatim.ios.transcribe"
    private var bgRegistered = false
    private var bgTask: AnyObject? = nil
    private var bgSubmitted = false
    private var bgTicker: Timer? = nil

    func keepRunning() {
        guard #available(iOS 26, *), !bgSubmitted else { return }
        if !bgRegistered {
            bgRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgIdentifier, using: nil) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in self?.adopt(task) }
            }
        }
        guard bgRegistered else { return }
        let req = BGContinuedProcessingTaskRequest(identifier: Self.bgIdentifier, title: "Transcribing", subtitle: "Verbose keeps going while you're away")
        req.strategy = .fail
        do { try BGTaskScheduler.shared.submit(req); bgSubmitted = true }
        catch { Log.note("continued processing not available: \(error)") }
    }

    @available(iOS 26, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        guard isBusy() else { task.setTaskCompleted(success: true); bgSubmitted = false; return }
        bgTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 5
        task.expirationHandler = { [weak self, weak task] in
            // iOS needs the time back. The job stops where it is; the next time Verbatim opens, a long recording
            // picks up after its last finished section (SectionCheckpoint), a short one starts again.
            task?.setTaskCompleted(success: false)
            Task { @MainActor in self?.bgTask = nil; self?.bgSubmitted = false; self?.bgTicker?.invalidate() }
        }
        // The system banner expects steady progress. Long recordings report their share done after each section
        // (`fraction`); in between, and for short ones, the bar creeps toward 95%.
        bgTicker?.invalidate()
        bgTicker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let task = self.bgTask as? BGContinuedProcessingTask else { return }
                let p = task.progress
                let ceiling = self.reported.map { min(95, $0 + 3) } ?? 95
                if p.completedUnitCount < ceiling {
                    p.completedUnitCount = min(ceiling, p.completedUnitCount + max(1, (ceiling - p.completedUnitCount) / 12))
                }
            }
        }
    }

    /// The running job's share done (0…1, nil when unknown), as a percentage the banner never goes back from.
    private var reported: Int64? = nil

    /// Moves the system's progress bar to the job's real progress: a long recording reports after each section.
    func fraction(_ f: Double?) {
        guard let f else { return }
        let percent = Int64(max(0, min(1, f)) * 95)
        reported = percent
        guard #available(iOS 26, *), let task = bgTask as? BGContinuedProcessingTask else { return }
        if percent > task.progress.completedUnitCount { task.progress.completedUnitCount = percent }
    }

    /// Moves the system's progress banner along with the job's stage.
    func title(_ label: String) {
        guard #available(iOS 26, *), let task = bgTask as? BGContinuedProcessingTask else { return }
        task.updateTitle("Transcribing", subtitle: label)
    }

    /// The queue is empty: completes the continued-processing task.
    func finish() {
        guard #available(iOS 26, *) else { return }
        if let task = bgTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        }
        bgTask = nil; bgSubmitted = false
        bgTicker?.invalidate(); bgTicker = nil
        reported = nil
    }
}
