import ReplayKit
import AVFoundation

/// Transcribe what's playing: a ReplayKit broadcast upload extension that keeps only the sound other apps play.
///
/// ReplayKit hands this extension three streams. Only `.audioApp` is used; video (the screen) and `.audioMic` (your
/// voice) are dropped the moment they arrive. App audio is streamed straight into an AAC file in the App Group
/// (`Broadcasts/<id>.m4a`) with AVAssetWriter, one buffer at a time, so memory stays far below the extension's limit
/// of about 50 MB. When the broadcast stops, the file is finished, a manifest is written (VerbatimInbox), and a
/// Darwin notification tells an open Verbatim to import it now; otherwise the app imports it when it next opens.
/// One broadcast makes one transcript. Under a second of audio is thrown away.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.broadcast.writer")
    private var id = UUID()
    private var started = Date()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var fileURL: URL?
    private var sampleRate: Double = 44_100
    private var framesWritten: Int64 = 0
    private var broken = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.sync {
            id = UUID()
            started = Date()
            framesWritten = 0
            broken = false
        }
        guard VerbatimInbox.broadcasts != nil else {
            finishBroadcastWithError(NSError(domain: "Verbatim", code: 1, userInfo: [NSLocalizedDescriptionKey: "Verbose can't save the sound on this iPhone. Open Verbose, then try again."]))
            return
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // The screen and the microphone are never kept.
        guard sampleBufferType == .audioApp else { return }
        queue.sync { append(sampleBuffer) }
    }

    override func broadcastFinished() {
        let done = DispatchSemaphore(value: 0)
        var waiting = false
        queue.sync {
            guard let writer, let input, writer.status == .writing else { return }
            waiting = true
            input.markAsFinished()
            writer.finishWriting { done.signal() }
        }
        if waiting { _ = done.wait(timeout: .now() + 10) }
        queue.sync { save() }
    }

    // MARK: Writing

    private func append(_ buffer: CMSampleBuffer) {
        guard !broken, CMSampleBufferDataIsReady(buffer), CMSampleBufferGetNumSamples(buffer) > 0,
              let format = CMSampleBufferGetFormatDescription(buffer) else { return }
        if writer == nil { open(format: format, at: CMSampleBufferGetPresentationTimeStamp(buffer)) }
        guard let writer, let input, writer.status == .writing else {
            if self.writer?.status == .failed { broken = true }
            return
        }
        // Real time: a buffer the encoder isn't ready for is dropped, never held.
        guard input.isReadyForMoreMediaData else { return }
        if input.append(buffer) {
            framesWritten += Int64(CMSampleBufferGetNumSamples(buffer))
        } else if writer.status == .failed {
            broken = true
        }
    }

    /// Starts the file with the first buffer's format (ReplayKit sends 16-bit PCM, often big-endian, at 44.1 or
    /// 48 kHz; the writer converts it to AAC).
    private func open(format: CMFormatDescription, at time: CMTime) {
        guard let folder = VerbatimInbox.broadcasts,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { broken = true; return }
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
        let channels = asbd.mChannelsPerFrame >= 2 ? 2 : 1
        let url = folder.appendingPathComponent(id.uuidString + ".m4a")
        try? FileManager.default.removeItem(at: url)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 2 ? 128_000 : 64_000,
            ]
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { broken = true; return }
            w.add(i)
            guard w.startWriting() else { broken = true; return }
            w.startSession(atSourceTime: time)
            writer = w
            input = i
            fileURL = url
            sampleRate = rate
        } catch {
            broken = true
        }
    }

    /// Keeps the file and writes its manifest, or removes it when it's too short or didn't finish.
    private func save() {
        defer { writer = nil; input = nil; fileURL = nil }
        guard let url = fileURL, let folder = VerbatimInbox.broadcasts else { return }
        let seconds = Double(framesWritten) / max(sampleRate, 1)
        guard writer?.status == .completed, seconds >= 1 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let item = VerbatimInbox.Item(id: id, kind: .broadcast, fileName: url.lastPathComponent, originalName: nil, url: nil,
                                      date: Date(), sourceApp: nil, started: started, duration: seconds)
        do {
            try VerbatimInbox.writeManifest(item, in: folder)
            VerbatimInbox.post(VerbatimInbox.broadcastFinishedNote)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
