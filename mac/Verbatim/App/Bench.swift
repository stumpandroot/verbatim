import Foundation
import AppKit
import AVFoundation

/// Accuracy and latency bench (Mac only).
///
/// Launch with `-bench <clips dir> -benchOut <report.json>`. Verbatim then runs every WAV in the folder through
/// the dictation pipeline without the microphone or the hotkey: the loudness gate, the engine call dictation
/// makes (`FluidEngine.transcribeBoosted` with the Dictionary, plus a plain `transcribe` for comparison),
/// `DictionaryApplier`, and `FlowCleanup` at each level. It scores each step against the clip's reference,
/// writes a JSON report and a Markdown summary next to it, and quits. CI runs it on every build; see
/// mac/Bench/README.md for the options, the metrics, and how to add your own clips.
///
/// Optional arguments: `-benchModels v3,ultra,v2` (model ids from `Engines.options`; "whisper/base" also works),
/// `-benchCleanup none,light,medium`, `-benchBoost 0`, `-benchMinutes 20` (overall cap), `-benchClipTimeout 90`,
/// `-benchLoadTimeout 600`, `-benchDownload 0` (only models already on disk), `-benchLabel "build 123"`.
enum Bench {
    struct Options {
        var dir: URL
        var out: URL
        var models: [String]
        var boost: Bool
        var levels: [CleanupLevel]
        var capSeconds: Double
        var clipTimeout: Double
        var loadTimeout: Double
        var allowDownload: Bool
        var label: String?
    }

    /// Parsed once from the launch arguments; nil on a normal launch.
    static let options: Options? = parse(CommandLine.arguments)
    static var isRequested: Bool { options != nil }

    static func parse(_ args: [String]) -> Options? {
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL }
        func list(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard let dirArg = value("-bench") else { return nil }
        let dir = path(dirArg)
        var models: [String] = []
        for m in value("-benchModels").map(list) ?? [QualityPreset.balanced.config.1, "ultra", "v2"] where !models.contains(m) {
            models.append(m)
        }
        let levels = value("-benchCleanup").map { list($0).compactMap { CleanupLevel(stored: $0) } } ?? CleanupLevel.allCases
        return Options(
            dir: dir,
            out: value("-benchOut").map(path) ?? dir.appendingPathComponent("bench.json"),
            models: models,
            boost: value("-benchBoost") != "0",
            levels: levels,
            capSeconds: max(60, (value("-benchMinutes").flatMap(Double.init) ?? 20) * 60),
            clipTimeout: value("-benchClipTimeout").flatMap(Double.init) ?? 90,
            loadTimeout: value("-benchLoadTimeout").flatMap(Double.init) ?? 600,
            allowDownload: value("-benchDownload") != "0",
            label: value("-benchLabel"))
    }

    /// Starts the bench once. Safe to call from any thread; does nothing on a normal launch.
    static func start() { _ = launched }

