import Foundation

// Tests for NetworkActivity.swift (Local Only, the gate, the activity log, the data path badge), CorrectEverywhere.swift
// (Fix all), and DictionaryCSV.swift. Not part of any app target; run mac/tools/test-privacy.sh.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name)\(detail().isEmpty ? "" : "\n  " + detail())") }
}
func eq<T: Equatable>(_ name: String, _ a: T, _ b: T) { check(name, a == b, "got \(a)\n  expected \(b)") }

// MARK: Hosts: never a path, query, sign-in, or port

eq("host from a link", NetworkHost.of("https://www.YouTube.com/watch?v=abc&t=10s"), "youtube.com")
eq("host drops sign-in and port", NetworkHost.of("https://user:secret@Example.com:8443/a/b?key=1"), "example.com")
eq("host of a bare host", NetworkHost.of("api.anthropic.com"), "api.anthropic.com")
eq("clean drops a path", NetworkHost.clean("huggingface.co/FluidInference/model"), "huggingface.co")
eq("clean keeps a name", NetworkHost.clean("Apple"), "Apple")
eq("host of nil URL", NetworkHost.of(nil as URL?), "")
eq("event stores the clean host", NetworkEvent(purpose: .linkDownload, host: "https://vimeo.com/123?h=secret").host, "vimeo.com")

// MARK: Local Only and the gate

do {
    let d = UserDefaults(suiteName: "privacy-tests-\(UUID().uuidString)")!
    LocalOnly.defaults = d
    let log = NetworkActivityLog(file: nil)
    NetworkGate.log = log
    check("Local Only is off by default", !LocalOnly.isOn)
    check("everything is permitted when off", NetworkPurpose.allCases.allSatisfy { LocalOnly.permits($0) })
    let id = try? NetworkGate.begin(.cloudCleanup, host: "api.anthropic.com")
    check("an allowed request is logged", id != nil && log.events.first?.purpose == .cloudCleanup && log.events.first?.refused == false)
    NetworkGate.addBytes(id ?? nil, 1200)
    NetworkGate.addBytes(id ?? nil, 300)
    eq("bytes add up", log.events.first?.bytes, 1500)

    LocalOnly.isOn = true
    check("Local Only refuses every purpose", NetworkPurpose.allCases.allSatisfy { !LocalOnly.permits($0) })
    do {
        _ = try NetworkGate.begin(.linkDownload, host: "https://youtube.com/watch?v=x")
        check("a refused request throws", false)
    } catch let r as LocalOnlyRefusal {
        eq("refusal says what to do", r.localizedDescription, "Local Only is on. Turn it off in Settings › Privacy to download this link.")
    } catch {
        check("refusal type", false, "\(error)")
    }
    check("a refusal is logged as refused, host only", log.events.first?.refused == true && log.events.first?.host == "youtube.com")
    check("model refusal is recognized", LocalOnlyRefusal.isModelRefusal(LocalOnlyRefusal(purpose: .modelDownload).errorDescription))
    check("other refusals aren't model refusals", !LocalOnlyRefusal.isModelRefusal(LocalOnly.message(.linkDownload)))

    let now = Date()
    LocalOnly.allowModelDownloads(for: 600, now: now)
    check("Allow this download lets models through", LocalOnly.permits(.modelDownload, now: now.addingTimeInterval(10)))
    check("but nothing else", !LocalOnly.permits(.linkDownload, now: now) && !LocalOnly.permits(.cloudCleanup, now: now) && !LocalOnly.permits(.updateCheck, now: now))
    check("the allowance ends", !LocalOnly.permits(.modelDownload, now: now.addingTimeInterval(601)))
    check("and stays ended", !LocalOnly.permits(.modelDownload, now: now.addingTimeInterval(10)))

    check("a model isn't ready until it has loaded", !LocalOnly.modelReady("vad"))
    LocalOnly.markModelReady("vad")
    check("a loaded model is ready", LocalOnly.modelReady("vad"))
    LocalOnly.isOn = false
    LocalOnly.defaults = .standard
    NetworkGate.log = nil
}

