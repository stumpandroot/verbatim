import Foundation

/// The consolidation (approved October 28, 2026): settings on this Mac for features that merged or retired move to
/// what replaced them, once, at launch, before anything reads them. Each step is safe to run again; what an older
/// build stored is left readable (see each step). The pure rules shared with the iPhone are in Model/Consolidation.swift.
@MainActor
enum ConsolidationMac {
    static func migrateSettings(_ d: UserDefaults = .standard) {
        // The floating button retired: anyone on it moves to the Ribbon.
        if DictationSurface.migrateRetired(d) { Log.note("consolidation: floating button → Ribbon") }
        Consolidation.once(d) { existing in
            // The thought bubble starts off on new installs; an existing install that never changed it keeps it on.
            if existing, d.object(forKey: Thoughts.bubbleKey) == nil { d.set(true, forKey: Thoughts.bubbleKey) }
        }
    }
}
