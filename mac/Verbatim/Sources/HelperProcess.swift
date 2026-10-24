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

/// yt-dlp's command lines, environment, and output parsing, pure so the helper test checks them.
enum YtDlpCommand {
    /// Where yt-dlp may keep anything, and the JavaScript runtime it may run. yt-dlp runs as Verbose (its
    /// privacy permissions, its browser sign-ins), so nothing outside the app may add code or settings to it.
    struct Setup: Sendable, Equatable {
        /// The app's own yt-dlp folder (Application Support/Verbatim/yt-dlp): its cache and empty XDG homes.
        var support: String
        /// A JavaScript runtime (Deno) that passed `isLockedDown`, or nil for none. Never looked up on PATH.
        var deno: String? = nil

        var cacheDir: String { support + "/cache" }
        var configDir: String { support + "/config" }

        /// No config files (`--ignore-config`), no plugins from any folder (`--no-plugin-dirs`), no components
        /// fetched from the internet, a private cache, and only the JavaScript runtime named here.
        var options: [String] {
            var o = ["--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--cache-dir", cacheDir, "--no-js-runtimes"]
            if let deno { o += ["--js-runtimes", "deno:" + deno] }
            return o
        }
    }

    /// Options every run has after `Setup.options`: no playlists, and line-by-line output.
    static let base = ["--no-playlist", "--no-warnings", "--newline"]

    /// Mark yt-dlp's own lines in its output. Every value on them is printed as JSON (`%(field)j`), so a title or
    /// any other value a site chooses can't add a tab or a line break: it can never pose as another field or line.
    static let metaTag = "VBMETA"
    static let fileTag = "VBFILE"
    static let keepTag = "VBKEEP"

    /// The video's details, printed once they're known, before the download starts.
    static let metaFields = ["title", "uploader", "extractor_key", "thumbnail", "duration"]
    /// The downloaded file and the page's details, printed after the download.
    static let fileFields = ["filepath", "title", "uploader", "webpage_url", "extractor_key", "upload_date", "thumbnail"]
    /// Keep: each downloaded file and its codecs.
    static let keepFields = ["filepath", "vcodec", "acodec"]

    static func template(_ tag: String, _ fields: [String]) -> String {
        ([tag] + fields.map { "%(\($0))j" }).joined(separator: "\t")
    }

    /// Download a link's best audio to `template`. `--` ends the options, so a link can never be read as one.
    static func audio(link: String, template: String, signIn: [String], setup: Setup) -> [String] {
        signIn + setup.options + base + [
            "--progress",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--print", "video:" + Self.template(metaTag, metaFields),
            "--print", "after_move:" + Self.template(fileTag, fileFields),
            "--no-simulate",
            "-o", template, "--", link,
        ]
    }

    /// Keep: a link's best H.264 video (up to 1080p) and AAC audio as separate files.
    static func keep(link: String, template: String, signIn: [String], setup: Setup) -> [String] {
        // "," downloads each format separately (no merging needed). Falls back to one combined MP4.
        let format = "bv*[ext=mp4][vcodec^=avc1][height<=1080],ba[ext=m4a]/b[ext=mp4][height<=1080]/b[ext=mp4]"
        return signIn + setup.options + base + [
            "-f", format,
            "--print", "after_move:" + Self.template(keepTag, keepFields),
            "--no-simulate", "-o", template, "--", link,
        ]
    }

