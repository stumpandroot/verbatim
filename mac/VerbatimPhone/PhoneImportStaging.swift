import Foundation
import UniformTypeIdentifiers
import SwiftUI
import PhotosUI

/// Files picked on iPhone, staged inside the app before import.
///
/// The document picker hands back security-scoped URLs: the app can read them only between
/// `startAccessingSecurityScopedResource()` and `stop…`, and a file in iCloud may not be downloaded yet. Before this,
/// the import checked those URLs without opening access, saw nothing, and said "No audio or video found." (Tim, build
/// 187, a TikTok video from Files › Recents). Each pick is now copied into a temporary folder while access is open,
/// through a file coordinator so iCloud downloads it first, and the copy is what gets imported and then removed.
enum PhoneImportStaging {
    struct Item {
        let url: URL
        let title: String
        /// The temporary folder that holds the copy; removed when the import finishes or fails.
        let folder: URL
    }

    static func stage(_ urls: [URL]) -> [Item] {
        var out: [Item] = []
        let fm = FileManager.default
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &coordinatorError) { readable in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: readable.path, isDirectory: &isDir) else { return }
                let sources: [URL]
                if isDir.boolValue {
                    let items = (fm.enumerator(at: readable, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
                    sources = items.filter { isMediaFile($0) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                } else {
                    sources = isMediaFile(readable) ? [readable] : []
                }
                for s in sources { if let item = copy(s) { out.append(item) } }
            }
        }
        return out
    }

    /// Media by extension, or by the file's own content type when the name has no usable extension.
    static func isMediaFile(_ u: URL) -> Bool {
        if MediaImport.isMedia(u) { return true }
        guard let t = try? u.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return t.conforms(to: .audio) || t.conforms(to: .movie) || t.conforms(to: .audiovisualContent)
    }

    private static func copy(_ source: URL) -> Item? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var name = source.lastPathComponent
            // A file without a media extension gets one from its content type, so the importer can read it.
            if !MediaImport.isMedia(source),
               let t = try? source.resourceValues(forKeys: [.contentTypeKey]).contentType,
               let ext = t.preferredFilenameExtension {
                name = (name as NSString).deletingPathExtension + "." + ext
            }
            let dest = folder.appendingPathComponent(name)
            try fm.copyItem(at: source, to: dest)
            return Item(url: dest, title: source.deletingPathExtension().lastPathComponent, folder: folder)
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
    }
}

/// A video from the Photos picker, copied into a temporary folder the app owns.
struct PickedMovie: Transferable {
    let url: URL
    let folder: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(received.file.lastPathComponent)
            try fm.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest, folder: folder)
        }
    }
}

extension PhoneState {
    /// Files from the document picker (Import › Choose files…): staged off the main thread, then imported.
    func importPicked(_ urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            let staged = PhoneImportStaging.stage(urls)
            await MainActor.run { self.importStaged(staged, emptyMessage: "No audio or video found.") }
        }
    }

    /// Videos from the Photos picker (Import › Choose from Photos).
    func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var staged: [PhoneImportStaging.Item] = []
            for item in items {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    let title = movie.url.deletingPathExtension().lastPathComponent
                    staged.append(.init(url: movie.url, title: title.isEmpty ? "Video from Photos" : title, folder: movie.folder))
                }
            }
            importStaged(staged, emptyMessage: "Couldn't read that video.")
        }
    }

    private func importStaged(_ staged: [PhoneImportStaging.Item], emptyMessage: String) {
        guard !staged.isEmpty else { say(emptyMessage); return }
        importSources(staged.map { item in
            ImportSource(url: item.url, title: item.title, label: item.url.pathExtension.uppercased() + " file",
                         finished: { try? FileManager.default.removeItem(at: item.folder) })
        })
        if staged.count > 1 { say("Added \(staged.count) files") }
    }
}
