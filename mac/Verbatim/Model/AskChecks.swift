import Foundation

/// Ask your library's rules (Ask.swift, AskRecipes.swift), checked by both self-tests (UITest on Mac, PhoneUITest on
/// iPhone) and in more detail on Linux (mac/tools/test-ask.sh). Builds transcripts in memory; nothing is saved. The
/// samples are the mockup's: a client call, a design review, and a film idea.
enum AskChecks {
    static let clientTitle = "Client call · website refresh"
    static let reviewTitle = "Design review · onboarding"

    /// A finished recording with these lines (start time, speaker, words).
    static func recording(_ title: String, kind: RecordingKind, daysAgo: Double, project: UUID? = nil, now: Date = Date(),
                          lines: [(Double, String?, String)], speakers: [(String, String)] = []) -> Transcript {
        var t = Transcript(title: title, source: .voiceMemo, sourceLabel: "Voice memo", duration: (lines.last?.0 ?? 0) + 30, audioFileName: nil, model: "Test")
        t.segments = lines.enumerated().map { i, l in
            Segment(start: l.0, end: min(l.0 + 12, i + 1 < lines.count ? lines[i + 1].0 : l.0 + 12), text: l.2, speaker: l.1)
        }
        t.original = t.segments
        t.speakers = speakers.map { Speaker(id: $0.0, name: $0.1) }
        t.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
        t.kind = kind
        t.kindIsAuto = false
        t.projectId = project
        return t
    }

    /// The mockup's three recordings: Tuesday's client call, Monday's design review (both in `project`), and a film idea.
    static func samples(project: UUID? = nil, now: Date = Date()) -> [Transcript] {
        let call = recording(clientTitle, kind: .meeting, daysAgo: 2, project: project, now: now, lines: [
            (12, "S1", "Thanks for making time. We want the refreshed site live by November 18."),
            (760, "S2", "On the homepage, the headline is too long. On a phone it fills the screen before anything else shows."),
            (790, "S2", "Can the contact form sit higher on the page? People give up scrolling to find it."),
            (1625, "S2", "Put the case studies ahead of pricing. Visitors ask for examples first."),
            (1700, "S1", "I'll send two shorter headlines by Friday."),
        ], speakers: [("S1", "Sam"), ("S2", "Alex")])
        let review = recording(reviewTitle, kind: .meeting, daysAgo: 1, project: project, now: now, lines: [
            (30, nil, "Empty states need one sentence, not two."),
            (492, nil, "We agreed to test two headline lengths on a phone before sending them to Alex."),
            (900, nil, "The calendar dots read better in ink."),
        ])
        let film = recording("Film idea · the lighthouse keeper", kind: .idea, daysAgo: 3, now: now, lines: [
            (0, nil, "A short film about a lighthouse keeper who records the weather every night."),
            (38, nil, "Open on the radio, not the sea."),
        ])
        return [call, review, film]
    }

    static func candidates(_ list: [Transcript]) -> [AskCandidate] {
        list.flatMap { t in AskPassages.build(t).map { AskCandidate(passage: $0, title: t.title, createdAt: t.createdAt) } }
    }

    /// The answer the screenshots show for "What did Alex want changed on the homepage?" (as the model writes it).
    static let sampleAnswer = """
        Alex asked for a shorter headline, because on a phone it fills the screen before anything else shows [1], and for \
        the contact form to sit higher on the page [1]. Later in the same call, Alex asked to put case studies ahead of \
        pricing, since visitors ask for examples first [2].

        In Monday's design review, Sam agreed to test two headline lengths on a phone before sending them [3].
        """

    /// The screenshots' answer: the sample answer against the call's homepage and case-studies passages and the review's
    /// headline passage, in the seeded recordings (by title). nil when they aren't in `lib`.
    static func sampleResult(_ lib: [Transcript], scope: AskScope = .all, device: String) -> AskResult? {
        let pool = candidates(lib.filter { $0.title == clientTitle || $0.title == reviewTitle })
        let picks = ["homepage", "case studies", "headline lengths"].compactMap { w in pool.first { $0.passage.text.contains(w) } }
        guard picks.count == 3 else { return nil }
        let hits = picks.map { AskHit(candidate: $0, score: 1, matched: 1, semantic: nil) }
        var r = AskResult(question: "What did Alex want changed on the homepage?", scope: scope, state: .answered, device: device)
        r.answer = AskCitations.parse(sampleAnswer, passages: hits)
        r.found = hits.enumerated().map { AskSource(number: $0 + 1, $1) }
        r.passageCount = 9
        r.recordingCount = 2
        return r.answer == nil ? nil : r
    }

    /// The screenshots' digest for "Action items from this week's meetings".
    static let sampleDigestAnswer = """
        Website refresh
        - Send two shorter headlines by Friday [1]
        - Test two headline lengths on a phone before sending them to Alex [2]
        - Move the contact form higher on the page [3]
        """

    static func sampleDigest(_ lib: [Transcript], question: String, scope: AskScope, device: String) -> AskResult? {
        let pool = candidates(lib.filter { $0.title == clientTitle || $0.title == reviewTitle })
        let picks = ["I'll send", "headline lengths", "contact form"].compactMap { w in pool.first { $0.passage.text.contains(w) } }
        guard picks.count == 3 else { return nil }
        let hits = picks.map { AskHit(candidate: $0, score: 1, matched: 1, semantic: nil) }
        var r = AskResult(question: question, scope: scope, state: .answered, device: device)
        r.answer = AskCitations.parse(sampleDigestAnswer, passages: hits)
        r.found = hits.enumerated().map { AskSource(number: $0 + 1, $1) }
        r.passageCount = 6
        r.recordingCount = 2
        return r.answer == nil ? nil : r
    }