// MARK: The log: ring, file, and tolerance

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-tests-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("network-activity.json")
    let log = NetworkActivityLog(file: file)
    for i in 0..<(NetworkActivityLog.cap + 25) { log.add(.modelDownload, host: "huggingface.co", bytes: Int64(i)) }
    eq("the ring keeps 500", log.events.count, 500)
    eq("newest first", log.events.first?.bytes, Int64(NetworkActivityLog.cap + 24))
    eq("oldest dropped", log.events.last?.bytes, 25)
    log.flush()
    let back = NetworkActivityLog(file: file)
    eq("the file round-trips", back.events.map(\.id), log.events.map(\.id))
    back.clear(); back.flush()
    eq("Clear empties the log and the file", NetworkActivityLog(file: file).events.count, 0)

    let mixed = #"[{"id":"7B0E7E0A-1C2B-4D6E-9F00-000000000001","date":"2026-10-22T14:03:00Z","purpose":"updateCheck","host":"raw.githubusercontent.com"},{"date":"2026-10-22T14:04:00Z","purpose":"telepathy","host":"x.com"},{"purpose":"linkDownload","host":"vimeo.com/1?x=2","bytes":10,"refused":true}]"#
    let read = NetworkActivityLog.decode(Data(mixed.utf8))
    eq("unknown purposes are skipped, not the file", read.map(\.purpose), [.updateCheck, .linkDownload])
    eq("hosts are cleaned when read", read.last?.host, "vimeo.com")
    check("refused and bytes read back", read.last?.refused == true && read.last?.bytes == 10)
    eq("garbage reads as empty", NetworkActivityLog.decode(Data("not json".utf8)).count, 0)
    let encoded = String(data: NetworkActivityLog.encode([NetworkEvent(purpose: .cloudCleanup, host: "api.openai.com")]) ?? Data(), encoding: .utf8) ?? ""
    check("the file holds no paths", !encoded.contains("/v1/") && encoded.contains("api.openai.com"))
    try? FileManager.default.removeItem(at: dir)
}

// MARK: Data path badge

eq("local", DataPath.badge(linkHost: nil, cloudCleanup: nil), "Local audio · local text")
eq("cloud cleanup", DataPath.badge(linkHost: nil, cloudCleanup: "Anthropic"), "Local audio · cloud cleanup (Anthropic)")
eq("link", DataPath.badge(linkHost: "www.youtube.com", cloudCleanup: ""), "Audio from youtube.com · local text")
check("left device", DataPath.leftDevice(linkHost: "vimeo.com", cloudCleanup: nil) && !DataPath.leftDevice(linkHost: "", cloudCleanup: nil))
eq("bytes text", ByteText.format(nil), nil)
check("bytes text formats", ByteText.format(1_400_000) != nil)

// MARK: Fix all

do {
    let text = "Teh cat and teh dog. TEH end. Tehran stays, and so does steh."
    eq("whole words, any case", CorrectEverywhere.ranges(of: "teh", in: text).count, 3)
    let c = CorrectEverywhere.changes(heard: "teh", fix: "the", in: text)
    eq("case kept", c.map(\.with), ["The", "the", "THE"])
    eq("found text kept", c.map(\.found), ["Teh", "teh", "TEH"])
    eq("capitalized fix stays capitalized", CorrectEverywhere.casePreserved("Jon", for: "jon"), "Jon")
    eq("single capital letter isn't all caps", CorrectEverywhere.casePreserved("a", for: "I"), "A")
    eq("phrases match across spaces", CorrectEverywhere.ranges(of: "new  york", in: "I love New York and new york.").count, 2)
    eq("places already fixed are skipped", CorrectEverywhere.changes(heard: "apple", fix: "Apple", in: "apple and Apple").map(\.found), ["apple"])
    eq("count across lines", CorrectEverywhere.count(heard: "teh", fix: "the", in: ["teh", "no", "Teh teh"]), 3)
    eq("no count for an empty word", CorrectEverywhere.count(heard: " ", fix: "x", in: ["x"]), 0)
    eq("no count for the same word", CorrectEverywhere.count(heard: "x", fix: "x", in: ["x"]), 0)
    eq("punctuation around a word", CorrectEverywhere.ranges(of: "verbatum", in: "(Verbatum), verbatum's, verbatum.").count, 3)
    eq("accented letters are word characters", CorrectEverywhere.ranges(of: "cafe", in: "café cafe").count, 1)
    eq("button title", CorrectEverywhere.buttonTitle(4), "Fix all 4")
    eq("button title for one", CorrectEverywhere.buttonTitle(1), "Fix 1 more")
    eq("banner", CorrectEverywhere.bannerText(heard: "teh", count: 4), "“teh” appears 4 more times in this transcript.")
}

