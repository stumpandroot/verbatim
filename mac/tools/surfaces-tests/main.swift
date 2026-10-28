import Foundation

// The Mac dictation surfaces' pure rules: notch geometry (Flow/NotchGeometry.swift), the style choice and the thought
// bubble's placement (Flow/DictationSurface.swift), and the hotkey picker's shortcuts, conflicts, and upgrade
// (Flow/HotkeyRules.swift). Not part of any app target; run mac/tools/test-surfaces.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }

// MARK: Notch geometry

// MacBook Pro 14" at default scaling: 1512 × 982, a 32 pt safe area, 663 + 663 pt either side of a 186 pt housing.
let mbp14 = CGRect(x: 0, y: 0, width: 1512, height: 982)
let g14 = NotchGeometry.measure(frame: mbp14, safeAreaTop: 32, leftAreaWidth: 663, rightAreaWidth: 663, menuBarHeight: 32)
check("14\": a notch", g14.hasNotch)
check("14\": camera is the gap between the side areas", near(g14.cameraWidth, 186), "\(g14.cameraWidth)")
check("14\": centered on the gap", near(g14.centerX, 756), "\(g14.centerX)")
check("14\": first row is the housing plus 1 pt", near(g14.rowHeight, 33))
check("14\": flush with the top", near(g14.top, 982))
check("14\": rest is the hardware plus 1 pt each side", near(g14.width(.rest), 188))
check("14\": listening is 420 wide (mockup)", near(g14.width(.active), 420))
check("14\": hovered is 460 wide (mockup)", near(g14.width(.wide), 460))
check("14\": peek is 340 wide (mockup)", near(g14.width(.peek), 340))
check("14\": wings stay under 120 pt while active", g14.wingWidth(g14.width(.active)) < 120)
check("14\": panel is centered on the camera", near(g14.panelFrame.midX, 756, 1), "\(g14.panelFrame)")
check("14\": panel hangs from the top edge", near(g14.panelFrame.maxY, 982))
check("14\": panel fits a prompt and its flares", g14.panelFrame.width >= g14.width(.prompt) + 2 * NotchGeometry.flare)
let r14 = g14.shapeRect(width: 420, height: 33)
check("14\": shape rect is centered and flush", near(r14.midX, 756) && near(r14.maxY, 982) && near(r14.height, 33))

// MacBook Pro 16": 1728 × 1117, the housing off center by half a point to test the arithmetic.
let mbp16 = CGRect(x: 0, y: 0, width: 1728, height: 1117)
let g16 = NotchGeometry.measure(frame: mbp16, safeAreaTop: 32, leftAreaWidth: 771, rightAreaWidth: 770, menuBarHeight: 32)
check("16\": camera width", near(g16.cameraWidth, 187), "\(g16.cameraWidth)")
check("16\": center follows the gap, not the screen", near(g16.centerX, 771 + 93.5), "\(g16.centerX)")

// The built-in display to the right of a main external one: screen coordinates start at x = 2560.
let side = CGRect(x: 2560, y: -200, width: 1512, height: 982)
let gs = NotchGeometry.measure(frame: side, safeAreaTop: 32, leftAreaWidth: 663, rightAreaWidth: 663, menuBarHeight: 32)
check("second display: center in global coordinates", near(gs.centerX, 2560 + 756))
check("second display: top in global coordinates", near(gs.top, 782))

// A notch reported without side areas: the measured default, centered.
let noAreas = NotchGeometry.measure(frame: mbp14, safeAreaTop: 32, leftAreaWidth: nil, rightAreaWidth: nil, menuBarHeight: 32)
check("no side areas: default camera, screen center", noAreas.hasNotch && near(noAreas.cameraWidth, 186) && near(noAreas.centerX, 756))
let odd = NotchGeometry.measure(frame: mbp14, safeAreaTop: 32, leftAreaWidth: 10, rightAreaWidth: 10, menuBarHeight: 32)
check("side areas that leave an impossible gap: default camera", near(odd.cameraWidth, 186))

