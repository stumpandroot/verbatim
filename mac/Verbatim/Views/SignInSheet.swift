import SwiftUI
import AppKit

/// A link that stopped because the video needs a signed-in viewer, waiting for you to pick a browser's sign-in.
struct LinkSignInRequest: Identifiable, Equatable {
    enum Reason: Equatable {
        /// yt-dlp said the video is private, members-only, age-restricted, or needs a login.
        case needsSignIn
        /// The Safari sign-in was chosen, but macOS kept its cookies from Verbatim (Full Disk Access).
        case safariNeedsAccess
    }
    let id = UUID()
    var transcriptID: UUID
    var link: String
    var keepVideo: Bool
    var reason: Reason
}

extension LinkSignIn {
    /// System Settings › Privacy & Security › Full Disk Access.
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func isInstalled(_ b: Browser) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) != nil
    }

    /// The browsers on this Mac whose sign-in yt-dlp can use, in a fixed order.
    static var installed: [Browser] { Browser.allCases.filter(isInstalled) }

    /// The privacy footnote, shared by the sheet and Settings.
    static let privacyNote = "Verbose reads cookies only for the link you're fetching and never stores them."
}

/// "This video needs you to be signed in": the browsers on this Mac, then Cancel. When Safari's cookies were out of
/// reach, it explains Full Disk Access first.
struct SignInSheet: View {
    @EnvironmentObject var app: AppState
    let request: LinkSignInRequest
    private let browsers = LinkSignIn.installed

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if request.reason == .safariNeedsAccess {
                Text("Safari's sign-in needs Full Disk Access").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("macOS keeps Safari's cookies private. Turn on Verbose in Privacy & Security › Full Disk Access, then choose Try again. If it still fails, quit and reopen Verbose.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Full Disk Access") { NSWorkspace.shared.open(LinkSignIn.fullDiskAccessURL) }.buttonStyle(.pillLine())
                    Button("Try again") { app.useSignIn(.safari) }.buttonStyle(.pillDark()).keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
                let others = browsers.filter { $0 != .safari }
                if !others.isEmpty {
                    Text("Or use your sign-in from:").font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 6)
                    browserList(others)
                }
            } else {
                Text("This video needs you to be signed in").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                if browsers.isEmpty {
                    Text("Verbose can use a sign-in from Safari, Chrome, Firefox, Brave, or Edge, and none of them is on this Mac. Download the video another way and import the file.")
                        .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Use your sign-in from:").font(.system(size: 13)).foregroundStyle(Ink.dim)
                    browserList(browsers)
                }
            }
            Text(footnote).font(.system(size: 12)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            HStack {
                Spacer()
                Button("Cancel") { app.cancelSignIn() }.buttonStyle(.pillLine()).keyboardShortcut(.cancelAction).uiTarget("signin-cancel")
            }
            .padding(.top, 4)
        }
        .padding(20).frame(width: 400, alignment: .leading).background(Ink.paper)
    }

    private var footnote: String {
        var parts = [LinkSignIn.privacyNote]
        if browsers.contains(where: \.usesKeychain) {
            parts.append("Chrome, Brave, and Edge ask for your Keychain password the first time; choose Always Allow so they don't ask again.")
        }
        if request.reason == .needsSignIn, browsers.contains(.safari) { parts.append("Safari needs Full Disk Access.") }
        parts.append("Change this in Settings › Sync and storage.")
        return parts.joined(separator: " ")
    }

    private func browserList(_ list: [LinkSignIn.Browser]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element) { i, b in
                Button { app.useSignIn(b) } label: {
                    HStack(spacing: 10) {
                        // Only installed browsers are listed, so the icon is always found (the space holds while it loads).
                        AppIcon(key: .bundleID(b.bundleID), interpolation: nil) { Color.clear }.frame(width: 22, height: 22)
                        Text(b.name).font(.system(size: 13.5)).foregroundStyle(Ink.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.mute)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .uiTarget("signin-\(b.rawValue)")
                .overlay(alignment: .top) { if i > 0 { RowRule() } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .cardSurface(radius: Radius.row)
    }
}

/// Settings › Storage and iCloud › Links: the browser whose sign-in opens private videos, or Off.
struct LinkSignInSettingsRow: View {
    @AppStorage(LinkSignIn.defaultsKey) private var raw = "off"

    private var choices: [LinkSignIn.Browser] {
        var list = LinkSignIn.installed
        if let saved = LinkSignIn.Browser(rawValue: raw), !list.contains(saved) { list.append(saved) }
        return list
    }

    private var detail: String {
        var d = LinkSignIn.privacyNote + " When a video needs a sign-in, Verbose uses this browser's instead of asking."
        switch LinkSignIn.Browser(rawValue: raw) {
        case .safari?: d += " Safari needs Full Disk Access."
        case let b? where b.usesKeychain: d += " \(b.name) asks for your Keychain password the first time."
        case let b? where !LinkSignIn.isInstalled(b): d += " \(b.name) isn't on this Mac."
        default: break
        }
        return d
    }

    var body: some View {
        SettingsRow("links.signIn", detail: detail) {
            HStack(spacing: 8) {
                if raw == LinkSignIn.Browser.safari.rawValue {
                    Button("Open Full Disk Access") { NSWorkspace.shared.open(LinkSignIn.fullDiskAccessURL) }.buttonStyle(.settingsPill)
                }
                Picker("Sign-in for private videos", selection: $raw) {
                    Text("Off").tag("off")
                    ForEach(choices) { Text($0.name).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}
