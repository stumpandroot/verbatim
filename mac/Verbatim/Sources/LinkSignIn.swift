import Foundation

/// Private and signed-in videos on the Mac: which browser's sign-in yt-dlp borrows (`--cookies-from-browser`), and
/// how to tell from yt-dlp's output that a video needs one. Foundation only, so mac/tools/cloudlink-tests runs it on
/// Linux. Verbatim never reads, stores, or logs the cookies; yt-dlp reads them for the one link it's fetching.
enum LinkSignIn {
    /// UserDefaults key: the browser to borrow a sign-in from, or absent or "off" for none.
    static let defaultsKey = "links.cookieBrowser"

    enum Browser: String, CaseIterable, Identifiable, Sendable {
        case safari, chrome, firefox, brave, edge

        var id: String { rawValue }

        var name: String {
            switch self {
            case .safari: return "Safari"
            case .chrome: return "Chrome"
            case .firefox: return "Firefox"
            case .brave: return "Brave"
            case .edge: return "Edge"
            }
        }

        /// How the app is found on this Mac.
        var bundleID: String {
            switch self {
            case .safari: return "com.apple.Safari"
            case .chrome: return "com.google.Chrome"
            case .firefox: return "org.mozilla.firefox"
            case .brave: return "com.brave.Browser"
            case .edge: return "com.microsoft.edgemac"
            }
        }

        /// The name yt-dlp's `--cookies-from-browser` takes.
        var helperName: String { rawValue }

        /// Chrome-family browsers keep their cookie key in the Keychain; macOS asks once.
        var usesKeychain: Bool { self == .chrome || self == .brave || self == .edge }
    }

    /// The saved browser, if any.
    static func saved(_ defaults: UserDefaults = .standard) -> Browser? {
        defaults.string(forKey: defaultsKey).flatMap(Browser.init(rawValue:))
    }

    static func save(_ b: Browser?, _ defaults: UserDefaults = .standard) {
        defaults.set(b?.rawValue ?? "off", forKey: defaultsKey)
    }

    /// yt-dlp's arguments for a browser's sign-in.
    static func arguments(_ b: Browser?) -> [String] {
        guard let b else { return [] }
        return ["--cookies-from-browser", b.helperName]
    }

    /// Whether yt-dlp's error means the video needs a signed-in viewer: private, members-only, age-restricted,
    /// "sign in to confirm", or "login required".
    static func needsSignIn(_ output: String) -> Bool {
        let s = output.lowercased()
        let markers = [
            "sign in to confirm", "sign in to view", "sign in to watch", "please sign in", "login required", "log in to",
            "login to", "requires login", "requires authentication", "authentication required", "private video",
            "video is private", "this video is private", "age-restricted", "age restricted", "confirm your age",
            "inappropriate for some users", "members-only", "members only", "join this channel", "only available to registered users",
            "use --cookies", "--cookies-from-browser", "cookies for the authentication", "not a bot", "account cookies",
        ]
        return markers.contains(where: s.contains)
    }

    /// Whether yt-dlp couldn't read Safari's cookies because Verbatim lacks Full Disk Access.
    static func safariAccessDenied(_ output: String) -> Bool {
        let s = output.lowercased()
        let denied = s.contains("operation not permitted") || s.contains("permission denied") || s.contains("permissionerror")
        return denied && (s.contains("cookies.binarycookies") || s.contains("com.apple.safari") || s.contains("safari"))
    }
}

/// Self-tests for `LinkSignIn` (Mac only). The Mac self-test (`UITest`) and `mac/tools/test-cloudlinks.sh` run them.
enum LinkSignInChecks {
    static func run() -> [CloudShareLinkChecks.Result] {
        var out: [CloudShareLinkChecks.Result] = []
        func check(_ name: String, _ ok: Bool) {
            out.append(CloudShareLinkChecks.Result(name: "private videos: " + name, ok: ok, detail: ""))
        }
        check("sign-in errors are recognized",
              LinkSignIn.needsSignIn("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.")
              && LinkSignIn.needsSignIn("ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video")
              && LinkSignIn.needsSignIn("ERROR: [vimeo] 123: This video is only available for registered users. Use --cookies-from-browser or --cookies for the authentication.")
              && LinkSignIn.needsSignIn("ERROR: [instagram] x: Requested content is not available, rate-limit reached or login required.")
              && LinkSignIn.needsSignIn("ERROR: [youtube] abc: Sign in to confirm you're not a bot"))
        check("other errors aren't sign-in errors",
              !LinkSignIn.needsSignIn("ERROR: Unsupported URL: https://example.com/") && !LinkSignIn.needsSignIn("ERROR: [youtube] abc: Video unavailable")
              && !LinkSignIn.needsSignIn("ERROR: unable to download video data: HTTP Error 404: Not Found"))
        check("Safari Full Disk Access errors",
              LinkSignIn.safariAccessDenied("PermissionError: [Errno 1] Operation not permitted: '/Users/tim/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'")
              && !LinkSignIn.safariAccessDenied("ERROR: [youtube] abc: Private video"))
        check("browser arguments", LinkSignIn.arguments(.chrome) == ["--cookies-from-browser", "chrome"] && LinkSignIn.arguments(nil).isEmpty
              && LinkSignIn.Browser.allCases.allSatisfy { !$0.bundleID.isEmpty })
        let suite = "co.stumpandroot.verbatim.signin-checks"
        if let d = UserDefaults(suiteName: suite) {
            LinkSignIn.save(.firefox, d)
            let wasFirefox = LinkSignIn.saved(d) == .firefox
            LinkSignIn.save(nil, d)
            check("the browser choice is remembered", wasFirefox && LinkSignIn.saved(d) == nil && d.string(forKey: LinkSignIn.defaultsKey) == "off")
            d.removePersistentDomain(forName: suite)
        }
        return out
    }
}
