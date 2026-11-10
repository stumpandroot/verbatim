import Foundation

/// Self-tests for clean while you talk (`PreClean`, `PreCleanAudio`, `PreCleanSession`), with a stand-in for the
/// model. Foundation only: the Mac self-test (`DictationPolishChecks`) and `mac/tools/test-preclean.sh` run them.
enum PreCleanChecks {
    struct Result {
        let name: String
        let ok: Bool
        let detail: String
    }

    private static let one = "I sent the draft to the client this morning."
    private static let two = "They want two more rounds of changes before Friday."
    private static let three = "After that we can book the crew for the shoot."
    private static let four = "Let me know if the budget still works for you."

    /// The sealing, matching, and pacing rules.
    static func run() -> [Result] {
        var out: [Result] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            out.append(Result(name: name, ok: ok, detail: ok ? "" : detail()))
        }
        func ends(_ s: String) -> [String] {
            let c = Array(s)
            var from = 0
            var parts: [String] = []
            for e in PreClean.sentenceEnds(c) { parts.append(String(c[from..<e]).trimmingCharacters(in: .whitespacesAndNewlines)); from = e }
            parts.append(String(c[from...]).trimmingCharacters(in: .whitespacesAndNewlines))
            return parts
        }
        func texts(_ p: [PreClean.Part]) -> [String] { p.map(\.text) }

