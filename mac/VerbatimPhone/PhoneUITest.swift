import SwiftUI
import AVFoundation
import UIKit

/// Screenshot tour for CI. With VERBATIM_UITEST=1 the app seeds sample transcripts, walks its screens, and
/// writes each screen's name to Documents/show.txt; the CI job captures the simulator when the name changes.
@MainActor
enum PhoneUITest {
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1"

    static func run(_ app: PhoneState) {
        seed(app)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await show("p01-home")
            app.showRecorder = true
            await show("p02-record")
            app.showRecorder = false
            try? await Task.sleep(nanoseconds: 600_000_000)
            app.showLinkSheet = true
            await show("p03-link")
            app.showLinkSheet = false
            try? await Task.sleep(nanoseconds: 600_000_000)
            app.tab = .library
            await show("p04-library")
            if let rich = app.store.live.first(where: { $0.title == "Lapp Wagons catalog call" }) {
                app.libraryPath.append(rich.id)
                await show("p05-transcript")
                app.libraryPath = NavigationPath()
                try? await Task.sleep(nanoseconds: 500_000_000)
                app.tab = .home
                app.homePath.append(DocumentRoute(id: rich.id))
                await show("p06-document")
                app.homePath = NavigationPath()
            }
            if let link = app.store.live.first(where: { $0.title == "Folding wagon walkthrough" }) {
                app.tab = .library
                try? await Task.sleep(nanoseconds: 400_000_000)
                app.libraryPath.append(link.id)
                await show("p07-link-transcript")
                app.libraryPath = NavigationPath()
            }
            app.tab = .moments
            await show("p08-moments")
            app.tab = .settings
            await show("p09-settings")
            app.appearance = "dark"
            app.tab = .home
            await show("p10-dark-home")
            if let rich = app.store.live.first(where: { $0.title == "Lapp Wagons catalog call" }) {
                app.homePath.append(rich.id)
                await show("p11-dark-transcript")
                app.homePath = NavigationPath()
            }
            app.appearance = "system"
            write("done")
            Log.note("UITEST phone tour done")
        }
    }

    private static func show(_ name: String) async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // let presentations settle
        snapshot(name)
        write(name)
        Log.note("UITEST show \(name)")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    /// Renders the key window (sheets and covers included) into Documents/screens/<name>.png. The app takes
    /// its own screenshots so they match the screen exactly, with no timing race against the CI runner.
    private static func snapshot(_ name: String) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let w = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? img.pngData()?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private static func write(_ name: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("show.txt")
        try? (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func seed(_ app: PhoneState) {
        let store = app.store
        guard !store.transcripts.contains(where: { $0.title == "Lapp Wagons catalog call" }) else { return }
        let project = store.projects.first { $0.name == "Lapp Wagons" } ?? store.addProject("Lapp Wagons")
        store.dictionary.append(DictionaryEntry(preferred: "Lititz", heardAs: ["Lit it's", "Lititz's"], learnedFrom: "Added by you"))

        var link = Transcript(title: "Folding wagon walkthrough", source: .link, sourceLabel: "youtube.com", duration: 412, audioFileName: nil, model: "Parakeet TDT v3")
        link.sourceURL = "https://www.youtube.com/watch?v=ab12cd34ef5"
        link.link = LinkInfo(url: "https://www.youtube.com/watch?v=ab12cd34ef5", site: "YouTube", channel: "Lapp Wagons", uploadDate: "20260912")
        link.segments = [Segment(start: 0, end: 6, text: "This is the folding wagon, and here's how it folds flat for the truck."),
                         Segment(start: 6, end: 13, text: "Two latches on the side, lift the bed, and the wheels tuck under.")]
        link.original = link.segments
        link.createdAt = Date().addingTimeInterval(-86_400 * 2)
        store.add(link)
        store.addNote(Note(text: "Latches on the side; good close-up for the catalog.", at: 7, segmentId: link.segments[1].id), to: link.id)

        var queued = Transcript(title: "https://vimeo.com/123456789", source: .link, sourceLabel: "vimeo.com", duration: 0, audioFileName: nil, model: "")
        queued.sourceURL = "https://vimeo.com/123456789"; queued.status = .processing; queued.pendingLink = true
        store.add(queued)

        var onMac = Transcript(title: "Dealer call, Lititz", source: .file, sourceLabel: "M4A file", duration: 1260, audioFileName: "dealer.m4a", model: "")
        onMac.status = .processing; onMac.processingDevice = "mac-device"; onMac.processingDeviceName = "Tim's MacBook Pro"
        onMac.createdAt = Date().addingTimeInterval(-3600)
        store.add(onMac)

        let url = store.newAudioURL(ext: "wav")
        writeToneFile(url, seconds: 42)
        var t = Transcript(title: "Lapp Wagons catalog call", source: .voiceMemo, sourceLabel: "Voice memo", duration: 42, audioFileName: url.lastPathComponent, model: "Parakeet TDT v3")
        let lines: [(Double, Double, String, String)] = [
            (0, 6, "Okay, so the catalog needs to work for the folding wagon and the full wheel line.", "S1"),
            (6, 11, "Right. Jonathan wants the wheels first, then the wagons as a second section.", "S2"),
            (11, 18, "Then we shoot the wheels on white, and the wagons out in the field by the shop in Ephrata.", "S1"),
            (18, 24, "Chris mentioned the Lititz dealer wants a one-page sheet too. Same photos, trimmed copy.", "S2"),
            (24, 31, "Fine. One hero per product, three details, and a spec table. Keep the copy plain.", "S1"),
            (31, 37, "And the folding wagon gets its own spread, because thats the one people ask about.", "S2"),
            (37, 42, "Agreed. I'll send the shot list Thursday.", "S1"),
        ]
        t.segments = lines.map { Segment(start: $0.0, end: $0.1, text: $0.2, speaker: $0.3) }
        t.original = t.segments
        t.speakers = [Speaker(id: "S1", name: "Tim"), Speaker(id: "S2", name: "Jonathan")]
        t.projectId = project.id
        t.waveform = Waveform.envelope(of: url)
        t.pinned = true
        store.add(t)
        store.addNote(Note(text: "Ask Jonathan for the wheel spec sheet before the shoot.", at: 11, segmentId: t.segments[2].id), to: t.id)
        store.addNote(Note(text: "Folding wagon spread", at: 31, segmentId: t.segments[5].id, isBookmark: true), to: t.id)
    }

    private static func writeToneFile(_ url: URL, seconds: Double) {
        let sr = 16_000.0
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true),
              let file = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true) else { return }
        let n = AVAudioFrameCount(sr * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        buf.frameLength = n
        var seed: UInt32 = 12345
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let syllable = max(0, sin(t * 2 * .pi * 4.2)) * (0.5 + 0.5 * sin(t * 0.7))
            let pause = (Int(t) % 9 == 8) ? 0.05 : 1.0
            let v = (sin(t * 2 * .pi * 180) * 0.6 + noise * 0.4) * syllable * pause * 0.5
            buf.int16ChannelData![0][i] = Int16(max(-1, min(1, v)) * 32000)
        }
        try? file.write(from: buf)
    }
}
