import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Runs a helper executable (yt-dlp) and collects what it prints. Pure Foundation, so mac/tools/test-helper.sh
/// checks it on Linux with a fake helper.
///
/// Both pipes are read to end of file on their own threads, and every chunk is handled on one serial queue, so the
/// output buffers are never touched from two threads at once. The result is delivered only once the process has
/// exited and both pipes have reached end of file: a helper that prints and exits at once loses nothing.
enum HelperProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        /// Standard error lines not handed to `onStderrLine` as consumed (see `run`).
        var stderr: String
    }

    /// Lets a caller stop the running helper (Task cancellation).
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private(set) var cancelled = false
        fileprivate func attach(_ p: Process) { lock.lock(); process = p; let c = cancelled; lock.unlock(); if c { Self.stop(p) } }
        func cancel() { lock.lock(); cancelled = true; let p = process; lock.unlock(); if let p { Self.stop(p) } }
        /// SIGTERM, then SIGKILL two seconds later if it's still running (it may ignore or block TERM).
        private static func stop(_ p: Process) {
            guard p.isRunning else { return }
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
        }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    /// Splits a byte stream into lines (pipes deliver arbitrary chunks, sometimes mid-character). Used only on the
    /// serial queue.
    final class LineSplitter {
        private var pending = Data()
        func feed(_ d: Data, _ each: (Substring) -> Void) {
            pending.append(d)
            while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if !line.isEmpty { each(Substring(line)) }
            }
        }
        /// The last line, when the stream ended without a newline.
        func finish(_ each: (Substring) -> Void) {
            guard !pending.isEmpty else { return }
            let line = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            if !line.isEmpty { each(Substring(line)) }
        }
    }

    /// Runs `exe` with `args` and exactly `environment` (nothing inherited). Each line of standard output goes to
    /// `onStdoutLine`; each line of standard error goes to `onStderrLine`, which returns true when it consumed the
    /// line (progress) and false to keep it in `Output.stderr`. Throws `CancellationError` when `handle` was
    /// cancelled, or the launch error.
    static func run(_ exe: URL, _ args: [String], environment: [String: String], handle: Handle = Handle(),
                    onStdoutLine: @escaping @Sendable (Substring) -> Void = { _ in },
                    onStderrLine: @escaping @Sendable (Substring) -> Bool = { _ in false }) async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.environment = environment
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice

                let state = Collector(cont: cont, handle: handle, onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)
                p.terminationHandler = { proc in state.exited(proc.terminationStatus) }
                do {
                    try p.run()
                } catch {
                    state.failedToLaunch(error)
                    return
                }
                handle.attach(p)
                // Process closes its copies of the write ends once the helper is launched, so each read ends at the
                // helper's exit (or its children's, if they keep the pipe open).
                state.read(out.fileHandleForReading, stderr: false)
                state.read(err.fileHandleForReading, stderr: true)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Everything mutable lives here and is touched only on `queue`.
    private final class Collector: @unchecked Sendable {
        private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.helper")
        private var cont: CheckedContinuation<Output, Error>?
        private let handle: Handle
        private let onStdoutLine: @Sendable (Substring) -> Void
        private let onStderrLine: @Sendable (Substring) -> Bool
        private var stdout = Data()
        private var stderrKept = ""
        private let outLines = LineSplitter(), errLines = LineSplitter()
        private var outDone = false, errDone = false
        private var status: Int32?

        init(cont: CheckedContinuation<Output, Error>, handle: Handle, onStdoutLine: @escaping @Sendable (Substring) -> Void,
             onStderrLine: @escaping @Sendable (Substring) -> Bool) {
            self.cont = cont; self.handle = handle; self.onStdoutLine = onStdoutLine; self.onStderrLine = onStderrLine
        }

        /// Reads one pipe to end of file on its own thread; every chunk is handled on `queue`, in order.
        func read(_ h: FileHandle, stderr: Bool) {
            Thread.detachNewThread { [self] in
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    queue.async { self.chunk(d, stderr: stderr) }
                }
                queue.async { self.ended(stderr: stderr) }
            }
        }

        private func chunk(_ d: Data, stderr: Bool) {
            if stderr {
                errLines.feed(d) { l in if !onStderrLine(l) { stderrKept += l + "\n" } }
            } else {
                stdout.append(d)
                outLines.feed(d) { onStdoutLine($0) }
            }
        }

        private func ended(stderr: Bool) {
            if stderr {
                errLines.finish { l in if !onStderrLine(l) { stderrKept += l + "\n" } }
                errDone = true
            } else {
                outLines.finish { onStdoutLine($0) }
                outDone = true
            }
            finishIfDone()
        }

        func exited(_ s: Int32) { queue.async { self.status = s; self.finishIfDone() } }

        func failedToLaunch(_ e: Error) { queue.async { self.cont?.resume(throwing: e); self.cont = nil } }

        private func finishIfDone() {
            guard let status, let c = cont else { return }
            // Cancelled: done once the helper exits (a child it started may still hold the pipes open).
            if handle.isCancelled { cont = nil; c.resume(throwing: CancellationError()); return }
            guard outDone, errDone else { return }
            cont = nil
            c.resume(returning: Output(status: status, stdout: String(decoding: stdout, as: UTF8.self), stderr: stderrKept))
        }
    }
}

