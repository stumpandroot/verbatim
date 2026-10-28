import Foundation

// Shipping builds (no VERBOSE_SELFTEST): the screenshot tour (PhoneUITest.swift) isn't compiled in. This stand-in
// keeps its call sites building and does nothing. Debug builds and CI's tour build set VERBOSE_SELFTEST.
#if !VERBOSE_SELFTEST
@MainActor
enum PhoneUITest {
    static let enabled = false
    static var onboardingStep = 0
    static func run(_ app: PhoneState) {}
}
#endif
