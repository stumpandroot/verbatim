import SwiftUI
import AVFoundation
import Combine

// Voice profile enrollment, shared by the Mac (VoiceProfileSection.swift, a sheet over Settings) and the iPhone
// (VoiceProfileScreen.swift, pushed from Settings › Your voice). Three steps: what it does, read aloud, the result.
// The engine is `VoiceProfile` (Transcription/VoiceProfile.swift); this file records, tracks reading progress, and
// draws the pieces both apps share.

/// What you read aloud. Three short passages make about 30 seconds; Read more adds one of the extras.
enum VoicePassages {
    static let first: [String] = [
        "The morning light came through the studio windows while we set up the second key. We moved the chair twice before the shadows looked right.",
        "After lunch we drove out past the covered bridge to find the old mill, where the owner told us how his grandfather built the wheel by hand.",
        "By evening the rain had cleared, so we packed the gear, thanked everyone, and read our notes aloud one more time before heading home.",
    ]
    static let extras: [String] = [
        "Every Saturday the market opens before sunrise. Farmers stack crates of apples and sweet corn, and the line at the bakery wraps around the corner.",
        "She wrote the list on the back of an envelope: call the printer, pick up the frames, and send the final cut to the client before Friday.",
        "The quiet hour after dinner is the best time to think. The house settles, the dog finds his spot by the window, and the day slows down.",
        "We tested three microphones in the small room upstairs. The cheapest one sounded warm and clear, which surprised everybody, including the engineer.",
    ]
    private static let extraKey = "voice.nextExtra"

    /// The next extra passage, in turn, so Read more doesn't repeat itself.
    static func nextExtra() -> String {
        let i = UserDefaults.standard.integer(forKey: extraKey)
        UserDefaults.standard.set(i + 1, forKey: extraKey)
        return extras[i % extras.count]
    }

    /// Comparable words: lowercased letters and digits, apostrophes dropped ("grandfather's" → "grandfathers").
    static func normalized(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") })
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }

    /// How many of `passage`'s words the heard words cover, in order. A heard word may skip up to two passage words
    /// (a misheard or dropped word doesn't stall progress); words that match nothing are ignored.
    static func matched(_ passage: [String], heard: [String]) -> Int {
        var p = 0
        for h in heard {
            guard p < passage.count else { break }
            for k in 0..<3 where p + k < passage.count && passage[p + k] == h {
                p += k + 1
                break
            }
        }
        return p
    }
}

/// Whether a voice profile exists, for views that must redraw after an enrollment or a delete.
@MainActor
final class VoiceProfileStatus: ObservableObject {
    static let shared = VoiceProfileStatus()
    @Published private(set) var isEnrolled = VoiceProfile.isEnrolled
    /// Saved, but with less than `VoiceProfile.minSeconds` of speech (not used yet).
    @Published private(set) var isPartial = VoiceProfile.stored != nil && !VoiceProfile.isEnrolled
    @Published private(set) var quality: Float? = VoiceProfile.currentQuality

    func refresh() {
        isEnrolled = VoiceProfile.isEnrolled
        isPartial = VoiceProfile.stored != nil && !isEnrolled
        quality = VoiceProfile.currentQuality
    }

    /// Deletes the profile from this device.
    func delete() {
        VoiceProfile.reset()
        refresh()
    }

    /// The panel's sentence for the saved profile.
    var line: String {
        guard let q = quality else { return "Verbatim doesn't know your voice yet." }
        if !isEnrolled { return "Read a little more so Verbatim knows your voice." }
        return q >= VoiceProfile.goodQuality ? VoiceEnrollment.greatLine : VoiceEnrollment.goodLine
    }
}

/// One enrollment session: records you reading, follows along, and hands the recording to `VoiceProfile`.
@MainActor
final class VoiceEnrollment: ObservableObject {
    enum Step: Equatable {
        case intro
        case reading
        case analyzing
        case result(VoiceProfile.Enrollment)
        case failed(String)

        /// 1, 2, or 3, for "STEP 2 OF 3".
        var number: Int {
            switch self {
            case .intro: return 1
            case .reading: return 2
            case .analyzing, .result, .failed: return 3
            }
        }
    }

    static let goodLine = "Good. A little more makes it great."
    static let greatLine = "Great — Verbatim knows your voice."
    static let quietLine = "Too many voices — try somewhere quieter."

    /// Average reading pace, for the time estimate and for following along when live words are off.
    static let wordsPerSecond = 2.6

