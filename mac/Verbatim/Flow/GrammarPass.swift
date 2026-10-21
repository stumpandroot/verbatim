import Foundation

/// A deterministic grammar pass with Harper (https://github.com/Automattic/harper, Apache-2.0, offline), run on
/// dictation after Apple's model, or after the rules when the model doesn't run.
///
/// `harper_fix` (mac/harper-ffi) applies only rules that fix form, never meaning: "a" or "an", a capital to start
/// a sentence, "i" → "I", doubled spaces, "its" → "it's" before a verb, and "didnt" or "cant". No spelling
/// guesses, so names and jargon are safe. Its output is then checked word by word (`accepts`): only those
/// changes may appear, so a number, name, negation, or any other word can never change here. On any failure,
/// the input comes back as it was.
enum GrammarPass {
    /// Text longer than this is returned as it is (a dictation is far shorter; this bounds the time).
    static let maxLength = 20_000

    static func fix(_ text: String) -> String {
        guard !text.isEmpty, text.utf8.count <= maxLength, !text.contains("\0") else { return text }
        guard let p = text.withCString({ harper_fix($0, 0) }) else { return text }
        defer { harper_free(p) }
        let out = String(cString: p)
        return accepts(original: text, fixed: out) ? out : text
    }

    /// Loads Harper's dictionary and rules off the main thread, so the first dictation doesn't wait for them.
    static func prewarm() {
        warm.once()
    }

    private static let warm = Once {
        DispatchQueue.global(qos: .utility).async { _ = fix("i think a apple is here.") }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
        func once() {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            work()
        }
    }

    // MARK: Guard

    /// Word changes the pass may make. Everything else must match exactly, apart from capitals and spacing.
    private static let allowedSwaps: Set<String> = ["a>an", "an>a", "its>it's", "didnt>didn't", "cant>can't"]

    /// True when `fixed` differs from `original` only by the allowed changes: a swap above, a capital added to
    /// the first letter of a plain lowercase word, and spacing. Punctuation must be the same.
    static func accepts(original: String, fixed: String) -> Bool {
        // Line breaks (lists, paragraphs) stay exactly where they were.
        guard original.filter({ $0 == "\n" }).count == fixed.filter({ $0 == "\n" }).count else { return false }
        let a = tokens(original), b = tokens(fixed)
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x != y {
            let lx = x.lowercased(), ly = y.lowercased()
            if lx == ly {
                // Only a capital on the first letter of a word that had none: never "iPhone" → "IPhone".
                guard x.first?.isLowercase == true, !x.dropFirst().contains(where: { $0.isUppercase }),
                      y == x.prefix(1).uppercased() + x.dropFirst() else { return false }
                continue
            }
            if !allowedSwaps.contains("\(lx)>\(ly)") { return false }
            // A swap keeps the word's own capital ("A" → "An").
            if x.first?.isUppercase != y.first?.isUppercase { return false }
        }
        return true
    }

    /// Words (letters, digits, apostrophes) and single punctuation marks, without spacing.
    private static func tokens(_ s: String) -> [String] {
        let t = s.replacingOccurrences(of: "’", with: "'")
        var out: [String] = []
        var word = ""
        for ch in t {
            if ch.isLetter || ch.isNumber || ch == "'" {
                word.append(ch)
            } else {
                if !word.isEmpty { out.append(word); word = "" }
                if !ch.isWhitespace { out.append(String(ch)) }
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }
}
