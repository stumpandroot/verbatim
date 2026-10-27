import Foundation
import Combine
import NaturalLanguage
import UserNotifications
#if canImport(FoundationModels)
import FoundationModels
#endif

// Ask your library, the running part (the rules are in Model/Ask.swift and Model/AskRecipes.swift), for both apps.
//
// The index: each recording's passages and, where this device has a sentence embedding for its language
// (NaturalLanguage's NLEmbedding), one vector per passage, quantized to bytes. It's kept in Application Support on this
// device ("Ask Index", one small file per recording, left out of backups) and never synced or uploaded. It updates in
// the background a few seconds after the library changes, one recording at a time, only while nothing is recording or
// transcribing, and only for recordings whose words changed (a fingerprint of the lines). A question never waits for it:
// recordings it hasn't reached yet are searched by their words alone.
//
// A question: the passages in scope are ranked (Ask.swift), the best dozen or so go to Apple's on-device model with the
// question, and the answer comes back with numbered citations, which are checked against the passages given. Nothing
// leaves the device.

/// Passages and their vectors for every recording, off the main actor.
actor AskIndex {
    static let shared = AskIndex()

    struct Entry: Codable {
        /// The recording's fingerprint (AskPassages.fingerprint) in hex: a property list can't hold every UInt64.
        var fingerprint: String
        var passages: [AskPassage]
        /// The embedding's language ("en"), when there are vectors.
        var language: String?
        var dimension: Int = 0
        /// One vector per passage, `dimension` signed bytes each (component × 127 of the unit vector).
        var vectors: Data?
    }

    private var entries: [UUID: Entry] = [:]
    private var loaded = false
    private var embeddings: [String: NLEmbedding] = [:]
    private var noEmbedding: Set<String> = []
    /// Indexing on (self-tests turn the vectors off; the passages are always built).
    var embed = true

    static var folder: URL { AskStorage.indexFolder(in: Paths.local) }

    func setEmbedding(_ on: Bool) { embed = on }

    // MARK: Keeping up with the library

    /// Brings the index up to date with these recordings: new and changed ones get passages and vectors, deleted ones
    /// go. Stops between recordings while `canWork` says no (recording, transcribing), and yields between them.
    func sync(_ list: [Transcript], canWork: @escaping @Sendable () async -> Bool) async {
        loadIfNeeded()
        let live = list.filter { $0.deletedAt == nil && $0.status == .ready && !$0.isDictation && !$0.segments.isEmpty }
        let ids = Set(live.map(\.id))
        for id in entries.keys where !ids.contains(id) {
            entries[id] = nil
            try? FileManager.default.removeItem(at: file(id))
        }
        var done = 0
        for t in live.sorted(by: { $0.createdAt > $1.createdAt }) {
            if Task.isCancelled { return }
            let fp = String(AskPassages.fingerprint(t), radix: 16)
            if let e = entries[t.id], e.fingerprint == fp, e.vectors != nil || !embed { continue }
            // Vectors only where this device has a sentence embedding for the recording's language.
            let lang = embed ? language(for: t) : nil
            let model = lang.flatMap { embedding($0) }
            if entries[t.id]?.fingerprint == fp, model == nil { continue }
            while !(await canWork()) {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            var e = entries[t.id].flatMap { $0.fingerprint == fp ? $0 : nil } ?? Entry(fingerprint: fp, passages: AskPassages.build(t))
            if e.vectors == nil, let lang, let model {
                var bytes = Data(capacity: e.passages.count * model.dimension)
                for (i, p) in e.passages.enumerated() {
                    let v = model.vector(for: String(p.text.prefix(1_000))).map(Self.unit) ?? [Float](repeating: 0, count: model.dimension)
                    bytes.append(contentsOf: v.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 * 127).rounded())))) })
                    if i % 16 == 15 { await Task.yield() }
                }
                e.language = lang; e.dimension = model.dimension; e.vectors = bytes
            }
            entries[t.id] = e
            save(t.id, e)
            done += 1
            await Task.yield()
        }
        if done > 0 { Log.note("ask: indexed \(done) recording(s); \(entries.count) in the index") }
    }

    /// Everything in the index goes (Delete all data).
    func clear() {
        entries = [:]
        loaded = true   // nothing to read back
        try? FileManager.default.removeItem(at: Self.folder)
    }

    /// Recordings deleted or moved to Recently Deleted leave the index at once, from memory and disk.
    func remove(_ ids: [UUID]) {
        for id in ids { entries[id] = nil }
        AskStorage.removeIndex(for: ids, in: Paths.local)
    }

    // MARK: Asking

    /// The candidates for these recordings: the indexed passages and vectors, or passages built now for recordings the
    /// index hasn't reached (words only).
    func candidates(_ list: [Transcript]) -> [AskCandidate] {
        loadIfNeeded()
        var out: [AskCandidate] = []
        for t in list {
            let fp = String(AskPassages.fingerprint(t), radix: 16)
            let e = entries[t.id].flatMap { $0.fingerprint == fp ? $0 : nil }
            let passages = e?.passages ?? AskPassages.build(t)
            for (i, p) in passages.enumerated() {
                out.append(AskCandidate(passage: p, title: t.title, createdAt: t.createdAt, vector: e.flatMap { Self.vector($0, i) }))
            }
        }
        return out
    }

    /// The question's vector in a language the index has vectors for, and that language.
    func questionVector(_ q: String) -> [Float]? {
        guard embed else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(q)
        guard let lang = r.dominantLanguage?.rawValue, let model = embedding(lang) else { return nil }
        return model.vector(for: q).map(Self.unit)
    }

    var count: Int { entries.count }
    func entry(_ id: UUID) -> Entry? { entries[id] }

    // MARK: Parts

    private func language(for t: Transcript) -> String? {
        if let l = t.language, !l.isEmpty { return String(l.prefix(2)).lowercased() }
        let r = NLLanguageRecognizer()
        r.processString(String(t.text.prefix(600)))
        return r.dominantLanguage?.rawValue
    }

    private func embedding(_ lang: String) -> NLEmbedding? {
        if let e = embeddings[lang] { return e }
        guard !noEmbedding.contains(lang) else { return nil }
        guard let e = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: lang)) else { noEmbedding.insert(lang); return nil }
        embeddings[lang] = e
        return e
    }

    private static func unit(_ v: [Double]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { Float($0 / n) } : v.map { Float($0) }
    }

    private static func vector(_ e: Entry, _ i: Int) -> [Float]? {
        guard let data = e.vectors, e.dimension > 0, data.count >= (i + 1) * e.dimension else { return nil }
        let start = data.startIndex + i * e.dimension
        return data[start..<(start + e.dimension)].map { Float(Int8(bitPattern: $0)) / 127 }
    }

    private func file(_ id: UUID) -> URL { AskStorage.indexFile(id, in: Paths.local) }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var u = Self.folder
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        let dec = PropertyListDecoder()
        for f in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "plist" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: f), let e = try? dec.decode(Entry.self, from: data) else { continue }
            entries[id] = e
        }
    }

    private func save(_ id: UUID, _ e: Entry) {
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        guard let data = try? enc.encode(e) else { return }
        try? data.write(to: file(id), options: .atomic)
    }
}

