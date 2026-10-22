import Foundation

/// The network half of cloud share links (CloudShareLink.swift has the rules). Shared by the Mac and the iPhone:
///
/// - `resolve(_:)` turns a plan into a confirmed direct-download URL: it asks iCloud for its download URL, then
///   opens the URL and reads the first bytes. A web page instead of a file is read to see why (Drive's virus-scan
///   page is followed once; a sign-in page is a private link). Nothing is kept from the probe.
/// - `download(_:into:progress:)` downloads the file with progress on the Mac. The iPhone downloads on its
///   background session instead (LinkDownloads.swift) and checks the result with `checkDownloadedFile(_:service:)`.
enum CloudShareFetch {
    /// A cloud file, ready to download.
    struct Target: Sendable {
        var url: URL
        var service: CloudShareLink.Service
        /// The original file name: Content-Disposition, else the link's own hint.
        var fileName: String?
        var mime: String?
        /// Bytes, when the server says.
        var length: Int64?

        /// The Library title: the file name without its extension.
        var title: String? { fileName.map(CloudShareLink.title(fromFileName:)) }
        /// The download's extension, from the name or the Content-Type.
        var ext: String? { CloudShareLink.fileExtension(fileName: fileName, mime: mime) }
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: Resolving

    static func resolve(_ plan: CloudShareLink.Plan, session: URLSession = .shared) async throws -> Target {
        let service = plan.service
        var url: URL
        var name = plan.nameHint
        switch plan.request {
        case .get(let u):
            url = u
        case .iCloudResolve(let id):
            let r = try await resolveICloud(id, nameHint: name, session: session)
            url = r.url
            name = r.fileName ?? name
        }
        do {
            return try await probe(url, name: name, service: service, session: session)
        } catch let first as CloudShareLink.Failure where first != .folder {
            // OneDrive: the shares API can refuse a link the share page itself still serves.
            guard let fallback = plan.fallback else { throw first }
            Log.note("cloud link: trying the fallback download (\(service.name))")
            do { return try await probe(fallback, name: name, service: service, session: session) } catch is CloudShareLink.Failure { throw first }
        }
    }

    /// Opens a download URL and reads its first bytes: the file, or the reason it isn't one.
    private static func probe(_ start: URL, name: String?, service: CloudShareLink.Service, session: URLSession) async throws -> Target {
        var url = start
        // Twice at most: Drive's virus-scan page names the real download once.
        for attempt in 0..<2 {
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else { bytes.task.cancel(); throw CloudShareLink.Failure.webPage(service) }
            let final = http.url ?? url
            if CloudShareLink.isLoginPage(final) { bytes.task.cancel(); throw CloudShareLink.Failure.privateLink }
            if let f = CloudShareLink.failure(status: http.statusCode, service: service) { bytes.task.cancel(); throw f }
            let mime = (http.mimeType ?? "").lowercased()
            var head = Data()
            if !mime.contains("html") {
                for try await b in bytes {
                    head.append(b)
                    if head.count >= 1024 { break }
                }
                if !CloudShareLink.looksLikeHTML(head) {
                    bytes.task.cancel()
                    let disposition = http.value(forHTTPHeaderField: "Content-Disposition")
                    let length = http.expectedContentLength > 0 ? http.expectedContentLength : nil
                    return Target(url: final, service: service, fileName: CloudShareLink.fileName(contentDisposition: disposition) ?? name,
                                  mime: mime.isEmpty ? nil : mime, length: length)
                }
            }
            // A web page: read it (up to 2 MB) and find out why.
            var page = head
            for try await b in bytes {
                page.append(b)
                if page.count > 2_000_000 { break }
            }
            bytes.task.cancel()
            let html = String(decoding: page, as: UTF8.self)
            if attempt == 0, service == .googleDrive, let next = CloudShareLink.driveConfirmURL(fromHTML: html, base: final) {
                url = next
                continue
            }
            throw CloudShareLink.pageFailure(html: html, finalURL: final, service: service)
        }
        throw CloudShareLink.Failure.webPage(service)
    }

