import Foundation

/// Self-tests for cloud share links (`CloudShareLink`). Foundation only, no network. The Mac self-test (`UITest`),
/// the iPhone self-test (`PhoneUITest`), and `mac/tools/test-cloudlinks.sh` run them.
enum CloudShareLinkChecks {
    struct Result {
        let name: String
        let ok: Bool
        let detail: String
    }

    static func run() -> [Result] {
        var out: [Result] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            out.append(Result(name: "cloud links: " + name, ok: ok, detail: ok ? "" : detail()))
        }
        func url(_ s: String) -> URL { URL(string: s)! }
        func planned(_ s: String) -> CloudShareLink.Plan? { (try? CloudShareLink.plan(url(s))) ?? nil }
        func getURL(_ s: String) -> String? {
            if case .get(let u)? = planned(s)?.request { return u.absoluteString }
            return nil
        }
        func query(_ s: String?) -> [String: String] {
            guard let s, let items = URLComponents(string: s)?.queryItems else { return [:] }
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        func isFolder(_ s: String) -> Bool {
            do { _ = try CloudShareLink.plan(url(s)); return false } catch { return (error as? CloudShareLink.Failure) == .folder }
        }

        // Recognizing
        check("other links aren't cloud links",
              CloudShareLink.service(of: url("https://www.youtube.com/watch?v=dQw4w9WgXcQ")) == nil
              && CloudShareLink.service(of: url("https://example.com/talk.mp3")) == nil
              && CloudShareLink.service(of: url("https://www.icloud.com/photos/")) == nil
              && CloudShareLink.service(of: url("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit")) == nil
              && CloudShareLink.service(of: url("ftp://www.dropbox.com/s/abc/x.mp4")) == nil)
        check("services from hosts",
              CloudShareLink.service(of: url("https://www.dropbox.com/s/abc123/talk.mp4?dl=0")) == .dropbox
              && CloudShareLink.service(of: url("https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQ/view")) == .googleDrive
              && CloudShareLink.service(of: url("https://1drv.ms/u/s!AbCdEf")) == .oneDrive
              && CloudShareLink.service(of: url("https://contoso.sharepoint.com/:v:/g/personal/x/EAbc")) == .sharePoint
              && CloudShareLink.service(of: url("https://www.icloud.com/iclouddrive/0a1B2c3D4e#Interview")) == .iCloudDrive)

        // Dropbox
        let dbOld = getURL("https://www.dropbox.com/s/abc123/Team%20call.m4a?dl=0")
        check("Dropbox /s/ gets dl=1", query(dbOld)["dl"] == "1" && dbOld?.contains("/s/abc123/") == true && dbOld?.contains("dl=0") == false, dbOld ?? "nil")
        let dbNew = getURL("https://www.dropbox.com/scl/fi/xyz789/interview.mp4?rlkey=k3y&st=s1&dl=0")
        check("Dropbox /scl/fi/ keeps rlkey", query(dbNew)["rlkey"] == "k3y" && query(dbNew)["dl"] == "1" && query(dbNew)["st"] == "s1", dbNew ?? "nil")
        let dbBare = getURL("https://dropbox.com/scl/fi/xyz789/interview.mp4?rlkey=k3y")
        check("Dropbox without dl adds it", query(dbBare)["dl"] == "1" && query(dbBare)["rlkey"] == "k3y", dbBare ?? "nil")
        check("Dropbox name from the path", planned("https://www.dropbox.com/s/abc123/Team%20call.m4a?dl=0")?.nameHint == "Team call.m4a"
              && planned("https://www.dropbox.com/scl/fi/xyz789/interview.mp4?rlkey=k3y&dl=0")?.nameHint == "interview.mp4")
        check("Dropbox folders", isFolder("https://www.dropbox.com/sh/abc123/AADxyz?dl=0") && isFolder("https://www.dropbox.com/scl/fo/abc/def?rlkey=k&dl=0"))
        check("Dropbox direct links stay", getURL("https://dl.dropboxusercontent.com/s/abc/x.mp3") == "https://dl.dropboxusercontent.com/s/abc/x.mp3")

        // Google Drive
        let driveWant = "https://drive.usercontent.google.com/download?id=1AbCdEfGhIjKlMnOpQ_rS-t&export=download&confirm=t"
        check("Drive /file/d/<id>/view", getURL("https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQ_rS-t/view?usp=sharing") == driveWant,
              getURL("https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQ_rS-t/view?usp=sharing") ?? "nil")
        check("Drive /file/u/0/d/<id>", getURL("https://drive.google.com/file/u/0/d/1AbCdEfGhIjKlMnOpQ_rS-t/edit") == driveWant)
        check("Drive open?id=", getURL("https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQ_rS-t") == driveWant)
        check("Drive uc?id=", getURL("https://drive.google.com/uc?id=1AbCdEfGhIjKlMnOpQ_rS-t&export=download") == driveWant
              && getURL("https://docs.google.com/uc?export=download&id=1AbCdEfGhIjKlMnOpQ_rS-t") == driveWant)
        check("Drive keeps resourcekey", query(getURL("https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQ/view?resourcekey=0-abc"))["resourcekey"] == "0-abc")
        check("Drive folders", isFolder("https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOp?usp=sharing")
              && isFolder("https://drive.google.com/drive/u/0/folders/1AbCdEfGhIjKlMnOp"))
        let interstitial = """
        <!DOCTYPE html><html><head><title>Google Drive - Virus scan warning</title></head><body>
        <div class="uc-main"><p class="uc-warning-subcaption">Google Drive can't scan this file for viruses.</p>
        <form id="download-form" action="https://drive.usercontent.google.com/download" method="get">
        <input type="submit" id="uc-download-link" class="goog-inline-block jfk-button" value="Download anyway"/>
        <input type="hidden" name="id" value="1AbCdEfGhIjKlMnOpQ"><input type="hidden" name="export" value="download">
        <input type="hidden" name="confirm" value="t"><input type="hidden" name="uuid" value="5f3c-aa&amp;b"></form></div></body></html>
        """
        let confirm = CloudShareLink.driveConfirmURL(fromHTML: interstitial)?.absoluteString
        let cq = query(confirm)
        check("Drive virus-scan page gives the confirm URL",
              confirm?.hasPrefix("https://drive.usercontent.google.com/download?") == true && cq["id"] == "1AbCdEfGhIjKlMnOpQ"
              && cq["export"] == "download" && cq["confirm"] == "t" && cq["uuid"] == "5f3c-aa&b" && cq["uc-download-link"] == nil, confirm ?? "nil")
        let reordered = "<html><form action='/download' id='other'></form><form method=get action=\"https://drive.usercontent.google.com/download\"><input value=\"xyz\" name=\"id\" type=\"hidden\"/><input name=uuid type=hidden value=u1></form></html>"
        let rq = query(CloudShareLink.driveConfirmURL(fromHTML: reordered, base: url("https://drive.usercontent.google.com/download?id=xyz"))?.absoluteString)
        check("Drive form with attributes in any order", rq["id"] == "xyz" && rq["uuid"] == "u1", "\(rq)")
        check("a page without the form gives nothing", CloudShareLink.driveConfirmURL(fromHTML: "<html><body>Sign in</body></html>") == nil)

        // OneDrive and SharePoint
        let share = "https://1drv.ms/v/s!AkL3d_9-xyz?e=abc"
        let shares = getURL(share)
        let encoded = Data(share.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        check("OneDrive uses the shares API", shares == "https://api.onedrive.com/v1.0/shares/u!\(encoded)/root/content", shares ?? "nil")
        let fallback = planned(share)?.fallback?.absoluteString
        check("OneDrive falls back to the link with download=1", query(fallback)["download"] == "1" && query(fallback)["e"] == "abc"
              && fallback?.hasPrefix("https://1drv.ms/v/s!AkL3d_9-xyz?") == true, fallback ?? "nil")
        check("base64url has no padding or + and /", CloudShareLink.base64url("https://1drv.ms/u/s!A??~") == "aHR0cHM6Ly8xZHJ2Lm1zL3UvcyFBPz9-"
              && !CloudShareLink.base64url("ab?").contains("=") && !CloudShareLink.base64url("??>").contains("/"))
        check("onedrive.live.com uses the shares API", getURL("https://onedrive.live.com/?cid=ABC&id=ABC%21123&authkey=%21xyz")?.hasPrefix("https://api.onedrive.com/v1.0/shares/u!") == true)
        check("OneDrive folders", isFolder("https://1drv.ms/f/s!AkL3d_9-xyz") && isFolder("https://1drv.ms/f/c/abc/def"))
        let sp = getURL("https://contoso.sharepoint.com/:v:/g/personal/tim_contoso_com/EAbcDEF?e=xYz")
        check("SharePoint gets download=1", query(sp)["download"] == "1" && query(sp)["e"] == "xYz" && sp?.contains("/:v:/g/personal/") == true, sp ?? "nil")
        let sp2 = getURL("https://contoso-my.sharepoint.com/:u:/p/tim/EAbc?download=0")
        check("SharePoint replaces download=0", query(sp2)["download"] == "1" && (sp2?.components(separatedBy: "download=").count ?? 0) == 2, sp2 ?? "nil")
        check("SharePoint folders", isFolder("https://contoso.sharepoint.com/:f:/g/personal/x/EAbc"))

        // iCloud Drive
        let icloud = planned("https://www.icloud.com/iclouddrive/0a1B2c3D4e5F#Interview_take_2")
        check("iCloud Drive resolves its short GUID", icloud?.request == .iCloudResolve(shortGUID: "0a1B2c3D4e5F") && icloud?.nameHint == "Interview take 2")
        let body = String(decoding: CloudShareLink.iCloudRequestBody(shortGUID: "0a1B2c3D4e5F"), as: UTF8.self)
        check("iCloud request body", body.replacingOccurrences(of: " ", with: "") == #"{"shortGUIDs":[{"value":"0a1B2c3D4e5F"}]}"#, body)
        let answer = #"{"results":[{"rootRecord":{"recordType":"DriveItem","fields":{"extension":{"value":"m4a"},"fileContent":{"value":{"size":123,"downloadURL":"https://cvws.icloud-content.com/B/AbC/${f}?o=xyz"}}}}}]}"#
        let r = try? CloudShareLink.iCloudResult(from: Data(answer.utf8), nameHint: "Interview take 2")
        check("iCloud download URL names the file", r?.url.absoluteString == "https://cvws.icloud-content.com/B/AbC/Interview%20take%202.m4a?o=xyz"
              && r?.fileName == "Interview take 2.m4a", r?.url.absoluteString ?? "nil")
        func iCloudFailure(_ json: String) -> CloudShareLink.Failure? {
            do { _ = try CloudShareLink.iCloudResult(from: Data(json.utf8), nameHint: nil); return nil } catch { return error as? CloudShareLink.Failure }
        }
        check("iCloud access errors are private links", iCloudFailure(#"{"results":[{"serverErrorCode":"ACCESS_DENIED"}]}"#) == .privateLink
              && iCloudFailure(#"{"results":[{"serverErrorCode":"NOT_FOUND"}]}"#) == .gone)
        check("iCloud folders", iCloudFailure(#"{"results":[{"rootRecord":{"recordType":"DriveFolder","fields":{}}}]}"#) == .folder)
        check("iCloud answers without a file fall back to a clear error", iCloudFailure(#"{"results":[{}]}"#) == .iCloudUnavailable
              && iCloudFailure("not json") == .iCloudUnavailable)

        // Responses
        check("Content-Disposition filename*", CloudShareLink.fileName(contentDisposition: #"attachment; filename="fallback.mp4"; filename*=UTF-8''Caf%C3%A9%20talk.mp4"#) == "Café talk.mp4")
        check("Content-Disposition quoted filename", CloudShareLink.fileName(contentDisposition: #"attachment; filename="Team call; part 1.m4a""#) == "Team call; part 1.m4a")
        check("Content-Disposition bare filename", CloudShareLink.fileName(contentDisposition: "inline; filename=talk.mp3") == "talk.mp3")
        check("Content-Disposition can't name folders", CloudShareLink.fileName(contentDisposition: #"attachment; filename="../../etc/passwd""#) == "passwd"
              && CloudShareLink.fileName(contentDisposition: "attachment") == nil && CloudShareLink.fileName(contentDisposition: nil) == nil)
        check("titles drop the extension", CloudShareLink.title(fromFileName: "Café talk.mp4") == "Café talk" && CloudShareLink.title(fromFileName: "README") == "README")
        check("extension from name or type", CloudShareLink.fileExtension(fileName: "a.MOV", mime: nil) == "mov"
              && CloudShareLink.fileExtension(fileName: nil, mime: "audio/mpeg; charset=binary") == "mp3"
              && CloudShareLink.fileExtension(fileName: "noext", mime: "application/octet-stream") == nil)
        check("HTML is spotted", CloudShareLink.looksLikeHTML(Data("\u{FEFF}\n  <!DOCTYPE html><html>".utf8))
              && CloudShareLink.looksLikeHTML(Data("<html lang=en>".utf8)))
        let mp4 = Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        check("media isn't HTML", !CloudShareLink.looksLikeHTML(mp4) && !CloudShareLink.looksLikeHTML(Data("ID3\u{3}".utf8))
              && !CloudShareLink.looksLikeHTML(Data()) && !CloudShareLink.looksLikeHTML(Data("<?xml version=\"1.0\"?><rss>".utf8)))
        check("sign-in redirects are private links", CloudShareLink.isLoginPage(url("https://accounts.google.com/v3/signin/identifier?continue=x"))
              && CloudShareLink.isLoginPage(url("https://login.microsoftonline.com/common/oauth2"))
              && CloudShareLink.isLoginPage(url("https://www.dropbox.com/login?cont=x"))
              && !CloudShareLink.isLoginPage(url("https://drive.usercontent.google.com/download?id=x")))
        check("status codes", CloudShareLink.failure(status: 200, service: .dropbox) == nil && CloudShareLink.failure(status: 403, service: .oneDrive) == .privateLink
              && CloudShareLink.failure(status: 404, service: .dropbox) == .gone && CloudShareLink.failure(status: 500, service: .sharePoint) == .http(.sharePoint, 500))
        check("pages: private, quota, or a web page",
              CloudShareLink.pageFailure(html: "<html><title>Sign in - Google Accounts</title>", finalURL: nil, service: .googleDrive) == .privateLink
              && CloudShareLink.pageFailure(html: "<html>Google Drive - Quota exceeded</html>", finalURL: nil, service: .googleDrive) == .quota
              && CloudShareLink.pageFailure(html: "<html>You need access</html>", finalURL: nil, service: .googleDrive) == .privateLink
              && CloudShareLink.pageFailure(html: "<html>hello</html>", finalURL: nil, service: .dropbox) == .webPage(.dropbox))
        check("error messages", CloudShareLink.Failure.privateLink.localizedDescription == "This link isn't shared publicly. Change sharing to 'Anyone with the link', or download the file and import it."
              && CloudShareLink.Failure.folder.localizedDescription == "This is a folder link. Share a single file instead.")

        return out
    }
}
