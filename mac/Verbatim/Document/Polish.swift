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
            case .none: return "As transcribed"
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

    enum Status { case ready, needsMacOS26, appleIntelligenceOff, unavailable(String) }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(let reason):
                let r = String(describing: reason)
                return r.contains("appleIntelligenceNotEnabled") ? .appleIntelligenceOff : .unavailable(r)
            }
        }
        #endif
        return .needsMacOS26
    }

    static func instructions(level: Level, tone: Tone) -> String {
        var rules = ["You edit a transcript of someone speaking. Return only the edited paragraph, nothing else.",
                     "Keep the speaker's meaning, facts, names, numbers, and first-person voice. Never add information.",
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

    /// Rewrites each paragraph. Calls `progress` with the fraction done. Paragraphs the model refuses come back unchanged.
    static func rewrite(_ paragraphs: [String], level: Level, tone: Tone, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: instructions(level: level, tone: tone))
            session.prewarm()
            var out: [String] = []
            for (i, p) in paragraphs.enumerated() {
                if p.split(separator: " ").count < 3 { out.append(p); progress(Double(i + 1) / Double(paragraphs.count)); continue }
                do {
                    let r = try await session.respond(to: "Paragraph:\n\(p)")
                    let text = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(text.isEmpty ? p : text)
                } catch {
                    Log.note("polish: paragraph \(i) kept as-is: \(error)")
                    out.append(p)
                }
                progress(Double(i + 1) / Double(paragraphs.count))
            }
            return out
        }
        #endif
        throw NSError(domain: "Verbatim", code: 2, userInfo: [NSLocalizedDescriptionKey: "Clean up and Tone need macOS 26 with Apple Intelligence on."])
    }
}
