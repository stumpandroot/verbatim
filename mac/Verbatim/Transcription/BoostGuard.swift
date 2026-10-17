import Foundation

/// Second opinion on the vocabulary boost: a swap is kept only when the words it replaces look like the Dictionary
/// word (or one of its "heard as" spellings) it brings in. Anything else goes back to what the engine heard.
enum BoostGuard {
    /// How alike the replaced words and the Dictionary word must be (0–1, letters only).
    static let minSimilarity = 0.7

    struct Result { var text: String; var kept: Int; var reverted: Int }

    static func filter(original: String, boosted: String, terms: [(text: String, aliases: [String])]) -> Result {
        let a = original.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let b = boosted.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let na = a.map(norm), nb = b.map(norm)
        // Longest common subsequence over normalized words.
        let n = a.count, m = b.count
        guard n > 0, m > 0, n <= 600, m <= 600 else { return Result(text: boosted, kept: 0, reverted: 0) }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = na[i] == nb[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [String] = []
        var kept = 0, reverted = 0
        var i = 0, j = 0
        var spanA: [String] = [], spanB: [String] = []
        func flush(atEnd: Bool) {
            defer { spanA = []; spanB = [] }
            if spanA.isEmpty && spanB.isEmpty { return }
            let newWords = spanB.map(norm).filter { !$0.isEmpty }.joined(separator: " ")
            let oldLetters = spanA.map(norm).joined()
            let ok = !spanB.isEmpty && terms.contains { t in
                let termWords = t.text.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
                guard termWords == newWords else { return false }
                if t.aliases.contains(where: { norm($0) == oldLetters }) { return true }
                return similarity(oldLetters, norm(t.text)) >= minSimilarity
            }
            if ok || spanA.isEmpty {
                // Keep the swap; carry over the original's trailing punctuation if the rescorer dropped it.
                var words = spanB
                if let lastOld = spanA.last, let p = lastOld.last, ".,!?;:".contains(p), let lastNew = words.last, lastNew.last.map({ !".,!?;:".contains($0) }) ?? true {
                    words[words.count - 1] = lastNew + String(p)
                }
                out += words
                if !spanB.isEmpty { kept += 1 }
            } else {
                out += spanA
                reverted += 1
            }
        }
        while i < n && j < m {
            if na[i] == nb[j] { flush(atEnd: false); out.append(b[j]); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { spanA.append(a[i]); i += 1 }
            else { spanB.append(b[j]); j += 1 }
        }
        while i < n { spanA.append(a[i]); i += 1 }
        while j < m { spanB.append(b[j]); j += 1 }
        flush(atEnd: true)
        return Result(text: out.joined(separator: " "), kept: kept, reverted: reverted)
    }

    /// Lowercased letters and digits only.
    static func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }

    /// 1 − edit distance / longer length.
    static func similarity(_ x: String, _ y: String) -> Double {
        let a = Array(x), b = Array(y)
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = Array(0...b.count), cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}
