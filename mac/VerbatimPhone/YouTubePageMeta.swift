import Foundation

/// A YouTube video's channel and upload date from its public pages, for the link card ("Allie Beth Stuckey ·
/// YouTube", "Oct 23, 2026"), as the Mac's yt-dlp fills them. YouTubeKit's metadata has only the title, description,
/// and thumbnail. Pure Foundation, so mac/tools/test-linkmedia.sh checks the parsing on Linux; PhoneLinkFetcher does
/// the fetching.
enum YouTubePageMeta {
    /// The oEmbed endpoint for a video (public JSON, no key): `author_name` is the channel.
    static func oEmbedURL(videoID: String) -> URL? {
        var c = URLComponents(string: "https://www.youtube.com/oembed")
        c?.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"), URLQueryItem(name: "format", value: "json")]
        return c?.url
    }

    /// The channel from an oEmbed answer.
    static func author(oEmbed data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return clean(json["author_name"] as? String)
    }

    /// The channel and upload date (yyyyMMdd, like yt-dlp's `upload_date`) from a watch page's HTML: its
    /// `itemprop` tags, or the player data's `ownerChannelName`, `author`, `uploadDate`, and `publishDate`.
    static func parse(html: String) -> (channel: String?, uploadDate: String?) {
        var channel: String?
        // <span itemprop="author" …><link itemprop="name" content="Channel"></span>
        if let r = html.range(of: #"itemprop=["']author["'][\s\S]{0,400}?itemprop=["']name["'][^>]*content=["']([^"']+)["']"#, options: .regularExpression) {
            channel = attribute(String(html[r]), last: true).map(decodeEntities)
        }
        if channel == nil { channel = jsonString(html, key: "ownerChannelName") ?? jsonString(html, key: "author") }
        var date: String?
        for key in ["uploadDate", "datePublished"] {
            let pattern = #"itemprop=["']"# + key + #"["'][^>]*content=["']\d{4}-\d{2}-\d{2}"#
            if let r = html.range(of: pattern, options: .regularExpression) { date = yyyyMMdd(String(html[r].suffix(10))); break }
        }
        if date == nil, let s = jsonString(html, key: "uploadDate") ?? jsonString(html, key: "publishDate") { date = yyyyMMdd(s) }
        return (clean(channel), date)
    }

    /// "2026-10-23", or "2026-10-23T05:00:12-07:00", as "20261023": the date as the page writes it.
    static func yyyyMMdd(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 10 else { return nil }
        let day = t.prefix(10)
        let parts = day.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]), (1...12).contains(month), let d = Int(parts[2]), (1...31).contains(d) else { return nil }
        return parts.joined()
    }

    // MARK: Helpers

    /// The first `"key":"value"` in the page's embedded JSON, with its escapes decoded.
    private static func jsonString(_ html: String, key: String) -> String? {
        let pattern = "\"" + key + #""\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let r = html.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(html[r])
        guard let colon = match.firstIndex(of: ":") else { return nil }
        let literal = match[match.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let data = "[\(literal)]".data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return arr.first
    }

    /// The `content` attribute's value in a run of tags (the last one when `last`).
    private static func attribute(_ s: String, last: Bool) -> String? {
        let pattern = #"content=["']([^"']+)["']"#
        let range = last ? s.range(of: pattern, options: [.regularExpression, .backwards]) : s.range(of: pattern, options: .regularExpression)
        guard let r = range else { return nil }
        return String(s[r].dropFirst("content=\"".count).dropLast())
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
