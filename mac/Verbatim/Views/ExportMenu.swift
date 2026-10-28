import SwiftUI
import AppKit

/// Copy: takes the tab you're on (Original or Cleaned) with its own defaults, never the export sheet's options. The
/// transcript's Share menu copies with timestamps, the other version, or the engine's words; Export opens the export
/// sheet (ExportSheet), which keeps its own saved options.
enum ExportMenu {
    /// Copies one version with Copy's own defaults. Also bound to ⌘⇧C once per transcript screen.
    static func copy(_ t: Transcript, _ v: Exporter.CopyVersion, timestamps: Bool = false, app: AppState) {
        guard t.status == .ready else { return }
        Exporter.copy(t, v, timestamps: timestamps)
        app.toast = Toast("Copied the \(v.name)" + (timestamps ? " with timestamps" : ""))
        Sounds.done()
    }
}
