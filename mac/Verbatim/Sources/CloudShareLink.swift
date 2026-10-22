import Foundation

/// Share links from cloud drives (Dropbox, Google Drive, OneDrive and SharePoint, iCloud Drive), turned into
/// direct-download requests. Pure Foundation with no networking, so the Mac, the iPhone, and the Linux tests
/// (mac/tools/cloudlink-tests) all compile it. CloudShareFetch.swift does the network part on Apple platforms.
///
/// - Dropbox: `/s/…` and `/scl/fi/…?rlkey=…` get `dl=1`, keeping `rlkey` and anything else in the query.
/// - Google Drive: `/file/d/<id>/…`, `open?id=`, `uc?id=` become `drive.usercontent.google.com/download`. Files
///   too big for Drive's virus scan answer with an HTML page whose form `driveConfirmURL(fromHTML:base:)` reads.
/// - OneDrive (personal): `1drv.ms` and `onedrive.live.com` go through the documented shares API
///   (`api.onedrive.com/v1.0/shares/u!<base64url>/root/content`). SharePoint links get `download=1`.
/// - iCloud Drive: `icloud.com/iclouddrive/<id>#name` is resolved with CloudKit's public `records/resolve`.
enum CloudShareLink {
    enum Service: String, Sendable, CaseIterable {
        case dropbox, googleDrive, oneDrive, sharePoint, iCloudDrive

        /// The service as people say it, for the link card and the Library.
        var name: String {
            switch self {
            case .dropbox: return "Dropbox"
            case .googleDrive: return "Google Drive"
            case .oneDrive: return "OneDrive"
            case .sharePoint: return "SharePoint"
            case .iCloudDrive: return "iCloud Drive"
            }
        }
    }

    /// The first request for a share link.
    enum Request: Equatable, Sendable {
        /// A GET that should answer with the file (following redirects).
        case get(URL)
        /// A POST to CloudKit's `records/resolve` with this short GUID; its answer names the download URL.
        case iCloudResolve(shortGUID: String)
    }

    struct Plan: Equatable, Sendable {
        var service: Service
        var request: Request
        /// A file name the link itself carries (Dropbox's path, iCloud's fragment), used until the server names one.
        var nameHint: String?
        /// A second GET to try once when the first is refused (OneDrive: the share link with `download=1`).
        var fallback: URL? = nil
    }

    /// Why a cloud link didn't give a file. The messages are shown as is.
    enum Failure: Error, Equatable, LocalizedError {
        case privateLink
        case folder
        case gone
        case quota
        case webPage(Service)
        case iCloudUnavailable
        case http(Service, Int)

        var errorDescription: String? {
            switch self {
            case .privateLink:
                return "This link isn't shared publicly. Change sharing to 'Anyone with the link', or download the file and import it."
            case .folder:
                return "This is a folder link. Share a single file instead."
            case .gone:
                return "Nothing is at this link anymore. Check the link, or download the file and import it."
            case .quota:
                return "Google Drive is limiting downloads of this file. Try again later, or download the file and import it."
            case .webPage(let s):
                return "\(s.name) sent a web page instead of the file. Check that the link is shared with 'Anyone with the link', or download the file and import it."
            case .iCloudUnavailable:
                return "iCloud Drive didn't hand over this file. Open the link in Safari, download the file, and import it."
            case .http(let s, let code):
                return "\(s.name) returned error \(code). Try again, or download the file and import it."
            }
        }
    }

    // MARK: Recognizing

