import Foundation

/// Every outside address the iPhone app opens, in one place.
///
/// PLACEHOLDER: the web pages below don't exist yet. Confirm (or change) `base`, `privacy`, and `terms` before
/// release; App Review requires a working privacy policy link.
enum Links {
    /// The Verbatim page on the studio site (placeholder; also what Share Verbatim shares).
    static let base = URL(string: "https://stumpandroot.co/verbatim")!
    /// Privacy policy (placeholder).
    static let privacy = base.appendingPathComponent("privacy")
    /// Terms of use (placeholder).
    static let terms = base.appendingPathComponent("terms")

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