    private static let launched: Bool = {
        guard let o = Bench.options else { return false }
        Log.note("BENCH requested dir=\(o.dir.path) out=\(o.out.path) models=\(o.models.joined(separator: ","))")
        let snap = BenchSnapshot(out: o.out, report: Bench.initialReport(o))
        snap.write()
        // Hard stop: whatever happens below, the app exits after the cap with the report it has so far.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + o.capSeconds) {
            if snap.write(status: "timeout", final: true) { Log.note("BENCH timeout after \(Int(o.capSeconds)) s; partial report written") }
            Thread.sleep(forTimeInterval: 1)
            exit(2)
        }
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)   // let the app finish launching
            let status = await Bench.run(o, snap)
            snap.write(status: status, final: true)
            Log.note("BENCH \(status) report=\(o.out.path)")
            try? await Task.sleep(nanoseconds: 500_000_000)     // let the log line land
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(0) }   // if terminate is held up
            await MainActor.run { NSApp.terminate(nil) }
        }
        return true
    }()

    // MARK: Suite

    struct Clip {
        var id: String
        var url: URL
        var reference: String
        var expected: String
        var category: String
        var terms: [String]
        var mustContain: [String]
        var mustNotContain: [String]
    }

    struct TermSpec: Codable {
        var text: String
        var heardAs: [String]?
    }

    private struct ClipSpec: Decodable {
        var id: String
        var text: String?
        var category: String?
        var terms: [String]?
        var expected: String?
        var cleanupMustContain: [String]?
        var cleanupMustNotContain: [String]?
    }

    private struct SuiteFile: Decodable {
        var dictionary: [TermSpec]?
        var clips: [ClipSpec]?
        var voices: [String: String]?
    }

    struct Suite {
        var clips: [Clip] = []
        var dictionary: [TermSpec] = []
        var missing: [String] = []
        var skipped: [String] = []
        var voices: [String: String]?
    }

    /// Reads `<dir>/clips.json` (optional) and every `<id>.wav` in the folder. A WAV without a clips.json entry
    /// needs `<id>.txt` (its reference); `<id>.terms` and `<dir>/dictionary.txt` are optional.
    static func loadSuite(_ dir: URL) throws -> Suite {
        let fm = FileManager.default
        var suite = Suite()
        var file = SuiteFile()
        let json = dir.appendingPathComponent("clips.json")
        if fm.fileExists(atPath: json.path) { file = try JSONDecoder().decode(SuiteFile.self, from: Data(contentsOf: json)) }
        suite.voices = file.voices
        suite.dictionary = file.dictionary ?? []

        // dictionary.txt: one entry per line, "Preferred" or "Preferred | heard as, another heard as".
        if let txt = try? String(contentsOf: dir.appendingPathComponent("dictionary.txt"), encoding: .utf8) {
            for line in txt.components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: "|")
                let preferred = parts[0].trimmingCharacters(in: .whitespaces)
                guard !preferred.isEmpty, !preferred.hasPrefix("#") else { continue }
                let heard = parts.count > 1 ? parts[1].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
                suite.dictionary.append(TermSpec(text: preferred, heardAs: heard))
            }
        }

        let wavs = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var byId: [String: URL] = [:]
        for w in wavs { byId[w.deletingPathExtension().lastPathComponent] = w }
        var used = Set<String>()

        func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

        for spec in file.clips ?? [] {
            guard let url = byId[spec.id] else { suite.missing.append(spec.id); continue }
            used.insert(spec.id)
            let ref = spec.text ?? read(spec.id + ".txt") ?? ""
            suite.clips.append(Clip(id: spec.id, url: url, reference: ref, expected: spec.expected ?? ref,
                                    category: spec.category ?? "uncategorized", terms: spec.terms ?? [],
                                    mustContain: spec.cleanupMustContain ?? [], mustNotContain: spec.cleanupMustNotContain ?? []))
        }
        for w in wavs {
            let id = w.deletingPathExtension().lastPathComponent
            guard !used.contains(id) else { continue }
            guard let ref = read(id + ".txt") else { suite.skipped.append(id + " (no .txt reference)"); continue }
            let terms = (read(id + ".terms") ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            suite.clips.append(Clip(id: id, url: w, reference: r, expected: r, category: "private", terms: terms,
                                    mustContain: [], mustNotContain: []))
        }
        // Every spoken term is in the Dictionary, as it would be for a real user.
        for t in suite.clips.flatMap(\.terms) where !suite.dictionary.contains(where: { $0.text.lowercased() == t.lowercased() }) {
            suite.dictionary.append(TermSpec(text: t, heardAs: []))
        }
        return suite
    }

    // MARK: Run

    private static func run(_ o: Options, _ snap: BenchSnapshot) async -> String {
        let suite: Suite
        do { suite = try loadSuite(o.dir) } catch {
            snap.update { $0.notes.append("Couldn't read the clips folder: \(error)") }
            return "error"
        }
        guard !suite.clips.isEmpty else {
            snap.update { $0.notes.append("No clips found in \(o.dir.path)") }
            return "error"
        }
        let start = Date()
        let softDeadline = start.addingTimeInterval(o.capSeconds - min(90, o.capSeconds * 0.1))
        let analyses = suite.clips.map { analyze($0.url) }
        let entries = suite.dictionary.map { DictionaryEntry(preferred: $0.text, heardAs: $0.heardAs ?? [], learnedFrom: "Bench") }
        let vocabulary = suite.dictionary.map(\.text)
        let boostTerms: [(text: String, aliases: [String])] = o.boost ? suite.dictionary.map { (text: $0.text, aliases: $0.heardAs ?? []) } : []
        let cleanupAvailable = FlowCleanup.available
        snap.update {
            $0.clipCount = suite.clips.count
            $0.missing = suite.missing
            $0.skipped = suite.skipped
            $0.voices = suite.voices
            $0.settings.dictionary = vocabulary
        }
        Log.note("BENCH \(suite.clips.count) clips, \(vocabulary.count) Dictionary terms, cleanup \(cleanupAvailable ? "available" : "unavailable")")
        let warm = suite.clips.first { !$0.reference.isEmpty } ?? suite.clips[0]
        var partial = false

        for spec in o.models {
            guard let opt = resolve(spec) else {
                snap.update { $0.models.append(ModelRun(id: spec, name: spec, status: "skipped", error: "unknown model id (see Engines.options)")) }
                continue
            }
            var mr = ModelRun(id: opt.id, name: opt.name, status: "running")
            if Date() > softDeadline {
                mr.status = "skipped"; mr.error = "time budget used up"; partial = true
                snap.update { $0.models.append(mr) }
                continue
            }
            if !o.allowDownload, opt.engine == "fluid",
               !FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent("parakeet-\(opt.model)").path) {
                mr.status = "skipped"; mr.error = "not installed (-benchDownload 0)"
                snap.update { $0.models.append(mr) }
                continue
            }
            let index = snap.appendModel(mr)
            let engine = Engines.engine(for: opt.engine)
            let model = opt.model

            // Load: download (first run), compile, and one throwaway transcription.
            Log.note("BENCH \(opt.id) loading")
            let t0 = Date()
            do {
                let url = warm.url
                _ = try await timed(o.loadTimeout) { try await engine.transcribe(url: url, model: model, progress: { _ in }) }
                mr.loadSeconds = Date().timeIntervalSince(t0)
            } catch {
                mr.status = "failed"; mr.error = "load: \(error)"
                snap.update { $0.models[index] = mr }
                snap.write()
                Log.note("BENCH \(opt.id) load failed: \(error)")
                continue
            }
            let boosting = opt.engine == "fluid" && !boostTerms.isEmpty
            if boosting {
                let t1 = Date()
                do {
                    let url = warm.url
                    _ = try await timed(o.loadTimeout) { try await FluidEngine.shared.transcribeBoosted(url: url, model: model, terms: boostTerms) }
                    mr.boostWarmSeconds = Date().timeIntervalSince(t1)
                } catch {
                    mr.notes.append("vocabulary boost warm-up failed: \(error)")
                }
            }
            Log.note("BENCH \(opt.id) loaded in \(String(format: "%.1f", mr.loadSeconds ?? 0)) s")
            snap.update { $0.models[index] = mr }

            var failuresInARow = 0
            for (i, clip) in suite.clips.enumerated() {
                if Date() > softDeadline { mr.status = "partial"; partial = true; mr.notes.append("stopped at the time budget"); break }
                let a = analyses[i]
                var c = ClipResult(id: clip.id, category: clip.category, reference: clip.reference,
                                   expected: clip.expected == clip.reference ? nil : clip.expected,
                                   audioSeconds: a.seconds, gate: Gate(skip: a.skip, reason: a.reason, loudness: a.loudness))
                let url = clip.url
                var plainSegments: [Segment]?
                var boostedSegments: [Segment]?

                // 1. The plain engine call (what file transcription and dictation without a Dictionary use).
                do {
                    let t = Date()
                    let r = try await timed(o.clipTimeout) { try await engine.transcribe(url: url, model: model, progress: { _ in }) }
                    plainSegments = r.segments
                    let text = join(r.segments)
                    c.engine = Output(seconds: Date().timeIntervalSince(t), text: text, score: score(text, clip, reference: clip.reference, vocabulary: vocabulary))
                } catch {
                    c.engine = Output(error: "\(error)")
                }
                // 2. Dictation's call when the Dictionary has words and boosting is on (the default).
                if boosting {
                    do {
                        let t = Date()
                        let r = try await timed(o.clipTimeout) { try await FluidEngine.shared.transcribeBoosted(url: url, model: model, terms: boostTerms) }
                        boostedSegments = r.segments
                        let text = join(r.segments)
                        c.boosted = Output(seconds: Date().timeIntervalSince(t), text: text, score: score(text, clip, reference: clip.reference, vocabulary: vocabulary))
                    } catch {
                        c.boosted = Output(error: "\(error)")
                    }
                }
                // 3. Dictionary replacements and the loudness gate: the text dictation would hand to cleanup.
                let chosen = boosting ? (boostedSegments, c.boosted?.seconds) : (plainSegments, c.engine?.seconds)
                if var segs = chosen.0 {
                    failuresInARow = 0
                    let t = Date()
                    let fixes = DictionaryApplier.apply(entries, to: &segs)
                    let raw = a.skip ? "" : join(segs)
                    let seconds = (chosen.1 ?? 0) + Date().timeIntervalSince(t)
                    c.dictionaryFixes = fixes.count
                    c.dictation = Output(seconds: seconds, text: raw, score: score(raw, clip, reference: clip.reference, vocabulary: vocabulary))

                    // 4. Cleanup at each level.
                    let category: AppCategory = clip.category == "email" ? .email : .other
                    let style: FlowStyle = category == .email ? .formal : .casual   // FlowSettings' defaults
                    for level in o.levels {
                        var out = CleanupOutput(level: level.rawValue, status: "")
                        if a.skip { out.status = "gated"; c.cleanup.append(out); continue }
                        if level != .none && !cleanupAvailable { out.status = "unavailable"; c.cleanup.append(out); continue }
                        let req = (raw: raw, level: level, style: style, category: category)
                        let tc = Date()
                        do {
                            let r = try await timed(30) {
                                await FlowCleanup.run(.init(raw: req.raw, level: req.level, style: req.style, category: req.category,
                                                            context: nil, vocabulary: vocabulary, useContext: false))
                            }
                            out.seconds = Date().timeIntervalSince(tc)
                            out.text = r.text
                            out.note = r.note
                            out.status = level == .none ? "literal" : (r.cleaned ? "cleaned" : (r.note == nil ? "unchanged" : "fallback"))
                            var s = score(r.text, clip, reference: clip.expected, vocabulary: vocabulary)
                            if level != .none, !clip.mustContain.isEmpty || !clip.mustNotContain.isEmpty {
                                s.checksPassed = checks(r.text, mustContain: clip.mustContain, mustNotContain: clip.mustNotContain)
                            }
                            out.score = s
                        } catch {
                            out.status = "error"; out.note = "\(error)"
                        }
                        c.cleanup.append(out)
                    }
                } else {
                    failuresInARow += 1
                }

                mr.clips.append(c)
                mr.overall = aggregate(mr.clips)
                mr.categories = Dictionary(grouping: mr.clips, by: \.category).mapValues(aggregate)
                snap.update { $0.models[index] = mr }
                snap.write()
                let werText = c.dictation?.score?.wer.map { String(format: "%.3f", $0) } ?? "-"
                let msText = c.dictation?.seconds.map { String(Int($0 * 1000)) } ?? "-"
                let errText = c.dictation == nil ? " error=" + (c.engine?.error ?? c.boosted?.error ?? "?") : ""
                Log.note("BENCH \(opt.id) \(clip.id) wer=\(werText) ms=\(msText)\(errText)")
                if failuresInARow >= 3 { mr.status = "failed"; mr.error = "3 clips in a row failed"; break }
            }
            if mr.status == "running" { mr.status = "ok" }
            snap.update { $0.models[index] = mr }
            snap.write(markdown: true)
            let modelWER = mr.overall?.werDictation.map { String(format: "%.3f", $0) } ?? "-"
            Log.note("BENCH \(opt.id) \(mr.status) wer=\(modelWER)")
        }
        return partial ? "partial" : "done"
    }

    static func resolve(_ spec: String) -> EngineOption? {
        let parts = spec.split(separator: "/").map(String.init)
        let engine = parts.count == 2 ? parts[0] : "fluid"
        let model = parts.count == 2 ? parts[1] : spec
        return Engines.options.first { $0.engine == engine && $0.model == model }
    }

    private static func join(_ segs: [Segment]) -> String {
        segs.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Audio

    struct Analysis { var seconds: Double; var loudness: Double; var skip: Bool; var reason: String? }

    /// Duration plus a replica of dictation's gate: under 0.4 s, or the loudest 10% of a 120-point envelope of
    /// Recorder-style levels averaging below 0.05, and dictation never runs the models.
    static func analyze(_ url: URL) -> Analysis {
        guard let f = try? AVAudioFile(forReading: url) else { return Analysis(seconds: 0, loudness: 0, skip: true, reason: "unreadable") }
        let format = f.processingFormat
        let seconds = Double(f.length) / format.sampleRate
        guard f.length > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else {
            return Analysis(seconds: seconds, loudness: 0, skip: true, reason: "unreadable")
        }
        // Recorder levels come from ~2,048-frame buffers at 48 kHz, two per envelope point.
        let chunk = max(1, Int(format.sampleRate * 2048 / 48_000))
        let n = Int(buf.frameLength)
        var env: [Float] = []
        var acc: Float = 0, count = 0, i = 0
        while i < n {
            let end = min(n, i + chunk)
            var sum: Float = 0
            for k in i..<end { sum += ch[k] * ch[k] }
            let rms = (sum / Float(end - i)).squareRoot()
            acc += min(1, pow(max(0, rms - 0.004) * 6, 0.5)); count += 1
            if count >= 2 { env.append(acc / Float(count)); acc = 0; count = 0 }
            i = end
        }
        let e = Waveform.resample(env, to: 120)
        let loud = e.sorted(by: >).prefix(max(1, e.count / 10))
        let level = loud.isEmpty ? 0 : Double(loud.reduce(0, +) / Float(loud.count))
        if seconds < 0.4 { return Analysis(seconds: seconds, loudness: level, skip: true, reason: "shorter than 0.4 s") }
        if !e.isEmpty, level < 0.05 { return Analysis(seconds: seconds, loudness: level, skip: true, reason: "below the loudness gate") }
        return Analysis(seconds: seconds, loudness: level, skip: false, reason: nil)
    }

    // MARK: Scoring

    static func score(_ text: String, _ clip: Clip, reference: String, vocabulary: [String]) -> Score {
        let hyp = BenchText.tokens(text)
        let ref = BenchText.tokens(reference)
        var s = Score(normalized: hyp.joined(separator: " "))
        if ref.isEmpty {
            s.falseActivation = !hyp.isEmpty
        } else {
            let e = BenchText.editCounts(hyp: hyp, ref: ref)
            s.substitutions = e.sub; s.deletions = e.del; s.insertions = e.ins; s.refWords = ref.count
            s.wer = Double(e.sub + e.del + e.ins) / Double(ref.count)
            let negRef = ref.filter(BenchText.negations.contains).count
            if negRef > 0 { s.negationKept = hyp.filter(BenchText.negations.contains).count >= negRef }
            let numRef = ref.filter(BenchText.isNumber)
            if !numRef.isEmpty {
                var pool = hyp.filter(BenchText.isNumber)
                s.numbersKept = numRef.allSatisfy { n in
                    guard let k = pool.firstIndex(of: n) else { return false }
                    pool.remove(at: k); return true
                }
            }
        }
        if !clip.terms.isEmpty {
            s.nameTotal = clip.terms.count
            s.nameHits = clip.terms.filter { BenchText.occurrences(of: BenchText.tokens($0), in: hyp) > 0 }.count
            s.nameHitsCased = clip.terms.filter { text.range(of: $0) != nil }.count
        }
        s.vocabFalseInsertions = vocabulary.reduce(0) { sum, term in
            let t = BenchText.tokens(term)
            return sum + max(0, BenchText.occurrences(of: t, in: hyp) - BenchText.occurrences(of: t, in: ref))
        }
        return s
    }

    static func checks(_ text: String, mustContain: [String], mustNotContain: [String]) -> Bool {
        let hyp = BenchText.tokens(text)
        return mustContain.allSatisfy { BenchText.occurrences(of: BenchText.tokens($0), in: hyp) > 0 }
            && mustNotContain.allSatisfy { BenchText.occurrences(of: BenchText.tokens($0), in: hyp) == 0 }
    }

    static func aggregate(_ clips: [ClipResult]) -> Aggregate {
        var a = Aggregate()
        a.clips = clips.count
        a.audioSeconds = clips.reduce(0) { $0 + $1.audioSeconds }
        a.errors = clips.filter { $0.dictation == nil }.count
        func corpus(_ scores: [Score?]) -> Double? {
            let s = scores.compactMap { $0 }.filter { $0.refWords != nil }
            let words = s.reduce(0) { $0 + ($1.refWords ?? 0) }
            guard words > 0 else { return nil }
            return Double(s.reduce(0) { $0 + ($1.substitutions ?? 0) + ($1.deletions ?? 0) + ($1.insertions ?? 0) }) / Double(words)
        }
        func recall(_ scores: [Score?], cased: Bool = false) -> Double? {
            let s = scores.compactMap { $0 }.filter { ($0.nameTotal ?? 0) > 0 }
            let total = s.reduce(0) { $0 + ($1.nameTotal ?? 0) }
            guard total > 0 else { return nil }
            return Double(s.reduce(0) { $0 + ((cased ? $1.nameHitsCased : $1.nameHits) ?? 0) }) / Double(total)
        }
        func rate(_ flags: [Bool?]) -> Double? {
            let f = flags.compactMap { $0 }
            return f.isEmpty ? nil : Double(f.filter { $0 }.count) / Double(f.count)
        }
        let engine = clips.map { $0.engine?.score }
        let boosted = clips.map { $0.boosted?.score }
        let dictation = clips.map { $0.dictation?.score }
        a.werEngine = corpus(engine)
        a.werBoosted = corpus(boosted)
        a.werDictation = corpus(dictation)
        a.nameRecallEngine = recall(engine)
        a.nameRecallBoosted = recall(boosted)
        a.nameRecallDictation = recall(dictation)
        a.nameRecallDictationCased = recall(dictation, cased: true)
        a.negationKept = rate(dictation.map { $0?.negationKept })
        a.numbersKept = rate(dictation.map { $0?.numbersKept })
        a.silenceClips = clips.filter { $0.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        a.falseActivationsEngine = engine.filter { $0?.falseActivation == true }.count
        a.falseActivationsDictation = dictation.filter { $0?.falseActivation == true }.count
        a.vocabFalseInsertions = dictation.reduce(0) { $0 + ($1?.vocabFalseInsertions ?? 0) }
        a.engineMs = Stats.of(clips.compactMap { $0.engine?.seconds })
        a.dictationMs = Stats.of(clips.compactMap { $0.dictation?.seconds })
        let transcribeSeconds = clips.reduce(0.0) { $0 + ($1.engine?.seconds ?? 0) }
        let transcribedAudio = clips.filter { $0.engine?.seconds != nil }.reduce(0.0) { $0 + $1.audioSeconds }
        if transcribeSeconds > 0 { a.rtfx = transcribedAudio / transcribeSeconds }

        let levels = Set(clips.flatMap { $0.cleanup.map(\.level) })
        for level in levels {
            let outs = clips.compactMap { c in c.cleanup.first { $0.level == level } }
            let scores = outs.map(\.score)
            if let w = corpus(scores) { a.werCleanup[level] = w }
            if let r = recall(scores) { a.nameRecallCleanup[level] = r }
            if let r = rate(scores.map { $0?.negationKept }) { a.negationKeptCleanup[level] = r }
            if let r = rate(scores.map { $0?.numbersKept }) { a.numbersKeptCleanup[level] = r }
            if let r = rate(scores.map { $0?.checksPassed }) { a.cleanupChecksPassed[level] = r }
            if let st = Stats.of(outs.compactMap(\.seconds)) { a.cleanupMs[level] = st }
            a.cleanupStatus[level] = Dictionary(grouping: outs, by: \.status).mapValues(\.count)
        }
        return a
    }

    // MARK: Report

    static func initialReport(_ o: Options) -> Report {
        let info = Bundle.main.infoDictionary
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var vm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isVM: Bool? = sysctlbyname("kern.hv_vmm_present", &vm, &size, nil, 0) == 0 ? vm != 0 : nil
        return Report(
            status: "running",
            startedAt: ISO8601DateFormatter().string(from: Date()),
            build: BuildInfo(label: o.label, version: info?["CFBundleShortVersionString"] as? String ?? "?",
                             build: info?["CFBundleVersion"] as? String ?? "?"),
            machine: Machine(model: sysctlString("hw.model"), cpu: sysctlString("machdep.cpu.brand_string"), arch: arch,
                             memoryGB: (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 10).rounded() / 10,
                             os: ProcessInfo.processInfo.operatingSystemVersionString, virtualMachine: isVM,
                             cleanupAvailable: FlowCleanup.available),
            settings: RunSettings(models: o.models, boost: o.boost, cleanupLevels: o.levels.map(\.rawValue),
                               capMinutes: o.capSeconds / 60, clipTimeoutSeconds: o.clipTimeout, loadTimeoutSeconds: o.loadTimeout,
                               dictionary: [], normalizer: BenchText.summary,
                               gate: "Dictation's gate: skip under 0.4 s, or when the loudest 10% of the level envelope averages below 0.05",
                               cleanupStyle: "FlowSettings defaults: email clips use the Email category and Formal style; others use Other and Casual; no app context"),
            clipsDir: o.dir.path)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func save(_ r: Report, to url: URL, markdown: Bool) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try enc.encode(r).write(to: url, options: .atomic) } catch { Log.note("BENCH couldn't write \(url.path): \(error)") }
        if markdown {
            let md = url.deletingPathExtension().appendingPathExtension("md")
            try? BenchMarkdown.render(r).write(to: md, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Timeout

    enum BenchError: Error, CustomStringConvertible {
        case timeout(Double)
        var description: String {
            switch self { case .timeout(let s): return "timed out after \(Int(s)) s" }
        }
    }

    /// Returns the work's result, or throws after `seconds`. Unlike a task group, it never waits for work that
    /// ignores cancellation (a stuck Core ML call keeps running in the background, but the bench moves on).
    static func timed<T>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = BenchRaceGate<T>()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            gate.arm(cont)
            let worker = Task.detached(priority: .userInitiated) {
                do { gate.resolve(.success(try await work())) } catch { gate.resolve(.failure(error)) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.resolve(.failure(BenchError.timeout(seconds))) { worker.cancel() }
            }
        }
    }
}

/// One-shot continuation shared by the work and its timer; the first to finish wins.
final class BenchRaceGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    func arm(_ c: CheckedContinuation<T, Error>) { lock.lock(); cont = c; lock.unlock() }
    @discardableResult func resolve(_ r: Result<T, Error>) -> Bool {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        guard let c else { return false }
        c.resume(with: r)
        return true
    }
}

/// The report so far, shared with the watchdog so a timeout still leaves a readable file.
final class BenchSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var report: Bench.Report
    private var finished = false
    let out: URL

    init(out: URL, report: Bench.Report) { self.out = out; self.report = report }

    func update(_ change: (inout Bench.Report) -> Void) { lock.lock(); change(&report); lock.unlock() }

    func appendModel(_ run: Bench.ModelRun) -> Int {
        lock.lock(); defer { lock.unlock() }
        report.models.append(run)
        return report.models.count - 1
    }

    /// Writes the JSON (and the Markdown when asked or final). After the final write, later writes do nothing,
    /// so a late watchdog can't replace a finished report. Returns whether it wrote.
    @discardableResult
    func write(status: String? = nil, markdown: Bool = false, final: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        if let status { report.status = status }
        if final { finished = true; report.finishedAt = ISO8601DateFormatter().string(from: Date()) }
        Bench.save(report, to: out, markdown: markdown || final)
        return true
    }
}

