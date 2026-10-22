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

let env = YtDlpCommand.environment(from: ProcessInfo.processInfo.environment, home: dir.path)

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
    let built = YtDlpCommand.environment(from: ProcessInfo.processInfo.environment, home: dir.path)
    let envDump = fake("env", "env")
    if let r = try? await HelperProcess.run(envDump, [], environment: built) {
        let vars = Dictionary(r.stdout.split(separator: "\n").compactMap { l -> (String, String)? in
            guard let eq = l.firstIndex(of: "=") else { return nil }
            return (String(l[..<eq]), String(l[l.index(after: eq)...]))
        }, uniquingKeysWith: { a, _ in a })
        check("the helper's PATH is the fixed one", vars["PATH"] == YtDlpCommand.path, vars["PATH"] ?? "none")
        check("HOME is set", vars["HOME"] == dir.path)
        check("unrelated variables aren't inherited", vars["VERBATIM_TEST_LEAK"] == nil && vars["PYTHONPATH"] == nil)
        check("a proxy passes through", vars["https_proxy"] == "http://proxy.example:8080")
        check("only allowed variables are set", Set(vars.keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD"])
              .isSubset(of: Set(YtDlpCommand.passThrough + ["HOME", "PATH", "PYTHONUNBUFFERED"])), "\(vars.keys.sorted())")
    } else { check("env run", false) }

    // 5. Arguments: no config files, and the link after "--" even when it looks like an option.
    let argDump = fake("args", "for a in \"$@\"; do echo \"$a\"; done")
    let link = "-o/tmp/x https://example.com/watch?v=1"
    let audioArgs = YtDlpCommand.audio(link: link, template: "/tmp/%(id)s.%(ext)s", signIn: ["--cookies-from-browser", "chrome"])
    if let r = try? await HelperProcess.run(argDump, audioArgs, environment: env) {
        let got = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        check("arguments reach the helper unchanged", got == audioArgs, "\(got)")
    } else { check("args run", false) }
    check("audio: --ignore-config is passed", audioArgs.contains("--ignore-config"))
    check("audio: the link comes last, right after --", audioArgs.suffix(2) == ["--", link])
    check("audio: the sign-in options come before --", audioArgs.firstIndex(of: "--cookies-from-browser")! < audioArgs.firstIndex(of: "--")!)
    let keepArgs = YtDlpCommand.keep(link: "https://example.com/v", template: "/tmp/k.%(ext)s", signIn: [])
    check("keep: --ignore-config and -- before the link", keepArgs.contains("--ignore-config") && keepArgs.suffix(2) == ["--", "https://example.com/v"])
    check("-- appears once", audioArgs.filter { $0 == "--" }.count == 1 && keepArgs.filter { $0 == "--" }.count == 1)

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
}

let done = DispatchSemaphore(value: 0)
Task { await runTests(); done.signal() }
done.wait()
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