    /// CloudKit's public `records/resolve`: the file's download URL and name. Anything unexpected is a clear error.
    private static func resolveICloud(_ id: String, nameHint: String?, session: URLSession) async throws -> (url: URL, fileName: String?) {
        var req = URLRequest(url: CloudShareLink.iCloudResolveEndpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.icloud.com", forHTTPHeaderField: "Origin")
        req.httpBody = CloudShareLink.iCloudRequestBody(shortGUID: id)
        let answer: (Data, URLResponse)
        do {
            answer = try await session.data(for: req)
        } catch let e as URLError where e.code != .notConnectedToInternet && e.code != .cancelled {
            Log.note("iCloud resolve failed: \(e.code.rawValue)")
            throw CloudShareLink.Failure.iCloudUnavailable
        }
        let data = answer.0
        let status = (answer.1 as? HTTPURLResponse)?.statusCode ?? 0
        do {
            return try CloudShareLink.iCloudResult(from: data, nameHint: nameHint)
        } catch CloudShareLink.Failure.iCloudUnavailable {
            Log.note("iCloud resolve gave no file (status \(status))")
            if status == 401 || status == 403 { throw CloudShareLink.Failure.privateLink }
            if status == 404 { throw CloudShareLink.Failure.gone }
            throw CloudShareLink.Failure.iCloudUnavailable
        }
    }

    // MARK: Checking a download

    /// Throws when a downloaded file is a web page rather than the media (and removes it).
    static func checkDownloadedFile(_ file: URL, service: CloudShareLink.Service) throws {
        guard let h = try? FileHandle(forReadingFrom: file) else { return }
        let head = (try? h.read(upToCount: 1024)) ?? Data()
        try? h.close()
        guard CloudShareLink.looksLikeHTML(head) else { return }
        let page = (try? Data(contentsOf: file)).map { String(decoding: $0.prefix(2_000_000), as: UTF8.self) } ?? ""
        try? FileManager.default.removeItem(at: file)
        throw CloudShareLink.pageFailure(html: page, finalURL: nil, service: service)
    }

    // MARK: Downloading (Mac)

    /// Downloads a target into `folder` as `<stamp>.<ext>`, with progress 0…1 (nil when the size isn't known).
    /// Cancelling the calling Task stops the download. Returns the file and the server's file name, when it gives one.
    static func download(_ target: Target, into folder: URL, stamp: String,
                         progress: @escaping @Sendable (Double?) -> Void) async throws -> (file: URL, fileName: String?) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = target.ext ?? "mp4"
        let dest = folder.appendingPathComponent("\(stamp).\(ext)")
        let loader = Downloader(dest: dest, service: target.service, progress: progress)
        let result = try await loader.run(target.url)
        try checkDownloadedFile(result.file, service: target.service)
        return result
    }

    /// One download with progress, on its own URLSession (invalidated when it ends).
    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let dest: URL
        private let service: CloudShareLink.Service
        private let progress: @Sendable (Double?) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(file: URL, fileName: String?), Error>?
        private var outcome: Result<(file: URL, fileName: String?), Error>?
        private var task: URLSessionDownloadTask?
        private var lastPercent = -2

        init(dest: URL, service: CloudShareLink.Service, progress: @escaping @Sendable (Double?) -> Void) {
            self.dest = dest; self.service = service; self.progress = progress
        }

        func run(_ url: URL) async throws -> (file: URL, fileName: String?) {
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var req = URLRequest(url: url)
            req.setValue(CloudShareFetch.userAgent, forHTTPHeaderField: "User-Agent")
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<(file: URL, fileName: String?), Error>) in
                    self.lock.lock()
                    self.continuation = c
                    let t = session.downloadTask(with: req)
                    self.task = t
                    self.lock.unlock()
                    if Task.isCancelled { t.cancel() } else { t.resume() }
                }
            } onCancel: {
                self.lock.lock(); let t = self.task; self.lock.unlock()
                t?.cancel()
            }
        }

        private func finish(_ r: Result<(file: URL, fileName: String?), Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: r)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let fraction: Double? = totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
            let pct = fraction.map { Int($0 * 100) } ?? -1
            lock.lock(); let changed = pct != lastPercent; lastPercent = pct; lock.unlock()
            if changed { progress(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let http = downloadTask.response as? HTTPURLResponse
            if let http, let f = CloudShareLink.failure(status: http.statusCode, service: service) {
                lock.lock(); outcome = .failure(f); lock.unlock(); return
            }
            if let final = http?.url, CloudShareLink.isLoginPage(final) {
                lock.lock(); outcome = .failure(CloudShareLink.Failure.privateLink); lock.unlock(); return
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                let name = CloudShareLink.fileName(contentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition"))
                lock.lock(); outcome = .success((dest, name)); lock.unlock()
            } catch {
                lock.lock(); outcome = .failure(error); lock.unlock()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let o = outcome; lock.unlock()
            if let error {
                if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) } else { finish(.failure(error)) }
                return
            }
            finish(o ?? .failure(CloudShareLink.Failure.webPage(service)))
        }
    }
}