// MARK: - Report types

extension Bench {
    struct Report: Encodable {
        var schema = 1
        var status: String
        var startedAt: String
        var finishedAt: String?
        var build: BuildInfo
        var machine: Machine
        var settings: RunSettings
        var clipsDir: String
        var clipCount = 0
        var voices: [String: String]?
        var missing: [String] = []
        var skipped: [String] = []
        var notes: [String] = []
        var models: [ModelRun] = []
    }

    struct BuildInfo: Encodable {
        var label: String?
        var version: String
        var build: String
    }

    struct Machine: Encodable {
        var model: String?
        var cpu: String?
        var arch: String
        var memoryGB: Double
        var os: String
        var virtualMachine: Bool?
        var cleanupAvailable: Bool
    }

    struct RunSettings: Encodable {
        var models: [String]
        var boost: Bool
        var cleanupLevels: [String]
        var capMinutes: Double
        var clipTimeoutSeconds: Double
        var loadTimeoutSeconds: Double
        var dictionary: [String]
        var normalizer: String
        var gate: String
        var cleanupStyle: String
    }

    struct ModelRun: Encodable {
        var id: String
        var name: String
        var status: String          // running, ok, partial, failed, skipped
        var error: String?
        var loadSeconds: Double?    // first transcription, including download and Core ML compile
        var boostWarmSeconds: Double?
        var notes: [String] = []
        var overall: Aggregate?
        var categories: [String: Aggregate] = [:]
        var clips: [ClipResult] = []
    }

