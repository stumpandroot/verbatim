import Foundation

/// Clean while you talk (Mac dictation): the rules, kept free of AppKit and the models so `mac/tools/test-preclean.sh`
/// and the Mac self-test (`PreCleanChecks`) can check them anywhere.
///
/// The wait after letting go of the dictation key is cleanup's model step, which rewrites the whole dictation. While
/// you talk, a background worker (`PreCleanRun`) transcribes what was said so far at each pause, and cleans the
/// sentences that are finished ("sealed") with Apple's on-device model. When you let go, the whole recording is
/// transcribed and run through the rules exactly as before, and cleanup then asks whether the start of that text was
/// already cleaned (`PreCleanSession.reuse`). Only the rest goes to the model.
///
/// The final pass stays in charge:
/// - A sealed part is reused only when the final text starts with the same words, part by part, and each part still
///   ends where a sentence ends. A spoken correction that reached back, a word the Dictionary boost changed, or a
///   sentence that carried on reuses only the parts before it. With nothing to reuse, cleanup runs exactly as it did.
/// - Work done while you talk is never pasted, kept, or logged, and it never leaves the Mac: only Apple's on-device
///   model does it, and never when cloud cleanup would clean this dictation. Esc, a new dictation, or any other stop
///   discards it.
///
/// No setting in the app. To turn it off: `defaults write <bundle id> dictationPreClean -bool NO` (read once as each
/// dictation starts; on when unset).
enum PreClean {
    static let defaultsKey = "dictationPreClean"
    static var isOn: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// What starting a dictation knows right away. The worker checks the rest off the main thread before its first
    /// model call (`allowed`).
    static func mayStart(flag: Bool, engine: String, command: Bool, usesModel: Bool) -> Bool {
        flag && engine == "fluid" && !command && usesModel
    }

    /// Whether this dictation's finished sentences may be cleaned while you talk. Never in command mode, for a
    /// thought, at Literal, in code apps, with another speech engine, without Apple's model, or when cloud cleanup
    /// would clean this dictation: your words don't leave the Mac before you let go.
    static func allowed(flag: Bool, engine: String, command: Bool, thought: Bool, usesModel: Bool, codeApp: Bool,
                        cloudCleanup: Bool, modelAvailable: Bool) -> Bool {
        mayStart(flag: flag, engine: engine, command: command, usesModel: usesModel)
            && !thought && !codeApp && !cloudCleanup && modelAvailable
    }

    // MARK: Parts

    /// A run of finished sentences, and the break that came before it ("" for the first).
    struct Part: Equatable, Sendable {
        var sep: String
        var text: String
    }

    /// What cleaning a part gave: the model's text, or the rule-based text with why the model's wasn't used.
    struct Outcome: Equatable, Sendable {
        var text: String
        var cleaned: Bool
        var note: String?
    }

    /// The parts to reuse when you let go, and what's left for the model.
    struct Hit: Equatable, Sendable {
        var parts: [(sep: String, outcome: Outcome)]
        /// The break between the reused parts and the remainder, as the final text has it.
        var remainderSep: String
        var remainder: String

        static func == (a: Hit, b: Hit) -> Bool {
            a.remainderSep == b.remainderSep && a.remainder == b.remainder && a.parts.count == b.parts.count
                && zip(a.parts, b.parts).allSatisfy { $0.sep == $1.sep && $0.outcome == $1.outcome }
        }

        /// The reused parts' text, joined with the final text's own breaks.
        var text: String { parts.enumerated().map { ($0.offset == 0 ? "" : $0.element.sep) + $0.element.outcome.text }.joined() }
        var cleanedAny: Bool { parts.contains { $0.outcome.cleaned } }
        var note: String? { parts.compactMap(\.outcome.note).first }
    }

    /// Counts for the log. Never text.
    struct Stats: Equatable, Sendable {
        var sealed = 0
        var reused = 0
        var remainderCharacters = 0
        /// Seconds the release waited for a part that was still being cleaned.
        var waited: Double = 0

        var logLine: String {
            "dictation pre-clean: \(sealed) part\(sealed == 1 ? "" : "s") sealed, \(reused) reused, remainder \(remainderCharacters) chars"
                + (waited >= 0.01 ? ", waited \(String(format: "%.2f", waited)) s" : "")
        }
    }