        // Sentences
        check("sentences: a period, a question mark, and an exclamation point end one",
              ends("We shipped it. Did you see? It works! Good") == ["We shipped it.", "Did you see?", "It works!", "Good"], "\(ends("We shipped it. Did you see? It works! Good"))")
        check("sentences: abbreviations don't end one",
              ends("Bring snacks, e.g. Pretzels and dip. Dr. Lane will join. Ask Mr. Hale etc. Then go.") == ["Bring snacks, e.g. Pretzels and dip.", "Dr. Lane will join.", "Ask Mr. Hale etc. Then go."],
              "\(ends("Bring snacks, e.g. Pretzels and dip. Dr. Lane will join. Ask Mr. Hale etc. Then go."))")
        check("sentences: decimals, bare numbers, and initials don't end one",
              ends("It grew 3.5 percent. Call J. Lane at 2. Then rest.") == ["It grew 3.5 percent.", "Call J. Lane at 2. Then rest."],
              "\(ends("It grew 3.5 percent. Call J. Lane at 2. Then rest."))")
        check("sentences: an ellipsis doesn't end one",
              ends("I was thinking... Maybe not. Or… Maybe so.") == ["I was thinking... Maybe not.", "Or… Maybe so."], "\(ends("I was thinking... Maybe not. Or… Maybe so."))")
        check("sentences: a lowercase word after a period carries the sentence on, except a mixed-case word",
              ends("We met at noon. and then left. iPhone first. Then the Mac.") == ["We met at noon. and then left.", "iPhone first.", "Then the Mac."],
              "\(ends("We met at noon. and then left. iPhone first. Then the Mac."))")
        check("sentences: quotes close with the sentence, and a paragraph break is a break after a mark",
              ends("She said \"go.\" Then we left.\n\nNext topic") == ["She said \"go.\"", "Then we left.", "Next topic"], "\(ends("She said \"go.\" Then we left.\n\nNext topic"))")
        check("sentences: text without sentence punctuation has no breaks",
              PreClean.sentenceEnds(Array("so we went to the store and then we went home and then we ate dinner and nothing else happened at all")).isEmpty
                && PreClean.sentenceEnds(Array("हम कल बाज़ार गए थे और फिर घर लौट आए और खाना खाया")).isEmpty)
        check("sentences: full-width marks end one without a space",
              ends("今日は会議があります。明日は休みです。また来週") == ["今日は会議があります。", "明日は休みです。", "また来週"], "\(ends("今日は会議があります。明日は休みです。また来週"))")

        // Sealing
        let a = PreClean.seal(sealed: [], snapshot: "\(one) \(two) After that we")
        check("seal: finished sentences form one part, and the last sentence is never sealed",
              a == [PreClean.Part(sep: "", text: "\(one) \(two)")], "\(a)")
        check("seal: one sentence so far seals nothing, and a short one waits",
              PreClean.seal(sealed: [], snapshot: one).isEmpty && texts(PreClean.seal(sealed: [], snapshot: "\(one) They want")) == [one]
                && PreClean.seal(sealed: [], snapshot: "I sent it. They want").isEmpty)
        let b = PreClean.seal(sealed: a, snapshot: "\(one) \(two) \(three) \(four) And one more")
        check("seal: a longer snapshot seals only what's new", b == [PreClean.Part(sep: " ", text: "\(three) \(four)")], "\(b)")
        check("seal: the same snapshot again seals nothing new", PreClean.seal(sealed: a, snapshot: "\(one) \(two) After that we").isEmpty)
        check("seal: a snapshot that rewrites earlier text seals nothing new",
              PreClean.seal(sealed: a, snapshot: "I sent the draft to the client this evening. \(two) \(three) \(four) And more").isEmpty)
        check("seal: a snapshot where a sealed sentence carries on seals nothing new",
              PreClean.seal(sealed: a, snapshot: "\(one) \(two) and \(three) \(four) And more").isEmpty)
        check("seal: fewer than 8 new words wait for the next sentence",
              PreClean.seal(sealed: a, snapshot: "\(one) \(two) Sounds good. And then").isEmpty
                && texts(PreClean.seal(sealed: a, snapshot: "\(one) \(two) Sounds good. \(three) And then")) == ["Sounds good. \(three)"])
        check("seal: a break before a correction isn't sealed",
              texts(PreClean.seal(sealed: [], snapshot: "\(one) The call is at nine tomorrow morning for everyone. Actually, wait, eleven")) == [one]
                && PreClean.seal(sealed: [], snapshot: "The call is at nine tomorrow morning for everyone. Scratch that").isEmpty)
        let p = PreClean.seal(sealed: [], snapshot: "\(one) \(two)\n\n\(three) \(four) And")
        check("seal: a paragraph break inside a part is kept as written", texts(p) == ["\(one) \(two)\n\n\(three) \(four)"], "\(p)")
        let q = PreClean.seal(sealed: a, snapshot: "\(one) \(two)\n\n\(three) \(four) And")
        check("seal: a part remembers the break before it", q == [PreClean.Part(sep: "\n\n", text: "\(three) \(four)")], "\(q)")
        let long = (0..<700).map { _ in "word" }.joined(separator: " ")
        check("seal: a very long sentence without punctuation is never sealed",
              PreClean.seal(sealed: [], snapshot: long).isEmpty && PreClean.seal(sealed: [], snapshot: "\(long). \(one) \(two) And").isEmpty)
        let many = (0..<80).map { "Sentence number \($0) has exactly eight words in it." }.joined(separator: " ")
        let split = PreClean.seal(sealed: [], snapshot: many + " And")
        check("seal: a long run is split into parts of at most 2,500 characters at sentence breaks",
              split.count == 2 && split.allSatisfy { $0.text.count <= PreClean.maxPartCharacters && $0.text.hasSuffix(".") }
                && split.map { $0.sep + $0.text }.joined() == many, "\(split.map { $0.text.count })")
        let wide = PreClean.seal(sealed: [], snapshot: "今日は会議があります。明日は休みです。来週また連絡しますのでよろしくお願いします。資料は")
        check("seal: writing without spaces is measured in characters", wide.map(\.text) == ["今日は会議があります。明日は休みです。来週また連絡しますのでよろしくお願いします。"]
                && PreClean.seal(sealed: [], snapshot: "今日は会議です。明日は").isEmpty, "\(wide)")
        check("seal: text in a language without sentence marks is never sealed",
              PreClean.seal(sealed: [], snapshot: "हम कल बाज़ार गए थे और फिर घर लौट आए और खाना खाया और सो गए").isEmpty)

        // Matching
        let parts = a + b
        let done = parts.map { PreClean.Outcome(text: "<" + $0.text + ">", cleaned: true, note: nil) }
        let full = "\(one) \(two) \(three) \(four) And one more thing."
        check("match: every sealed part at the start of the final text is reusable", PreClean.reusable(parts, in: full) == 2)
        let h = PreClean.hit(parts, outcomes: done, count: 2, in: full)
        check("match: the remainder is what follows the reused parts",
              h?.remainder == "And one more thing." && h?.remainderSep == " " && h?.text == "<\(one) \(two)> <\(three) \(four)>", "\(String(describing: h))")
        check("match: a mismatch in the middle reuses only the parts before it",
              PreClean.reusable(parts, in: "\(one) \(two) \(three) Let me know if the budget still works for them. And") == 1
                && PreClean.reusable(parts, in: "I sent the draft to the client last night. \(two) \(three) \(four)") == 0)
        check("match: a correction that removed sealed text reuses nothing after it",
              PreClean.reusable(parts, in: "\(one) \(three) \(four) And") == 0 && PreClean.reusable(parts, in: "And one more thing.") == 0
                && PreClean.reusable(parts, in: "") == 0)
        check("match: a part whose last sentence carried on isn't reused",
              PreClean.reusable(parts, in: "\(one) \(two) \(three) \(four) and one more thing.") == 1
                && PreClean.reusable(parts, in: "\(one) \(two) \(three) \(four)... And") == 1)
        check("match: a correction right after a part sends that part back to the model",
              PreClean.reusable(parts, in: "\(one) \(two) \(three) \(four) Actually, make that Thursday.") == 1
                && PreClean.reusable(parts, in: "\(one) \(two) Scratch that.") == 0)
        let para = PreClean.hit(parts, outcomes: done, count: 2, in: "\(one) \(two)\n\n\(three) \(four)\n\nAnd one more thing.")
        check("match: breaks between parts come from the final text",
              para?.text == "<\(one) \(two)>\n\n<\(three) \(four)>" && para?.remainderSep == "\n\n" && para?.remainder == "And one more thing.", "\(String(describing: para))")
        check("match: a break inside a part must be the same",
              PreClean.reusable(p, in: "\(one) \(two) \(three) \(four) And") == 0 && PreClean.reusable(p, in: "\(one) \(two)\n\n\(three) \(four) And") == 1)
        let whole = PreClean.hit(parts, outcomes: done, count: 2, in: "\(one) \(two) \(three) \(four)")
        check("match: nothing left over means no model call", whole?.remainder == "" && whole?.remainderSep == "" && whole?.parts.count == 2, "\(String(describing: whole))")
        let kept = [PreClean.Outcome(text: parts[0].text, cleaned: false, note: "Kept your words: a number changed"), done[1]]
        let mixed = PreClean.hit(parts, outcomes: kept, count: 2, in: full)
        check("match: a part the model didn't clean keeps its rule-based text and its note",
              mixed?.text == "\(one) \(two) <\(three) \(four)>" && mixed?.note == "Kept your words: a number changed" && mixed?.cleanedAny == true)
        check("match: parts that aren't at the start give no hit", PreClean.hit(parts, outcomes: done, count: 2, in: "\(one) \(two) Something else. \(four)") == nil
                && PreClean.hit(parts, outcomes: done, count: 0, in: full) == nil)

        // The switch and where it may run
        func allowed(flag: Bool = true, engine: String = "fluid", command: Bool = false, thought: Bool = false, usesModel: Bool = true,
                     codeApp: Bool = false, cloud: Bool = false, model: Bool = true) -> Bool {
            PreClean.allowed(flag: flag, engine: engine, command: command, thought: thought, usesModel: usesModel, codeApp: codeApp,
                             cloudCleanup: cloud, modelAvailable: model)
        }
        check("switch: on for an ordinary dictation with Apple's model", allowed())
        check("switch: off means nothing runs while you talk",
              !allowed(flag: false) && !PreClean.mayStart(flag: false, engine: "fluid", command: false, usesModel: true))
        check("switch: never with cloud cleanup, so no words leave the Mac before you let go", !allowed(cloud: true))
        check("switch: never in command mode, for a thought, at Literal, in code apps, with another engine, or without the model",
              !allowed(command: true) && !allowed(thought: true) && !allowed(usesModel: false) && !allowed(codeApp: true)
                && !allowed(engine: "whisper") && !allowed(model: false))

        // Pacing
        typealias P = PreClean.Pacing
        check("pacing: a pause after 4 s of new speech takes a snapshot",
              P.shouldSnapshot(total: 6, lastSnapshotAt: 0, speechSince: 5, trailingSilence: 0.7)
                && !P.shouldSnapshot(total: 6, lastSnapshotAt: 0, speechSince: 5, trailingSilence: 0.3)
                && !P.shouldSnapshot(total: 6, lastSnapshotAt: 0, speechSince: 3, trailingSilence: 0.7))
        check("pacing: never more often than every 3 s, and less often as the dictation grows",
              !P.shouldSnapshot(total: 9, lastSnapshotAt: 7, speechSince: 5, trailingSilence: 1)
                && P.interval(total: 20) == 3 && P.interval(total: 120) == 12
                && !P.shouldSnapshot(total: 120, lastSnapshotAt: 112, speechSince: 7, trailingSilence: 1)
                && P.shouldSnapshot(total: 120, lastSnapshotAt: 107, speechSince: 7, trailingSilence: 1))
        check("pacing: without a pause, 12 s of speech takes one anyway",
              P.shouldSnapshot(total: 14, lastSnapshotAt: 0, speechSince: 12.5, trailingSilence: 0)
                && !P.shouldSnapshot(total: 14, lastSnapshotAt: 0, speechSince: 9, trailingSilence: 0))
        check("pacing: no snapshots past 5 minutes", !P.shouldSnapshot(total: 301, lastSnapshotAt: 200, speechSince: 60, trailingSilence: 2))

        // The audio so far
        let audio = PreCleanAudio()
        func feed(_ seconds: Double, level: Int16) {
            let block = [Int16](repeating: 0, count: 1_600).enumerated().map { $0.offset % 2 == 0 ? level : -level }
            for _ in 0..<Int(seconds * 10) { block.withUnsafeBufferPointer { audio.append($0) } }
        }
        feed(5, level: 4_000)
        check("audio: speech counts as speech", audio.status.total == 5 && audio.status.speechSince == 5 && audio.status.trailingSilence == 0, "\(audio.status)")
        feed(0.8, level: 20)
        check("audio: quiet after speech is a pause", abs(audio.status.trailingSilence - 0.8) < 0.001 && audio.status.speechSince == 5, "\(audio.status)")
        let snap = audio.snapshot()
        check("audio: a snapshot is everything so far, and the recording goes on",
              snap?.count == 92_800 && abs((snap?.first ?? 0) - 4_000.0 / 32_768) < 0.000_1 && audio.status.speechSince == 0 && audio.status.lastSnapshotAt == 5.8,
              "\(snap?.count ?? -1) \(audio.status)")
        feed(2, level: 4_000)
        check("audio: a later snapshot starts from the beginning again", audio.snapshot()?.count == 124_800)
        audio.stop()
        feed(1, level: 4_000)
        check("audio: stopping lets go of the audio and takes no more", audio.snapshot() == nil && audio.status.over)
        let capped = PreCleanAudio()
        let second = [Int16](repeating: 3_000, count: 16_000)
        for _ in 0..<301 { second.withUnsafeBufferPointer { capped.append($0) } }
        check("audio: past 5 minutes it lets go of the audio", capped.status.over && capped.snapshot() == nil)

        check("log: counts only",
              PreClean.Stats(sealed: 3, reused: 2, remainderCharacters: 41).logLine == "dictation pre-clean: 3 parts sealed, 2 reused, remainder 41 chars"
                && PreClean.Stats(sealed: 1, reused: 0, remainderCharacters: 80, waited: 0.5).logLine == "dictation pre-clean: 1 part sealed, 0 reused, remainder 80 chars, waited 0.50 s")
        return out
    }

    /// Counts the stand-in model's calls and lets a test hold one open.
    private final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(text: String, first: Bool)] = []
        private var held = false
        private var cancelledCalls = 0
        var calls: [(text: String, first: Bool)] { lock.lock(); defer { lock.unlock() }; return seen }
        var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancelledCalls }
        func hold(_ on: Bool) { lock.lock(); held = on; lock.unlock() }
        private var holding: Bool { lock.lock(); defer { lock.unlock() }; return held }
        private func record(_ text: String, _ first: Bool) { lock.lock(); seen.append((text, first)); lock.unlock() }
        private func noteCancelled() { lock.lock(); cancelledCalls += 1; lock.unlock() }

        func clean(_ text: String, _ first: Bool) async -> PreClean.Outcome? {
            record(text, first)
            while holding {
                if Task.isCancelled { noteCancelled(); return nil }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return PreClean.Outcome(text: "<" + text + ">", cleaned: true, note: nil)
        }
    }

    private static func settle(_ done: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await done() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// One dictation's session, from snapshots to letting go, with a stand-in for the model.
    static func runSession() async -> [Result] {
        var out: [Result] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            out.append(Result(name: name, ok: ok, detail: ok ? "" : detail()))
        }
        let first = "\(one) \(two)"
        let second = "\(three) \(four)"
        let full = "\(first) \(second) And one more thing."

        // Growing snapshots, then letting go.
        do {
            let stub = Stub()
            let s = PreCleanSession(clean: { await stub.clean($0, $1) })
            await s.start(key: "k")
            await s.offer("\(first) After that we")
            await s.offer("\(first) \(second) And one")
            let cleanedBoth = await settle { stub.calls.count == 2 }
            _ = await settle { await s.stats().sealed == 2 }
            try? await Task.sleep(nanoseconds: 30_000_000)
            let hit = await s.reuse(pre: full, key: "k", wait: 1)
            let stats = await s.stats()
            check("session: finished sentences are cleaned as you talk, the first part with context",
                  cleanedBoth && stub.calls.map(\.text) == [first, second] && stub.calls.map(\.first) == [true, false], "\(stub.calls)")
            check("session: letting go reuses them and leaves the last sentence for the model",
                  hit?.text == "<\(first)> <\(second)>" && hit?.remainder == "And one more thing." && stats.sealed == 2 && stats.reused == 2
                    && stats.remainderCharacters == 19, "\(String(describing: hit)) \(stats)")
            let again = await s.reuse(pre: full, key: "k", wait: 0)
            await s.offer("\(full) \(one) \(two) And")
            check("session: it serves one dictation once", again == nil && stub.calls.count == 2)
        }

        // A final text that changed part way.
        do {
            let stub = Stub()
            let s = PreCleanSession(clean: { await stub.clean($0, $1) })
            await s.start(key: "k")
            await s.offer("\(first) After that we")
            await s.offer("\(first) \(second) And one")
            _ = await settle { stub.calls.count == 2 }
            try? await Task.sleep(nanoseconds: 30_000_000)
            let hit = await s.reuse(pre: "\(first) After that we can book the crew for the reshoot. \(four) And", key: "k", wait: 0)
            let stats = await s.stats()
            check("session: a change in the middle reuses only the parts before it",
                  hit?.parts.count == 1 && hit?.remainder.hasPrefix("After that we can book the crew for the reshoot.") == true && stats.reused == 1 && stats.sealed == 2,
                  "\(String(describing: hit))")
        }

        // Settings that changed, and a final text that doesn't start the same.
        do {
            let stub = Stub()
            let s = PreCleanSession(clean: { await stub.clean($0, $1) })
            await s.start(key: "k")
            await s.offer("\(first) After that we")
            _ = await settle { stub.calls.count == 1 }
            let other = await s.reuse(pre: full, key: "another app", wait: 0)
            check("session: parts cleaned for other settings aren't reused", other == nil)
            let t = PreCleanSession(clean: { await stub.clean($0, $1) })
            await t.start(key: "k")
            await t.offer("\(first) After that we")
            _ = await settle { stub.calls.count == 2 }
            let miss = await t.reuse(pre: "Let me start again from the top. \(second)", key: "k", wait: 0)
            let stats = await t.stats()
            check("session: a final text that starts differently is a miss", miss == nil && stats.reused == 0 && stats.sealed == 1)
        }

        // Not started (the switch is off, or the dictation isn't one it runs for): nothing happens.
        do {
            let stub = Stub()
            let s = PreCleanSession(clean: { await stub.clean($0, $1) })
            await s.offer("\(first) After that we")
            try? await Task.sleep(nanoseconds: 20_000_000)
            let hit = await s.reuse(pre: full, key: "k", wait: 0)
            let stats = await s.stats()
            check("session: off, nothing is cleaned ahead and cleanup runs as before", hit == nil && stub.calls.isEmpty && stats == PreClean.Stats(sealed: 0, reused: 0, remainderCharacters: 0))
        }

        // Cancel while a part is being cleaned.
        do {
            let stub = Stub()
            stub.hold(true)
            let s = PreCleanSession(clean: { await stub.clean($0, $1) })
            await s.start(key: "k")
            await s.offer("\(first) \(second) And one")
            _ = await settle { stub.calls.count == 1 }
            await s.cancel()
            let stopped = await settle { stub.cancelled == 1 }
            await s.offer("\(first) \(second) \(one) \(two) And")
            let hit = await s.reuse(pre: full, key: "k", wait: 0.2)
            stub.hold(false)
            try? await Task.sleep(nanoseconds: 30_000_000)
            check("session: cancel stops the model call in flight", stopped)
            check("session: after cancel nothing is cleaned or reused", hit == nil && stub.calls.count == 1, "\(stub.calls.count)")
        }

        // Letting go while a part is still being cleaned.
        do {
            let stub = Stub()
            stub.hold(true)
            let s = PreCleanSession(clean: { await stub.clean($0, $1) })
            await s.start(key: "k")
            await s.offer("\(first) \(second) And one")
            _ = await settle { stub.calls.count == 1 }
            let t0 = Date()
            let hit = await s.reuse(pre: full, key: "k", wait: 0.15)
            let took = Date().timeIntervalSince(t0)
            let stopped = await settle { stub.cancelled == 1 }
            stub.hold(false)
            let stats = await s.stats()
            check("session: a part still being cleaned is waited for only as long as allowed, then left to the model",
                  hit == nil && took >= 0.14 && took < 1 && stopped && stats.reused == 0 && stats.waited >= 0.14, "\(took)")

            let quick = Stub()
            quick.hold(true)
            let u = PreCleanSession(clean: { await quick.clean($0, $1) })
            await u.start(key: "k")
            await u.offer("\(first) \(second) And one")
            _ = await settle { quick.calls.count == 1 }
            Task { try? await Task.sleep(nanoseconds: 60_000_000); quick.hold(false) }
            let late = await u.reuse(pre: full, key: "k", wait: 2)
            check("session: a part that finishes during the wait is reused", late?.parts.count == 1 && late?.remainder == "And one more thing.", "\(String(describing: late))")
        }

        // A model that gives no answer.
        do {
            let s = PreCleanSession(clean: { _, _ in nil })
            await s.start(key: "k")
            await s.offer("\(first) After that we")
            try? await Task.sleep(nanoseconds: 40_000_000)
            await s.offer("\(first) \(second) And one")
            let hit = await s.reuse(pre: full, key: "k", wait: 0.5)
            let stats = await s.stats()
            check("session: a part the model couldn't answer is left to the release, with no wait", hit == nil && stats.waited < 0.1 && stats.reused == 0, "\(stats)")
        }
        return out
    }
}
