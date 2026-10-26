import SwiftUI
import WidgetKit

/// The Mac's desktop widgets (VerbatimMacWidgets): Record and Dictate, Recent recordings, This week, New thought
/// (Quick capture's kind), and Today's thoughts (VerbatimWidgets/HomeWidgets.swift, shared with iPhone). They draw from the snapshot the app writes to the
/// App Group container (WidgetSnapshot.swift) and open verbatim:// links in the app (SystemHooks.swift handles them).
@main
struct VerbatimMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordDictateWidget()
        RecentRecordingsWidget()
        WeekWidget()
        QuickCaptureWidget()
        TodayThoughtsWidget()
    }
}

/// The Mac app's Native look swaps tokens for system colors (Views/NativeLook.swift), which Tokens.swift asks on the
/// Mac. The widgets draw each look themselves from the snapshot's look, so here the tokens keep their Verbose values.
enum NativeSwap {
    static let on = false
    static func color(light: UInt32, dark: Bool, increased: Bool) -> NSColor? { nil }
    static func serif(_ size: CGFloat, weight: Font.Weight) -> Font { .system(size: size, weight: weight, design: .serif) }
}

/// Increase Contrast for Tokens.swift's colors (the app watches it in Views/NativeLook.swift; a widget reads it).
enum ContrastSetting {
    static var increased: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}
