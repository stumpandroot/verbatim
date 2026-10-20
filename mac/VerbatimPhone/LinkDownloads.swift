import Foundation

/// Link downloads on a background URLSession: they keep going after you leave Verbatim, and a relaunch picks up the
/// same download instead of starting over.
///
/// - Direct files: one download task. If iOS stops it (you force-quit Verbatim), the resume data is saved and the
///   next try continues from there.
/// - Chunked (YouTube): 8 MB ranged download tasks appended to `link-<id>.<ext>.part`. The delegate schedules the
///   next chunk itself, so the chain continues while Verbatim is in the background (iOS paces background tasks, so
///   it may slow down). After a relaunch the part file's size is the offset to continue from.
///
/// Files are named by transcript: `link-<id>.<ext>` once finished, so a download that finished while Verbatim was
/// closed is found by `finished(_:)`. Every task carries its `Job` in `taskDescription`.
final class LinkDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = LinkDownloads()
    static let identifier = "co.stumpandroot.verbatim.ios.links"
    private static let chunk: Int64 = 8 * 1024 * 1024

    /// iOS's completion handler when it wakes Verbatim for this session's events (PhoneAppDelegate).
    static var backgroundCompletion: (() -> Void)?

    struct Job: Codable {
        var id: UUID
        /// One start of a download. Events from an older run (cancelled, or replaced by a retry) are ignored.
        var run: UUID
        var url: URL
        var ext: String
        var chunked: Bool
        var offset: Int64 = 0
        var total: Int64?
        var userAgent: String?
    }

    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var reporters: [UUID: @Sendable (Double?) -> Void] = [:]
    private var runs: [UUID: UUID] = [:]
    /// Tasks whose events are already handled in didFinishDownloadingTo (a next chunk, or a failure).
    private var handled: [Int: Error?] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "LinkDownloads"
        session = URLSession(configuration: c, delegate: self, delegateQueue: q)
    }

    /// Recreates the session at launch, so iOS delivers events for downloads that finished while Verbatim was closed.
    func activate() { _ = session }

    // MARK: Files

    private static func base(_ id: UUID) -> String { "link-\(id.uuidString)" }
    private static func finalURL(_ id: UUID, _ ext: String) -> URL { Paths.downloads.appendingPathComponent("\(base(id)).\(ext)") }
    private static func partURL(_ id: UUID, _ ext: String) -> URL { Paths.downloads.appendingPathComponent("\(base(id)).\(ext).part") }
    private static func resumeURL(_ id: UUID) -> URL { Paths.downloads.appendingPathComponent("\(base(id)).resume") }
    private static func jobURL(_ id: UUID) -> URL { Paths.downloads.appendingPathComponent("\(base(id)).job") }
    private static let bookkeeping: Set<String> = ["part", "resume", "job"]

    /// The finished file for this transcript, if a download completed (perhaps while Verbatim was closed).
    func finished(_ id: UUID) -> URL? {
        let prefix = Self.base(id) + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.downloads.path)) ?? []
        guard let name = names.first(where: { $0.hasPrefix(prefix) && !Self.bookkeeping.contains(($0 as NSString).pathExtension) }) else { return nil }
        return Paths.downloads.appendingPathComponent(name)
    }

    private func removeFiles(_ id: UUID) {
        let prefix = Self.base(id) + "."
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Paths.downloads.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: Paths.downloads.appendingPathComponent(name))
        }
    }

    private static func size(_ u: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value
    }

    private static func savedJob(_ id: UUID) -> Job? {
        (try? Data(contentsOf: jobURL(id))).flatMap { try? JSONDecoder().decode(Job.self, from: $0) }
    }

    private static func save(_ job: Job) {
        if let d = try? JSONEncoder().encode(job) { try? d.write(to: jobURL(job.id)) }
    }

    private func job(of task: URLSessionTask) -> Job? {
        task.taskDescription.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Job.self, from: $0) }
    }

    // MARK: Starting, waiting, cancelling

    /// Downloads `url` for transcript `id`, continuing an earlier attempt when there is one. Progress is 0…1, or nil.
    func download(id: UUID, url: URL, ext: String, chunked: Bool, userAgent: String?, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        if let f = finished(id) { return f }
        return try await wait(id, progress: progress) { [self] in
            if await self.isRunning(id) { return }
            self.start(id: id, url: url, ext: ext, chunked: chunked, userAgent: userAgent)
        }
    }

    /// Waits for a download already under way for transcript `id` (it outlives the app). Nil when there's none.
    func attach(id: UUID, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL? {
        if let f = finished(id) { return f }
        guard await isRunning(id) else { return nil }
        return try await wait(id, progress: progress, then: nil)
    }

    private func isRunning(_ id: UUID) async -> Bool {
        let tasks: [URLSessionTask] = await session.allTasks
        for t in tasks where t.state == .running || t.state == .suspended {
            guard let j = job(of: t), j.id == id else { continue }
            adopt(j)
            return true
        }
        return false
    }

    /// After a relaunch, a running task's run becomes the current one.
    private func adopt(_ j: Job) {
        lock.lock(); if runs[j.id] == nil { runs[j.id] = j.run }; lock.unlock()
    }

    private func start(id: UUID, url: URL, ext: String, chunked: Bool, userAgent: String?) {
        try? FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        var job = Job(id: id, run: UUID(), url: url, ext: ext, chunked: chunked, userAgent: userAgent)
        lock.lock(); runs[id] = job.run; lock.unlock()
        let task: URLSessionDownloadTask
        if chunked {
            // A part file from an earlier try: continue after its last byte (the server's total is checked later).
            let part = Self.partURL(id, ext)
            if let have = Self.size(part), have > 0, let saved = Self.savedJob(id), saved.chunked, saved.ext == ext {
                job.offset = have; job.total = saved.total
            } else {
                try? FileManager.default.removeItem(at: part)
            }
            task = session.downloadTask(with: request(job))
        } else if let data = try? Data(contentsOf: Self.resumeURL(id)), Self.savedJob(id)?.url == url {
            try? FileManager.default.removeItem(at: Self.resumeURL(id))
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: request(job))
        }
        Self.save(job)
        describe(task, job)
        task.resume()
    }

    private func request(_ job: Job) -> URLRequest {
        var req = URLRequest(url: job.url)
        if let ua = job.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if job.chunked { req.setValue("bytes=\(job.offset)-\(job.offset + Self.chunk - 1)", forHTTPHeaderField: "Range") }
        return req
    }

    private func describe(_ task: URLSessionTask, _ job: Job) {
        task.taskDescription = (try? JSONEncoder().encode(job)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func wait(_ id: UUID, progress: @escaping @Sendable (Double?) -> Void, then begin: (@Sendable () async -> Void)?) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.lock()
                let old = waiters.updateValue(c, forKey: id)
                reporters[id] = progress
                lock.unlock()
                old?.resume(throwing: CancellationError())
                Task {
                    if let begin { await begin() }
                    // It may have finished, or stopped, before this waiter was registered.
                    if let f = self.finished(id) { self.resolve(id, .success(f)) }
                    else if !(await self.isRunning(id)) { self.resolve(id, .failure(LinkFetchError.message("The download stopped. Choose Retry to try again."))) }
                }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    private func resolve(_ id: UUID, _ result: Result<URL, Error>) {
        lock.lock()
        let c = waiters.removeValue(forKey: id)
        reporters[id] = nil
        lock.unlock()
        c?.resume(with: result)
    }

    /// Stops transcript `id`'s download and removes its files.
    func cancel(_ id: UUID) {
        lock.lock()
        let stopped = UUID()
        runs[id] = stopped
        lock.unlock()
        removeFiles(id)
        resolve(id, .failure(CancellationError()))
        session.getAllTasks { tasks in
            self.lock.lock(); let current = self.runs[id]; self.lock.unlock()
            for t in tasks { if let j = self.job(of: t), j.id == id, j.run != current { t.cancel() } }
        }
    }

    /// Whether this task belongs to the current run of its download (adopting it after a relaunch).
    private func isCurrent(_ job: Job) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let r = runs[job.id] { return r == job.run }
        runs[job.id] = job.run
        return true
    }

    private func report(_ id: UUID, _ fraction: Double?) {
        lock.lock(); let r = reporters[id]; lock.unlock()
        r?(fraction)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = job(of: downloadTask), isCurrent(job) else { return }
        if job.chunked {
            report(job.id, job.total.map { min(1, Double(job.offset + totalBytesWritten) / Double(max(1, $0))) })
        } else {
            report(job.id, totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = job(of: downloadTask), isCurrent(job) else { return }
        let fm = FileManager.default
        let http = downloadTask.response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else { handled[downloadTask.taskIdentifier] = LinkFetchError.http(code); return }
        let dest = Self.finalURL(job.id, job.ext)
        do {
            if !job.chunked || code == 200 {
                // The whole file (a direct download, or a server that ignored the Range header).
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: location, to: dest)
                try? fm.removeItem(at: Self.partURL(job.id, job.ext))
                try? fm.removeItem(at: Self.jobURL(job.id))
                return
            }
            let part = Self.partURL(job.id, job.ext)
            let total = http?.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: "/").last }.flatMap { Int64($0) }
            var next = job
            next.total = total ?? job.total
            let have = Self.size(part) ?? 0
            if let t = total, let was = job.total, t != was, job.offset > 0 {
                // A different file than the part we kept (the stream changed): start over.
                try? fm.removeItem(at: part)
                next.offset = 0
            } else if have == job.offset {
                if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
                let h = try FileHandle(forWritingTo: part)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: try Data(contentsOf: location))
                next.offset = Self.size(part) ?? have
            } else if have > job.offset {
                next.offset = have   // this chunk was already appended
            } else {
                try? fm.removeItem(at: part)
                next.offset = 0
            }
            let gotNothing = next.offset == job.offset && next.offset > 0
            if let t = next.total, next.offset >= t || gotNothing {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: part, to: dest)
                try? fm.removeItem(at: Self.jobURL(job.id))
                return
            }
            if next.total == nil && gotNothing {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: part, to: dest)
                return
            }
            report(job.id, next.total.map { min(1, Double(next.offset) / Double(max(1, $0))) })
            Self.save(next)
            let task = session.downloadTask(with: request(next))
            describe(task, next)
            task.resume()
            handled[downloadTask.taskIdentifier] = .some(nil)   // continues in the next chunk
        } catch {
            handled[downloadTask.taskIdentifier] = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let marked = handled.removeValue(forKey: task.taskIdentifier)
        guard let job = job(of: task), isCurrent(job) else { return }
        if let error {
            let ns = error as NSError
            if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !job.chunked {
                try? data.write(to: Self.resumeURL(job.id))   // the next try continues from here
            }
            if (error as? URLError)?.code == .cancelled, ns.userInfo[NSURLSessionDownloadTaskResumeData] == nil { return }
            resolve(job.id, .failure(error))
            return
        }
        switch marked {
        case .some(.some(let failure)): resolve(job.id, .failure(failure))
        case .some(.none): break   // the next chunk is running
        case .none:
            if let f = finished(job.id) { resolve(job.id, .success(f)) }
            else { resolve(job.id, .failure(LinkFetchError.message("The download finished without a file."))) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let done = LinkDownloads.backgroundCompletion
            LinkDownloads.backgroundCompletion = nil
            done?()
        }
    }
}