// MARK: - Asking

/// Asks questions for the screens and recipes, and keeps the index in step with the library.
@MainActor
final class AskCenter: ObservableObject {
    static let shared = AskCenter()

    #if os(macOS)
    static let here = "Mac"
    #else
    static let here = "iPhone"
    #endif

    enum Phase: Equatable { case idle, finding, answering, done }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: AskResult? = nil
    /// Questions asked on this device, newest first (Ask › Questions).
    @Published private(set) var history: [AskResult] = []

    /// True while recording or transcribing: the index waits.
    var isBusy: () -> Bool = { false }
    /// Stands in for Apple's model in the self-tests (and returns the model's raw answer).
    var responder: ((String) async -> String?)? = nil
    /// Off in the self-tests: no background indexing on its own.
    var automatic = true

    private weak var store: Store?
    private var bag = Set<AnyCancellable>()
    private var indexing: Task<Void, Never>? = nil
    private var work: Task<Void, Never>? = nil
    private var runID = 0

    static var unavailableReason: String? { Polish.status.reason.map { "Answers need Apple Intelligence. " + $0 } }

    /// After the library loads: the index catches up a little later, then follows the library's changes.
    func attach(_ store: Store, isBusy: @escaping () -> Bool) {
        self.store = store
        self.isBusy = isBusy
        history = AskHistoryFile.load()
        // A recording deleted or moved to Recently Deleted leaves the index, the answers, and the digests at once.
        store.onTranscriptsRemoved = { ids in AskCenter.shared.removed(ids) }
        guard automatic else { return }
        store.anyChange
            .debounce(for: .seconds(8), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reindex() } }
            .store(in: &bag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.reindex() }
    }

    /// Updates the index in the background (a recording at a time, never while recording or transcribing).
    func reindex() {
        guard let store, store.isLoaded else { return }
        let list = store.live
        indexing?.cancel()
        indexing = Task.detached(priority: .background) {
            await AskIndex.shared.sync(list, canWork: { await MainActor.run { !AskCenter.shared.isBusy() } })
        }
    }

    /// Asks a question for the screens: `result` and `phase` follow it. A new question replaces one still running.
    func ask(_ question: String, scope: AskScope) {
        guard let store else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        runID += 1
        let id = runID
        work?.cancel()
        phase = .finding
        work = Task { @MainActor in
            let r = await Self.answer(q, scope: scope, store: store, progress: { p in if id == self.runID { self.phase = p } })
            guard id == self.runID, !Task.isCancelled else { return }
            self.result = r
            self.phase = .done
            self.remember(r)
        }
    }

    /// Shows a result again (a recent question, or a test's).
    func show(_ r: AskResult?) { runID += 1; work?.cancel(); result = r; phase = r == nil ? .idle : .done }

    func clear() { show(nil) }

    private func remember(_ r: AskResult) {
        history.removeAll { $0.question.lowercased() == r.question.lowercased() && $0.scope == r.scope }
        history.insert(r, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        AskHistoryFile.save(history)
    }

    func forget() { history = []; AskHistoryFile.save([]) }

    /// Recordings deleted or trashed: their passages leave the index, and answers here and in digests drop their
    /// citations.
    func removed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        Task.detached(priority: .utility) { await AskIndex.shared.remove(ids) }
        if let r = result { result = AskCleanup.pruned(r, removing: set) }
        let pruned = history.map { AskCleanup.pruned($0, removing: set) }
        if pruned != history { history = pruned; AskHistoryFile.save(history) }
        AskRecipeCenter.shared.removed(set)
    }

    /// Delete all data: the index, recent questions, and the current answer.
    func eraseAll() async {
        runID += 1; work?.cancel(); indexing?.cancel()
        result = nil; phase = .idle; history = []
        await AskIndex.shared.clear()
        AskStorage.removeAll(in: Paths.local)
    }

    /// Finds the passages, then answers from them. Used by the screens and by recipes.
    static func answer(_ question: String, scope: AskScope, store: Store, now: Date = Date(),
                       progress: ((Phase) -> Void)? = nil) async -> AskResult {
        let inScope = store.live.filter { scope.includes($0, now: now) }
        var result = AskResult(question: question, scope: scope, state: .nothingFound, device: here, askedAt: now)
        let overview = AskIntent.isOverview(question)
        let picked: [AskHit] = await Task.detached(priority: .userInitiated) {
            let candidates = await AskIndex.shared.candidates(inScope)
            if overview { return AskRanker.overview(question: question, candidates: candidates) }
            let qv = await AskIndex.shared.questionVector(question)
            let ranked = AskRanker.rank(question: question, candidates: candidates, questionVector: qv)
            if ranked.isEmpty {
                // Nothing relevant: the closest few, to show, never to answer from.
                let closest = AskRanker.rank(question: question, candidates: candidates, questionVector: qv, all: true).filter { $0.score > 0 }
                return Array(closest.prefix(3)).map { var h = $0; h.score = -1; return h }
            }
            return AskRanker.select(ranked)
        }.value
        if picked.isEmpty || picked.allSatisfy({ $0.score < 0 }) {
            result.state = .nothingFound
            result.found = picked.enumerated().map { AskSource(number: $0 + 1, $1) }
            return result
        }
        result.found = picked.enumerated().map { AskSource(number: $0 + 1, $1) }
        result.passageCount = picked.count
        result.recordingCount = Set(picked.map(\.passage.transcriptId)).count
        let responder = AskCenter.shared.responder
        if responder == nil, let why = unavailableReason {
            result.state = .searchOnly
            result.reason = why
            return result
        }
        progress?(.answering)
        // Fewer passages when the model's window overflows.
        var given = picked
        for _ in 0..<3 {
            let prompt = AskPrompt.prompt(question: question, passages: given)
            let raw: String?
            do {
                if let responder { raw = await responder(prompt) } else { raw = try await respond(prompt) }
            } catch AskFailure.tooLong where given.count > 3 {
                given = Array(given.prefix(max(3, given.count * 2 / 3)))
                continue
            } catch {
                raw = nil
            }
            if Task.isCancelled { return result }
            guard let raw else { break }
            if let a = AskCitations.parse(raw, passages: given) {
                result.state = .answered
                result.answer = a
                result.passageCount = given.count
                result.recordingCount = Set(given.map(\.passage.transcriptId)).count
                return result
            }
            break
        }
        result.state = .noAnswer
        result.found = Array(result.found.prefix(4))
        return result
    }

    enum AskFailure: Error { case tooLong, declined }

    /// Apple's on-device model: the default guardrails first, then the relaxed mode Apple provides for working on the
    /// person's own text when it declines (as the transcript actions do).
    nonisolated static func respond(_ prompt: String) async throws -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: AskPrompt.instructions)
                let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1))
                let out = TranscriptActions.clean(r.content)
                if !out.isEmpty, !OnDeviceTextRefusal.isRefusal(out) { return out }
            } catch let e as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = e { throw AskFailure.tooLong }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.note("ask: the model failed (\(String(describing: type(of: error)))); trying the relaxed mode")
            }
            do {
                let out = TranscriptActions.clean(try await OnDeviceText.respond(instructions: AskPrompt.instructions, prompt: prompt, temperature: 0.1))
                return out.isEmpty || OnDeviceTextRefusal.isRefusal(out) ? nil : out
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.note("ask: the relaxed mode failed too (\(String(describing: type(of: error))))")
                return nil
            }
        }
        #endif
        return nil
    }
}