// External display: no safe area, a 24 pt menu bar. The pill drops 8 pt below it.
let ext = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
let ge = NotchGeometry.measure(frame: ext, safeAreaTop: 0, leftAreaWidth: nil, rightAreaWidth: nil, menuBarHeight: 24)
check("external: no notch", !ge.hasNotch)
check("external: pill is 8 pt deeper than the menu bar", near(ge.rowHeight, 32))
check("external: centered on the display", near(ge.centerX, -960))
check("external: pill hidden at rest", near(ge.width(.rest), 0))
check("external: pill is 250 wide (mockup)", near(ge.width(.active), 250))
check("external: pill row is one piece", near(ge.wingWidth(250), 250))
let hidden = NotchGeometry.measure(frame: ext, safeAreaTop: 0, leftAreaWidth: nil, rightAreaWidth: nil, menuBarHeight: 0)
check("menu bar hidden (full screen): pill still drops from a 24 pt bar", near(hidden.rowHeight, 32))

check("radius: the notch's own 9 pt for one row", near(g14.radius(height: 33), 9))
check("radius: the pill's 14 pt for one row", near(ge.radius(height: 32), 14))
check("radius: pasted (two rows) is 16", near(g14.radius(height: 65), 16))
check("radius: an error is 18", near(g14.radius(height: 99), 18))
check("radius: hovered with words is 20", near(g14.radius(height: 125), 20))

// MARK: Notices in the notch

let mute = NoticeText.split("Stopped listening: AirPods is muted. Unmute it, then dictate again.")
check("notice: colon ends the title", mute.title == "Stopped listening" && mute.detail == "AirPods is muted. Unmute it, then dictate again.", "\(mute)")
let paste = NoticeText.split("Notes didn't take the paste. Saved to the thought pad; ⌃⌘V tries again.")
check("notice: first sentence is the title", paste.title == "Notes didn't take the paste." && paste.detail.hasPrefix("Saved"), "\(paste)")
let one = NoticeText.split("Cancelled")
check("notice: one sentence has no detail", one.title == "Cancelled" && one.detail.isEmpty)
let decimal = NoticeText.split("Stopped at 2.5 minutes")
check("notice: a decimal point isn't a sentence end", decimal.title == "Stopped at 2.5 minutes" && decimal.detail.isEmpty)

// MARK: Which surface shows

check("Ribbon everywhere", DictationSurface.shown(chosen: .ribbon, hasNotch: true, fallback: .pill) == .ribbon)
check("notch where there is one", DictationSurface.shown(chosen: .notch, hasNotch: true, fallback: .ribbon) == .notch)
check("pill without a notch (default)", DictationSurface.shown(chosen: .notch, hasNotch: false, fallback: .pill) == .pill)
check("Ribbon without a notch when chosen", DictationSurface.shown(chosen: .notch, hasNotch: false, fallback: .ribbon) == .ribbon)
check("two styles: the Ribbon and the notch", DictationSurface.allCases == [.ribbon, .notch])
let fresh = UserDefaults(suiteName: "surfaces-tests-\(UUID().uuidString)")!
check("nothing saved: the Ribbon, as before", DictationSurface.stored(fresh) == .ribbon)
check("nothing saved: pill without a notch", NotchFallback.stored(fresh) == .pill)
check("nothing saved: click the notch is on", NotchClick.isOn(fresh))
fresh.set("rocket", forKey: DictationSurface.key)
check("an unknown value reads as the Ribbon", DictationSurface.stored(fresh) == .ribbon)
check("nothing to move unless it's the floating button", !DictationSurface.migrateRetired(fresh) && fresh.string(forKey: DictationSurface.key) == "rocket")
// The floating button retired (October 28, 2026): its value reads as the Ribbon and moves there once.
fresh.set("button", forKey: DictationSurface.key)
fresh.set("label", forKey: "flow.button.look")
check("the retired floating button reads as the Ribbon", DictationSurface.stored(fresh) == .ribbon)
check("the floating button moves to the Ribbon", DictationSurface.migrateRetired(fresh) && fresh.string(forKey: DictationSurface.key) == "ribbon")
check("once", !DictationSurface.migrateRetired(fresh) && DictationSurface.stored(fresh) == .ribbon)
check("its own settings stay for an older build", fresh.string(forKey: "flow.button.look") == "label")
fresh.set("notch", forKey: DictationSurface.key)
check("the notch stays the notch", !DictationSurface.migrateRetired(fresh) && DictationSurface.stored(fresh) == .notch)

