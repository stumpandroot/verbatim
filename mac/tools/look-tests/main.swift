import Foundation

// The look (DESIGN.md §13): what the keyboard reads from the App Group, and the Native accent's contrast.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

// MARK: The keyboard's reading (KeyboardLook.swift)

check("native reads as Native", KeyboardLook.isNative(raw: "native"))
check("verbose reads as Verbose style", !KeyboardLook.isNative(raw: "verbose"))
check("nothing stored (a new install) reads as Verbose style", !KeyboardLook.isNative(raw: nil))
check("an unknown value reads as Verbose style", !KeyboardLook.isNative(raw: "Native ") && !KeyboardLook.isNative(raw: "dark"))
check("no App Group (no Full Access) reads as Verbose style", !KeyboardLook.isNative(nil as UserDefaults?))

let suite = "look-tests-\(UUID().uuidString)"
if let d = UserDefaults(suiteName: suite) {
    check("an empty store reads as Verbose style", !KeyboardLook.isNative(d))
    d.set("native", forKey: KeyboardLook.key)
    check("the app's Native choice reaches the keyboard", KeyboardLook.isNative(d))
    d.set("verbose", forKey: KeyboardLook.key)
    check("and back to Verbose style", !KeyboardLook.isNative(d))
    d.removePersistentDomain(forName: suite)
}

// MARK: Contrast math

check("black on white is 21:1", abs(KeyboardLook.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
check("contrast is symmetric", KeyboardLook.contrast(0xFA6B47, 0xFFFFFF) == KeyboardLook.contrast(0xFFFFFF, 0xFA6B47))
check("the brand persimmon fails with white (about 2.9:1)", KeyboardLook.contrast(0xFA6B47, 0xFFFFFF) < 3)
check("the mockup's #E04E2A measures 4.0:1 with white", abs(KeyboardLook.contrast(0xE04E2A, 0xFFFFFF) - 3.97) < 0.02)

// MARK: Tokens.swift and Look.swift, read as text

func source(_ i: Int) -> String {
    guard CommandLine.arguments.count > i, let s = try? String(contentsOfFile: CommandLine.arguments[i], encoding: .utf8) else {
        print("FAIL can't read \(CommandLine.arguments.count > i ? CommandLine.arguments[i] : "argument \(i)")"); exit(1)
    }
    return s
}
func hex(_ name: String, in text: String) -> UInt32? {
    guard let r = text.range(of: name + #": UInt32 = 0x[0-9A-Fa-f]{6}"#, options: .regularExpression) else { return nil }
    return UInt32(text[r].suffix(6), radix: 16)
}
let tokens = source(1)
let light = hex("nativeAccentLightHex", in: tokens)
let dark = hex("nativeAccentDarkHex", in: tokens)
check("Tokens.swift defines the Native accent's light and dark values", light != nil && dark != nil)
if let light, let dark {
    check("white on the light accent reaches 4.5:1 (buttons)", KeyboardLook.contrast(0xFFFFFF, light) >= 4.5)
    check("the light accent on white reaches 4.5:1 (tinted text)", KeyboardLook.contrast(light, 0xFFFFFF) >= 4.5)
    check("the light accent is still persimmon, as light as it can be: one step lighter fails",
          KeyboardLook.contrast(0xFFFFFF, light &+ 0x010101) < 4.5)
    check("the dark accent is #FF6B47", dark == 0xFF6B47)
    check("the dark accent reaches 4.5:1 on dark gray (#1C1C1E)", KeyboardLook.contrast(dark, 0x1C1C1E) >= 4.5)
    check("the dark accent reaches 4.5:1 on black", KeyboardLook.contrast(dark, 0x000000) >= 4.5)
}

let look = source(2)
check("the keyboard reads the app's key", look.contains("static let key = \"\(KeyboardLook.key)\""))
check("the app's Native value is the one the keyboard reads", look.contains("case verbose, native"))
check("new installs start in Verbose style", look.contains("?? .verbose"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