    struct Gate: Encodable {
        var skip: Bool
        var reason: String?
        var loudness: Double
    }

    struct ClipResult: Encodable {
        var id: String
        var category: String
        var reference: String
        var expected: String?
        var audioSeconds: Double
        var gate: Gate
        var engine: Output?         // FluidEngine.transcribe / WhisperEngine.transcribe
        var boosted: Output?        // FluidEngine.transcribeBoosted with the Dictionary
        var dictation: Output?      // boosted (or plain) + DictionaryApplier + gate: what cleanup receives
        var dictionaryFixes: Int?
        var cleanup: [CleanupOutput] = []
    }

    struct Output: Encodable {
        var seconds: Double?
        var text: String?
        var error: String?
        var score: Score?
    }

    struct CleanupOutput: Encodable {
        var level: String
        var status: String          // literal, cleaned, unchanged, fallback, unavailable, gated, error
        var seconds: Double?
        var text: String?
        var note: String?
        var score: Score?
    }

    struct Score: Encodable {
        var normalized: String
        var wer: Double?
        var substitutions: Int?
        var deletions: Int?
        var insertions: Int?
        var refWords: Int?
        var nameHits: Int?
        var nameHitsCased: Int?
        var nameTotal: Int?
        var negationKept: Bool?
        var numbersKept: Bool?
        var falseActivation: Bool?
        var vocabFalseInsertions = 0
        var checksPassed: Bool?
    }