// MARK: The thought bubble's placement

let vis = CGRect(x: 0, y: 80, width: 1512, height: 870)
let btn = CGSize(width: 44, height: 44)
let clamped = FloatingGeometry.clamp(CGPoint(x: -50, y: 2000), in: vis, size: btn)
check("clamp: pulled back onto the screen", near(clamped.x, 30) && near(clamped.y, 950 - 30), "\(clamped)")
let inside = FloatingGeometry.clamp(CGPoint(x: 700, y: 500), in: vis, size: btn)
check("clamp: a spot inside stays put", near(inside.x, 700) && near(inside.y, 500))
let spot = FloatingGeometry.spot(for: CGPoint(x: 756, y: 515), in: vis)
check("spot: fractions of the visible frame", abs(spot.x - 0.5) < 0.001 && abs(spot.y - 0.5) < 0.001, "\(spot)")
let smaller = CGRect(x: 0, y: 25, width: 1280, height: 775)
let moved = FloatingGeometry.center(for: ButtonSpot(x: 0.999, y: 0.999), in: smaller, size: btn)
check("spot on a smaller display clamps onto it", moved.x <= 1280 - 30 && moved.y <= 800 - 30, "\(moved)")
let standard = FloatingGeometry.center(for: nil, in: vis, size: btn)
check("no saved spot: lower right, on screen", standard.x > vis.midX && standard.y < vis.midY && standard.x <= vis.maxX - 30)

// MARK: Recorded shortcuts

let ctrlOptD = KeyCombo(keyCode: 2, mods: [.control, .option])
check("title: ⌃⌥D", ctrlOptD.title == "⌃⌥D", ctrlOptD.title)
check("keycaps: one per key", ctrlOptD.keycaps == ["⌃", "⌥", "D"])
check("modifier order is ⌃⌥⇧⌘", KeyCombo(keyCode: 49, mods: [.command, .shift, .option, .control]).title == "⌃⌥⇧⌘Space")
check("match: exact", ctrlOptD.match(keyCode: 2, mods: [.control, .option]) == .exact)
check("match: with ⇧ edits by voice", ctrlOptD.match(keyCode: 2, mods: [.control, .option, .shift]) == .withShift)
check("match: another modifier doesn't count", ctrlOptD.match(keyCode: 2, mods: [.control, .option, .command]) == nil)
check("match: another key doesn't count", ctrlOptD.match(keyCode: 3, mods: [.control, .option]) == nil)
let withShift = KeyCombo(keyCode: 2, mods: [.control, .shift])
check("match: a shortcut with ⇧ only matches exactly", withShift.match(keyCode: 2, mods: [.control, .shift]) == .exact)
check("stored round trip", KeyCombo(stored: ctrlOptD.stored) == ctrlOptD)
check("stored garbage reads as nothing", KeyCombo(stored: "x:y") == nil && KeyCombo(stored: nil) == nil && KeyCombo(stored: "2:99") == nil)
check("function keys are named", KeyNames.name(122) == "F1" && KeyNames.name(90) == "F20")

// MARK: Conflicts

