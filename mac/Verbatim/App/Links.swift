import Foundation

/// Every outside address the Mac and iPhone apps open, in one place: the pages on getverbose.app (App Review AR-02,
/// October 31, 2026; the earlier stumpandroot.co/verbatim addresses never existed).
enum Links {
    /// Verbose's website (also what Share Verbose shares).
    static let base = URL(string: "https://getverbose.app")!
    /// Privacy policy.
    static let privacy = base.appendingPathComponent("privacy")
    /// Terms of use.
    static let terms = base.appendingPathComponent("terms")
    /// Refund policy for the Mac app sold directly: a section of the terms. iPhone refunds go through Apple.
    static let refunds = URL(string: "https://getverbose.app/terms#refunds")!
    /// Setup steps and fixes.
    static let support = base.appendingPathComponent("support")

    static let supportEmail = "hello@stumpandroot.co"

    /// A new email to support with the subject filled in.
    static func mail(subject: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: subject)]
        return c.url
    }
}
