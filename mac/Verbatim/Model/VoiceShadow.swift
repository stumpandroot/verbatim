import Foundation

// "Only keep my voice in dictation" as pure rules, and the numbers kept about each decision so its threshold can be
// tuned on real dictations (shadow mode). Foundation only: VoiceProfile (Transcription/VoiceProfile.swift) turns a
// diarization and your voice profile into these inputs, and mac/tools/test-voice-shadow.sh checks the rules on Linux.
// The Mac's self-test runs the same cases (`VoiceShadowChecks`).
//
// One decision (`VoiceGate.decide`) serves the real filter and shadow mode, so they can't drift apart: the filter
// applies its `keep`, shadow mode only records it. What's recorded is numbers only (`VoiceShadowRecord`): never a
// word, a name, or audio.

/// The decision behind "Only keep my voice": which words fall in turns of voices that aren't yours.
enum VoiceGate {
    /// One stretch of one voice, from the diarizer.
    struct Turn: Equatable, Sendable {
        var speaker: String
        var start: Double
        var end: Double
    }

    /// A word's time (or a whole line's, when the engine gave no word times).
    struct Span: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    /// Why every word was kept.
    enum Abstain: String, Codable, Sendable, CaseIterable {
        /// The dictation is shorter than `minClipSeconds`: too short to tell voices apart.
        case tooShort
        /// Fewer than two voices were found.
        case fewVoices
        /// No voice sounds like you.
        case noMatch
        /// Every voice sounds like you.
        case onlyYou
        /// No word falls in another voice's turn.
        case nothingToDrop
        /// Every word would go.
        case nothingLeft
        /// The voices couldn't be told apart (the diarizer failed, or the audio is gone).
        case failed

        /// For the log.
        var phrase: String {
            switch self {
            case .tooShort: return "under \(Int(VoiceGate.minClipSeconds)) s"
            case .fewVoices: return "fewer than two voices"
            case .noMatch: return "no voice matched"
            case .onlyYou: return "every voice matched"
            case .nothingToDrop: return "nothing to drop"
            case .nothingLeft: return "nothing would be left"
            case .failed: return "couldn't tell voices apart"
            }
        }
    }

    /// One turn, as numbers.
    struct TurnScore: Codable, Equatable, Sendable {
        /// The turn's length in seconds.
        var seconds: Double
        /// Cosine similarity of the turn's voice to your profile (-1…1); nil when the voice has no usable embedding.
        var score: Double?
        /// Words (or lines) that belong to the turn.
        var words: Int
        /// Whether the filter drops (or, in shadow mode, would drop) the turn's words at the threshold in force.
        var wouldDrop: Bool
        /// Which voice, numbered from 0 in order of first appearance. A number, never a name.
        var voice: Int
    }

    struct Decision: Equatable, Sendable {
        /// One per span: whether the word stays. All true when the gate abstains.
        var keep: [Bool]
        /// Why every word stays, or nil when some are dropped.
        var abstained: Abstain?
        var turns: [TurnScore]
        /// How many voices the diarizer found.
        var voices: Int
        /// Spans dropped; 0 when the gate abstains.
        var dropped: Int

        /// Every word kept, for a reason that needs no turns (too short, a failure).
        static func abstaining(_ why: Abstain, spans: Int) -> Decision {
            Decision(keep: [Bool](repeating: true, count: spans), abstained: why, turns: [], voices: 0, dropped: 0)
        }
    }

    /// The least a dictation must last before voices are told apart.
    static let minClipSeconds: Double = 2