check("⌘Space belongs to Spotlight", ShortcutCheck.check(KeyCombo(keyCode: 49, mods: [.command])) == .taken(owner: "Spotlight", sentence: "⌘Space opens Spotlight."))
if case .taken(let owner, _) = ShortcutCheck.check(KeyCombo(keyCode: 48, mods: [.command])) { check("⌘Tab belongs to the app switcher", owner == "the app switcher") }
else { check("⌘Tab belongs to the app switcher", false) }
if case .taken(let owner, _) = ShortcutCheck.check(KeyCombo(keyCode: 9, mods: [.control, .command])) { check("⌃⌘V is Verbose's own", owner == "Verbose") }
else { check("⌃⌘V is Verbose's own", false) }
check("⌃↑ is Mission Control", ShortcutCheck.check(KeyCombo(keyCode: 126, mods: [.control])) != .ok)
check("⌃⌥D is free", ShortcutCheck.check(ctrlOptD) == .ok)
check("⌃⌥ Space stays allowed (the old menu's choice)", ShortcutCheck.check(.controlOptionSpace) == .ok)
check("a letter alone needs a modifier", ShortcutCheck.check(KeyCombo(keyCode: 2, mods: [])) == .needsModifier)
check("⇧ alone isn't enough", ShortcutCheck.check(KeyCombo(keyCode: 2, mods: [.shift])) == .needsModifier)
check("a function key may stand alone", ShortcutCheck.check(KeyCombo(keyCode: 96, mods: [])) == .ok)
check("Esc alone cancels dictation", ShortcutCheck.check(KeyCombo(keyCode: 53, mods: [])) == .escape)
let recall = ShortcutCheck.Known(combo: KeyCombo(keyCode: 9, mods: [.option, .command]), owner: "Verbose", does: "opens Recent dictations")
check("the Recent dictations setting counts when passed in", ShortcutCheck.check(KeyCombo(keyCode: 9, mods: [.option, .command]), also: [recall]) == .taken(owner: "Verbose", sentence: "⌥⌘V opens Recent dictations."))
check("…and not otherwise", ShortcutCheck.check(KeyCombo(keyCode: 9, mods: [.option, .command])) == .ok)
// Mark a moment's hotkey (Settings › Dictation › Other shortcuts).
check("the mark hotkey is ⌃⌥B unless you change it", MarkHotkeyStore.standard.title == "⌃⌥B" && MarkHotkeyStore.standard.keycaps == ["⌃", "⌥", "B"])
check("⌃⌥B is free of macOS's and Verbose's fixed shortcuts", ShortcutCheck.check(MarkHotkeyStore.standard) == .ok)
check("a dictation hotkey on the mark hotkey is taken", ShortcutCheck.check(MarkHotkeyStore.standard, also: [MarkHotkeyStore.known(MarkHotkeyStore.standard)])
      == .taken(owner: "Verbose", sentence: "⌃⌥B marks a moment while recording."))
let markDefaults = UserDefaults(suiteName: "mark-hotkey-test-\(UUID().uuidString)")!
check("no stored mark hotkey reads as ⌃⌥B", MarkHotkeyStore.current(markDefaults) == MarkHotkeyStore.standard)
markDefaults.set(KeyCombo(keyCode: 46, mods: [.control, .option]).stored, forKey: MarkHotkeyStore.key)
check("a rebound mark hotkey reads back", MarkHotkeyStore.current(markDefaults).title == "⌃⌥M")

// MARK: Mouse buttons

check("left, right, and middle don't count", !MouseButtons.isSideButton(0) && !MouseButtons.isSideButton(1) && !MouseButtons.isSideButton(2))
check("buttons 4 and 5 count", MouseButtons.isSideButton(3) && MouseButtons.isSideButton(4))
check("named from 1", MouseButtons.title(3) == "button 4")

// MARK: Upgrading saved settings

let up = HotkeyStore.upgrade(stored: "controlOptionSpace")
check("⌃⌥ Space becomes a recorded ⌃⌥ Space", up == HotkeyStore.Upgrade(choice: "custom", custom: .controlOptionSpace))
check("right ⌥ is left alone", HotkeyStore.upgrade(stored: "rightOption") == nil)
check("right ⌘ is left alone", HotkeyStore.upgrade(stored: "rightCommand") == nil)
check("Fn is left alone", HotkeyStore.upgrade(stored: "fnGlobe") == nil)
check("nothing saved is left alone (the default)", HotkeyStore.upgrade(stored: nil) == nil)
// The upgraded shortcut behaves like the old ⌃⌥ Space: ⌃⌥ Space starts, ⌃⌥⇧ Space edits by voice.
if let c = up?.custom {
    check("upgraded: ⌃⌥ Space starts", c.match(keyCode: 49, mods: [.control, .option]) == .exact)
    check("upgraded: ⌃⌥⇧ Space edits by voice", c.match(keyCode: 49, mods: [.control, .option, .shift]) == .withShift)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
