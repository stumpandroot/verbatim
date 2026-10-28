import Foundation

/// The consolidation (approved October 28, 2026) on this iPhone: settings for features that merged or retired move to
/// what replaced them, once, at launch, before the welcome tour or What's new writes anything. The pure rules shared
/// with the Mac are in Model/Consolidation.swift; the Mac's moves are in App/ConsolidationMac.swift.
enum PhoneConsolidation {
    static func migrateSettings(_ d: UserDefaults = .standard) {
        Consolidation.once(d) { existing in
            Log.note("consolidation: first launch with it, \(existing ? "an existing install" : "a new install")")
        }
    }
}
