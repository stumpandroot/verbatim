import Foundation

/// Which look the keyboard draws (DESIGN.md §13): the app's choice on this iPhone, read from the App Group once per
/// appearance, the same way the dictate button's settings are (`KeyboardModel.resume`). No second setting: the
/// keyboard follows Settings › Appearance › Look. Without Full Access there's no App Group, so Verbose style.
/// Pure Foundation, so the Linux tests (mac/tools/test-look.sh) cover it.
enum KeyboardLook {
    /// `AppLook.key` (Look.swift); its values are "verbose" and "native".
    static let key = "appearance.look"

    static func isNative(raw: String?) -> Bool { raw == "native" }

    /// True when the app chose Native. Nil defaults (no Full Access) and anything unknown read as Verbose style.
    static func isNative(_ defaults: UserDefaults?) -> Bool { isNative(raw: defaults?.string(forKey: key)) }

    // MARK: Contrast (WCAG 2.x), for checking the Native accent's values in the tests.

    /// Relative luminance of an sRGB color given as 0xRRGGBB.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// The contrast ratio between two colors, 1...21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