    /// Decides which spans stay. A voice is yours when its score is at or above `threshold`; a voice with no score
    /// counts as someone else's. A span belongs to the voice whose turns cover most of it (the earlier voice on a tie),
    /// and a span in no turn stays. The gate abstains (keeps everything) with fewer than two voices, when no voice or
    /// every voice is yours, when nothing would be dropped, and when nothing would be left.
    static func decide(spans: [Span], turns: [Turn], scores: [String: Float], threshold: Float) -> Decision {
        var order: [String] = []
        var number: [String: Int] = [:]
        for t in turns where number[t.speaker] == nil { number[t.speaker] = order.count; order.append(t.speaker) }

        // Each span's turn: the voice with the most overlap, then that voice's turn with the most.
        var ownerTurn = [Int?](repeating: nil, count: spans.count)
        var wordsInTurn = [Int](repeating: 0, count: turns.count)
        for (i, s) in spans.enumerated() {
            let start = s.start, end = max(s.end, s.start + 0.05)
            var overlap = [Double](repeating: 0, count: order.count)
            var bestTurn = [Int?](repeating: nil, count: order.count)
            var bestTurnOverlap = [Double](repeating: 0, count: order.count)
            for (j, t) in turns.enumerated() {
                let o = min(end, t.end) - max(start, t.start)
                guard o > 0, let v = number[t.speaker] else { continue }
                overlap[v] += o
                if o > bestTurnOverlap[v] { bestTurnOverlap[v] = o; bestTurn[v] = j }
            }
            var best: Int?
            for v in order.indices where overlap[v] > 0 && (best == nil || overlap[v] > overlap[best!]) { best = v }
            if let best, let j = bestTurn[best] { ownerTurn[i] = j; wordsInTurn[j] += 1 }
        }

        var scored: [TurnScore] = turns.enumerated().map { j, t in
            TurnScore(seconds: round(max(0, t.end - t.start), places: 2), score: scores[t.speaker].map { round(Double($0), places: 3) },
                      words: wordsInTurn[j], wouldDrop: false, voice: number[t.speaker] ?? 0)
        }
        func abstain(_ why: Abstain) -> Decision {
            Decision(keep: [Bool](repeating: true, count: spans.count), abstained: why, turns: scored, voices: order.count, dropped: 0)
        }
        guard order.count >= 2 else { return abstain(.fewVoices) }
        let mine = Set(order.filter { v in scores[v].map { $0 >= threshold } ?? false })
        guard !mine.isEmpty else { return abstain(.noMatch) }
        guard mine.count < order.count else { return abstain(.onlyYou) }

        let keep = ownerTurn.map { j in j.map { mine.contains(turns[$0].speaker) } ?? true }
        let dropped = keep.filter { !$0 }.count
        guard dropped > 0 else { return abstain(.nothingToDrop) }
        guard dropped < spans.count else { return abstain(.nothingLeft) }
        for j in scored.indices where !mine.contains(turns[j].speaker) && scored[j].words > 0 { scored[j].wouldDrop = true }
        return Decision(keep: keep, abstained: nil, turns: scored, voices: order.count, dropped: dropped)
    }

    static func round(_ v: Double, places: Int) -> Double {
        guard v.isFinite else { return 0 }
        let m = pow(10.0, Double(places))
        return (v * m).rounded() / m
    }
}

/// One dictation's decision, as numbers: what the filter did (the setting on) or would have done (shadow mode, the
/// setting off). Kept on this device only, beside the voice profile, and deleted with it. Never a word or any audio.
struct VoiceShadowRecord: Codable, Equatable, Sendable {
    var date: Date
    /// The dictation's length in seconds.
    var clipSeconds: Double
    /// Seconds inside the diarizer's turns; nil when the voices weren't told apart.
    var voicedSeconds: Double?
    var voices: Int
    var turns: [VoiceGate.TurnScore]
    var abstained: VoiceGate.Abstain?
    /// The threshold in force.
    var threshold: Double
    /// True when "Only keep my voice" was on and this was the real decision; false for shadow mode.
    var filterOn: Bool
    /// Words (or lines, when `byWord` is false) the decision covered, and how many it dropped or would have.
    var words: Int
    var dropped: Int
    var byWord: Bool
    /// The kind of input ("Built-in", "Bluetooth", "USB") and its rate, when known. Never a device's name.
    var input: String?
    var inputRate: Int?
}

/// When the iPhone's dictation runs Only keep my voice. The keyboard is waiting for the words, so the filter gets a
/// time limit, and anything it can't do in time keeps every word.
enum PhoneVoiceFilterRules {
    /// Longer dictations keep every word: finding the voices in them takes longer than the keyboard should wait.
    static let maxClipSeconds: Double = 120
    /// The longest the keyboard waits for the filter.
    static let budgetSeconds: Double = 3