    @Published private(set) var step: Step
    @Published private(set) var passages: [String] = VoicePassages.first
    @Published private(set) var passageIndex = 0
    /// Words of the current passage read so far.
    @Published private(set) var wordsRead = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var isStarting = false
    @Published private(set) var micName = ""
    /// Whether progress follows your words (live words on) or the clock.
    @Published private(set) var followsWords = false

    private let preview: Bool
    private var recorder: Recorder?
    private let transcriber = LiveTranscriber()
    private var url: URL?
    private var replacing = true
    private var ticker: Task<Void, Never>?
    private var heardBase = 0
    private var passageStart: TimeInterval = 0
    private var passageDoneAt: TimeInterval?
    private var lastAnnounced = 0
    private var analysis: Task<Void, Never>?

    /// `preview` (UI tour, no microphone): opens on step 2 with made-up progress and never records.
    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            step = .reading
            passageIndex = 0
            wordsRead = 15
            elapsed = 18
            #if os(macOS)
            micName = "MacBook Pro Microphone"
            #else
            micName = "iPhone Microphone"
            #endif
            return
        }
        step = .intro
        transcriber.prepare()
        refreshMicName()
    }

    var passage: String { passages[min(passageIndex, passages.count - 1)] }
    var passageTokens: [String] { passage.split(separator: " ").map(String.init) }

    /// About how long all the passages take, rounded to 5 seconds: "0:30".
    var aboutSeconds: Int {
        let words = passages.reduce(0) { $0 + VoicePassages.normalized($1).count }
        return max(10, Int((Double(words) / Self.wordsPerSecond / 5).rounded()) * 5)
    }

    /// 0…1 across every passage, by words read.
    var fraction: Double {
        let counts = passages.map { VoicePassages.normalized($0).count }
        let total = counts.reduce(0, +)
        guard total > 0 else { return 0 }
        let done = counts.prefix(passageIndex).reduce(0, +) + wordsRead
        return min(1, Double(done) / Double(total))
    }

    /// "0:18 OF ABOUT 0:30 · SHURE MV7"
    var progressLabel: String {
        var s = "\(Self.clock(elapsed)) OF ABOUT \(Self.clock(Double(aboutSeconds)))"
        if !micName.isEmpty { s += " · \(micName.uppercased())" }
        return s
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// The panel's sentence for an enrollment result.
    static func line(for e: VoiceProfile.Enrollment) -> String {
        switch e.hint {
        case .good: return greatLine
        case .otherVoices: return quietLine
        case .noSpeech: return e.message
        case .readMore: return e.isEnrolled ? goodLine : e.message
        }
    }

    // MARK: Steps

    /// Step 2 from the start: the three passages, replacing any saved profile.
    func start() {
        guard !preview else { return }
        passages = VoicePassages.first
        replacing = true
        begin()
    }

    /// One more passage, added to the saved profile.
    func readMore() {
        guard !preview else { return }
        passages = [VoicePassages.nextExtra()]
        replacing = false
        begin()
    }

    /// Pauses or resumes the reading.
    func togglePause() {
        guard step == .reading, let recorder, !isStarting else { return }
        recorder.togglePause()
        isPaused = recorder.isPaused
    }

    /// Ends the reading now and learns from what was recorded.
    func finishNow() {
        guard step == .reading else { return }
        finish()
    }

    /// Leaves without saving anything new: stops the microphone and deletes the recording.
    func cancel() {
        ticker?.cancel(); ticker = nil
        analysis?.cancel(); analysis = nil
        transcriber.stop()
        recorder?.discard()
        recorder = nil
        removeRecording()
        isPaused = false
        isStarting = false
    }

    func backToIntro() {
        cancel()
        step = .intro
    }

    // MARK: Recording

    private func begin() {
        cancel()
        passageIndex = 0; wordsRead = 0; elapsed = 0; heardBase = 0; passageStart = 0; passageDoneAt = nil
        lastAnnounced = 0; followsWords = false
        step = .reading
        isStarting = true
        refreshMicName()
        Self.askForMicrophone { [weak self] ok in
            guard let self, self.step == .reading else { return }
            guard ok else {
                #if os(macOS)
                self.fail("Verbatim needs the microphone to learn your voice. Allow it in System Settings › Privacy & Security › Microphone, then try again.")
                #else
                self.fail("Verbatim needs the microphone to learn your voice. Allow it in the Settings app › Verbatim, then try again.")
                #endif
                return
            }
            self.record()
        }
    }

    private func record() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-enroll-\(UUID().uuidString).wav")
        self.url = url
        let r = Recorder()
        recorder = r
        r.liveTap = transcriber.tap
        #if os(macOS)
        r.begin(to: url) { [weak self] error in
            guard let self, self.recorder === r else { return }
            if let error { self.fail(error.localizedDescription); return }
            self.started()
        }
        #else
        do {
            try r.start(to: url)
            refreshMicName()
            started()
        } catch {
            fail(error.localizedDescription)
        }
        #endif
    }

    private func started() {
        isStarting = false
        transcriber.start(format: Recorder.targetFormat)
        Log.note("voice enroll: reading \(passages.count) passage(s), replacing=\(replacing)")
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard step == .reading, let recorder, !isPaused else { return }
        elapsed = recorder.elapsed
        let words = VoicePassages.normalized(passage)
        let heard = VoicePassages.normalized(transcriber.text)
        if !heard.isEmpty { followsWords = true }
        let inPassage = elapsed - passageStart
        let read: Int
        if followsWords {
            read = VoicePassages.matched(words, heard: Array(heard.dropFirst(min(heardBase, heard.count))))
        } else {
            read = Int(inPassage * Self.wordsPerSecond)
        }
        let next = min(words.count, max(wordsRead, read))
        if next != wordsRead { wordsRead = next }

        // A passage is done when its words are read (or the last one is all that's missing), or after plenty of
        // time, so a word the recognizer missed never stalls the reading. A short pause lets the last word land.
        let expected = Double(words.count) / Self.wordsPerSecond
        let wordsDone = wordsRead >= words.count - (followsWords ? 1 : 0)
        if passageDoneAt == nil, wordsDone || inPassage > expected * 1.8 + 2 {
            passageDoneAt = elapsed
            if wordsRead != words.count { wordsRead = words.count }
        }
        if let doneAt = passageDoneAt, elapsed - doneAt >= 0.8 {
            if passageIndex + 1 < passages.count {
                passageIndex += 1
                wordsRead = 0
                heardBase = heard.count
                passageStart = elapsed
                passageDoneAt = nil
            } else {
                finish()
                return
            }
        }
        announceProgress()
    }

    /// VoiceOver hears the time every 10 seconds.
    private func announceProgress() {
        let s = Int(elapsed)
        guard s >= lastAnnounced + 10 else { return }
        lastAnnounced = s - s % 10
        let message: String = "\(lastAnnounced) seconds of about \(aboutSeconds)"
        AccessibilityNotification.Announcement(message).post()
    }

    private func finish() {
        ticker?.cancel(); ticker = nil
        transcriber.stop()
        guard let recorder else { return }
        let stopped = recorder.stop()
        self.recorder = nil
        isPaused = false
        guard let stopped else {
            fail("Verbatim couldn't keep that recording. Try again.")
            return
        }
        let file = stopped.0, seconds = stopped.1
        guard seconds >= 2 else {
            removeRecording()
            fail("That was too short to learn from. Read the passage aloud, close to the microphone.")
            return
        }
        step = .analyzing
        let replacing = self.replacing
        analysis = Task { @MainActor [weak self] in
            do {
                let result = try await VoiceProfile.enroll(from: [file], replacing: replacing)
                guard let self, !Task.isCancelled else { return }
                self.removeRecording()
                VoiceProfileStatus.shared.refresh()
                self.step = .result(result)
                let message: String = Self.line(for: result)
                AccessibilityNotification.Announcement(message).post()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.removeRecording()
                VoiceProfileStatus.shared.refresh()
                self.fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        ticker?.cancel(); ticker = nil
        transcriber.stop()
        recorder?.discard()
        recorder = nil
        removeRecording()
        isStarting = false
        isPaused = false
        Log.note("voice enroll: \(message)")
        step = .failed(message)
    }

    private func removeRecording() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        RecordingSegments.removeSegments(of: url)
        self.url = nil
    }

    private func refreshMicName() {
        guard !preview else { return }
        #if os(macOS)
        // Core Audio can be slow to answer; asked off the main thread.
        Task { [weak self] in
            let name = await Self.currentMicName()
            self?.micName = name
        }
        #else
        micName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone Microphone"
        #endif
    }

    #if os(macOS)
    nonisolated private static func currentMicName() async -> String { AudioDevices.current()?.name ?? "" }
    #endif

    private static func askForMicrophone(_ done: @escaping @MainActor (Bool) -> Void) {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in Task { @MainActor in done(ok) } }
        default: done(false)
        }
        #else
        switch AVAudioApplication.shared.recordPermission {
        case .granted: done(true)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { ok in Task { @MainActor in done(ok) } }
        default: done(false)
        }
        #endif
    }
}

