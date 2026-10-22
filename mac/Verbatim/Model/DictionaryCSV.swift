import Foundation

/// The Dictionary as CSV (Dictionary › Import CSV… and Export CSV…). Foundation only, so mac/tools/test-privacy.sh
/// tests it; the app turns rows into `DictionaryEntry` values (Transcript+Trust.swift).
///
/// Columns follow `DictionaryEntry`: heard (every "heard as" form, separated by " | "), replacement (the spelling you
/// want), enabled, project (by name, empty for every transcript), learned_from, and created (ISO 8601). Import reads
/// a header in any order and any case, with a few aliases ("heard as", "preferred", "word"), and also a file with no
/// header whose first two columns are heard and replacement.
enum DictionaryCSV {
    struct Row: Equatable {
        var heard: [String]
        var replacement: String
        var enabled = true
        var project: String? = nil
        var learnedFrom: String? = nil
        var created: Date? = nil
    }

    static let header = ["heard", "replacement", "enabled", "project", "learned_from", "created"]
    static let heardSeparator = " | "

    // MARK: Writing

    static func export(_ rows: [Row]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [header.joined(separator: ",")]
        for r in rows {
            let fields = [r.heard.joined(separator: heardSeparator), r.replacement, r.enabled ? "true" : "false",
                          r.project ?? "", r.learnedFrom ?? "", r.created.map { iso.string(from: $0) } ?? ""]
            lines.append(fields.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// One field, quoted when it holds a comma, a quote, a line break, or space at either end. A field that starts
    /// with = + - or @ gets a leading apostrophe, so a spreadsheet never runs it as a formula.
    static func field(_ s: String) -> String {
        var v = s
        if let f = v.first, "=+-@".contains(f) { v = "'" + v }
        let needs = v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r")
            || v.first?.isWhitespace == true || v.last?.isWhitespace == true
        return needs ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
    }

    // MARK: Reading

    /// Records and fields per RFC 4180: quoted fields may hold commas, quotes ("" is one quote), and line breaks.
    /// CRLF, LF, and CR all end a record. A byte order mark is ignored.
    static func records(_ text: String) -> [[String]] {
        var out: [[String]] = []
        var record: [String] = []
        var cur = ""
        var quoted = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        func endRecord() {
            record.append(cur); cur = ""
            if !(record.count == 1 && record[0].isEmpty) { out.append(record) }
            record = []
        }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted = false }
                } else {
                    cur.append(c)
                }
            } else {
                switch c {
                case "\"" where cur.isEmpty: quoted = true
                case ",": record.append(cur); cur = ""
                case "\r\n", "\n", "\r": endRecord()
                default: cur.append(c)
                }
            }
            i += 1
        }
        if !cur.isEmpty || !record.isEmpty { endRecord() }
        return out
    }

    struct Parsed: Equatable {
        var rows: [Row]
        /// Lines without a replacement or a heard form, skipped.
        var invalid: Int
    }

    private static let aliases: [String: String] = [
        "heard": "heard", "heard as": "heard", "heard_as": "heard", "heardas": "heard", "misheard": "heard", "from": "heard",
        "replacement": "replacement", "preferred": "replacement", "word": "replacement", "to": "replacement", "spelling": "replacement",
        "enabled": "enabled", "on": "enabled", "project": "project",
        "learned_from": "learned_from", "learned from": "learned_from", "source": "learned_from",
        "created": "created", "created_at": "created", "date": "created",
    ]

    static func parse(_ text: String) -> Parsed {
        var recs = records(text)
        guard !recs.isEmpty else { return Parsed(rows: [], invalid: 0) }
        // A header when any first-row cell names a known column; otherwise heard, replacement by position.
        let names = recs[0].map { aliases[$0.trimmingCharacters(in: .whitespaces).lowercased()] }
        var col: [String: Int] = ["heard": 0, "replacement": 1]
        if names.contains(where: { $0 != nil }) {
            col = [:]
            for (i, n) in names.enumerated() { if let n, col[n] == nil { col[n] = i } }
            recs.removeFirst()
        }
        let iso = ISO8601DateFormatter()
        var rows: [Row] = [], invalid = 0
        for r in recs {
            func value(_ k: String) -> String? {
                guard let i = col[k], i < r.count else { return nil }
                var v = r[i].trimmingCharacters(in: .whitespacesAndNewlines)
                // Undo the export's formula guard.
                if v.hasPrefix("'"), let n = v.dropFirst().first, "=+-@".contains(n) { v.removeFirst() }
                return v.isEmpty ? nil : v
            }
            let heard = splitHeard(value("heard") ?? "")
            guard let replacement = value("replacement"), !heard.isEmpty else {
                if !r.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { invalid += 1 }
                continue
            }
            var row = Row(heard: heard, replacement: replacement)
            if let e = value("enabled")?.lowercased() { row.enabled = !["false", "no", "0", "off"].contains(e) }
            row.project = value("project")
            row.learnedFrom = value("learned_from")
            row.created = value("created").flatMap { iso.date(from: $0) }
            rows.append(row)
        }
        return Parsed(rows: rows, invalid: invalid)
    }

    /// "heard" holds one form, or several separated by | or ;. Duplicates (ignoring case) are dropped.
    static func splitHeard(_ s: String) -> [String] {
        var out: [String] = []
        for part in s.split(whereSeparator: { $0 == "|" || $0 == ";" }) {
            let t = part.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { out.append(t) }
        }
        return out
    }

    // MARK: Merging

    /// What importing one row does to the Dictionary.
    enum Step: Equatable {
        /// A new entry.
        case add(Row)
        /// An entry with the same replacement and project gains heard forms it didn't have.
        case addHeard(index: Int, [String])
        /// Everything in the row is already there.
        case skip
    }

    struct Report: Equatable {
        var added = 0, updated = 0, skipped = 0, invalid = 0
        /// "Added 12 words, updated 2, skipped 3 already in your Dictionary."
        var summary: String {
            var parts = ["Added \(added) word\(added == 1 ? "" : "s")"]
            if updated > 0 { parts.append("updated \(updated)") }
            if skipped > 0 { parts.append("skipped \(skipped) already in your Dictionary") }
            if invalid > 0 { parts.append("skipped \(invalid) line\(invalid == 1 ? "" : "s") without a word") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Plans an import against `existing`: same replacement (ignoring case) in the same project is the same entry.
    /// Rows repeated within the file merge into the first.
    static func plan(existing: [Row], incoming: [Row]) -> (steps: [Step], report: Report) {
        func key(_ r: Row) -> String { r.replacement.lowercased() + "\u{1}" + (r.project ?? "").lowercased() }
        var known = existing
        var index: [String: Int] = [:]
        for (i, r) in known.enumerated() where index[key(r)] == nil { index[key(r)] = i }
        var steps: [Step] = [], report = Report()
        var newIndexFor: [Int: Int] = [:]   // index in `known` of an entry this import added → its step
        for r in incoming {
            if let i = index[key(r)] {
                let have = known[i].heard
                let extra = r.heard.filter { h in !have.contains { $0.caseInsensitiveCompare(h) == .orderedSame } }
                if extra.isEmpty { steps.append(.skip); report.skipped += 1; continue }
                known[i].heard += extra
                if let s = newIndexFor[i], case .add(var added) = steps[s] {
                    // A repeat of a row this file added: fold it in.
                    added.heard += extra; steps[s] = .add(added); steps.append(.skip)
                } else {
                    steps.append(.addHeard(index: i, extra)); report.updated += 1
                }
            } else {
                known.append(r)
                index[key(r)] = known.count - 1
                newIndexFor[known.count - 1] = steps.count
                steps.append(.add(r)); report.added += 1
            }
        }
        return (steps, report)
    }
}
