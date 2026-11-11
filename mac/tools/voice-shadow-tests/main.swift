import Foundation

// "Only keep my voice in dictation" and its shadow mode (Verbatim/Model/VoiceShadow.swift): the decision the real
// filter and shadow mode share, the numbers kept per dictation, the stored list's cap, when shadow mode runs, and the
// threshold report (VoiceShadowChecks, which the Mac's self-test also runs). Then the sources: the filter and shadow
// mode go through the one decision, shadow scoring starts only after the paste, nothing but numbers is stored or
// logged, and deleting the voice profile deletes the records. Reads the Swift sources from the mac/ folder given as
// the first argument. Not part of any app target; run mac/tools/test-voice-shadow.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

VoiceShadowChecks.run { check($0, $1) }

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String {
    guard let s = try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8) else {
        print("FAIL  can't read \(path)"); exit(1)
    }
    return s
}

/// The text of a declaration, from it to the next declaration at the same indent.
func body(_ text: String, _ decl: String) -> String {
    guard let r = text.range(of: decl) else { return "" }
    let rest = text[r.lowerBound...]
    let tail = rest.dropFirst(decl.count)
    let ends = ["\n    func ", "\n    private func ", "\n    private var ", "\n    static func ", "\n    @discardableResult", "\n    private static func ",
                "\n    /// "].compactMap { tail.range(of: $0)?.lowerBound }
    return String(ends.min().map { rest[..<$0] } ?? rest)
}
func before(_ a: String, _ b: String, in text: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

let profile = read("Verbatim/Transcription/VoiceProfile.swift")
let dictation = read("Verbatim/App/Dictation.swift")

let gate = body(profile, "static func gate(")
check("sources: the filter's words come from the shared decision, and nowhere else",
      gate.contains("VoiceGate.decide(") && body(profile, "static func keepUserWords(").contains("gate(segments, turns: turns, embeddings: embeddings).kept")
      && (profile.components(separatedBy: "enum VoiceShadowStore").first ?? "").components(separatedBy: "VoiceGate.decide(").count == 2, gate)
let run = body(profile, "private static func gateDictation(")
check("sources: the real filter and shadow mode run the same scoring",
      run.contains("VoiceGate.minClipSeconds") && run.contains("diarizeDetailed(") && run.contains("return gate(")
      && body(profile, "static func filterDictation(").contains("await gateDictation(")
      && body(profile, "static func shadowDictation(").contains("await gateDictation("))
let filter = body(profile, "static func filterDictation(")
check("sources: the real filter still runs only with the setting on, and fails open",
      before("guard dictationFilterEnabled", "gateDictation(", in: filter) && filter.contains("return run.kept"), filter)
let shadow = body(profile, "static func shadowDictation(")
check("sources: shadow mode returns nothing, so it can't change a dictation's words", shadow.contains(") async {") && !shadow.contains("return run.kept")
      && !shadow.contains("-> [Segment]"), shadow)
check("sources: shadow mode checks the kill switch, the profile, the length, and low power before it scores",
      before("VoiceShadowRules.skip(", "gateDictation(", in: shadow) && shadow.contains("VoiceShadowRules.enabled(.standard)")
      && shadow.contains("isLowPowerModeEnabled"), shadow)

let store = profile.range(of: "enum VoiceShadowStore").map { String(profile[$0.lowerBound...]) } ?? ""
check("sources: the records sit beside the voice profile, on this device only",
      store.contains("VoiceProfile.fileURL.deletingLastPathComponent()") && profile.contains("Paths.local.appendingPathComponent(\"voice\"")
      && !store.contains("Paths.root") && !store.contains("Cloud.") && store.contains("isExcludedFromBackup = true"))
check("sources: the stored list is capped by the rules, and nothing is added without a profile",
      store.contains("VoiceShadowRules.appending(") && store.contains("guard VoiceProfile.isEnrolled"), store)
let reset = body(profile, "static func reset(")
check("sources: deleting the voice profile deletes the records", reset.contains("VoiceShadowStore.clear()"), reset)
check("sources: what's logged is the rules' line of counts", store.contains("Log.note(VoiceShadowRules.summary(") || profile.contains("Log.note(VoiceShadowRules.summary("))
check("sources: the records never hold a word (no Segment or text reaches the store)",
      !store.contains("Segment") && !store.contains(".text") && !read("Verbatim/Model/VoiceShadow.swift").contains("var text"))

let finish = body(dictation, "private func finishNow(")
check("sources: a dictation's shadow scoring is handed to the paste, never run before it",
      !finish.contains("shadowDictation(") && finish.contains("shadow:") && dictation.components(separatedBy: "VoiceProfile.shadowDictation(").count == 2)
let deliver = body(dictation, "private func deliver(")
check("sources: shadow scoring starts only after the paste has returned",
      before("await Paster.paste(", "shadow?()", in: deliver) && deliver.components(separatedBy: "shadow?()").count == 2, deliver)
let after = body(dictation, "private func shadowScore(")
check("sources: it waits a moment, and gives way to a dictation that's listening or being written",
      before("Task.sleep(", "VoiceProfile.shadowDictation(", in: after) && after.contains("VoiceShadowRules.delayAfterPaste")
      && after.contains("self.isListening || self.isWorking") && after.contains("priority: .utility"), after)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
