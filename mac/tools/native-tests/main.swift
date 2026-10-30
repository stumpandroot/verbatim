import Foundation

// The Native look's pure rules (LookRules.swift): which system color stands in for each Verbose token, the SF Symbols,
// title case for buttons, the welcome tour's steps, and the accent's contrast (read from Tokens.swift). Not part of any
// app target; run mac/tools/test-native.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: Token roles

check("paper becomes the window background", NativeRoles.role(light: 0xF5F0E6) == .window)
check("reader and card become content", NativeRoles.role(light: 0xFFFDF9) == .content)
check("ink becomes the label color", NativeRoles.role(light: 0x26352E) == .label)
check("dim and mute become secondary text", NativeRoles.role(light: 0x545E56) == .secondaryLabel && NativeRoles.role(light: 0x606962) == .secondaryLabel)
check("faint becomes tertiary text", NativeRoles.role(light: 0x8E938A) == .tertiaryLabel)
check("accent text becomes the Native accent", NativeRoles.role(light: 0xB23F24) == .accentText)
check("chips and tracks become a fill", [0xE6DFD1, 0xDAD4C7, 0xE8E2D6, 0xEEE7DA].allSatisfy { NativeRoles.role(light: $0) == .fill })
// Brand fills keep their color in both looks: persimmon, petal, butter, sage, their tints and panel fills.
let brand: [UInt32] = [0xFA6B47, 0xEFB6C8, 0xF4C76B, 0xAFC398, 0xFB7350, 0xFDE4DA, 0xFAE6EC, 0xFCF0D2, 0xE9EFE0, 0xF7E2AE, 0x4F6440]
check("brand fills have no Native role", brand.allSatisfy { NativeRoles.role(light: $0) == nil })
check("the Native accent itself has no role (no loop)", NativeRoles.role(light: 0xD5431F) == nil)
// NativeSwap caches one resolved color per token, appearance, and contrast setting.
let keys = [0xF5F0E6, 0x26352E].flatMap { l in [false, true].flatMap { d in [false, true].map { c in NativeRoles.cacheKey(light: UInt32(l), dark: d, increased: c) } } }
check("each token, appearance, and contrast setting has its own cache slot", Set(keys).count == keys.count)
check("the same lookup lands in the same slot", NativeRoles.cacheKey(light: 0xF5F0E6, dark: true, increased: false) == NativeRoles.cacheKey(light: 0xF5F0E6, dark: true, increased: false))

// MARK: Symbols

let sidebarItems = ["home", "library", "links", "moments", "queue", "dictations", "you", "dictionary"]
let sidebarSymbols = sidebarItems.map(NativeSymbols.sidebar)
check("every sidebar item has its own symbol", Set(sidebarSymbols).count == sidebarItems.count && !sidebarSymbols.contains("circle"), "\(sidebarSymbols)")
check("a meeting shows two people", NativeSymbols.kind("meeting") == "person.2")
check("a voice note without a kind shows a waveform", NativeSymbols.kind(nil) == "waveform")
check("a link without a kind shows a link", NativeSymbols.kind(nil, link: true) == "link")
check("a podcast from a link shows a link", NativeSymbols.kind("podcast", link: true) == "link")
check("a dictation shows a text bubble", NativeSymbols.kind(nil, dictation: true) == "text.bubble")
check("two speakers without a kind show two people", NativeSymbols.kind(nil, speakers: 2) == "person.2")

// MARK: Title case

let cases: [(String, String)] = [
    ("Start recording", "Start Recording"),
    ("Clean up", "Clean Up"),
    ("Copy", "Copy"),
    ("Don't ask for this app", "Don't Ask for This App"),
    ("Copy for AI", "Copy for AI"),
    ("Add from Library…", "Add from Library…"),
    ("Show all", "Show All"),
    ("New project", "New Project"),
    ("Export 3 transcripts", "Export 3 Transcripts"),
    ("Keep video (MP4)", "Keep Video (MP4)"),
    ("Sync with iCloud", "Sync with iCloud"),
    ("Try again", "Try Again"),
    ("the end of the line", "The End of the Line"),
    ("Look for", "Look For"),
    ("", ""),
]
for (input, want) in cases {
    let got = NativeText.titleCase(input)
    check("title case: \(input.isEmpty ? "(empty)" : input)", got == want, "got \(got)")
}

// MARK: Welcome tour

check("the tour has six steps", OnboardingStep.count == 6)
check("Pick a look comes right after the welcome", OnboardingStep.at(1) == .look && OnboardingStep.at(0) == .welcome)
check("permissions follow the look", OnboardingStep.at(2) == .permissions)
check("the last step is quality", OnboardingStep.at(5) == .quality && OnboardingStep.at(99) == .quality && OnboardingStep.at(-3) == .welcome)
check("the Native counter reads Step 2 of 6", OnboardingStep.look.counter == "Step 2 of 6")
check("the look step's label", OnboardingStep.look.label == "Pick a look")

// MARK: Accent contrast (Tokens.swift)

func luminance(_ hex: UInt32) -> Double {
    func c(_ v: UInt32) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * c((hex >> 16) & 0xFF) + 0.7152 * c((hex >> 8) & 0xFF) + 0.0722 * c(hex & 0xFF)
}
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
let args = CommandLine.arguments
let pattern = try! NSRegularExpression(pattern: #"nativeAccentLightHex: UInt32 = 0x([0-9A-Fa-f]{6}), nativeAccentDarkHex: UInt32 = 0x([0-9A-Fa-f]{6})"#)
if args.count > 1, let tokens = try? String(contentsOfFile: args[1], encoding: .utf8),
   let m = pattern.firstMatch(in: tokens, range: NSRange(tokens.startIndex..., in: tokens)),
   let r1 = Range(m.range(at: 1), in: tokens), let r2 = Range(m.range(at: 2), in: tokens),
   let light = UInt32(tokens[r1], radix: 16), let dark = UInt32(tokens[r2], radix: 16) {
    check("the light accent reaches 4.5:1 on white", contrast(light, 0xFFFFFF) >= 4.5, String(format: "%.2f:1", contrast(light, 0xFFFFFF)))
    // Not darker than it needs to be: it stays close to #E04E2A.
    check("the light accent stays close to #E04E2A", contrast(light, 0xFFFFFF) < 4.7, String(format: "%.2f:1", contrast(light, 0xFFFFFF)))
    check("the dark accent is #FF6B47", dark == 0xFF6B47)
    check("the dark accent reaches 4.5:1 on dark gray", contrast(dark, 0x1C1C1E) >= 4.5, String(format: "%.2f:1", contrast(dark, 0x1C1C1E)))
} else {
    check("Tokens.swift defines the Native accent's light and dark values", false, "pass Tokens.swift's path as the first argument")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