    /// The cloud service a link belongs to, from its host alone. Nil for every other link.
    static func service(of u: URL) -> Service? {
        guard let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let host = (u.host ?? "").lowercased()
        if host == "dropbox.com" || host.hasSuffix(".dropbox.com") || host == "dropboxusercontent.com" || host.hasSuffix(".dropboxusercontent.com") { return .dropbox }
        if host == "drive.google.com" || host == "drive.usercontent.google.com" { return .googleDrive }
        if host == "docs.google.com", driveFileID(u) != nil { return .googleDrive }
        if host == "1drv.ms" || host == "onedrive.live.com" || host == "onedrive.com" || host == "www.onedrive.com" { return .oneDrive }
        if host.hasSuffix(".sharepoint.com") { return .sharePoint }
        if host == "icloud.com" || host == "www.icloud.com", iCloudShortGUID(u) != nil { return .iCloudDrive }
        return nil
    }

    static func isCloudLink(_ u: URL) -> Bool { service(of: u) != nil }
    static func isCloudLink(_ s: String) -> Bool {
        URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)).map(isCloudLink) ?? false
    }

    /// What to request for a share link. Nil when it isn't a cloud file link Verbatim knows; throws `.folder`
    /// for a folder link.
    static func plan(_ u: URL) throws -> Plan? {
        guard let service = service(of: u) else { return nil }
        switch service {
        case .dropbox:
            if isDropboxFolder(u) { throw Failure.folder }
            guard let direct = dropboxDirectURL(u) else { return nil }
            return Plan(service: .dropbox, request: .get(direct), nameHint: dropboxName(u))
        case .googleDrive:
            if isDriveFolder(u) { throw Failure.folder }
            guard let id = driveFileID(u) else { return nil }
            return Plan(service: .googleDrive, request: .get(driveDownloadURL(id: id, resourceKey: query(u, "resourcekey"))), nameHint: nil)
        case .oneDrive:
            if isOneDriveFolder(u) { throw Failure.folder }
            guard let api = oneDriveSharesURL(u) else { return nil }
            return Plan(service: .oneDrive, request: .get(api), nameHint: nil, fallback: sharePointDownloadURL(u))
        case .sharePoint:
            if isSharePointFolder(u) { throw Failure.folder }
            guard let direct = sharePointDownloadURL(u) else { return nil }
            return Plan(service: .sharePoint, request: .get(direct), nameHint: nil)
        case .iCloudDrive:
            guard let id = iCloudShortGUID(u) else { return nil }
            return Plan(service: .iCloudDrive, request: .iCloudResolve(shortGUID: id), nameHint: iCloudNameHint(u))
        }
    }

    // MARK: Dropbox

    static func isDropboxFolder(_ u: URL) -> Bool {
        let p = u.path.lowercased()
        return p.hasPrefix("/sh/") || p.hasPrefix("/scl/fo/")
    }

    /// `dl=1` in place of `dl=0` (or added), keeping `rlkey` and the rest. Direct `dropboxusercontent.com` links stay.
    static func dropboxDirectURL(_ u: URL) -> URL? {
        let host = (u.host ?? "").lowercased()
        if host.hasSuffix("dropboxusercontent.com") { return u }
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        var items = (c.queryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" }
        items.append(URLQueryItem(name: "dl", value: "1"))
        c.queryItems = items
        c.fragment = nil
        return c.url
    }

    /// The file name in a Dropbox link's path (`/s/<id>/<name>`, `/scl/fi/<id>/<name>`).
    static func dropboxName(_ u: URL) -> String? {
        let parts = u.path.split(separator: "/").map(String.init)
        let named = (parts.first == "s" && parts.count >= 3) || (parts.count >= 4 && parts[0] == "scl" && parts[1] == "fi")
        guard named, let last = parts.last, last.contains(".") else { return nil }
        return cleanFileName(last.removingPercentEncoding ?? last)
    }

    // MARK: Google Drive

    static func isDriveFolder(_ u: URL) -> Bool {
        let p = u.path.lowercased()
        return p.contains("/folders/") || p.hasSuffix("/folderview") || p.contains("/drive/folders")
    }

    /// The file ID in `/file/d/<id>/…` (also `/file/u/0/d/<id>`), or in an `id=` query (`open`, `uc`, `download`).
    static func driveFileID(_ u: URL) -> String? {
        let parts = u.path.split(separator: "/").map(String.init)
        if let f = parts.firstIndex(of: "file"), let d = parts[f...].firstIndex(of: "d"), d + 1 < parts.count {
            return validDriveID(parts[d + 1])
        }
        let last = parts.last?.lowercased() ?? ""
        if ["open", "uc", "download"].contains(last), let id = query(u, "id") { return validDriveID(id) }
        return nil
    }

    private static func validDriveID(_ s: String) -> String? {
        s.count >= 10 && s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) ? s : nil
    }

    static func driveDownloadURL(id: String, resourceKey: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = "drive.usercontent.google.com"; c.path = "/download"
        var items = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "export", value: "download"), URLQueryItem(name: "confirm", value: "t")]
        if let resourceKey, !resourceKey.isEmpty { items.append(URLQueryItem(name: "resourcekey", value: resourceKey)) }
        c.queryItems = items
        return c.url!
    }

    /// Drive's "can't scan this file for viruses" page: its download form's action with the hidden inputs
    /// (id, export, confirm, uuid, and whatever else it carries) as the query. Nil when the page has no such form.
    static func driveConfirmURL(fromHTML html: String, base: URL? = nil) -> URL? {
        // The form that downloads: id="download-form", or one whose action downloads, with a hidden `id` input.
        var cursor = html.startIndex
        while let open = html.range(of: #"<form\b[^>]*>"#, options: [.regularExpression, .caseInsensitive], range: cursor..<html.endIndex) {
            cursor = open.upperBound
            let formTag = String(html[open])
            let actionText = attribute("action", in: formTag) ?? ""
            guard attribute("id", in: formTag) == "download-form" || actionText.contains("/download") || actionText.hasSuffix("/uc"),
                  let action = URL(string: actionText, relativeTo: base)?.absoluteURL, action.host != nil else { continue }
            let close = html.range(of: "</form>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
            let body = html[open.upperBound..<(close?.lowerBound ?? html.endIndex)]
            var items: [URLQueryItem] = []
            var inputCursor = body.startIndex
            while let r = body.range(of: #"<input\b[^>]*>"#, options: [.regularExpression, .caseInsensitive], range: inputCursor..<body.endIndex) {
                let tag = String(body[r])
                inputCursor = r.upperBound
                guard (attribute("type", in: tag) ?? "").lowercased() == "hidden", let name = attribute("name", in: tag) else { continue }
                items.append(URLQueryItem(name: name, value: attribute("value", in: tag) ?? ""))
            }
            guard items.contains(where: { $0.name == "id" }), var c = URLComponents(url: action, resolvingAgainstBaseURL: false) else { continue }
            c.queryItems = items
            if let u = c.url { return u }
        }
        return nil
    }

    /// An attribute's value in one HTML tag (double, single, or no quotes), with entities decoded.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\s"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...3 {
            if let r = Range(m.range(at: i), in: tag) { return decodeEntities(String(tag[r])) }
        }
        return nil
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#x3D;", with: "=").replacingOccurrences(of: "&#61;", with: "=")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: OneDrive and SharePoint

    static func isOneDriveFolder(_ u: URL) -> Bool {
        let host = (u.host ?? "").lowercased()
        return host == "1drv.ms" && u.path.lowercased().hasPrefix("/f/")
    }

    /// The shares API's content URL: `u!` and the link in unpadded base64url.
    static func oneDriveSharesURL(_ u: URL) -> URL? {
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        guard let link = c?.url?.absoluteString else { return nil }
        return URL(string: "https://api.onedrive.com/v1.0/shares/u!\(base64url(link))/root/content")
    }

    static func base64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    /// SharePoint share links name their kind after the colon: `/:f:/` is a folder; `/:v:/`, `/:u:/`, `/:b:/` are files.
    static func isSharePointFolder(_ u: URL) -> Bool {
        u.path.lowercased().hasPrefix("/:f:/")
    }

    static func sharePointDownloadURL(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        var items = (c.queryItems ?? []).filter { $0.name.lowercased() != "download" }
        items.append(URLQueryItem(name: "download", value: "1"))
        c.queryItems = items
        c.fragment = nil
        return c.url
    }

    // MARK: iCloud Drive

    static let iCloudResolveEndpoint = URL(string: "https://ckdatabasews.icloud.com/database/1/com.apple.cloudkit/production/public/records/resolve")!

    /// The short GUID in `icloud.com/iclouddrive/<id>`.
    static func iCloudShortGUID(_ u: URL) -> String? {
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0].lowercased() == "iclouddrive" else { return nil }
        let id = parts[1]
        return !id.isEmpty && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) ? id : nil
    }

    /// The name in the link's fragment (`#Interview_take_2`), as iCloud writes it: spaces became underscores.
    static func iCloudNameHint(_ u: URL) -> String? {
        guard let f = URLComponents(url: u, resolvingAgainstBaseURL: false)?.fragment, !f.isEmpty else { return nil }
        let name = (f.removingPercentEncoding ?? f).replacingOccurrences(of: "_", with: " ")
        return cleanFileName(name)
    }

    static func iCloudRequestBody(shortGUID: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["shortGUIDs": [["value": shortGUID]]])) ?? Data()
    }

    /// The download URL in CloudKit's answer (`fileContent.value.downloadURL`, with `${f}` set to the file name),
    /// and the file name (the hint plus the record's extension). Throws `.privateLink` for an access error,
    /// `.folder` for a folder, and `.iCloudUnavailable` when the answer has no file.
    static func iCloudResult(from data: Data, nameHint: String?) throws -> (url: URL, fileName: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.iCloudUnavailable }
        let result = (json["results"] as? [[String: Any]])?.first ?? json
        if let code = (result["serverErrorCode"] as? String ?? json["serverErrorCode"] as? String)?.uppercased() {
            if code.contains("NOT_FOUND") { throw Failure.gone }
            if code.contains("ACCESS") || code.contains("AUTH") || code.contains("PERMISSION") { throw Failure.privateLink }
            throw Failure.iCloudUnavailable
        }
        let root = result["rootRecord"] as? [String: Any] ?? result
        let fields = root["fields"] as? [String: Any] ?? [:]
        let ext = ((fields["extension"] as? [String: Any])?["value"] as? String).map { $0.lowercased() }
        var name = nameHint
        if let n = name, let ext, !ext.isEmpty, (n as NSString).pathExtension.lowercased() != ext { name = n + "." + ext }
        guard let raw = firstString("downloadURL", in: fields["fileContent"]) ?? firstString("downloadURL", in: result) else {
            if (root["recordType"] as? String ?? "").lowercased().contains("folder") { throw Failure.folder }
            throw Failure.iCloudUnavailable
        }
        let fileForURL = (name ?? "file").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? "file"
        guard let url = URL(string: raw.replacingOccurrences(of: "${f}", with: fileForURL)) else { throw Failure.iCloudUnavailable }
        return (url, name)
    }

    /// The first string under `key`, anywhere in a JSON value.
    private static func firstString(_ key: String, in value: Any?) -> String? {
        if let d = value as? [String: Any] {
            if let s = d[key] as? String { return s }
            for v in d.values { if let s = firstString(key, in: v) { return s } }
        } else if let a = value as? [Any] {
            for v in a { if let s = firstString(key, in: v) { return s } }
        }
        return nil
    }

    // MARK: Responses

    /// The file name in a Content-Disposition header. `filename*` (RFC 5987) wins over `filename`.
    static func fileName(contentDisposition header: String?) -> String? {
        guard let h = header, !h.isEmpty else { return nil }
        if let r = h.range(of: #"filename\*\s*=\s*([^;]+)"#, options: [.regularExpression, .caseInsensitive]) {
            var v = String(h[r]).replacingOccurrences(of: #"^filename\*\s*=\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            // charset'language'value
            if let q = v.range(of: "'", options: .backwards) { v = String(v[q.upperBound...]) }
            if let decoded = v.removingPercentEncoding, let name = cleanFileName(decoded) { return name }
        }
        if let r = h.range(of: #"filename\s*=\s*"((?:[^"\\]|\\.)*)""#, options: [.regularExpression, .caseInsensitive]) {
            let quoted = String(h[r]).replacingOccurrences(of: #"^filename\s*=\s*""#, with: "", options: [.regularExpression, .caseInsensitive])
            let v = String(quoted.dropLast()).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            return cleanFileName(v)
        }
        if let r = h.range(of: #"filename\s*=\s*([^;]+)"#, options: [.regularExpression, .caseInsensitive]) {
            let v = String(h[r]).replacingOccurrences(of: #"^filename\s*=\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            return cleanFileName(v.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A file name with no folders, control characters, or surrounding space. Nil when nothing is left.
    static func cleanFileName(_ s: String) -> String? {
        let last = s.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? s
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? nil : cleaned
    }

    /// A Library title from a file name: the name without its extension.
    static func title(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// The file's extension from its name, or from the Content-Type, lowercased. Nil when neither says.
    static func fileExtension(fileName: String?, mime: String?) -> String? {
        if let n = fileName {
            let e = (n as NSString).pathExtension.lowercased()
            if !e.isEmpty, e.count <= 5 { return e }
        }
        switch (mime ?? "").lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) ?? "" {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/aacp": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/flac", "audio/x-flac": return "flac"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        default: return nil
        }
    }

    /// Whether the first bytes of a response or file are an HTML page rather than media.
    static func looksLikeHTML(_ head: Data) -> Bool {
        var bytes = head.prefix(1024)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let first = bytes.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }), first == UInt8(ascii: "<") else { return false }
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        return ["<!doctype html", "<html", "<head", "<body", "<meta", "<title", "<script", "<form", "<div"].contains { text.contains($0) }
    }

    /// Hosts that mean "sign in first": a link that redirects here isn't shared publicly.
    static func isLoginPage(_ u: URL) -> Bool {
        let host = (u.host ?? "").lowercased()
        let path = u.path.lowercased()
        if host == "accounts.google.com" || host == "login.microsoftonline.com" || host == "login.live.com" || host == "idmsa.apple.com" { return true }
        if host.hasSuffix("dropbox.com"), path.hasPrefix("/login") || path.hasPrefix("/signin") { return true }
        if host.hasSuffix(".sharepoint.com"), path.contains("/_forms/") || path.contains("accessdenied") || path.contains("/_layouts/15/authenticate") { return true }
        return false
    }

    /// The failure for an HTTP status, or nil for a success.
    static func failure(status: Int, service: Service) -> Failure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .privateLink
        case 404, 410: return .gone
        case 429: return service == .googleDrive ? .quota : .http(service, status)
        default: return .http(service, status)
        }
    }

    /// Why a share link answered with a web page.
    static func pageFailure(html: String, finalURL: URL?, service: Service) -> Failure {
        if let u = finalURL, isLoginPage(u) { return .privateLink }
        let page = html.lowercased()
        if page.contains("quota exceeded") || page.contains("too many users have viewed or downloaded") { return .quota }
        let signIn = ["accounts.google.com/servicelogin", "accounts.google.com/v3/signin", "accounts.google.com/signin",
                      "you need access", "request access", "you need permission", "login.microsoftonline.com",
                      "login.live.com", "dropbox.com/login", "<title>sign in", "<title>sign in - google accounts"]
        if signIn.contains(where: page.contains) { return .privateLink }
        if page.contains("this item might not exist or is no longer available") || page.contains("that link is broken")
            || page.contains("this link has been disabled") || page.contains("error 404") { return .gone }
        return .webPage(service)
    }

    private static func query(_ u: URL, _ name: String) -> String? {
        URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
