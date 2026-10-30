import SwiftUI

/// While the library loads at launch (`Store.isLoaded`): the screen's own background, and after a moment a small
/// spinner. A quick load shows nothing extra; a big one shows it's on its way. The caller supplies the background, so
/// it matches the screen.
struct LibraryLoadingView: View {
    @State private var shown = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                shown = true
            }
            .accessibilityLabel("Opening your library")
    }
}

/// Launch timing for the self-tests (`UITEST TIMING launch-first-frame` and `store-ready`): from the start of the app's
/// own code (after the self-test's big library is written) to the first frame, and to the library loaded.
@MainActor
enum LaunchClock {
    private static var start: TimeInterval?
    /// The first window's root `onAppear` (appeared) and the main-loop turn after it (settled), in ms since `start`.
    private(set) static var firstFrame: (appeared: Double, settled: Double)?

    /// When the library finished loading (`Store.finishLoad`), in ms since `start`.
    private(set) static var libraryReady: Double?

    static func markStart() { if start == nil { start = ProcessInfo.processInfo.systemUptime } }

    static func libraryLoaded() { if libraryReady == nil, start != nil { libraryReady = sinceStart() } }

    /// The launch lines both self-tests log once the library has loaded: `store-load`, `launch-first-frame`, and
    /// `store-ready`.
    static func logTimings(_ store: Store) {
        Log.note("UITEST TIMING store-load \(Int(store.loadMs.rounded())) transcripts=\(store.transcripts.count)")
        if let f = firstFrame { Log.note("UITEST TIMING launch-first-frame \(Int(f.appeared.rounded())) settled=\(Int(f.settled.rounded()))") }
        if let r = libraryReady { Log.note("UITEST TIMING store-ready \(Int(r.rounded()))") }
    }

    /// Milliseconds since `markStart`.
    static func sinceStart() -> Double {
        guard let start else { return 0 }
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    /// Call from the first window's root `onAppear`; only the first call counts.
    static func rootAppeared() {
        guard firstFrame == nil, start != nil else { return }
        let appeared = sinceStart()
        firstFrame = (appeared, appeared)
        DispatchQueue.main.async { MainActor.assumeIsolated { firstFrame = (appeared, sinceStart()) } }
    }
}

/// The self-tests' big library (VERBATIM_UITEST only): 1,000 made-up recordings written into the library before the
/// Store loads, so launch, the load, and screen changes are timed with a library that size. The self-tests time them,
/// then delete these again before their usual steps, so every other check and screenshot sees the library it always
/// did. IDs are fixed, so a run that stops early leaves files the next run overwrites and deletes.
enum BigLibrarySeed {
    static let count = 1_000

    /// The i-th seeded transcript's ID: "B16B0000-0000-4000-8000-" and the index.
    static func id(_ i: Int) -> UUID { UUID(uuidString: String(format: "B16B0000-0000-4000-8000-%012ld", i))! }

    static func isSeeded(_ id: UUID) -> Bool { id.uuidString.hasPrefix("B16B0000-0000-4000-8000-") }

    /// Writes the transcripts that aren't on disk yet. Call before the Store exists.
    static func write() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.transcripts, withIntermediateDirectories: true)
        let lines = ["We walked through the catalog and agreed the wheels should lead it this season.",
                     "The folding wagon needs its own spread, since that's what people ask about first.",
                     "Shoot the wheels on white, and the wagons out in the field behind the shop.",
                     "The dealer wants a one-page sheet with the same photos and shorter copy.",
                     "Let's check the dates again on Thursday before anything goes to print."]
        let now = Date()
        var written = 0
        for i in 0..<count {
            let url = TranscriptFiles.url(id(i))
            if fm.fileExists(atPath: url.path) { continue }
            var t = Transcript(title: "Archive recording \(i + 1)", source: i % 3 == 0 ? .file : .voiceMemo,
                               sourceLabel: i % 3 == 0 ? "MP3 file" : "Voice memo", duration: 120 + Double(i % 40) * 30,
                               audioFileName: nil, model: "Parakeet TDT v3")
            t.id = id(i)
            // Older than anything else the self-tests make: from a month to about two and a half years ago.
            t.createdAt = now.addingTimeInterval(-Double(30 * 24 + i * 19) * 3600)
            t.segments = (0..<24).map { k in
                Segment(start: Double(k) * 5, end: Double(k) * 5 + 4.5, text: lines[(i + k) % lines.count], speaker: k % 4 == 0 ? "S2" : "S1")
            }
            t.original = t.segments
            t.speakers = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")]
            if let data = try? TranscriptFiles.enc.encode(t) { Cloud.write(data, to: url); written += 1 }
        }
        Log.note("UITEST big library: wrote \(written) of \(count) transcripts")
    }

    /// Deletes the seeded transcripts from the library (files included), and waits for the deletes to land.
    @MainActor static func remove(from store: Store) {
        let seeded = store.transcripts.filter { isSeeded($0.id) }
        for t in seeded { store.delete(t) }
        store.waitForWrites()
        Log.note("UITEST big library: removed \(seeded.count) transcripts")
    }
}
