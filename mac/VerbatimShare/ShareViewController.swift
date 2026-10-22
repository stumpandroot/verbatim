import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Verbatim in the share sheet. A shared video or audio file is copied into the App Group inbox (VerbatimInbox) and
/// transcribed the next time Verbatim opens; a web link goes to the app's link flow. A TikTok link gets an
/// explanation instead: Verbatim never downloads TikTok media. Nothing here opens the app.
///
/// Kept small for the extension memory limit: files are copied with FileManager, never read into memory.
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private var completed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareCardView(model: model, onDone: { [weak self] in self?.complete() }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? []).flatMap { $0.attachments ?? [] }
        ShareIntake.run(Array(providers.prefix(VerbatimInbox.maxShared))) { [weak self] outcome in
            guard let self else { return }
            self.model.outcome = outcome
            if outcome.closesByItself {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.complete() }
            }
        }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

// MARK: - What happened

enum ShareOutcome: Equatable {
    case working
    /// Files copied into the inbox, by their original names.
    case added([String])
    /// A web link saved for the link flow, by its host.
    case link(String)
    /// A TikTok link: Verbatim can't download it.
    case tiktok
    case failed(String)

    var closesByItself: Bool {
        switch self {
        case .added, .link: return true
        case .working, .tiktok, .failed: return false
        }
    }
}

final class ShareModel: ObservableObject {
    @Published var outcome: ShareOutcome = .working
}

/// Results from attachments loading on their own queues.
private final class Collected {
    private let lock = NSLock()
    var names: [String] = []
    var links: [String] = []
    var tiktok = false
    var errors: [String] = []
    func with(_ f: (Collected) -> Void) { lock.lock(); f(self); lock.unlock() }
}

enum ShareIntake {
    static func run(_ providers: [NSItemProvider], done: @escaping (ShareOutcome) -> Void) {
        guard let inbox = VerbatimInbox.inbox else {
            done(.failed("Verbatim can't reach its inbox. Open Verbatim once, then try again."))
            return
        }
        let c = Collected()
        let group = DispatchGroup()
        for p in providers {
            if let type = mediaType(p) {
                group.enter()
                let suggested = p.suggestedName
                // The file is only there during the callback: copy it before returning.
                _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    defer { group.leave() }
                    guard let url else {
                        c.with { $0.errors.append(error?.localizedDescription ?? "Couldn't read the file.") }
                        return
                    }
                    do {
                        let name = try ShareIntake.store(file: url, typeID: type, suggested: suggested, in: inbox)
                        c.with { $0.names.append(name) }
                    } catch {
                        c.with { $0.errors.append(error.localizedDescription) }
                    }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                    defer { group.leave() }
                    let url: URL? = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        ?? (item as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    guard let url else {
                        c.with { $0.errors.append(error?.localizedDescription ?? "Verbatim takes videos, audio files, and web links.") }
                        return
                    }
                    if url.isFileURL {
                        // A file shared by its location (the Files app): audio and video only.
                        guard VerbatimInbox.isMedia(url) else {
                            c.with { $0.errors.append("Verbatim takes videos, audio files, and web links.") }
                            return
                        }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let name = try ShareIntake.store(file: url, typeID: nil, suggested: nil, in: inbox)
                            c.with { $0.names.append(name) }
                        } catch {
                            c.with { $0.errors.append(error.localizedDescription) }
                        }
                        return
                    }
                    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, host.contains(".") else {
                        c.with { $0.errors.append("Verbatim takes videos, audio files, and web links.") }
                        return
                    }
                    if VerbatimInbox.isTikTok(url) {
                        c.with { $0.tiktok = true }
                        return
                    }
                    do {
                        try VerbatimInbox.addLink(url, in: inbox)
                        c.with { $0.links.append(host.replacingOccurrences(of: "www.", with: "")) }
                    } catch {
                        c.with { $0.errors.append(error.localizedDescription) }
                    }
                }
            } else {
                c.with { $0.errors.append("Verbatim takes videos, audio files, and web links.") }
            }
        }
        group.notify(queue: .main) {
            var outcome = ShareOutcome.failed("Verbatim takes videos, audio files, and web links.")
            c.with { r in
                if !r.names.isEmpty { outcome = .added(r.names) }
                else if let host = r.links.first { outcome = .link(host) }
                else if r.tiktok { outcome = .tiktok }
                else if let e = r.errors.first { outcome = .failed(e) }
            }
            done(outcome)
        }
    }

    /// The attachment's first registered type that's a movie or audio, so the copy keeps its real extension. An
    /// MKV, WebM, or other file iOS doesn't know as media counts too, by its extension (the app reads it with FFmpeg).
    private static func mediaType(_ p: NSItemProvider) -> String? {
        if let id = p.registeredTypeIdentifiers.first(where: { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .movie) || t.conforms(to: .audio)
        }) { return id }
        return p.registeredTypeIdentifiers.first { id in
            guard let e = UTType(id)?.preferredFilenameExtension?.lowercased() else { return false }
            return VerbatimInbox.extraMediaExts.contains(e)
        } ?? p.suggestedName.flatMap { name in
            let e = (name as NSString).pathExtension.lowercased()
            guard VerbatimInbox.extraMediaExts.contains(e) else { return nil }
            return p.registeredTypeIdentifiers.first { $0 != UTType.url.identifier && $0 != UTType.fileURL.identifier && $0 != UTType.plainText.identifier }
        }
    }

    /// Copies a file into the inbox and writes its manifest. Returns the name to show.
    private static func store(file url: URL, typeID: String?, suggested: String?, in inbox: URL) throws -> String {
        let id = UUID()
        var ext = url.pathExtension
        if ext.isEmpty, let typeID, let e = UTType(typeID)?.preferredFilenameExtension { ext = e }
        if ext.isEmpty, let suggested { ext = (suggested as NSString).pathExtension }
        if ext.isEmpty { ext = "mov" }
        ext = ext.lowercased()
        let fileName = id.uuidString + "." + ext
        try FileManager.default.copyItem(at: url, to: inbox.appendingPathComponent(fileName))
        var original = (suggested?.isEmpty == false ? suggested! : url.lastPathComponent)
        if (original as NSString).pathExtension.isEmpty { original += "." + ext }
        try VerbatimInbox.writeManifest(VerbatimInbox.Item(id: id, kind: .file, fileName: fileName, originalName: original, date: Date()), in: inbox)
        return original
    }
}