    /// Why the filter doesn't run for a dictation, or nil when it does.
    enum Skip: String, Sendable, CaseIterable { case off, noModels, tooLong }

    /// It runs when the setting is on with a voice profile, the speaker models are already on the iPhone (a
    /// dictation never downloads them), and the dictation isn't long.
    static func skip(on: Bool, modelsReady: Bool, clipSeconds: Double) -> Skip? {
        if !on { return .off }
        if !modelsReady { return .noModels }
        if clipSeconds > maxClipSeconds { return .tooLong }
        return nil
    }
}

enum VoiceShadowRules {
    /// The kill switch (no setting on screen): `defaults write … voice.shadowScoring -bool NO` turns the records off.
    static let enabledKey = "voice.shadowScoring"
    static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

    /// Dictations kept, newest last.
    static let limit = 500
    /// Turns kept per dictation (a long dictation's first turns).
    static let turnLimit = 200
    /// Shadow mode skips longer dictations: its scoring runs after the paste, and shouldn't still be running when the
    /// next dictation is transcribed.
    static let maxClipSeconds: Double = 120
    /// Seconds after the paste before shadow scoring starts, so a dictation that follows at once goes first.
    static let delayAfterPaste: Double = 1.5

    /// Why shadow scoring doesn't run for a dictation, or nil when it does.
    enum Skip: String, Sendable, CaseIterable { case off, notEnrolled, filterOn, unsupported, tooLong, lowPower, busy }

    /// Shadow mode runs when it's allowed (the kill switch), you have a voice profile, the real filter is off (when
    /// it's on, the real decision is recorded instead), the device can tell voices apart, the dictation isn't long,
    /// the device isn't saving power, and no other dictation is being heard or written.
    static func skip(enabled: Bool, enrolled: Bool, filterOn: Bool, supported: Bool, clipSeconds: Double, lowPower: Bool, busy: Bool) -> Skip? {
        if !enabled { return .off }
        if !enrolled { return .notEnrolled }
        if filterOn { return .filterOn }
        if !supported { return .unsupported }
        if clipSeconds > maxClipSeconds { return .tooLong }
        if lowPower { return .lowPower }
        if busy { return .busy }
        return nil
    }

    /// The record of one decision.
    static func record(_ d: VoiceGate.Decision, date: Date, clipSeconds: Double, threshold: Float, filterOn: Bool, byWord: Bool,
                       input: String?, inputRate: Int?) -> VoiceShadowRecord {
        let diarized = d.abstained != .tooShort && d.abstained != .failed
        return VoiceShadowRecord(date: date, clipSeconds: VoiceGate.round(clipSeconds, places: 2),
                                 voicedSeconds: diarized ? VoiceGate.round(d.turns.reduce(0) { $0 + $1.seconds }, places: 2) : nil,
                                 voices: d.voices, turns: Array(d.turns.prefix(turnLimit)), abstained: d.abstained,
                                 threshold: VoiceGate.round(Double(threshold), places: 3), filterOn: filterOn, words: d.keep.count,
                                 dropped: d.dropped, byWord: byWord, input: input, inputRate: inputRate)
    }

    /// The stored list with one more record: the newest `limit`, oldest first.
    static func appending(_ r: VoiceShadowRecord, to list: [VoiceShadowRecord], limit: Int = VoiceShadowRules.limit) -> [VoiceShadowRecord] {
        Array((list + [r]).suffix(max(0, limit)))
    }

