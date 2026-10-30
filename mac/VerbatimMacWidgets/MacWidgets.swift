import SwiftUI
import WidgetKit

/// The Mac's desktop widgets (VerbatimMacWidgets): Record and dictate, Recent recordings, This week, New thought
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

/// Increase Contrast for Tokens.swift's colors (the app watches it in Views/MacAppearance.swift; a widget reads it).
enum ContrastSetting {
    static var increased: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}