// MARK: - The card

/// A small opaque card on paper: what was added, and when it's transcribed. No glass behind text.
struct ShareCardView: View {
    @ObservedObject var model: ShareModel
    var onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            card
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 14)
                .scaleEffect(shown || reduceMotion ? 1 : 0.96)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.34)) { shown = true }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.3), value: model.outcome)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(markFill)
                    Image(systemName: markSymbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Ink.inkFixed)
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                Overline(text: "Verbatim", color: Ink.accentText)
                Spacer(minLength: 0)
            }

            Text(title)
                .font(Ink.serif(26)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)

            if let subject {
                Text(subject)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    .lineLimit(2).truncationMode(.middle)
                    .padding(.top, 8)
            }

            Text(detail)
                .font(.system(size: 15)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if model.outcome == .working {
                ProgressView().tint(Ink.ink).padding(.top, 16)
            } else {
                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ShareButtonStyle())
                .padding(.top, 18)
            }
        }
        .padding(20)
        .frame(maxWidth: 360, alignment: .leading)
        .cardSurface(radius: 20)
        .shadow(color: Ink.inkFixed.opacity(0.08), radius: 16, y: 8)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch model.outcome {
        case .working: return "Adding to Verbatim"
        case .added, .link: return "Added to Verbatim"
        case .tiktok: return "Save the video first"
        case .failed: return "Couldn't add this"
        }
    }

    private var subject: String? {
        switch model.outcome {
        case .added(let names): return names.count == 1 ? names[0] : "\(names.count) files"
        case .link(let host): return host
        case .working, .tiktok, .failed: return nil
        }
    }

    private var detail: String {
        switch model.outcome {
        case .working: return "Copying it to Verbatim on this iPhone."
        case .added, .link: return "It transcribes the next time you open Verbatim."
        case .tiktok: return "Verbatim can't download TikTok videos. In TikTok, tap Share › Save video, then share the saved video to Verbatim. Or use Transcribe what's playing in Verbatim."
        case .failed(let reason): return reason
        }
    }

    private var markSymbol: String {
        switch model.outcome {
        case .added, .link: return "checkmark"
        case .working: return "arrow.down"
        case .tiktok, .failed: return "exclamationmark"
        }
    }

    private var markFill: Color {
        switch model.outcome {
        case .added, .link: return Ink.sage
        case .working: return Ink.butter
        case .tiktok, .failed: return Ink.persimmon
        }
    }
}

/// Ink fill, reader-white label (cream with an ink label in dark), 12 pt corners.
private struct ShareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Ink.onInteractive)
            .background(Ink.interactive.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