    /// A part is at least this many words (`longEnough`); fewer wait for the next sentence.
    static let minWords = 8
    /// A part is at most this long, the same limit cleanup's own parts have (`FlowCleanup.chunkParts`).
    static let maxPartCharacters = 2_500

    // MARK: Sentences

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie", "no", "inc", "ltd", "co", "corp",
        "approx", "apt", "dept", "est", "fig", "gen", "gov", "hon", "mt", "rev", "sgt", "col", "capt", "lt", "ave", "blvd",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    ]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
    private static let openers: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "«"]
    private static let wideEnds: Set<Character> = ["。", "！", "？"]

    /// Where sentences end inside `c`: each offset is just past a sentence's closing mark, with another sentence
    /// after it. The end of the text isn't listed. Cautious on purpose, since a missed break only seals less: an
    /// abbreviation ("e.g.", "Dr."), an initial, a bare number ("2."), a decimal ("3.5"), an ellipsis, or a next word
    /// in lowercase is not a break. Text without sentence punctuation has none.
    static func sentenceEnds(_ c: [Character]) -> [Int] {
        var out: [Int] = []
        let n = c.count
        var i = 0
        while i < n {
            let ch = c[i]
            if wideEnds.contains(ch) {
                var j = i + 1
                while j < n, wideEnds.contains(c[j]) || closers.contains(c[j]) { j += 1 }
                var p = j
                while p < n, c[p].isWhitespace { p += 1 }
                if p < n { out.append(j) }
                i = max(j, i + 1)
                continue
            }
            guard ch == "." || ch == "!" || ch == "?" || ch == "…" else { i += 1; continue }
            var j = i
            var dots = 0, ellipsis = false
            while j < n, c[j] == "." || c[j] == "!" || c[j] == "?" || c[j] == "…" {
                if c[j] == "…" { ellipsis = true }
                if c[j] == "." { dots += 1 }
                j += 1
            }
            if dots > 1 { ellipsis = true }
            let marksEnd = j
            while j < n, closers.contains(c[j]) { j += 1 }
            defer { i = max(j, i + 1) }
            guard !ellipsis, j < n, c[j].isWhitespace else { continue }
            var p = j
            while p < n, c[p].isWhitespace { p += 1 }
            guard p < n, startsSentence(c, at: p) else { continue }
            // A lone period after an abbreviation, an initial, or a bare number doesn't end the sentence.
            if marksEnd - i == 1, ch == "." {
                var s = i
                while s > 0, !c[s - 1].isWhitespace { s -= 1 }
                let token = String(c[s..<i]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“‘([«"))
                let letters = token.lowercased().filter { $0.isLetter }
                if token.contains(".") || abbreviations.contains(token.lowercased()) || (letters.count == 1 && token.count == 1)
                    || (!token.isEmpty && token.allSatisfy { $0.isNumber }) || token.isEmpty { continue }
            }
            out.append(j)
        }
        return out
    }

    /// A capital, a digit, or a letter from a script without cases starts a sentence, after any opening quote. A
    /// lowercase word does only when it mixes cases ("iPhone").
    private static func startsSentence(_ c: [Character], at p: Int) -> Bool {
        var q = p
        while q < c.count, openers.contains(c[q]) { q += 1 }
        guard q < c.count else { return false }
        let f = c[q]
        if f.isNumber || f.isUppercase { return true }
        guard f.isLetter else { return false }
        if !f.isLowercase { return true }
        var e = q + 1
        while e < c.count, !c[e].isWhitespace {
            if c[e].isUppercase { return true }
            e += 1
        }
        return false
    }

    /// Words that open a spoken correction of what came just before ("Actually, make that Friday", "scratch that").
    /// A sentence that starts with one stays with the sentence before it, so the model sees both together.
    private static let correctionCues = ["actually", "no wait", "no, wait", "wait", "scratch that", "i mean", "sorry", "or rather", "rather",
                                         "make that", "delete", "let me start over", "start over", "never mind", "nevermind", "no", "correction",
                                         "strike that", "undo", "let me rephrase", "i meant"]

    static func startsWithCorrection(_ text: String) -> Bool {
        let t = text.lowercased().drop { !$0.isLetter }
        for cue in correctionCues where t.hasPrefix(cue) {
            let rest = t.dropFirst(cue.count)
            if rest.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { return true }
        }
        return false
    }

    /// At least `minWords` words, or, in writing without spaces between words, twice as many characters.
    private static func longEnough(_ c: ArraySlice<Character>) -> Bool {
        let words = c.split(whereSeparator: { $0.isWhitespace }).filter { w in w.contains { $0.isLetter || $0.isNumber } }.count
        if words >= minWords { return true }
        let wide = c.filter { ch in ch.isLetter && (ch.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false) }.count
        return wide >= minWords * 2
    }

    // MARK: Sealing

    /// The new parts a snapshot seals, given the parts sealed so far. `pre` is the rule-based text of everything
    /// said up to a pause.
    /// - The snapshot's last sentence is never sealed: the end of a partial recording is the unstable part.
    /// - Nothing new is sealed unless the snapshot still starts with every part sealed before, each ending at a
    ///   sentence break.
    /// - A break isn't sealed when the next sentence opens a correction.
    /// - New sentences form parts of at least `minWords` words and at most `maxPartCharacters` characters. A single
    ///   sentence longer than that is never sealed, and neither is anything after it.
    static func seal(sealed: [Part], snapshot pre: String) -> [Part] {
        let c = Array(pre)
        let ends = sentenceEnds(c)
        guard !ends.isEmpty else { return [] }
        let m = matched(sealed, in: c, ends: ends)
        guard m.count == sealed.count else { return [] }
        let from = m.last?.end ?? 0
        // Back off breaks whose next sentence opens a correction.
        var usable = ends.filter { $0 > from }
        while let last = usable.last, startsWithCorrection(String(c[last...])) { usable.removeLast() }
        guard let stable = usable.last else { return [] }
        var out: [Part] = []
        var start = from
        while start < stable {
            var s = start
            while s < stable, c[s].isWhitespace { s += 1 }
            let sep = start == 0 ? "" : String(c[start..<s])
            // The longest run of whole sentences that fits one part.
            guard let end = usable.last(where: { $0 > s && $0 - s <= maxPartCharacters }) else { break }
            guard longEnough(c[s..<end]) else { break }
            out.append(Part(sep: sep, text: String(c[s..<end])))
            start = end
        }
        return out
    }

    // MARK: Matching

    /// The leading parts found at the start of the text, in order: each part's words exactly, any break between
    /// parts, and each part ending where a sentence ends (or at the end of the text).
    private static func matched(_ parts: [Part], in c: [Character], ends: [Int]) -> [(sep: String, end: Int)] {
        var out: [(sep: String, end: Int)] = []
        let endSet = Set(ends)
        var pos = 0
        for (i, part) in parts.enumerated() {
            var s = pos
            while s < c.count, c[s].isWhitespace { s += 1 }
            if i > 0 && s == pos { break }   // parts are separated by a break
            let t = Array(part.text)
            guard !t.isEmpty, s + t.count <= c.count, c[s..<(s + t.count)].elementsEqual(t) else { break }
            let end = s + t.count
            guard end == c.count || endSet.contains(end) else { break }
            out.append((sep: i == 0 ? "" : String(c[pos..<s]), end: end))
            pos = end
        }
        return out
    }

    /// How many leading parts the final text starts with. Fewer when what follows opens a correction: the part
    /// before a correction goes back to the model with it.
    static func reusable(_ parts: [Part], in pre: String) -> Int {
        let c = Array(pre)
        let m = matched(parts, in: c, ends: sentenceEnds(c))
        var k = m.count
        while k > 0, startsWithCorrection(String(c[m[k - 1].end...])) { k -= 1 }
        return k
    }

    /// The first `count` parts' outcomes with the final text's breaks, and the remainder for the model. Nil when
    /// they aren't at the start of the text.
    static func hit(_ parts: [Part], outcomes: [Outcome], count: Int, in pre: String) -> Hit? {
        let c = Array(pre)
        let m = matched(Array(parts.prefix(count)), in: c, ends: sentenceEnds(c))
        guard count > 0, m.count == count, outcomes.count >= count else { return nil }
        let end = m[count - 1].end
        var s = end
        while s < c.count, c[s].isWhitespace { s += 1 }
        let rest = String(c[s...])
        return Hit(parts: (0..<count).map { (sep: m[$0].sep, outcome: outcomes[$0]) },
                   remainderSep: rest.isEmpty ? "" : String(c[end..<s]), remainder: rest)
    }

    // MARK: Pacing

    /// When the worker takes a snapshot of the audio so far.
    enum Pacing {
        /// Silence that counts as a pause.
        static let pause: Double = 0.6
        /// Speech needed since the last snapshot.
        static let minNewSpeech: Double = 4
        /// Without a pause, a snapshot is taken after this much speech anyway.
        static let speechWithoutPause: Double = 12
        static let minInterval: Double = 3
        /// Past this much audio, no more snapshots: the rest of a long dictation is cleaned when you let go.
        static let maxAudio: Double = 300

        /// Each snapshot transcribes everything said so far, so they spread out as the dictation grows.
        static func interval(total: Double) -> Double { max(minInterval, total / 10) }

        static func shouldSnapshot(total: Double, lastSnapshotAt: Double, speechSince: Double, trailingSilence: Double) -> Bool {
            guard total <= maxAudio, speechSince >= minNewSpeech, total - lastSnapshotAt >= interval(total: total) else { return false }
            return trailingSilence >= pause || speechSince >= speechWithoutPause
        }
    }
}

/// The dictation's audio so far, for snapshots: 16 kHz mono samples copied from the recorder's tap as they're
/// written, so the recording and its file are never touched. Safe from the audio thread: appending takes a short
/// lock and copies one buffer. Holds at most `PreClean.Pacing.maxAudio` (about 10 MB); past it, it lets go of the
/// audio and takes no more.
final class PreCleanAudio: @unchecked Sendable {
    static let rate: Double = 16_000
    private static let chunk = 16_000

    private let lock = NSLock()
    /// One-second chunks, so a snapshot copies references and the audio thread never copies the whole recording.
    private var chunks: [[Int16]] = []
    private var count = 0
    private var stopped = false
    private var silentRun = 0
    private var voicedSince = 0
    private var lastSnapshot = 0
    /// A slowly falling peak of loudness: silence is judged against how loud this voice and room are.
    private var loud: Float = 0

    struct Status: Equatable {
        var total: Double
        var lastSnapshotAt: Double
        var speechSince: Double
        var trailingSilence: Double
        var over: Bool
    }

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return Status(total: Double(count) / Self.rate, lastSnapshotAt: Double(lastSnapshot) / Self.rate,
                      speechSince: Double(voicedSince) / Self.rate, trailingSilence: Double(silentRun) / Self.rate, over: stopped)
    }

    func append(_ samples: UnsafeBufferPointer<Int16>) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { let f = Float(s); sum += f * f }
        let rms = (sum / Float(samples.count)).squareRoot()
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if count + samples.count > Int(PreClean.Pacing.maxAudio * Self.rate) {
            stopped = true; chunks = []
            return
        }
        loud = max(rms, loud * 0.999)
        if rms < max(190, loud * 0.15) { silentRun += samples.count } else { silentRun = 0; voicedSince += samples.count }
        var rest = samples[...]
        while !rest.isEmpty {
            if chunks.isEmpty || chunks[chunks.count - 1].count >= Self.chunk {
                var next: [Int16] = []
                next.reserveCapacity(Self.chunk)
                chunks.append(next)
            }
            let room = Self.chunk - chunks[chunks.count - 1].count
            let take = rest.prefix(room)
            chunks[chunks.count - 1].append(contentsOf: take)
            rest = rest.dropFirst(take.count)
        }
        count += samples.count
    }

    /// Everything heard so far as the engine takes it, and marks the snapshot. Nil when there's nothing, or past
    /// the limit.
    func snapshot() -> [Float]? {
        lock.lock()
        let held = chunks
        let n = count
        let ok = !stopped && n > 0
        if ok { lastSnapshot = n; voicedSince = 0 }
        lock.unlock()
        guard ok else { return nil }
        var out: [Float] = []
        out.reserveCapacity(n)
        for chunk in held { for s in chunk { out.append(Float(s) / 32_768) } }
        return out
    }

    /// Lets go of the audio and takes no more.
    func stop() {
        lock.lock(); stopped = true; chunks = []; count = 0; lock.unlock()
    }
}

