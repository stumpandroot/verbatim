import Foundation
import AppKit
import Combine

/// Whether each transcript's kept video, kept audio, and original import are still on disk, checked on a
/// background queue. Rows and menus read `exists` instead of statting in `body`: a stat on an external or iCloud
/// volume can block, and Links statted each kept video several times per row per render.
///
/// A path is checked when it first appears in the library (so the answer is usually ready before a screen shows
/// it), then again whenever the app becomes active or a screen that shows kept media appears (`refresh`), which
/// catches a file deleted in Finder. A path not checked yet reads as missing until its check lands.
@MainActor
final class KeptMedia: ObservableObject {
    static let shared = KeptMedia()

    /// Paths that exist, among those checked.
    @Published private(set) var present: Set<String> = []
    /// Paths checked or being checked.
    private var known: Set<String> = []
    /// Each transcript's paths as last scanned. Most `transcripts` publishes are progress ticks that change no path,
    /// so a scan compares these by id (cheap: the strings share storage with the last list) instead of hashing every
    /// path of every transcript into `known` again.
    private var scanned: [UUID: MediaPaths] = [:]
    private struct MediaPaths: Equatable {
        var video, audio, original: String?
        init(_ t: Transcript) { video = t.keptVideo; audio = t.keptAudio; original = t.originalMedia }
    }
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.kept-media", qos: .userInitiated)
    private var bag = Set<AnyCancellable>()

    private init() {}

    /// Follows the library: new kept or imported paths are checked as they appear.
    func attach(_ store: Store) {
        store.$transcripts.sink { [weak self] list in self?.checkNew(in: list) }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
    }

    /// Whether the file is there, as last checked. Never touches the disk.
    func exists(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        if !known.contains(path) { check([path]) }
        return present.contains(path)
    }

    /// `Transcript.videoFile` from the cache: the kept video or the original import, if it's a video and there.
    func videoFile(_ t: Transcript) -> URL? {
        for p in [t.keptVideo, t.originalMedia].compactMap({ $0 }) where exists(p) {
            let u = URL(fileURLWithPath: p)
            if MediaImport.videoExts.contains(u.pathExtension.lowercased()) { return u }
        }
        return nil
    }

    /// Checks every known path again; publishes only when something changed.
    func refresh() { check(Array(known)) }

    private func checkNew(in list: [Transcript]) {
        var fresh: [String] = []
        for t in list {
            let paths = MediaPaths(t)
            if scanned[t.id] == paths { continue }
            scanned[t.id] = paths
            for p in [paths.video, paths.audio, paths.original] {
                if let p, !p.isEmpty, !known.contains(p) { fresh.append(p) }
            }
        }
        if !fresh.isEmpty { check(fresh) }
    }

    private func check(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        known.formUnion(paths)
        // One serial queue, so results land in the order they were asked for.
        queue.async { [weak self] in
            let fm = FileManager.default
            let found = paths.map { (path: $0, there: fm.fileExists(atPath: $0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var next = self.present
                    for f in found { if f.there { next.insert(f.path) } else { next.remove(f.path) } }
                    if next != self.present { self.present = next }
                }
            }
        }
    }
}
