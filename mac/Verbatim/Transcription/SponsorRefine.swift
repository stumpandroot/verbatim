import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The optional second pass of sponsor detection: Apple's on-device model reads each read the rules found and says
/// whether it's a sponsor read and whose (macOS 26 or iOS 26 with Apple Intelligence on, the same check summaries
/// use). Without it, the rules' spans stand as they are. Never follows what the passage says; it only classifies it.
enum SponsorRefine {
    static var available: Bool { Polish.status.isReady }

    /// The most of a read the model gets: a read is a minute or two, well under the model's window.
    static let maxCharacters = 4_000

    static let instructions = """
        You check passages from podcast and video transcripts. Decide whether the passage is a paid sponsor read or \
        an advertisement: the host promoting a company, product, or organization, usually with an offer, a discount \
        code, or a web address. The show's own guests, topics, and the host's own projects are not sponsors. \
        Answer in exactly two lines and nothing else:
        SPONSOR: yes or no
        NAME: the sponsor's name as the company writes it, or none
        """

    /// The model's verdict on one passage; `.unknown` when it can't run, declines, or answers in another shape.
    static func check(_ passage: String) async -> SponsorDetect.Verdict {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), case .ready = Polish.status {
            let text = String(passage.prefix(maxCharacters))
            let prompt = "Passage:\n<passage>\n\(text)\n</passage>"
            guard let answer = try? await OnDeviceText.respond(instructions: instructions, prompt: prompt, temperature: 0),
                  !OnDeviceTextRefusal.isRefusal(answer) else { return .unknown }
            return SponsorDetect.verdict(from: answer)
        }
        #endif
        return .unknown
    }
}