/// Recent questions, on this device only (Paths.local, never synced).
enum AskHistoryFile {
    static var url: URL { AskStorage.historyFile(in: Paths.local) }
    static func load() -> [AskResult] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? Store.dec.decode([AskResult].self, from: d)) ?? []
    }
    static func save(_ list: [AskResult]) {
        guard let d = try? Store.enc.encode(list) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

// MARK: - Recipes

/// Runs recipes (now or on their weekly schedule) and keeps their digests, on this device.
@MainActor
final class AskRecipeCenter: ObservableObject {
    static let shared = AskRecipeCenter()

    @Published private(set) var digests: [AskDigest] = []
    @Published private(set) var device = RecipeDeviceState()
    @Published private(set) var running: Set<UUID> = []

    /// Off in the self-tests: no scheduled runs and no notifications on their own.
    var automatic = true
    /// iOS: asks for a background refresh at the next scheduled time (PhoneState).
    var scheduleBackground: ((Date?) -> Void)? = nil

    private weak var store: Store?
    private var timer: Timer? = nil

    static var digestsURL: URL { AskStorage.digestsFile(in: Paths.local) }

    var isAttached: Bool { store != nil }

    func attach(_ store: Store) {
        self.store = store
        device = RecipeDeviceState.load()
        if let d = try? Data(contentsOf: Self.digestsURL), let list = try? Store.dec.decode([AskDigest].self, from: d) { digests = list }
        guard automatic else { return }
        // A scheduled recipe runs while the app is open, or at the next launch after its time.
        #if os(macOS)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in AskRecipeCenter.shared.runDue() } }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.runDue() }
        planBackground()
    }

    // MARK: Recipes

    func add(_ question: String, scope: AskScope, schedule: RecipeSchedule? = nil) -> AskRecipe? {
        guard let store else { return nil }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let same = store.recipes.first(where: { $0.question.lowercased() == q.lowercased() && $0.scope == scope }) { return same }
        let r = AskRecipe(question: q, scope: scope)
        store.recipes.append(r)
        if let schedule { setSchedule(schedule, for: r.id) }
        return r
    }

    func update(_ r: AskRecipe) {
        guard let store, let i = store.recipes.firstIndex(where: { $0.id == r.id }) else { return }
        store.recipes[i] = r
    }

    func delete(_ id: UUID) {
        store?.recipes.removeAll { $0.id == id }
        var d = device; d.schedules[id] = nil; d.lastRun[id] = nil
        setDevice(d)
        digests.removeAll { $0.recipeId == id }
        saveDigests()
    }

    func schedule(_ id: UUID) -> RecipeSchedule? { device.schedules[id] }

    /// Recordings deleted or trashed: digests drop their citations.
    func removed(_ ids: Set<UUID>) {
        let pruned = AskCleanup.pruned(digests, removing: ids)
        guard pruned != digests else { return }
        digests = pruned
        saveDigests()
    }

    /// Delete all data: every recipe, its schedule, and its digests on this device.
    func eraseAll() {
        store?.recipes = []
        digests = []
        running = []
        setDevice(RecipeDeviceState())
        try? FileManager.default.removeItem(at: Self.digestsURL)
    }

    /// Sets or clears a recipe's weekly time on this device. A time already past this week waits for next week.
    func setSchedule(_ s: RecipeSchedule?, for id: UUID) {
        var d = device
        if var s { s.since = Date(); d.schedules[id] = s } else { d.schedules[id] = nil }
        setDevice(d)
    }

    private func setDevice(_ d: RecipeDeviceState) {
        device = d
        d.save()
        planBackground()
    }

    func latest(_ id: UUID) -> AskDigest? { digests.first { $0.recipeId == id } }

    // MARK: Running

    /// Runs a recipe now and keeps its answer as a digest.
    func run(_ r: AskRecipe, scheduled: Bool = false) {
        guard let store, !running.contains(r.id) else { return }
        running.insert(r.id)
        Task { @MainActor in
            let result = await AskCenter.answer(r.question, scope: r.scope, store: store)
            self.running.remove(r.id)
            if Task.isCancelled { return }
            let digest = AskDigest(recipeId: r.id, ranAt: Date(), scheduled: scheduled, result: result)
            self.keep(digest)
            if scheduled { self.notify(r, digest) }
        }
    }

    /// Keeps a run's answer and marks the recipe as run on this device.
    func keep(_ digest: AskDigest) {
        digests = AskDigest.trimmed([digest] + digests)
        saveDigests()
        var d = device; d.lastRun[digest.recipeId] = digest.ranAt
        setDevice(d)
    }

    /// Runs every recipe owed a scheduled run (once each, however many weeks were missed).
    func runDue(now: Date = Date()) {
        guard automatic, let store, store.isLoaded else { return }
        let owed = device.pruned(store.recipes).due(store.recipes, now: now)
        for (r, _) in owed where !running.contains(r.id) {
            Log.note("ask: running a scheduled recipe")
            run(r, scheduled: true)
        }
    }

    /// Waits for the owed runs to finish (iOS's background refresh), up to `timeout` seconds.
    func runDueAndWait(timeout: Double = 25) async {
        runDue()
        let end = Date().addingTimeInterval(timeout)
        while !running.isEmpty, Date() < end, !Task.isCancelled { try? await Task.sleep(nanoseconds: 500_000_000) }
    }

    private func planBackground() {
        guard automatic, let store else { return }
        scheduleBackground?(device.nextRun(store.recipes, after: Date()))
    }

    private func saveDigests() {
        guard let d = try? Store.enc.encode(digests) else { return }
        try? d.write(to: Self.digestsURL, options: .atomic)
    }

    /// A scheduled recipe's answer landed: a notification with its first sentence.
    private func notify(_ r: AskRecipe, _ d: AskDigest) {
        guard automatic, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let body = d.result.answer?.firstSentence ?? "Your answer is ready in Ask."
        let title = r.question
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.userInfo = ["askDigest": d.id.uuidString]
            center.add(UNNotificationRequest(identifier: "ask-\(d.id.uuidString)", content: c, trigger: nil))
        }
    }
}

/// Settings' Delete all data, on both apps: Ask's index, recent questions, recipes, schedules, and digests.
@MainActor
enum AskData {
    static func eraseAll() async {
        AskRecipeCenter.shared.eraseAll()
        await AskCenter.shared.eraseAll()
        Log.note("ask: deleted the index, questions, recipes, and digests")
    }
}