/// One dictation's parts cleaned while you talk. It belongs to that dictation only: `cancel` (Esc, a new dictation,
/// any stop) or `reuse` (letting go) ends it, and it never pastes, keeps, or logs text.
actor PreCleanSession {
    /// Cleans one part: `first` is the dictation's first part, which gets the app's context like cleanup's own first
    /// part. Nil when the model gave no answer to keep (cancelled, failed, or too slow): that part and every part
    /// after it are left for the release.
    typealias Cleaner = @Sendable (_ text: String, _ first: Bool) async -> PreClean.Outcome?

    private let clean: Cleaner
    /// Everything the model step depends on (`FlowCleanup.preCleanKey`). Parts are reused only by a cleanup with
    /// the same key.
    private var key: String?
    private var parts: [PreClean.Part] = []
    private var outcomes: [PreClean.Outcome?] = []
    private var pump: Task<Void, Never>?
    private var closed = false
    private var dead = false
    private var gaveUp = false
    private var counts = PreClean.Stats()

    init(clean: @escaping Cleaner) { self.clean = clean }

    func start(key: String) {
        guard !closed, !dead, self.key == nil else { return }
        self.key = key
    }

    /// A snapshot's rule-based text: seals its new finished sentences and cleans them, one part at a time.
    func offer(_ pre: String) {
        guard !closed, !dead, !gaveUp, key != nil else { return }
        let new = PreClean.seal(sealed: parts, snapshot: pre)
        guard !new.isEmpty else { return }
        parts += new
        outcomes += [PreClean.Outcome?](repeating: nil, count: new.count)
        counts.sealed = parts.count
        if pump == nil { pump = Task(priority: .utility) { [weak self] in await self?.run() } }
    }

    private func run() async {
        while !dead, !gaveUp, !Task.isCancelled, let i = outcomes.firstIndex(where: { $0 == nil }) {
            let text = parts[i].text
            let out = await clean(text, i == 0)
            if dead || Task.isCancelled { return }
            guard let out, i < outcomes.count else { gaveUp = true; break }
            outcomes[i] = out
        }
        pump = nil
    }

    /// Letting go: the sealed parts the final rule-based text starts with, when they were cleaned for the same
    /// `key`. A part still being cleaned is waited for up to `wait` seconds. Nil when there's nothing to reuse, and
    /// then cleanup runs as it always has. Ends the session either way.
    func reuse(pre: String, key: String, wait: Double) async -> PreClean.Hit? {
        guard !closed else { return nil }
        closed = true
        defer { shutDown() }
        guard !dead, let mine = self.key, mine == key else { return nil }
        let matched = PreClean.reusable(parts, in: pre)
        func ready() -> Int { outcomes.prefix(matched).prefix { $0 != nil }.count }
        var n = ready()
        if n < matched, pump != nil, !gaveUp, wait > 0 {
            let began = Date()
            // Only the part in flight is waited for; parts queued behind it go to the model with the rest.
            while !dead, !gaveUp, pump != nil, n < outcomes.count, outcomes[n] == nil, Date().timeIntervalSince(began) < wait {
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            counts.waited = Date().timeIntervalSince(began)
            if dead { return nil }
            n = ready()
        }
        guard n > 0, let hit = PreClean.hit(parts, outcomes: outcomes.prefix(n).compactMap { $0 }, count: n, in: pre) else {
            counts.remainderCharacters = pre.count
            return nil
        }
        counts.reused = n
        counts.remainderCharacters = hit.remainder.count
        return hit
    }

    /// Counts for the log.
    func stats() -> PreClean.Stats { counts }

    /// Esc, a new dictation, or any other stop: drops everything and stops the model.
    func cancel() {
        dead = true
        shutDown()
    }

    private func shutDown() {
        closed = true
        pump?.cancel()
        pump = nil
        parts = []
        outcomes = []
    }
}