    /// The log's line, counts only: "voice filter (shadow): 3 turns, 1 would drop (4 of 14 words)", or
    /// "voice filter (shadow): 1 turn, kept every word (fewer than two voices), 14 words".
    static func summary(_ r: VoiceShadowRecord) -> String {
        let head = "voice filter\(r.filterOn ? "" : " (shadow)"): \(r.turns.count) turn\(r.turns.count == 1 ? "" : "s")"
        let unit = r.byWord ? "word" : "line"
        if let why = r.abstained { return "\(head), kept every \(unit) (\(why.phrase)), \(r.words) \(unit)\(r.words == 1 ? "" : "s")" }
        let turns = r.turns.filter(\.wouldDrop).count
        return "\(head), \(turns) \(r.filterOn ? "dropped" : "would drop") (\(r.dropped) of \(r.words) \(unit)s)"
    }

    // MARK: Tuning

    /// How long a turn is, for tuning: a voice's score is less sure on a short turn.
    enum Bucket: String, CaseIterable, Sendable {
        case under1, from1To2, from2To3, from3To5, over5

        var title: String {
            switch self {
            case .under1: return "under 1 s"
            case .from1To2: return "1–2 s"
            case .from2To3: return "2–3 s"
            case .from3To5: return "3–5 s"
            case .over5: return "over 5 s"
            }
        }
    }

    /// Each bucket starts at its lower bound: 1.0 s is "1–2 s", 5.0 s is "over 5 s".
    static func bucket(_ seconds: Double) -> Bucket {
        if seconds < 1 { return .under1 }
        if seconds < 2 { return .from1To2 }
        if seconds < 3 { return .from2To3 }
        if seconds < 5 { return .from3To5 }
        return .over5
    }

    /// The thresholds a report compares unless told otherwise: the one in force (0.5) and one step either side.
    static let candidateThresholds: [Double] = [0.4, 0.5, 0.6]

    struct ThresholdReport: Equatable, Sendable {
        /// Turns and their words at or above a threshold (kept as yours) and below it (someone else's).
        struct Cell: Equatable, Sendable {
            var threshold: Double
            var turnsAtOrAbove = 0
            var turnsBelow = 0
            var wordsAtOrAbove = 0
            var wordsBelow = 0
        }
        struct Row: Equatable, Sendable {
            var bucket: Bucket
            /// Turns with a score, and turns without one (left out of the cells).
            var turns = 0
            var unscored = 0
            var cells: [Cell]
        }
        /// One row per bucket, in `Bucket.allCases` order.
        var rows: [Row]
        var dictations: Int
    }

    /// Counts, by turn length, of scores at or above and below each candidate threshold, over every stored turn.
    /// It says how the scores fall, not which are right: that needs dictations whose speakers are known.
    static func thresholdReport(_ records: [VoiceShadowRecord], thresholds: [Double] = candidateThresholds) -> ThresholdReport {
        var rows = Bucket.allCases.map { ThresholdReport.Row(bucket: $0, cells: thresholds.map { ThresholdReport.Cell(threshold: $0) }) }
        for r in records {
            for t in r.turns {
                guard let i = Bucket.allCases.firstIndex(of: bucket(t.seconds)) else { continue }
                guard let score = t.score else { rows[i].unscored += 1; continue }
                rows[i].turns += 1
                for c in rows[i].cells.indices {
                    if score >= rows[i].cells[c].threshold { rows[i].cells[c].turnsAtOrAbove += 1; rows[i].cells[c].wordsAtOrAbove += t.words }
                    else { rows[i].cells[c].turnsBelow += 1; rows[i].cells[c].wordsBelow += t.words }
                }
            }
        }
        return ThresholdReport(rows: rows, dictations: records.count)
    }
}

