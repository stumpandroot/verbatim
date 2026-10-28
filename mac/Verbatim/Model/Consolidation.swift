import Foundation

// The consolidation (approved by Tim, October 28, 2026): fewer concepts, fewer duplicate entry points, nothing lost.
// Features that merged or retired keep everything they made readable; their settings move to what replaced them once
// per device (the Mac: App/ConsolidationMac.swift; the iPhone: PhoneConsolidation.swift), and the pure rules for that
// are here, shared by both apps and checked on Linux by mac/tools/test-consolidation.sh. Settings never sync, so an
// older build on another device never sees these moves; the library's files (recordings, results, notes) aren't
// rewritten, so an older build still reads everything.

enum Consolidation {
    /// Set once this device has run the consolidation's one-time moves.
    static let doneKey = "consolidation.v1.done"

    /// An install that ran a build before this one: it finished or skipped the welcome tour, or has seen What's new.
    /// Read before this launch writes either, so a new install is never mistaken for an existing one.
    static func isExistingInstall(_ d: UserDefaults) -> Bool {
        d.integer(forKey: "onboarding.seenVersion") > 0 || d.object(forKey: "releaseNotes.lastSeenBuild") != nil
    }

    /// Runs `moves` once per device, with whether this is an existing install. Later launches skip it.
    static func once(_ d: UserDefaults, _ moves: (_ existing: Bool) -> Void) {
        guard !d.bool(forKey: doneKey) else { return }
        moves(isExistingInstall(d))
        d.set(true, forKey: doneKey)
    }
}