    struct Stats: Encodable {
        var n: Int
        var meanMs: Double
        var p50Ms: Double
        var p90Ms: Double
        var maxMs: Double

        static func of(_ seconds: [Double]) -> Stats? {
            guard !seconds.isEmpty else { return nil }
            let ms = seconds.map { $0 * 1000 }.sorted()
            func pct(_ p: Double) -> Double { ms[min(ms.count - 1, Int((p * Double(ms.count - 1)).rounded()))] }
            return Stats(n: ms.count, meanMs: ms.reduce(0, +) / Double(ms.count), p50Ms: pct(0.5), p90Ms: pct(0.9), maxMs: ms[ms.count - 1])
        }
    }

    struct Aggregate: Encodable {
        var clips = 0
        var audioSeconds = 0.0
        var errors = 0
        var werEngine: Double?
        var werBoosted: Double?
        var werDictation: Double?
        var werCleanup: [String: Double] = [:]
        var nameRecallEngine: Double?
        var nameRecallBoosted: Double?
        var nameRecallDictation: Double?
        var nameRecallDictationCased: Double?
        var nameRecallCleanup: [String: Double] = [:]
        var negationKept: Double?
        var negationKeptCleanup: [String: Double] = [:]
        var numbersKept: Double?
        var numbersKeptCleanup: [String: Double] = [:]
        var silenceClips = 0
        var falseActivationsEngine = 0
        var falseActivationsDictation = 0
        var vocabFalseInsertions = 0
        var cleanupChecksPassed: [String: Double] = [:]
        var cleanupStatus: [String: [String: Int]] = [:]
        var engineMs: Stats?
        var dictationMs: Stats?
        var cleanupMs: [String: Stats] = [:]
        var rtfx: Double?
    }
}