/// The rules above, checked by the Linux tests (`mac/tools/test-voice-shadow.sh`) and by the Mac's self-test. `check`
/// logs PASS or FAIL. Made-up times and scores; no audio and no words.
enum VoiceShadowChecks {
    static func run(_ check: (String, Bool) -> Void) {
        typealias G = VoiceGate
        typealias R = VoiceShadowRules
        func spans(_ times: [Double]) -> [G.Span] { times.map { G.Span(start: $0, end: $0 + 0.3) } }
        // You talk from 0 to 4 s and again from 7 to 9 s; someone else from 4 to 7 s.
        let turns = [G.Turn(speaker: "A", start: 0, end: 4), G.Turn(speaker: "B", start: 4, end: 7), G.Turn(speaker: "A", start: 7, end: 9)]
        let words = spans([0.2, 1, 2, 3, 4.2, 5, 6, 7.2, 8])
        let scores: [String: Float] = ["A": 0.72, "B": 0.21]

        let d = G.decide(spans: words, turns: turns, scores: scores, threshold: 0.5)
        check("gate: words in another voice's turn go, yours stay",
              d.abstained == nil && d.keep == [true, true, true, true, false, false, false, true, true] && d.dropped == 3 && d.voices == 2)
        check("gate: each turn has its length, its voice's score, its words, and whether it goes",
              d.turns == [G.TurnScore(seconds: 4, score: 0.72, words: 4, wouldDrop: false, voice: 0),
                          G.TurnScore(seconds: 3, score: 0.21, words: 3, wouldDrop: true, voice: 1),
                          G.TurnScore(seconds: 2, score: 0.72, words: 2, wouldDrop: false, voice: 0)])
        check("gate: a score exactly at the threshold is yours",
              G.decide(spans: words, turns: turns, scores: ["A": 0.5, "B": 0.49], threshold: 0.5).dropped == 3)
        check("gate: a word in no turn stays",
              G.decide(spans: spans([1, 5, 20]), turns: turns, scores: scores, threshold: 0.5).keep == [true, false, true])
        check("gate: a word across two turns goes to the voice that covers more of it",
              G.decide(spans: [G.Span(start: 1, end: 1.3), G.Span(start: 3.9, end: 4.5), G.Span(start: 3.5, end: 4.1)], turns: turns, scores: scores, threshold: 0.5).keep
              == [true, false, true])
        check("gate: a word with no length still counts where it starts",
              G.decide(spans: [G.Span(start: 1, end: 1), G.Span(start: 5, end: 5)], turns: turns, scores: scores, threshold: 0.5).keep == [true, false])

        let one = G.decide(spans: words, turns: [G.Turn(speaker: "A", start: 0, end: 9)], scores: ["A": 0.3], threshold: 0.5)
        check("gate: one voice keeps every word, and its score is still recorded",
              one.abstained == .fewVoices && one.keep.allSatisfy { $0 } && one.dropped == 0 && one.turns.first?.score == 0.3
              && one.turns.first?.words == 9 && one.turns.first?.wouldDrop == false)
        check("gate: no voices at all keeps every word", G.decide(spans: words, turns: [], scores: [:], threshold: 0.5).abstained == .fewVoices)
        let noMatch = G.decide(spans: words, turns: turns, scores: ["A": 0.4, "B": 0.2], threshold: 0.5)
        check("gate: no voice like yours keeps every word", noMatch.abstained == .noMatch && noMatch.keep.allSatisfy { $0 } && noMatch.turns.allSatisfy { !$0.wouldDrop })
        check("gate: every voice like yours keeps every word",
              G.decide(spans: words, turns: turns, scores: ["A": 0.8, "B": 0.6], threshold: 0.5).abstained == .onlyYou)
        check("gate: a voice with no score counts as someone else's",
              G.decide(spans: words, turns: turns, scores: ["A": 0.8], threshold: 0.5).dropped == 3
              && G.decide(spans: words, turns: turns, scores: ["A": 0.8], threshold: 0.5).turns[1].score == nil)
        check("gate: nothing in the other voice's turn keeps every word",
              G.decide(spans: spans([1, 2, 8]), turns: turns, scores: scores, threshold: 0.5).abstained == .nothingToDrop)
        let allGone = G.decide(spans: spans([4.2, 5, 6]), turns: turns, scores: scores, threshold: 0.5)
        check("gate: it never drops everything", allGone.abstained == .nothingLeft && allGone.keep == [true, true, true] && allGone.dropped == 0)
        check("gate: a lower threshold keeps more voices as yours",
              G.decide(spans: words, turns: turns, scores: ["A": 0.72, "B": 0.45], threshold: 0.4).abstained == .onlyYou
              && G.decide(spans: words, turns: turns, scores: ["A": 0.72, "B": 0.45], threshold: 0.5).dropped == 3)
        check("gate: too short or failed keeps every word with no turns",
              G.Decision.abstaining(.tooShort, spans: 3) == G.Decision(keep: [true, true, true], abstained: .tooShort, turns: [], voices: 0, dropped: 0))

        // The record and the log line.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let r = R.record(d, date: date, clipSeconds: 9.004, threshold: 0.5, filterOn: false, byWord: true, input: "Built-in", inputRate: 48_000)
        check("record: numbers only, with the lengths, the threshold, and the kind of input",
              r.clipSeconds == 9 && r.voicedSeconds == 9 && r.voices == 2 && r.turns == d.turns && r.abstained == nil && r.threshold == 0.5
              && !r.filterOn && r.words == 9 && r.dropped == 3 && r.byWord && r.input == "Built-in" && r.inputRate == 48_000)
        check("record: the log line has counts only", R.summary(r) == "voice filter (shadow): 3 turns, 1 would drop (3 of 9 words)")
        var real = r; real.filterOn = true
        check("record: the real filter's line says dropped", R.summary(real) == "voice filter: 3 turns, 1 dropped (3 of 9 words)")
        let quiet = R.record(one, date: date, clipSeconds: 9, threshold: 0.5, filterOn: false, byWord: true, input: nil, inputRate: nil)
        check("record: an abstention says why", R.summary(quiet) == "voice filter (shadow): 1 turn, kept every word (fewer than two voices), 9 words"
              && quiet.abstained == .fewVoices && quiet.voicedSeconds == 9)
        let short = R.record(.abstaining(.tooShort, spans: 2), date: date, clipSeconds: 1.2, threshold: 0.5, filterOn: true, byWord: false, input: nil, inputRate: nil)
        check("record: a dictation too short to score has no voiced time",
              short.voicedSeconds == nil && short.turns.isEmpty && R.summary(short) == "voice filter: 0 turns, kept every line (under 2 s), 2 lines")
        let encoded = (try? JSONEncoder().encode([r, quiet, short])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let keys = Set(encoded.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        check("record: what's stored is these numbers and nothing else (no text, no names)",
              keys == ["date", "clipSeconds", "voicedSeconds", "voices", "turns", "seconds", "score", "words", "wouldDrop", "voice", "threshold",
                       "filterOn", "dropped", "byWord", "input", "inputRate", "abstained", "fewVoices", "tooShort", "Built-in"])
        check("record: it reads back the same",
              (try? JSONDecoder().decode([VoiceShadowRecord].self, from: Data(encoded.utf8))) == [r, quiet, short])
        let long = G.Decision(keep: [], abstained: .fewVoices, turns: [G.TurnScore](repeating: d.turns[0], count: R.turnLimit + 50), voices: 1, dropped: 0)
        check("record: a long dictation keeps its first \(R.turnLimit) turns",
              R.record(long, date: date, clipSeconds: 600, threshold: 0.5, filterOn: true, byWord: true, input: nil, inputRate: nil).turns.count == R.turnLimit)

        // The stored list.
        func numbered(_ n: Int) -> VoiceShadowRecord { var x = r; x.words = n; return x }
        var list: [VoiceShadowRecord] = []
        for n in 0..<(R.limit + 25) { list = R.appending(numbered(n), to: list) }
        check("store: the newest \(R.limit) dictations are kept, oldest first",
              list.count == R.limit && list.first?.words == 25 && list.last?.words == R.limit + 24)
        check("store: a smaller cap trims a list that's already over it",
              R.appending(numbered(9), to: [numbered(1), numbered(2), numbered(3)], limit: 2).map(\.words) == [3, 9]
              && R.appending(numbered(9), to: [], limit: 0).isEmpty)

        // When shadow mode runs.
        func skip(enabled: Bool = true, enrolled: Bool = true, filterOn: Bool = false, supported: Bool = true, clip: Double = 10,
                  lowPower: Bool = false, busy: Bool = false) -> R.Skip? {
            R.skip(enabled: enabled, enrolled: enrolled, filterOn: filterOn, supported: supported, clipSeconds: clip, lowPower: lowPower, busy: busy)
        }
        check("shadow: runs with a voice profile and the filter off", skip() == nil)
        check("shadow: off with the kill switch, without a profile, and while the real filter is on",
              skip(enabled: false) == .off && skip(enrolled: false) == .notEnrolled && skip(filterOn: true) == .filterOn)
        check("shadow: skips long dictations, a device saving power, and a moment when another dictation is under way",
              skip(clip: R.maxClipSeconds + 1) == .tooLong && skip(clip: R.maxClipSeconds) == nil && skip(lowPower: true) == .lowPower
              && skip(busy: true) == .busy && skip(supported: false) == .unsupported)
        let suite = "voice-shadow-checks-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            let unset = R.enabled(defaults)
            defaults.set(false, forKey: R.enabledKey)
            let off = !R.enabled(defaults)
            defaults.removePersistentDomain(forName: suite)
            check("shadow: on unless turned off", unset && off)
        }

        // Tuning.
        check("buckets: each starts at its lower bound",
              [0, 0.99, 1, 1.99, 2, 2.99, 3, 4.99, 5, 60].map(R.bucket)
              == [.under1, .under1, .from1To2, .from1To2, .from2To3, .from2To3, .from3To5, .from3To5, .over5, .over5])
        func turn(_ seconds: Double, _ score: Double?, _ words: Int) -> G.TurnScore { G.TurnScore(seconds: seconds, score: score, words: words, wouldDrop: false, voice: 0) }
        var a = r; a.turns = [turn(0.5, 0.45, 1), turn(1.5, 0.55, 3), turn(1.2, 0.35, 2), turn(4, 0.62, 9), turn(4.5, nil, 2)]
        var b = r; b.turns = [turn(6, 0.5, 12), turn(0.8, 0.6, 2)]
        let report = R.thresholdReport([a, b])
        func cell(_ bucket: R.Bucket, _ threshold: Double) -> R.ThresholdReport.Cell? {
            report.rows.first { $0.bucket == bucket }?.cells.first { $0.threshold == threshold }
        }
        check("report: one row per bucket and one cell per threshold",
              report.rows.map(\.bucket) == R.Bucket.allCases && report.rows.allSatisfy { $0.cells.map(\.threshold) == [0.4, 0.5, 0.6] } && report.dictations == 2)
        check("report: turns and words at or above and below each threshold, by turn length",
              cell(.under1, 0.4) == .init(threshold: 0.4, turnsAtOrAbove: 2, turnsBelow: 0, wordsAtOrAbove: 3, wordsBelow: 0)
              && cell(.under1, 0.5) == .init(threshold: 0.5, turnsAtOrAbove: 1, turnsBelow: 1, wordsAtOrAbove: 2, wordsBelow: 1)
              && cell(.from1To2, 0.5) == .init(threshold: 0.5, turnsAtOrAbove: 1, turnsBelow: 1, wordsAtOrAbove: 3, wordsBelow: 2)
              && cell(.from3To5, 0.6) == .init(threshold: 0.6, turnsAtOrAbove: 1, turnsBelow: 0, wordsAtOrAbove: 9, wordsBelow: 0)
              && cell(.over5, 0.5) == .init(threshold: 0.5, turnsAtOrAbove: 1, turnsBelow: 0, wordsAtOrAbove: 12, wordsBelow: 0)
              && cell(.over5, 0.6) == .init(threshold: 0.6, turnsAtOrAbove: 0, turnsBelow: 1, wordsAtOrAbove: 0, wordsBelow: 12))
        check("report: a turn with no score is counted apart, and an empty bucket is all zeros",
              report.rows.first { $0.bucket == .from3To5 }?.unscored == 1 && report.rows.first { $0.bucket == .from3To5 }?.turns == 1
              && report.rows.first { $0.bucket == .from2To3 }?.turns == 0 && cell(.from2To3, 0.5) == .init(threshold: 0.5))
        check("report: no records is five empty rows", R.thresholdReport([]).rows.count == 5 && R.thresholdReport([]).dictations == 0)
    }
}