    /// The values of one of our lines: exactly `count` JSON values after `tag`, tab-separated. yt-dlp prints NA for
    /// a missing value; it, JSON null, and "" read as nil. Nil for any other line, or one that doesn't parse.
    static func fields(_ line: Substring, tag: String, count: Int) -> [String?]? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == count + 1, parts[0] == tag else { return nil }
        var out: [String?] = []
        for p in parts.dropFirst() {
            if p == "NA" { out.append(nil); continue }
            guard let v = try? JSONDecoder().decode(Scalar.self, from: Data(p.utf8)) else { return nil }
            out.append(v.text.flatMap { $0.isEmpty ? nil : $0 })
        }
        return out
    }

    /// The last line with `tag` that parses.
    static func lastFields(_ output: String, tag: String, count: Int) -> [String?]? {
        output.split(separator: "\n").reversed().lazy.compactMap { fields($0, tag: tag, count: count) }.first
    }

    /// One printed JSON value: a string, a number, or null.
    private struct Scalar: Decodable {
        let text: String?
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if c.decodeNil() { text = nil }
            else if let s = try? c.decode(String.self) { text = s }
            else { let n = try c.decode(Double.self); text = n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n) }
        }
    }

    /// A file yt-dlp says it wrote, used only when it's a regular file directly in `folder` whose name starts with
    /// `prefix` (this run's stamp), both as written and with symbolic links resolved. Anything else is ignored,
    /// never read, moved, or deleted.
    static func acceptedDownload(_ path: String?, in folder: URL, prefix: String) -> URL? {
        guard let path, path.hasPrefix("/"), !prefix.isEmpty else { return nil }
        let fm = FileManager.default
        let dir = folder.standardizedFileURL, u = URL(fileURLWithPath: path).standardizedFileURL
        guard u.deletingLastPathComponent().path == dir.path, u.lastPathComponent.hasPrefix(prefix) else { return nil }
        let realDir = dir.resolvingSymlinksInPath().standardizedFileURL, real = u.resolvingSymlinksInPath().standardizedFileURL
        guard real.deletingLastPathComponent().path == realDir.path, real.lastPathComponent == u.lastPathComponent else { return nil }
        guard (try? fm.destinationOfSymbolicLink(atPath: u.path)) == nil else { return nil }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return u
    }

    /// A thumbnail or other address a site gave: only http and https with a host, never file: or anything else.
    static func webURL(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }

    /// Whether `path` may run as yt-dlp's JavaScript runtime: with symbolic links resolved, it's an executable file,
    /// and it and every folder above it are owned by root and not writable by group or others. So no process
    /// running as you can replace it (a Homebrew install is yours to write, so it doesn't pass).
    static func isLockedDown(_ path: String) -> Bool {
        let fm = FileManager.default
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard fm.isExecutableFile(atPath: real.path) else { return false }
        var u = real
        while true {
            guard let a = try? fm.attributesOfItem(atPath: u.path), number(a[.ownerAccountID]) == 0,
                  let perms = number(a[.posixPermissions]), perms & 0o022 == 0 else { return false }
            if u.path == "/" { return true }
            u = u.deletingLastPathComponent()
        }
    }

    private static func number(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let n as Int: return n
        case let n as UInt: return Int(n)
        case let n as UInt32: return Int(n)
        case let n as UInt64: return Int(n)
        case let n as Int16: return Int(n)
        default: return nil
        }
    }

    /// The fixed search path yt-dlp gets: the system's folders only (protected by macOS). Never the person's own
    /// PATH, and no Homebrew or /usr/local folders, which are writable without an administrator: a program placed
    /// there would run inside every link fetch, as Verbose. A JavaScript runtime is passed by its full path instead.
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Variables passed through from the app's environment when set: proxies (so a network that needs one still
    /// works), the temporary folder, and the locale. Nothing else (no PYTHON*, no YTDLP_*, no shell setup).
    static let passThrough = ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                              "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE"]

    /// The whole environment yt-dlp runs with. HOME stays the real home folder: `--cookies-from-browser` finds each
    /// browser's sign-in there (and Python falls back to the account's home without it anyway). The XDG folders
    /// point inside the app's own yt-dlp folder, so nothing in ~/.config or ~/.cache is read.
    static func environment(from parent: [String: String], home: String, setup: Setup) -> [String: String] {
        var env: [String: String] = ["HOME": home, "PATH": path, "PYTHONUNBUFFERED": "1",
                                     "XDG_CONFIG_HOME": setup.configDir, "XDG_CACHE_HOME": setup.cacheDir]
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
