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

    /// Whether this device ran a build from before the consolidation, as `once` found it at its first launch with it.
    static let existingKey = "consolidation.v1.existing"

    /// Runs `moves` once per device, with whether this is an existing install, and keeps that answer for later readers
    /// (`wasExistingInstall`). Later launches skip it. Call it early at launch, before the welcome tour or What's new
    /// writes anything.
    static func once(_ d: UserDefaults, _ moves: (_ existing: Bool) -> Void) {
        guard !d.bool(forKey: doneKey) else { return }
        let existing = isExistingInstall(d)
        d.set(existing, forKey: existingKey)
        moves(existing)
        d.set(true, forKey: doneKey)
    }

    /// An install from before the consolidation, as found at its first launch with it (false before `once` runs).
    static func wasExistingInstall(_ d: UserDefaults) -> Bool { d.bool(forKey: existingKey) }
}

// MARK: - Templates and text actions

extension Consolidation {
    /// What happens to a saved text action (the Mac's `flow.actions`) whose ID is a retired built-in.
    enum TextActionMove: Equatable {
        /// Not a retired built-in, or one you changed: it stays, as yours.
        case keep
        /// An untouched Make a plan or Journal entry: the template that replaced it takes its place.
        case replace(UUID)
        /// An untouched Key points: it goes.
        case remove
    }

    static func textActionMove(id: UUID, name: String, instruction: String) -> TextActionMove {
        guard let spec = TranscriptActions.retired.first(where: { $0.id == id }) else { return .keep }
        let ws = CharacterSet.whitespacesAndNewlines
        guard name.trimmingCharacters(in: ws) == spec.name,
              instruction.trimmingCharacters(in: ws) == spec.instruction.trimmingCharacters(in: ws) else { return .keep }
        return TemplateLibrary.current(id).map(TextActionMove.replace) ?? .remove
    }
}