// MARK: Dictionary CSV

do {
    let rows = [
        DictionaryCSV.Row(heard: ["verbatum", "verba tim"], replacement: "Verbatim", enabled: true, project: nil, learnedFrom: "Added by you",
                          created: Date(timeIntervalSince1970: 1_792_677_780)),
        DictionaryCSV.Row(heard: ["tim, medina"], replacement: "Tim \"T\" Medina", enabled: false, project: "Star Quality", learnedFrom: nil, created: nil),
        DictionaryCSV.Row(heard: ["=cmd"], replacement: "+plus", enabled: true),
    ]
    let csv = DictionaryCSV.export(rows)
    check("header first", csv.hasPrefix("heard,replacement,enabled,project,learned_from,created\r\n"))
    check("quotes commas and quotes", csv.contains("\"tim, medina\",\"Tim \"\"T\"\" Medina\",false,Star Quality,,"))
    check("formula guard", csv.contains("'=cmd,'+plus"))
    let back = DictionaryCSV.parse(csv)
    eq("round trip", back.rows, rows)
    eq("no invalid rows", back.invalid, 0)

    let loose = "Word,Heard As\r\nGitHub,git hub; get hub\n\nChatGPT,\n,orphan\n\"Multi\nline\",x\n"
    let p = DictionaryCSV.parse(loose)
    eq("header aliases in any order", p.rows.first, DictionaryCSV.Row(heard: ["git hub", "get hub"], replacement: "GitHub"))
    eq("quoted line breaks", p.rows.last?.replacement, "Multi\nline")
    eq("rows without a word are counted", p.invalid, 2)
    eq("no header: heard, replacement", DictionaryCSV.parse("teh,the\nrecieve,receive").rows.map(\.replacement), ["the", "receive"])
    eq("byte order mark", DictionaryCSV.parse("\u{FEFF}heard,replacement\na,b").rows.count, 1)
    eq("enabled words", DictionaryCSV.parse("heard,replacement,enabled\na,b,no\nc,d,yes").rows.map(\.enabled), [false, true])
    eq("heard forms dedupe", DictionaryCSV.splitHeard("A | a ; b"), ["A", "b"])

    let existing = [DictionaryCSV.Row(heard: ["verbatum"], replacement: "Verbatim")]
    let incoming = [
        DictionaryCSV.Row(heard: ["VERBATUM"], replacement: "verbatim"),                     // already there
        DictionaryCSV.Row(heard: ["verba tim"], replacement: "Verbatim"),                    // a new heard form
        DictionaryCSV.Row(heard: ["git hub"], replacement: "GitHub"),                        // new
        DictionaryCSV.Row(heard: ["get hub", "git hub"], replacement: "GitHub"),             // repeat in the file
        DictionaryCSV.Row(heard: ["verbatum"], replacement: "Verbatim", project: "Work"),    // another project
    ]
    let (steps, report) = DictionaryCSV.plan(existing: existing, incoming: incoming)
    eq("plan steps", steps, [.skip, .addHeard(index: 0, ["verba tim"]), .add(DictionaryCSV.Row(heard: ["git hub", "get hub"], replacement: "GitHub")), .skip,
                             .add(DictionaryCSV.Row(heard: ["verbatum"], replacement: "Verbatim", project: "Work"))])
    eq("report counts", report, DictionaryCSV.Report(added: 2, updated: 1, skipped: 1, invalid: 0))
    var r = report; r.invalid = 1
    eq("report summary", r.summary, "Added 2 words, updated 1, skipped 1 already in your Dictionary, skipped 1 line without a word.")
}

print("privacy tests: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