// MARK: - Shared pieces

/// The voice mark: three rings, the smallest filled. Drawn in a 120 × 80 box.
struct VoiceRingsMark: View {
    var lineWidth: CGFloat = 1.6
    var color: Color = Ink.inkFixed

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 120, size.height / 80)
            let ox = (size.width - 120 * s) / 2, oy = (size.height - 80 * s) / 2
            func ring(_ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: ox + (60 - r) * s, y: oy + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            let style = StrokeStyle(lineWidth: lineWidth * s)
            ctx.stroke(ring(42, 34), with: .color(color), style: style)
            ctx.stroke(ring(52, 24), with: .color(color), style: style)
            ctx.fill(ring(62, 14), with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// The sage panel: how well Verbatim knows your voice.
struct VoiceQualityPanel: View {
    var line: String
    /// iPhone: the mark beside one line, as in Settings. Mac: overline, large mark, then the line.
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 14) {
                    VoiceRingsMark(lineWidth: 2.4).frame(width: 64, height: 44)
                    Text(line).font(Ink.serif(20)).foregroundStyle(Ink.inkFixed)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("HOW WELL IT KNOWS YOU").font(Ink.mono(11, weight: .medium)).tracking(1.8).foregroundStyle(Ink.inkFixed)
                    VoiceRingsMark().frame(width: 180, height: 120)
                    Text(line).font(Ink.serif(26)).foregroundStyle(Ink.inkFixed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(hex: Ink.sageHex), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How well Verbatim knows your voice: \(line)")
    }
}

/// The passage being read: words read so far in ink, the rest faint.
struct VoicePassageCard: View {
    @ObservedObject var model: VoiceEnrollment
    var size: CGFloat = 23
    @Environment(\.limitMotion) private var limitMotion

    /// The passage split into the words read so far and the rest. Display words and comparable words line up,
    /// except for stray punctuation tokens, which count as read along with the word before them.
    static func split(_ tokens: [String], wordsRead: Int) -> (read: String, rest: String) {
        var readTokens = 0, seen = 0
        for t in tokens {
            if !VoicePassages.normalized(t).isEmpty {
                if seen >= wordsRead { break }
                seen += 1
            }
            readTokens += 1
        }
        return (tokens.prefix(readTokens).joined(separator: " "), tokens.dropFirst(readTokens).joined(separator: " "))
    }

    var body: some View {
        let (read, rest) = Self.split(model.passageTokens, wordsRead: model.wordsRead)
        (Text(read).foregroundStyle(Ink.ink) + Text(read.isEmpty || rest.isEmpty ? rest : " " + rest).foregroundStyle(Ink.faint))
            .font(Ink.serif(size))
            .lineSpacing(size * 0.25)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, size > 22 ? 24 : 18).padding(.vertical, size > 22 ? 22 : 18)
            .cardSurface(radius: 18, fill: Ink.reader)
            .animation(limitMotion ? nil : Motion.touch, value: model.wordsRead)
            .id(model.passageIndex)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.passage)
            .accessibilityValue(model.passages.count > 1
                                ? "Passage \(model.passageIndex + 1) of \(model.passages.count). \(model.wordsRead) words read."
                                : "\(model.wordsRead) words read.")
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The persimmon progress rail and its mono label.
struct VoiceProgress: View {
    @ObservedObject var model: VoiceEnrollment
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.ink.opacity(0.10))
                    Capsule().fill(Ink.persimmon).frame(width: geo.size.width * model.fraction)
                }
            }
            .frame(height: 6)
            Text(model.isStarting ? "STARTING THE MICROPHONE…" : model.progressLabel)
                .font(Ink.mono(11)).tracking(1.2).foregroundStyle(Ink.mute)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(Int(model.elapsed)) seconds of about \(model.aboutSeconds)\(model.micName.isEmpty ? "" : ", \(model.micName)")")
    }
}

/// The big persimmon button: a square while recording (pause), a triangle while paused (resume).
struct VoiceRecordButton: View {
    @ObservedObject var model: VoiceEnrollment
    var size: CGFloat = 52

    var body: some View {
        Button { model.togglePause() } label: {
            ZStack {
                Circle().fill(Ink.persimmon)
                if model.isPaused {
                    Image(systemName: "play.fill").font(.system(size: size * 0.32, weight: .bold)).foregroundStyle(Color(hex: Ink.paperHex))
                        .offset(x: size * 0.03)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.06, style: .continuous).fill(Color(hex: Ink.paperHex))
                        .frame(width: size * 0.26, height: size * 0.26)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.isStarting)
        .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
        .accessibilityHint(model.isPaused ? "Continues recording." : "Pauses recording. You can resume or finish.")
    }
}
