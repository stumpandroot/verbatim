import Foundation

// The yt-dlp runner (HelperProcess) and its command lines (YtDlpCommand), with fake helpers written as shell
// scripts: ones that print and exit at once, leave a child printing after they exit, fail, or run until cancelled.
// Not part of any app target; run mac/tools/test-helper.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("helper-tests-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }

func fake(_ name: String, _ body: String) -> URL {
    let u = dir.appendingPathComponent(name)
    try? ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    return u
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: Substring) { lock.lock(); items.append(String(s)); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

let setup = YtDlpCommand.Setup(support: dir.appendingPathComponent("support").path)
let env = YtDlpCommand.environment(from: ProcessInfo.processInfo.environment, home: dir.path, setup: setup)

func runTests() async {
    // 1. Prints a lot on both streams and exits at once: nothing may be lost.
    let burst = fake("burst", """
    i=1
    while [ $i -le 3000 ]; do echo "out $i"; i=$((i+1)); done
    i=1
    while [ $i -le 800 ]; do echo "[download] $i.0% of 10MiB" 1>&2; echo "err $i" 1>&2; i=$((i+1)); done
    printf 'tail without newline'
    exit 0
    """)
    for round in 1...5 {
        let outLines = Lines(), progress = Lines()
        do {
            let r = try await HelperProcess.run(burst, [], environment: env,
                                                onStdoutLine: { outLines.add($0) },
                                                onStderrLine: { l in if l.contains("[download]") { progress.add(l); return true }; return false })
            let kept = r.stderr.split(separator: "\n")
            check("round \(round): every stdout line arrives, the last one without a newline too",
                  outLines.all.count == 3001 && outLines.all.first == "out 1" && outLines.all[2999] == "out 3000" && outLines.all.last == "tail without newline",
                  "\(outLines.all.count) lines, last \(outLines.all.last ?? "-")")
            check("round \(round): stdout is collected whole", r.stdout.hasPrefix("out 1\n") && r.stdout.hasSuffix("tail without newline")
                  && r.stdout.split(separator: "\n").count == 3001)
            check("round \(round): progress lines are consumed and the rest of stderr kept",
                  progress.all.count == 800 && kept.count == 800 && kept.first == "err 1" && kept.last == "err 800",
                  "\(progress.all.count) progress, \(kept.count) kept")
            check("round \(round): exit status", r.status == 0)
        } catch {
            check("round \(round): runs", false, "\(error)")
        }
    }

    // 2. A child keeps the pipe open and prints after the helper exits: the run waits for it.
    let late = fake("late", """
    (sleep 0.4; echo late) &
    echo early
    exit 0
    """)
    if let r = try? await HelperProcess.run(late, [], environment: env) {
        check("output printed after the helper exits is still read", r.stdout == "early\nlate\n", r.stdout.debugDescription)
    } else { check("late output run", false) }

    // 3. A failure: status and the ERROR line.
    let failing = fake("failing", """
    echo "[youtube] abc: Downloading webpage" 1>&2
    echo "ERROR: [youtube] abc: Private video. Sign in if you've been granted access" 1>&2
    exit 1
    """)
    if let r = try? await HelperProcess.run(failing, [], environment: env) {
        check("a failure keeps its status", r.status == 1)
        check("the ERROR line becomes the message", YtDlpCommand.errorMessage(stderr: r.stderr, status: r.status)
              == "[youtube] abc: Private video. Sign in if you've been granted access")
    } else { check("failing run", false) }
    check("no ERROR line: a status message", YtDlpCommand.errorMessage(stderr: "something\n", status: 2) == "yt-dlp exited with status 2.")

    // 4. The environment: exactly what YtDlpCommand gives, nothing inherited.
    setenv("VERBATIM_TEST_LEAK", "secret", 1)
    setenv("PYTHONPATH", "/tmp/evil", 1)
    setenv("https_proxy", "http://proxy.example:8080", 1)
    let built = YtDlpCommand.environment(from: ProcessInfo.processInfo.environment, home: dir.path, setup: setup)
    let envDump = fake("env", "env")
    if let r = try? await HelperProcess.run(envDump, [], environment: built) {
        let vars = Dictionary(r.stdout.split(separator: "\n").compactMap { l -> (String, String)? in
            guard let eq = l.firstIndex(of: "=") else { return nil }
            return (String(l[..<eq]), String(l[l.index(after: eq)...]))
        }, uniquingKeysWith: { a, _ in a })
        check("the helper's PATH is the fixed one", vars["PATH"] == YtDlpCommand.path, vars["PATH"] ?? "none")
        check("HOME is set", vars["HOME"] == dir.path)
        check("the XDG folders are the app's own", vars["XDG_CONFIG_HOME"] == setup.configDir && vars["XDG_CACHE_HOME"] == setup.cacheDir)
        check("PATH has only the system's folders", !(vars["PATH"] ?? "").contains("homebrew") && !(vars["PATH"] ?? "").contains("/usr/local"))
        check("unrelated variables aren't inherited", vars["VERBATIM_TEST_LEAK"] == nil && vars["PYTHONPATH"] == nil)
        check("a proxy passes through", vars["https_proxy"] == "http://proxy.example:8080")
        check("only allowed variables are set", Set(vars.keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD"])
              .isSubset(of: Set(YtDlpCommand.passThrough + ["HOME", "PATH", "PYTHONUNBUFFERED", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"])), "\(vars.keys.sorted())")
    } else { check("env run", false) }

    // 5. Arguments: no config files, and the link after "--" even when it looks like an option.
    let argDump = fake("args", "for a in \"$@\"; do echo \"$a\"; done")
    let link = "-o/tmp/x https://example.com/watch?v=1"
    let audioArgs = YtDlpCommand.audio(link: link, template: "/tmp/%(id)s.%(ext)s", signIn: ["--cookies-from-browser", "chrome"], setup: setup)
    if let r = try? await HelperProcess.run(argDump, audioArgs, environment: env) {
        let got = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        check("arguments reach the helper unchanged", got == audioArgs, "\(got)")
    } else { check("args run", false) }
    check("audio: --ignore-config is passed", audioArgs.contains("--ignore-config"))
    check("audio: the link comes last, right after --", audioArgs.suffix(2) == ["--", link])
    check("audio: the sign-in options come before --", audioArgs.firstIndex(of: "--cookies-from-browser")! < audioArgs.firstIndex(of: "--")!)
    let keepArgs = YtDlpCommand.keep(link: "https://example.com/v", template: "/tmp/k.%(ext)s", signIn: [], setup: setup)
    check("keep: --ignore-config and -- before the link", keepArgs.contains("--ignore-config") && keepArgs.suffix(2) == ["--", "https://example.com/v"])
    check("-- appears once", audioArgs.filter { $0 == "--" }.count == 1 && keepArgs.filter { $0 == "--" }.count == 1)
    for (name, args) in [("audio", audioArgs), ("keep", keepArgs)] {
        check("\(name): no plugins, no remote components, no JS runtime found on PATH",
              args.contains("--no-plugin-dirs") && args.contains("--no-remote-components") && args.contains("--no-js-runtimes")
              && !args.contains("--js-runtimes"))
        if let i = args.firstIndex(of: "--cache-dir") { check("\(name): the cache is the app's own", args[i + 1] == setup.cacheDir) }
        else { check("\(name): --cache-dir is passed", false) }
        check("\(name): every --print value is JSON", args.indices.filter { args[$0] == "--print" }.allSatisfy { i in
            let t = args[i + 1]
            return !t.contains(")s") && t.components(separatedBy: "%(").count - 1 == t.components(separatedBy: ")j").count - 1
        })
    }
    var withDeno = setup; withDeno.deno = "/usr/local/bin/deno"
    let denoArgs = withDeno.options
    check("a verified runtime is passed by its full path, after clearing the defaults",
          denoArgs.suffix(3) == ["--no-js-runtimes", "--js-runtimes", "deno:/usr/local/bin/deno"], "\(denoArgs)")

    // 6. Cancelling stops the helper and throws CancellationError promptly.
    // `exec`: the helper itself sleeps, so no orphaned child holds the pipes (Linux's Process reports the exit only
    // once they close).
    let slow = fake("slow", "echo started\nexec sleep 30")
    let start = Date()
    let task = Task { try await HelperProcess.run(slow, [], environment: env) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    var cancelled = false
    do { _ = try await task.value } catch is CancellationError { cancelled = true } catch {}
    check("cancelling stops the helper", cancelled && Date().timeIntervalSince(start) < 10, "\(Date().timeIntervalSince(start)) s")

    // 7. A helper that can't be launched.
    var launchFailed = false
    do { _ = try await HelperProcess.run(dir.appendingPathComponent("missing"), [], environment: env) } catch { launchFailed = !(error is CancellationError) }
    check("a missing helper throws", launchFailed)

    // 8. The line splitter: chunks split mid-line and mid-character.
    let splitter = HelperProcess.LineSplitter()
    let lines = Lines()
    let bytes = Array("café ünïcode\nsecond\r\nthird".utf8)
    for b in bytes { splitter.feed(Data([b])) { lines.add($0) } }
    splitter.finish { lines.add($0) }
    check("lines survive one-byte chunks and UTF-8 split across them", lines.all == ["café ünïcode", "second", "third"], "\(lines.all)")

    // 9. Output lines: JSON values after a tag. A title can't shift the fields or pose as another line.
    let n = YtDlpCommand.fileFields.count
    let good = "VBFILE\t\"/dl/1-ab.m4a\"\t\"A \\t tab\\nand newline\"\tNA\t\"https://e.com/v\"\t\"Youtube\"\t\"20260101\"\tnull"
    let f = YtDlpCommand.fields(Substring(good), tag: "VBFILE", count: n)
    check("a file line parses", f?[0] == "/dl/1-ab.m4a" && f?[1] == "A \t tab\nand newline" && f?[2] == nil && f?[6] == nil, "\(String(describing: f))")
    check("a raw (unquoted) value is refused", YtDlpCommand.fields("VBFILE\t/etc/passwd\tx\tNA\tNA\tNA\tNA\tNA", tag: "VBFILE", count: n) == nil)
    check("a line with too many fields is refused", YtDlpCommand.fields(Substring(good + "\t\"x\""), tag: "VBFILE", count: n) == nil)
    check("another tag is refused", YtDlpCommand.fields(Substring(good), tag: "VBMETA", count: n) == nil)
    check("numbers read as text", YtDlpCommand.fields("VBMETA\tNA\tNA\tNA\tNA\t212.0", tag: "VBMETA", count: 5)?[4] == "212"
          && YtDlpCommand.fields("VBMETA\tNA\tNA\tNA\tNA\t12.5", tag: "VBMETA", count: 5)?[4] == "12.5")
    // A title printed raw by an old template ("x\ty\t/path") can't produce a parsed line now; the last good line wins.
    let output = good + "\nVBFILE\tx\ty\t\"/Users/Shared/secret.m4a\"\n[download] 100%\n"
    check("the last line that parses is used", YtDlpCommand.lastFields(output, tag: "VBFILE", count: n)?[0] == "/dl/1-ab.m4a")
    check("the print templates use JSON for every field", YtDlpCommand.template("VBFILE", ["filepath", "title"]) == "VBFILE\t%(filepath)j\t%(title)j")

    // 10. The downloaded file: only this run's, directly in the downloads folder, symbolic links resolved.
    let downloads = dir.appendingPathComponent("downloads", isDirectory: true)
    let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
    try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
    try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let stamp = "1760000000-abcd1234."
    let mine = downloads.appendingPathComponent("1760000000-abcd1234.webm")
    let other = downloads.appendingPathComponent("1760000000-ffff0000.webm")
    let outside = elsewhere.appendingPathComponent("1760000000-abcd1234.m4a")
    for u in [mine, other, outside] { _ = fm.createFile(atPath: u.path, contents: Data("x".utf8)) }
    let planted = downloads.appendingPathComponent("1760000000-abcd1234.m4a")
    try? fm.createSymbolicLink(at: planted, withDestinationURL: outside)
    try? fm.createDirectory(at: downloads.appendingPathComponent("1760000000-abcd1234.dir"), withIntermediateDirectories: true)
    check("this run's file is accepted", YtDlpCommand.acceptedDownload(mine.path, in: downloads, prefix: stamp)?.path == mine.standardizedFileURL.path)
    check("another run's file is refused", YtDlpCommand.acceptedDownload(other.path, in: downloads, prefix: stamp) == nil)
    check("a file outside the folder is refused", YtDlpCommand.acceptedDownload(outside.path, in: downloads, prefix: stamp) == nil)
    check("a path that climbs out with .. is refused",
          YtDlpCommand.acceptedDownload(downloads.path + "/../elsewhere/1760000000-abcd1234.m4a", in: downloads, prefix: stamp) == nil)
    check("a symbolic link in the folder is refused", YtDlpCommand.acceptedDownload(planted.path, in: downloads, prefix: stamp) == nil)
    check("a folder is refused", YtDlpCommand.acceptedDownload(downloads.path + "/1760000000-abcd1234.dir", in: downloads, prefix: stamp) == nil)
    check("a relative path is refused", YtDlpCommand.acceptedDownload("1760000000-abcd1234.webm", in: downloads, prefix: stamp) == nil)
    check("a missing file is refused", YtDlpCommand.acceptedDownload(downloads.path + "/1760000000-abcd1234.mp3", in: downloads, prefix: stamp) == nil)
    check("no path is refused", YtDlpCommand.acceptedDownload(nil, in: downloads, prefix: stamp) == nil)
    let linkedDownloads = dir.appendingPathComponent("linked-downloads")
    try? fm.createSymbolicLink(at: linkedDownloads, withDestinationURL: downloads)
    check("a downloads folder reached through a link still works",
          YtDlpCommand.acceptedDownload(linkedDownloads.path + "/1760000000-abcd1234.webm", in: linkedDownloads, prefix: stamp) != nil)

    // 11. Thumbnails: web addresses only.
    check("https thumbnail accepted", YtDlpCommand.webURL("https://i.ytimg.com/vi/x/hq.jpg") != nil)
    check("http thumbnail accepted", YtDlpCommand.webURL("HTTP://example.com/a.png") != nil)
    for bad in ["file:///Users/Shared/a.jpg", "file://localhost/etc/passwd", "/Users/Shared/a.jpg", "data:image/png;base64,AAAA",
                "ftp://example.com/a.jpg", "https://", "javascript:alert(1)", "NA"] {
        check("thumbnail refused: \(bad)", YtDlpCommand.webURL(bad) == nil)
    }
    check("no thumbnail", YtDlpCommand.webURL(nil) == nil)

    // 12. A JavaScript runtime only from where only root can change it.
    check("a system binary passes", YtDlpCommand.isLockedDown("/bin/sh"))
    let fakeDeno = fake("deno", "exit 0")
    check("a runtime in a folder you can write is refused", !YtDlpCommand.isLockedDown(fakeDeno.path))
    let denoLink = dir.appendingPathComponent("deno-link")
    try? fm.createSymbolicLink(at: denoLink, withDestinationURL: fakeDeno)
    check("a link to such a runtime is refused", !YtDlpCommand.isLockedDown(denoLink.path))
    check("a missing runtime is refused", !YtDlpCommand.isLockedDown(dir.appendingPathComponent("nope").path))
}

let done = DispatchSemaphore(value: 0)
Task { await runTests(); done.signal() }
done.wait()
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