    static func run(_ check: (String, Bool) -> Void) {
        let now = Date()
        let project = UUID()
        let lib = samples(project: project, now: now)
        let all = candidates(lib)

        // Scopes.
        check("scope: All has every recording with words", lib.allSatisfy { AskScope.all.includes($0, now: now) })
        check("scope: Thoughts has the film idea only", lib.filter { AskScope(source: .thoughts).includes($0, now: now) }.map(\.kind) == [.idea])
        check("scope: Meetings and the project have the call and the review", lib.filter { AskScope(source: .meetings).includes($0, now: now) }.count == 2
              && lib.filter { AskScope(source: .project(project)).includes($0, now: now) }.count == 2)
        var old = lib[2]; old.createdAt = now.addingTimeInterval(-9 * 86_400)
        check("scope: This week is the last seven days", !AskScope(range: .thisWeek).includes(old, now: now) && AskScope(range: .thisWeek).includes(lib[2], now: now))
        var dict = lib[0]; dict.kind = .dictation
        check("scope: dictations aren't asked", !AskScope.all.includes(dict, now: now))
        var s = AskScope.all
        s.tapWeek(); s.tap(.thoughts)
        check("scope: This week and a source combine, and All clears both", s == AskScope(range: .thisWeek, source: .thoughts)
              && s.label(projects: [:]) == "Thoughts · This week" && { var x = s; x.tapAll(); return x.isAll }())
        check("scope: a recipe's scope reads back", AskScope(raw: AskScope(source: .project(project)).raw) == AskScope(source: .project(project)))

        // Ranking.
        let q = "What did Alex want changed on the homepage?"
        let hits = AskRanker.rank(question: q, candidates: all)
        check("ranking: the homepage passage comes first", hits.first?.candidate.title == clientTitle && hits.first?.passage.text.contains("homepage") == true)
        check("ranking: the film idea isn't relevant to the homepage", !hits.contains { $0.candidate.title.hasPrefix("Film idea") })
        check("ranking: nothing relevant for a question the library can't answer", AskRanker.rank(question: "What is the wifi password at the cabin?", candidates: all).isEmpty)
        let picked = AskRanker.select(AskRanker.rank(question: "headline", candidates: all), limit: 12, perRecording: 1)
        check("ranking: one recording gives at most its share", Set(picked.map(\.passage.transcriptId)).count == picked.count)
        let digest = AskRanker.overview(question: "Weekly digest of my thoughts", candidates: candidates(lib.filter { AskScope(range: .thisWeek, source: .thoughts).includes($0, now: now) }))
        check("ranking: a digest reads the scope even without the question's words", !digest.isEmpty && digest.allSatisfy { $0.candidate.title.hasPrefix("Film idea") })
        check("ranking: a digest question is an overview", AskIntent.isOverview("Weekly digest of my thoughts") && AskIntent.isOverview("Action items from this week's meetings")
              && !AskIntent.isOverview(q))

        // Citations.
        let given = Array(AskRanker.rank(question: q, candidates: all, all: true).prefix(3))
        let parsed = AskCitations.parse("The headline is too long [1]. Move the form up [2][9]. Nobody said this.", passages: given)
        check("citations: a number with no passage is dropped", parsed?.blocks.first == .paragraph([AskSentence(text: "The headline is too long.", cites: [1]),
                                                                                                     AskSentence(text: "Move the form up.", cites: [2])]))
        check("citations: a sentence with no citation is dropped", parsed?.plainText.contains("Nobody") == false)
        check("citations: renumbered in the order the answer uses them", AskCitations.parse("A [3]. B [1].", passages: given)?.citations.map(\.number) == [1, 2]
              && AskCitations.parse("A [3]. B [1].", passages: given)?.citations.first?.segmentId == given[2].passage.segmentId)
        check("citations: NOT_FOUND is no answer", AskCitations.parse("NOT_FOUND", passages: given) == nil)
        check("citations: an answer with only made-up numbers is no answer", AskCitations.parse("Something [7].", passages: given) == nil)

        // Recipes.
        let cal = Calendar(identifier: .gregorian)
        let friday4 = RecipeSchedule(weekday: 6, hour: 16, minute: 0, since: now.addingTimeInterval(-30 * 86_400))
        let owed = RecipeScheduling.due(friday4, lastRun: nil, now: now, calendar: cal)
        check("recipes: a missed schedule is owed once, for the latest time", owed != nil && owed! <= now && owed! > now.addingTimeInterval(-7 * 86_400))
        check("recipes: after it runs, nothing is owed until the next time", RecipeScheduling.due(friday4, lastRun: now, now: now.addingTimeInterval(60), calendar: cal) == nil)
        check("recipes: the schedule reads as words", friday4.label == "Every Friday at 4:00 PM" && friday4.shortLabel == "Fridays, 4:00 PM")
        let r = AskRecipe(question: "Weekly digest of my thoughts", scope: AskScope(range: .thisWeek, source: .thoughts), createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        check("recipes: a recipe round-trips for sync", (try? enc.encode([r])).flatMap { try? dec.decode([AskRecipe].self, from: $0) } == [r])
        check("samples: the screenshots' answer cites three passages", sampleResult(lib, device: "Mac")?.answer?.citations.count == 3)
        check("samples: the screenshots' digest has a heading and three items", sampleDigest(lib, question: "Q", scope: .all, device: "Mac")?.answer?.blocks.count == 4)
        check("recipes: three suggestions, none seeded", RecipeSuggestions.all(projects: [(project, "Website refresh")]).map(\.question)
              == ["Weekly digest of my thoughts", "Action items from this week\u{2019}s meetings", "What did I say about Website refresh"])
    }
}
