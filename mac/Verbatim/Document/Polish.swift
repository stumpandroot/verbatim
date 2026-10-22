import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Rewrites with Apple's on-device model (macOS 26). Paragraph by paragraph, so a long transcript fits the
/// model's 4,096-token window, and each paragraph comes back as a whole string the person can undo.
enum Polish {
    enum Level: String, CaseIterable, Identifiable {
        case none = "None", light = "Light", medium = "Medium", high = "High"
        var id: String { rawValue }
        var note: String {
            switch self {
            case .none: return "Spelling and punctuation only"
            case .light: return "Fillers and grammar only"
            case .medium: return "Clearer and tighter"
            case .high: return "Rewritten for brevity"
            }
        }
    }
    enum Tone: String, CaseIterable, Identifiable {
        case spoken = "As spoken", casual = "Casual", professional = "Professional", concise = "Concise"
        var id: String { rawValue }
    }

    /// Whether Apple's on-device model can run here. `unavailable` carries a sentence for people, not a code.
    enum Status { case ready, needsMacOS26, appleIntelligenceOff, unavailable(String) }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
                case .deviceNotEligible:
                    #if os(macOS)
                    return .unavailable("This Mac can't run Apple Intelligence.")
                    #else
                    return .unavailable("This device can't run Apple Intelligence.")
                    #endif
                case .modelNotReady: return .unavailable("Apple Intelligence is still downloading its model. It works once the download finishes.")
                @unknown default: return .unavailable("Apple Intelligence isn't available on this device.")
                }
            }
        }
        #endif
        return .needsMacOS26
    }

    static func instructions(level: Level, tone: Tone) -> String {
        var rules = ["You edit a transcript of someone speaking. Return only the edited paragraph, nothing else.",
                     "Use the same language as the paragraph. Never translate.",
                     "Keep the speaker's meaning, facts, names, numbers, negations, and first-person voice. Never add information. When unsure, keep the words as spoken.",
                     "If the paragraph starts with a speaker label like 'Name: ', keep that label exactly."]
        switch level {
        case .none: rules.append("Fix spelling, punctuation, and capitalization only. Keep every word otherwise.")
        case .light: rules.append("Remove filler words (um, uh, you know, like, I mean), false starts, and repeated words. Fix grammar and punctuation. Keep the wording and sentence order.")
        case .medium: rules.append("Remove fillers and false starts, fix grammar, and tighten wording for clarity. Keep sentence order and all points.")
        case .high: rules.append("Rewrite for brevity and polish: merge rambling sentences, cut repetition, keep every point and the order of ideas.")
        }
        switch tone {
        case .spoken: rules.append("Keep the speaker's natural tone.")
        case .casual: rules.append("Use a relaxed, conversational tone with contractions.")
        case .professional: rules.append("Use a clear, professional tone suitable for a work email. No slang.")
        case .concise: rules.append("Be as brief as possible without losing any point.")
        }
        return rules.joined(separator: " ")
    }

    /// Splits a long paragraph (one speaker for minutes) at sentence ends into chunks the model can take in
    /// one turn. Nothing is dropped; the chunks are polished separately and joined back.
    static func chunks(_ p: String, maxWords: Int = 450) -> [String] {
        guard p.split(separator: " ").count > maxWords else { return [p] }
        var out: [String] = [], cur = "", count = 0
        p.enumerateSubstrings(in: p.startIndex..., options: .bySentences) { sub, _, _, _ in
            guard let sentence = sub else { return }
            let n = sentence.split(separator: " ").count
            if count + n > maxWords, !cur.isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; count = 0 }
            cur += sentence; count += n
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
        return out.isEmpty ? [p] : out
    }

    /// Rewrites each paragraph. Calls `progress` with the fraction done. A chunk the model refuses, or whose
    /// answer looks cut off, comes back unchanged. Throws when the model is unavailable or returned nothing usable
    /// at all, so the person sees why instead of an unchanged document.
    static func rewrite(_ paragraphs: [String], level: Level, tone: Tone, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), status.isReady {
            let rules = instructions(level: level, tone: tone)
            var out: [String] = []
            var tried = 0, kept = 0
            for (i, p) in paragraphs.enumerated() {
                try Task.checkCancellation()
                if p.split(separator: " ").count < 3 { out.append(p); progress(Double(i + 1) / Double(paragraphs.count)); continue }
                var parts: [String] = []
                for chunk in chunks(p) {
                    try Task.checkCancellation()
                    tried += 1
                    do {
                        // A fresh session per chunk: a shared one keeps every earlier turn and overflows the
                        // model's 4,096-token window after a few thousand words. No maximumResponseTokens: a cap
                        // would cut an answer silently, while running out of room throws and the chunk is kept.
                        let session = LanguageModelSession(instructions: rules)
                        let r = try await session.respond(to: "Paragraph:\n\(chunk)")
                        let text = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if text.isEmpty || looksCut(source: chunk, output: text) {
                            Log.note("polish: paragraph \(i) chunk kept as-is (empty or cut off)")
                            kept += 1
                            parts.append(chunk)
                        } else {
                            parts.append(text)
                        }
                    } catch {
                        Log.note("polish: paragraph \(i) chunk kept as-is: \(type(of: error))")
                        kept += 1
                        parts.append(chunk)
                    }
                }
                out.append(parts.joined(separator: " "))
                progress(Double(i + 1) / Double(paragraphs.count))
            }
            if tried > 0 && kept == tried {
                throw NSError(domain: "Verbatim", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple's on-device model didn't return any text, so nothing changed. Try again in a moment."])
            }
            return out
        }
        #endif
        throw NSError(domain: "Verbatim", code: 2, userInfo: [NSLocalizedDescriptionKey: status.polishNotice ?? "Clean up and Tone need Apple Intelligence."])
    }

    /// An answer that stops mid-sentence where the source ended one, at under half its length, was cut off.
    private static func looksCut(source: String, output: String) -> Bool {
        let terminal: Set<Character> = [".", "!", "?", "…", "\"", "”", ")", "。", "！", "？"]
        guard let s = source.trimmingCharacters(in: .whitespacesAndNewlines).last,
              let o = output.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return terminal.contains(s) && !terminal.contains(o) && output.count * 2 < source.count
    }
}

extension Polish.Status {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Why Apple's model can't run here, as a sentence; nil when it can.
    var reason: String? {
        switch self {
        case .ready: return nil
        case .needsMacOS26:
            #if os(macOS)
            return "This Mac needs macOS 26 or later."
            #else
            return "This device needs iOS 26 or later."
            #endif
        case .appleIntelligenceOff:
            #if os(macOS)
            return "Apple Intelligence is off. Turn it on in System Settings › Apple Intelligence & Siri."
            #else
            return "Apple Intelligence is off. Turn it on in Settings › Apple Intelligence & Siri."
            #endif
        case .unavailable(let why): return why
        }
    }

    /// For dictation settings: what Verbatim does instead. Nil when the model is ready.
    var cleanupNotice: String? {
        reason.map { "Clean and Polished need Apple Intelligence to remove fillers and reword. On this device, Verbose formats lists and paragraphs by rules and keeps your words. " + $0 }
    }

    /// For Clean up, Tone, and saved actions: why they can't run. Nil when the model is ready.
    var polishNotice: String? {
        reason.map { "Clean up and Tone need Apple Intelligence; your text stays as it is on this device. " + $0 }
    }
}