// MARK: - Text normalization and WER

/// English normalizer for scoring, modeled on Whisper's EnglishTextNormalizer and the Open ASR Leaderboard
/// normalizer in FluidAudio's CLI (TextNormalizer.swift, Apache 2.0). It is a subset, written for dictation:
/// see `summary` for exactly what it does.
enum BenchText {
    static let summary = "lowercase; drop [bracketed] and <tagged> text; $/€/£ amounts become '<n> dollars/euros/pounds', % becomes percent, & becomes and; thousands commas removed; '3:00' becomes '3', a.m./p.m. become am/pm, o'clock dropped; Mr/Mrs/Dr expanded; contractions expanded (can't → can not, n't → not, 're, 've, 'll, 'd, 'm, it's/that's/… → is, gonna/wanna/gotta); other apostrophes removed; punctuation and symbols become spaces except decimal points; fillers (um, uh, hmm, mm, mhm, er) dropped; number words to digits (zero–billion, ordinals to plain numbers, 3rd → 3); 'N dollars and M cents' → 'N.MM dollars', 'M cents' → '0.MM dollars'; 'N point M' → 'N.M'; a two-digit pair starting 11–20 merged as a year (twenty twenty six → 2026, nineteen ninety nine → 1999); okay/ok and e-mail/email unified. No British-to-American spelling map. WER is (substitutions + deletions + insertions) / reference words, summed over clips."

