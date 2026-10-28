import SwiftUI
import AppKit

// Shipping builds (no VERBOSE_SELFTEST): the UI self-test (UITest.swift) and the speech bench (Bench.swift) aren't
// compiled in. These stand-ins keep their call sites building and do nothing: no self-test, no bench, and no frame
// readers on controls. Debug builds and CI's tour and bench builds set VERBOSE_SELFTEST and get the real ones.
#if !VERBOSE_SELFTEST
@MainActor
enum UITest {
    static let enabled = false
    static var onboardingStep = 0
    static var rowTargets = false
    static func run(app: AppState) {}
    static func screenAppeared(_ key: String, nav: Int, since start: Date, window: NSWindow?) {}
}

enum Bench {
    static var isRequested: Bool { false }
    static func start() {}
}

extension View {
    func uiTarget(_ id: String) -> some View { self }
    func uiWindowTarget(_ id: String) -> some View { self }
}
#endif
