import Foundation

/// Where a screen change's time goes, for the Mac self-test: each window root and screen calls `mark` as its body runs
/// or it appears, and the first call of each name is kept with its time since the click. Main thread only; does nothing
/// outside a navigation the self-test times (`begin` to `end`).
enum NavMarks {
    private static var marks: [(name: String, ms: Int)] = []
    private static var start = Date()
    private static var timing = false

    static func mark(_ name: @autoclosure () -> String) {
        guard timing else { return }
        let name = name()
        guard !marks.contains(where: { $0.name == name }) else { return }
        marks.append((name, Int((Date().timeIntervalSince(start) * 1000).rounded())))
    }

    /// Starts the marks for a screen change, at the click.
    static func begin() {
        timing = true
        marks = []
        start = Date()
    }

    /// Ends them at the self-test's settled time, as "name+ms" in the order they came.
    static func end() -> String {
        guard timing else { return "" }
        timing = false
        return marks.map { "\($0.name)+\($0.ms)" }.joined(separator: " ")
    }
}
