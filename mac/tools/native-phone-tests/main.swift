import Foundation

// The iPhone's Native look rules (NativeRules.swift), and a scan of the Native look code for Premium Native's retired
// chrome. Not part of any app target; run mac/tools/test-native-phone.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}
typealias R = NativeRules

// MARK: Recorder

check("the clock shows minutes, seconds, and hundredths", R.recorderClock(138.41) == "02:18.41", R.recorderClock(138.41))
check("the clock starts at zero", R.recorderClock(0) == "00:00.00")
check("the clock never goes negative", R.recorderClock(-3) == "00:00.00")
check("the clock adds hours once there are any", R.recorderClock(3738.5) == "1:02:18.50", R.recorderClock(3738.5))
check("hundredths round down, so 59.999 isn't 01:00", R.recorderClock(59.999) == "00:59.99", R.recorderClock(59.999))
let ticks = R.rulerTicks(elapsed: 134.5, window: 4)
check("the ruler marks each whole second in the window", ticks.map(\.second) == [131, 132, 133, 134], "\(ticks.map(\.second))")
check("a mark's distance back is its share of the window", abs(ticks.last!.back - 0.125) < 0.0001 && abs(ticks.first!.back - 0.875) < 0.0001)
check("no marks before the recording started", R.rulerTicks(elapsed: 1.5, window: 4).map(\.second) == [0, 1])
check("no marks without a window", R.rulerTicks(elapsed: 10, window: 0).isEmpty)
check("short clock", R.shortClock(131) == "2:11" && R.shortClock(3725) == "1:02:05" && R.shortClock(-1) == "0:00")
check("moments label", R.momentsLabel(1) == "1 moment" && R.momentsLabel(3) == "3 moments")

// The Native look code to scan: the iPhone folder is the first argument.
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "VerbatimPhone"

// MARK: This week

check("This week's line", R.weekDetail(recordings: 20, saved: "25 min") == "20 recordings · 25 min saved"
      && R.weekDetail(recordings: 1, saved: "2 min") == "1 recording · 2 min saved")

// MARK: Retired chrome

/// Every line of Native look code in a file: the whole file when it's marked `// brand: native file`, otherwise the
/// lines between `// brand: native begin` and `// brand: native end`.
func nativeLines(_ text: String) -> [(Int, String)] {
    let lines = text.components(separatedBy: "\n")
    if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "// brand: native file" }) {
        return Array(lines.enumerated().map { ($0.offset + 1, $0.element) })
    }
    var out: [(Int, String)] = []
    var on = false
    for (i, l) in lines.enumerated() {
        if l.contains("// brand: native begin") { on = true }
        if on { out.append((i + 1, l)) }
        if l.contains("// brand: native end") { on = false }
    }
    return out
}
let retired: [(String, String)] = [
    ("persimmon", "persimmon"), ("Ink.nativeAccent", "the brand accent"), ("PremiumStyle", "Premium's styles"),
    ("premiumCard(", "gradient cards"), ("premiumSoftCard(", "soft cards with shadows"), ("PremiumGradient", "gradient cards"),
    ("design: .rounded", "SF Pro Rounded numbers"), (".shadow(", "custom shadows"), ("accentSoft", "tinted icon circles"),
    ("PremiumPageBackground", "the glow"), ("RadialGradient", "glows"), ("LinearGradient", "gradients"),
]
var files: [String] = []
if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
    files = names.filter { $0.hasSuffix(".swift") && $0 != "PhoneUITest.swift" && $0 != "NativeRules.swift" }.sorted().map { dir + "/" + $0 }
}
if CommandLine.arguments.count > 2 { files.append(CommandLine.arguments[2]) }
var found: [String] = []
var scanned = 0
for f in files {
    guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
    let lines = nativeLines(text)
    if !lines.isEmpty { scanned += 1 }
    for (n, l) in lines {
        // The look thumbnails and pickers draw Verbose style too; such a line says so.
        if l.contains("// verbose look") { continue }
        let code = l.components(separatedBy: "//").first ?? l
        for (needle, what) in retired where code.contains(needle) {
            found.append("\((f as NSString).lastPathComponent):\(n) \(what): \(l.trimmingCharacters(in: .whitespaces))")
        }
    }
}
check("Native look code was read (\(scanned) files)", scanned >= 5)
check("no Premium Native chrome is left in the Native look (persimmon, the brand accent, gradients, glows, shadows, rounded numbers)",
      found.isEmpty, found.prefix(40).joined(separator: "\n    "))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