    static let negations: Set<String> = ["not", "no", "never", "nobody", "nothing", "none", "neither", "nor", "nowhere"]
    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "hmm", "mm", "mhm", "er", "erm"]

    static func isNumber(_ t: String) -> Bool {
        !t.isEmpty && t.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } && t.first != "." && t.last != "."
    }

    static func tokens(_ input: String) -> [String] {
        var s = input.lowercased()
        s = s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        s = s.re("\\[[^\\]]*\\]|<[^>]*>", " ")
        s = s.re("(\\d),(?=\\d{3}(?:\\D|$))", "$1")
        s = s.re("\\$\\s?(\\d+(?:\\.\\d+)?)", " $1 dollars ")
        s = s.re("€\\s?(\\d+(?:\\.\\d+)?)", " $1 euros ")
        s = s.re("£\\s?(\\d+(?:\\.\\d+)?)", " $1 pounds ")
        s = s.replacingOccurrences(of: "%", with: " percent ")
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.re("\\bper cent\\b", "percent")
        s = s.re("\\b(\\d{1,2}):00\\b", "$1")
        s = s.re("\\b([ap])\\.\\s?m\\b\\.?", "$1m")
        s = s.re("\\bo'?clock\\b", " ")
        s = s.re("\\be-mail", "email")
        s = s.re("\\bok\\b", "okay")
        s = s.re("\\bmrs\\b\\.?", "missus")
        s = s.re("\\bmr\\b\\.?", "mister")
        s = s.re("\\bdr\\b\\.?", "doctor")
        for (from, to) in wholeWords { s = s.re("\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b", to) }
        for (from, to) in suffixes { s = s.re("([a-z])" + NSRegularExpression.escapedPattern(for: from) + "\\b", "$1" + to) }
        s = s.replacingOccurrences(of: "'", with: "")
        s = s.re("(?<!\\d)\\.|\\.(?!\\d)", " ")
        s = s.re("[^\\p{L}\\p{N}\\s.]", " ")
        s = s.re("(\\d)([a-z])", "$1 $2")
        s = s.re("([a-z])(\\d)", "$1 $2")
        s = s.re("(\\d) (?:st|nd|rd|th)\\b", "$1")
        s = s.re("(\\d) s\\b", "$1s")
        let words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !fillers.contains($0) }
        return merge(numbers(words))
    }

    private static let wholeWords: [(String, String)] = [
        ("can't", "can not"), ("won't", "will not"), ("shan't", "shall not"), ("ain't", "is not"), ("let's", "let us"),
        ("cannot", "can not"), ("gonna", "going to"), ("wanna", "want to"), ("gotta", "got to"), ("y'all", "you all"),
        ("it's", "it is"), ("that's", "that is"), ("there's", "there is"), ("here's", "here is"), ("what's", "what is"),
        ("where's", "where is"), ("who's", "who is"), ("how's", "how is"), ("he's", "he is"), ("she's", "she is"),
        ("alright", "all right"),
    ]
    private static let suffixes: [(String, String)] = [
        ("n't", " not"), ("'re", " are"), ("'ve", " have"), ("'ll", " will"), ("'d", " would"), ("'m", " am"),
    ]

    private enum Kind { case unit, teen, tens, hundred, scale }
    private struct NumberWord { var value: Int; var kind: Kind; var ordinal: Bool }

    private static let numberWords: [String: NumberWord] = {
        var m: [String: NumberWord] = [:]
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        for (i, w) in units.enumerated() { m[w] = NumberWord(value: i, kind: .unit, ordinal: false) }
        for (i, w) in teens.enumerated() { m[w] = NumberWord(value: 10 + i, kind: .teen, ordinal: false) }
        for (i, w) in tens.enumerated() { m[w] = NumberWord(value: 20 + 10 * i, kind: .tens, ordinal: false) }
        let unitOrd = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        let teenOrd = ["tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
        let tensOrd = ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"]
        for (i, w) in unitOrd.enumerated() { m[w] = NumberWord(value: 1 + i, kind: .unit, ordinal: true) }
        for (i, w) in teenOrd.enumerated() { m[w] = NumberWord(value: 10 + i, kind: .teen, ordinal: true) }
        for (i, w) in tensOrd.enumerated() { m[w] = NumberWord(value: 20 + 10 * i, kind: .tens, ordinal: true) }
        m["hundred"] = NumberWord(value: 100, kind: .hundred, ordinal: false)
        m["thousand"] = NumberWord(value: 1_000, kind: .scale, ordinal: false)
        m["million"] = NumberWord(value: 1_000_000, kind: .scale, ordinal: false)
        m["billion"] = NumberWord(value: 1_000_000_000, kind: .scale, ordinal: false)
        return m
    }()

    /// Number words to digits: "two thousand twenty six" → 2026, "twenty first" → 21, "seven one seven" → 7 1 7,
    /// "12 thousand" → 12000.
    private static func numbers(_ words: [String]) -> [String] {
        var out: [String] = []
        var total = 0, current = 0, active = false
        var last: Kind = .unit
        func flush() {
            guard active else { return }
            out.append(String(total + current))
            total = 0; current = 0; active = false
        }
        for (i, w) in words.enumerated() {
            if let nw = numberWords[w] {
                if active {
                    switch nw.kind {
                    case .unit: if last == .unit || last == .teen { flush() }
                    case .teen, .tens: if last == .unit || last == .teen || last == .tens { flush() }
                    case .hundred, .scale: break
                    }
                }
                switch nw.kind {
                case .hundred: current = max(current, 1) * 100
                case .scale: total += max(current, 1) * nw.value; current = 0
                default: current += nw.value
                }
                active = true; last = nw.kind
                if nw.ordinal { flush() }
            } else if !active, let n = Int(w), i + 1 < words.count, let next = numberWords[words[i + 1]], next.kind == .hundred || next.kind == .scale {
                current = n; active = true; last = .tens
            } else {
                flush()
                out.append(w)
            }
        }
        flush()
        return out
    }

    /// Money, decimals, and years once number words are digits.
    private static func merge(_ t: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < t.count {
            let w = t[i]
            if Int(w) != nil, i + 4 < t.count, t[i + 1].hasPrefix("dollar"), t[i + 2] == "and", let m = Int(t[i + 3]), m < 100, t[i + 4].hasPrefix("cent") {
                out += [w + "." + String(format: "%02ld", m), "dollars"]; i += 5; continue
            }
            if let m = Int(w), m < 100, i + 1 < t.count, t[i + 1] == "cent" || t[i + 1] == "cents" {
                out += [String(format: "0.%02ld", m), "dollars"]; i += 2; continue
            }
            if w == "dollar" { out.append("dollars"); i += 1; continue }
            if w == "point", let a = out.last, Int(a) != nil, i + 1 < t.count, Int(t[i + 1]) != nil {
                out[out.count - 1] = a + "." + t[i + 1]; i += 2; continue
            }
            // Spoken years: "nineteen ninety nine" → 19 99 → 1999. "seventeen twenty twenty six" pairs the last two.
            func twoDigit(_ k: Int) -> Int? { k < t.count && t[k].count == 2 ? Int(t[k]).flatMap { (10...99).contains($0) ? $0 : nil } : nil }
            if let a = twoDigit(i), (11...20).contains(a), twoDigit(i + 1) != nil, twoDigit(i + 2) == nil {
                out.append(w + t[i + 1]); i += 2; continue
            }
            out.append(w); i += 1
        }
        return out
    }

    /// Word-level Levenshtein alignment counts.
    static func editCounts(hyp: [String], ref: [String]) -> (sub: Int, del: Int, ins: Int) {
        if ref.isEmpty { return (0, 0, hyp.count) }
        if hyp.isEmpty { return (0, ref.count, 0) }
        struct Cell { var cost: Int; var s: Int; var d: Int; var i: Int }
        var prev = (0...hyp.count).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        for r in 1...ref.count {
            var cur = [Cell(cost: r, s: 0, d: r, i: 0)]
            cur.reserveCapacity(hyp.count + 1)
            for h in 1...hyp.count {
                if ref[r - 1] == hyp[h - 1] { cur.append(prev[h - 1]); continue }
                let sub = prev[h - 1], del = prev[h], ins = cur[h - 1]
                var best = Cell(cost: sub.cost + 1, s: sub.s + 1, d: sub.d, i: sub.i)
                if del.cost + 1 < best.cost { best = Cell(cost: del.cost + 1, s: del.s, d: del.d + 1, i: del.i) }
                if ins.cost + 1 < best.cost { best = Cell(cost: ins.cost + 1, s: ins.s, d: ins.d, i: ins.i + 1) }
                cur.append(best)
            }
            prev = cur
        }
        let c = prev[hyp.count]
        return (c.s, c.d, c.i)
    }

    /// How many times `needle` appears as a contiguous run in `hay`.
    static func occurrences(of needle: [String], in hay: [String]) -> Int {
        guard !needle.isEmpty, hay.count >= needle.count else { return 0 }
        var n = 0
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { n += 1 }
        return n
    }
}