/// yt-dlp's command lines and environment, pure so the helper test checks them.
enum YtDlpCommand {
    /// Options every run starts with: no config file from the person's machine (`--ignore-config`) can change what
    /// runs, no playlists, and line-by-line output.
    static let base = ["--ignore-config", "--no-playlist", "--no-warnings", "--newline"]

    /// Marks the metadata line in yt-dlp's output.
    static let metaTag = "VBMETA"

    /// Download a link's best audio to `template`. `--` ends the options, so a link can never be read as one.
    static func audio(link: String, template: String, signIn: [String]) -> [String] {
        signIn + base + [
            "--progress",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            // Printed once the video's details are known, before the download starts.
            "--print", "video:\(metaTag)\t%(title)s\t%(uploader)s\t%(extractor_key)s\t%(thumbnail)s\t%(duration)s",
            "--print", "after_move:%(title)s\t%(uploader)s\t%(filepath)s\t%(webpage_url)s\t%(extractor_key)s\t%(upload_date)s\t%(thumbnail)s",
            "--no-simulate",
            "-o", template, "--", link,
        ]
    }

    /// Keep: a link's best H.264 video (up to 1080p) and AAC audio as separate files.
    static func keep(link: String, template: String, signIn: [String]) -> [String] {
        // "," downloads each format separately (no merging needed). Falls back to one combined MP4.
        let format = "bv*[ext=mp4][vcodec^=avc1][height<=1080],ba[ext=m4a]/b[ext=mp4][height<=1080]/b[ext=mp4]"
        return signIn + base + [
            "-f", format,
            "--print", "after_move:%(filepath)s\t%(vcodec)s\t%(acodec)s",
            "--no-simulate", "-o", template, "--", link,
        ]
    }

    /// The fixed search path yt-dlp gets: the system's, plus Homebrew's and /usr/local for a JavaScript runtime
    /// (Deno or Node) that some sites need. Never the person's own PATH.
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    /// Variables passed through from the app's environment when set: proxies (so a network that needs one still
    /// works), the temporary folder, and the locale. Nothing else (no PYTHON*, no YTDLP_*, no shell setup).
    static let passThrough = ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                              "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE"]

    /// The whole environment yt-dlp runs with.
    static func environment(from parent: [String: String], home: String) -> [String: String] {
        var env: [String: String] = ["HOME": home, "PATH": path, "PYTHONUNBUFFERED": "1"]
        for k in passThrough { if let v = parent[k] { env[k] = v } }
        if env["LANG"] == nil, env["LC_ALL"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// The message to show for a failed run: its last ERROR line, without the prefix.
    static func errorMessage(stderr: String, status: Int32) -> String {
        let msg = stderr.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init) ?? "yt-dlp exited with status \(status)."
        return msg.replacingOccurrences(of: "ERROR: ", with: "")
    }
}