private extension String {
    func re(_ pattern: String, _ template: String) -> String {
        replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

// MARK: - Markdown summary

enum BenchMarkdown {
    static func render(_ r: Bench.Report) -> String {
        var md: [String] = []
        md.append("# Verbatim bench\(r.build.label.map { ": \($0)" } ?? "")")
        md.append("")
        md.append("- **Status:** \(r.status) · started \(r.startedAt)\(r.finishedAt.map { " · finished \($0)" } ?? "")")
        md.append("- **App:** Verbatim \(r.build.version) (\(r.build.build))")
        let m = r.machine
        md.append("- **Machine:** \(m.model ?? "?") · \(m.cpu ?? "?") · \(m.arch) · \(fmt(m.memoryGB, 1)) GB · \(m.os)\(m.virtualMachine == true ? " · virtual machine (speeds aren't representative of a real Mac)" : "")")
        md.append("- **Cleanup (Apple Intelligence):** \(m.cleanupAvailable ? "available" : "unavailable, so only the literal level ran")")
        var clipLine = "- **Clips:** \(r.clipCount)"
        if !r.missing.isEmpty { clipLine += " · missing: " + r.missing.joined(separator: ", ") }
        if !r.skipped.isEmpty { clipLine += " · skipped: " + r.skipped.joined(separator: ", ") }
        clipLine += " · Dictionary: \(r.settings.dictionary.count) terms"
        if let v = r.voices {
            let names: [String] = v.keys.sorted().map { key in key + " " + (v[key] ?? "") }
            clipLine += " · voices: " + names.joined(separator: ", ")
        }
        md.append(clipLine)
        for n in r.notes { md.append("- **Note:** \(n)") }
        md.append("")
        md.append("## Models")
        md.append("")
        md.append("| Model | Status | Load s | WER engine | WER boosted | WER pasted | Names engine → pasted | Negation kept | Numbers kept | False activations | Median ms | p90 ms | RTFx |")
        md.append("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
        for run in r.models {
            let a = run.overall
            let fa = a.map { "\($0.falseActivationsEngine) / \($0.falseActivationsDictation) of \($0.silenceClips)" } ?? "–"
            md.append("| \(run.name) | \(run.status)\(run.error.map { ": " + cell($0) } ?? "") | \(fmt(run.loadSeconds, 1)) | \(pct(a?.werEngine)) | \(pct(a?.werBoosted)) | \(pct(a?.werDictation)) | \(pct(a?.nameRecallEngine)) → \(pct(a?.nameRecallDictation)) | \(pct(a?.negationKept)) | \(pct(a?.numbersKept)) | \(fa) | \(fmt(a?.dictationMs?.p50Ms, 0)) | \(fmt(a?.dictationMs?.p90Ms, 0)) | \(fmt(a?.rtfx, 0)) |")
        }
        md.append("")
        md.append("WER is normalized (case, punctuation, number format, and contractions ignored). *Pasted* is the text dictation hands to cleanup: the boosted transcript with Dictionary replacements, after the loudness gate. False activations are engine / pasted text on silence-only clips. Latency is the pasted path (transcription plus Dictionary) per clip, model already loaded.")

        let cleanupRows = r.models.flatMap { run -> [String] in
            guard let a = run.overall else { return [] }
            let order = CleanupLevel.allCases.map(\.rawValue)
            let levels = a.cleanupStatus.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            return levels.map { level in
                let st = a.cleanupStatus[level] ?? [:]
                let status = st.keys.sorted().map { "\($0) \(st[$0] ?? 0)" }.joined(separator: ", ")
                return "| \(run.name) | \(level) | \(status) | \(pct(a.werCleanup[level])) | \(pct(a.cleanupChecksPassed[level])) | \(pct(a.negationKeptCleanup[level])) | \(pct(a.numbersKeptCleanup[level])) | \(fmt(a.cleanupMs[level]?.p50Ms, 0)) |"
            }
        }
        if !cleanupRows.isEmpty {
            md.append("")
            md.append("## Cleanup")
            md.append("")
            md.append("| Model | Level | Outcomes | WER vs expected | Checks passed | Negation kept | Numbers kept | Median ms |")
            md.append("|---|---|---|--:|--:|--:|--:|--:|")
            md += cleanupRows
            md.append("")
            md.append("WER here is against each clip's *expected* text (self-corrections resolved, spoken punctuation applied). Checks are the clip's must-contain and must-not-contain words.")
        }

        for run in r.models where !run.categories.isEmpty {
            md.append("")
            md.append("## By category: \(run.name)")
            md.append("")
            md.append("| Category | Clips | WER engine | WER pasted | Names | Median ms |")
            md.append("|---|--:|--:|--:|--:|--:|")
            for (cat, a) in run.categories.sorted(by: { $0.key < $1.key }) {
                md.append("| \(cat) | \(a.clips) | \(pct(a.werEngine)) | \(pct(a.werDictation)) | \(pct(a.nameRecallDictation)) | \(fmt(a.dictationMs?.p50Ms, 0)) |")
            }
            let worst = run.clips.filter { ($0.dictation?.score?.wer ?? 0) > 0 }
                .sorted { ($0.dictation?.score?.wer ?? 0) > ($1.dictation?.score?.wer ?? 0) }.prefix(5)
            if !worst.isEmpty {
                md.append("")
                md.append("Hardest clips:")
                md.append("")
                md.append("| Clip | WER | Reference | Pasted |")
                md.append("|---|--:|---|---|")
                for c in worst {
                    md.append("| \(c.id) | \(pct(c.dictation?.score?.wer)) | \(cell(c.reference)) | \(cell(c.dictation?.text ?? "")) |")
                }
            }
        }
        md.append("")
        return md.joined(separator: "\n")
    }

    private static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }
    private static func fmt(_ v: Double?, _ digits: Int) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
    private static func cell(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "|", with: "\\|").components(separatedBy: .newlines).joined(separator: " ⏎ ")
        return flat.count > 120 ? String(flat.prefix(117)) + "…" : flat
    }
}
