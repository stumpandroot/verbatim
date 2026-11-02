import Foundation
import AVFoundation
import CoreMedia
import SoundAnalysis

/// The test stage for vocal expressions (laughter, chuckles, sighs, crying, and long pauses), before any of it is
/// stored or shown. It runs Apple's built-in sound classifier (SoundAnalysis, on device) over a recording and lists
/// what it heard, with times and confidence, next to the long pauses between words. Parakeet writes words only and
/// Whisper's bracketed tags aren't reliable, so the sounds come from this separate stage instead of the engine.
///
/// Used by TestFlight's Test vocal sounds (iPhone transcript › Export) and the Mac self-test, which logs the
/// classifier's labels. Nothing is saved and nothing leaves the device; the report is plain text you choose to share.
enum VocalSoundScan {
    struct Event: Equatable {
        var label: String
        var start: Double
        var end: Double
        var confidence: Double
    }

    struct Pause: Equatable {
        var start: Double
        var end: Double
        var length: Double { end - start }
    }

    /// Classifier labels worth reporting, matched as parts of its identifiers ("laughter", "belly_laugh",
    /// "chuckle_chortle", "crying_sobbing", and so on). Broad on purpose: the test is to learn what it hears.
    static let interesting = ["laugh", "giggl", "chuckl", "chortl", "snicker", "sigh", "cry", "sob", "whimper", "gasp",
                              "groan", "moan", "grunt", "throat", "cough", "sneez", "sniff", "breath", "pant", "wheez",
                              "scream", "yell", "shout", "whisper", "humm", "applause", "cheer", "crowd", "clap", "hiccup"]
    /// Windows below this confidence are left out. Low, so the test shows near misses too.
    static let floor = 0.3
    /// A gap between words this long or longer counts as a long pause.
    static let pauseSeconds = 2.0
    /// Hits of the same label closer than this merge into one event.
    static let mergeGap = 0.6
    static let windowSeconds = 1.0
    static let overlap = 0.5

    static func isInteresting(_ label: String) -> Bool {
        let l = label.lowercased()
        return interesting.contains { l.contains($0) }
    }

    /// Every label the built-in classifier knows, or empty when it isn't available.
    static func knownLabels() -> [String] {
        guard let r = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        return r.knownClassifications.sorted()
    }

    /// The interesting sounds in the audio file at `url`, merged into events, in time order.
    static func scan(url: URL, floor: Double = VocalSoundScan.floor) async throws -> [Event] {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = window(for: request.windowDurationConstraint)
        request.overlapFactor = overlap
        let collector = Collector(floor: floor)
        try analyzer.add(request, withObserver: collector)
        // analyze() blocks until the whole file is read; keep it off the main thread.
        await Task.detached(priority: .utility) { analyzer.analyze() }.value
        if let e = collector.error { throw e }
        return merge(collector.hits)
    }

    /// `windowSeconds`, or the closest window the classifier allows.
    private static func window(for c: SNTimeDurationConstraint) -> CMTime {
        let want = CMTime(seconds: windowSeconds, preferredTimescale: 48_000)
        // In Swift the constraint is an enum: a list of allowed windows, or a range.
        switch c {
        case .enumeratedDurations(let options):
            var best = want
            var bestGap = Double.infinity
            for o in options where abs(o.seconds - windowSeconds) < bestGap { best = o; bestGap = abs(o.seconds - windowSeconds) }
            return best
        case .durationRange(let r):
            return CMTimeClampToRange(want, range: r)
        @unknown default:
            return want
        }
    }

    /// One observation: a window's label and confidence.
    struct Hit: Equatable {
        var label: String
        var start: Double
        var end: Double
        var confidence: Double
    }

    /// Joins overlapping or nearby hits of the same label into one event (its confidence is the highest hit's).
    static func merge(_ hits: [Hit], gap: Double = mergeGap) -> [Event] {
        var out: [Event] = []
        let byLabel = Dictionary(grouping: hits, by: \.label)
        for (label, list) in byLabel {
            var current: Event?
            for h in list.sorted(by: { $0.start < $1.start }) {
                if var c = current, h.start <= c.end + gap {
                    c.end = max(c.end, h.end); c.confidence = max(c.confidence, h.confidence); current = c
                } else {
                    if let c = current { out.append(c) }
                    current = Event(label: label, start: h.start, end: h.end, confidence: h.confidence)
                }
            }
            if let c = current { out.append(c) }
        }
        return out.sorted { ($0.start, $0.label) < ($1.start, $1.label) }
    }

    /// Gaps of `minimum` seconds or more between consecutive words, from the engine's word timings (between lines
    /// when a line has no word timings).
    static func pauses(_ segments: [Segment], minimum: Double = pauseSeconds) -> [Pause] {
        var spans: [(Double, Double)] = []
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if let w = s.words, !w.isEmpty { spans += w.map { ($0.start, $0.end) } } else { spans.append((s.start, s.end)) }
        }
        var out: [Pause] = []
        var lastEnd: Double?
        for (start, end) in spans.sorted(by: { $0.0 < $1.0 }) {
            if let e = lastEnd, start - e >= minimum { out.append(Pause(start: e, end: start)) }
            lastEnd = max(lastEnd ?? end, end)
        }
        return out
    }

    /// "1:05.3"
    static func clock(_ s: Double) -> String {
        let tenths = Int((max(0, s) * 10).rounded())
        let m = tenths / 600, rest = tenths % 600
        return String(format: "%d:%02d.%d", m, rest / 10, rest % 10)
    }

    /// The three words before `start` and after `end`, so an event can be matched to a script without timing it:
    /// "going to work | I don't know". A side with no words reads "(start)" or "(end)".
    static func context(_ segments: [Segment], start: Double, end: Double) -> String {
        var words: [(text: String, start: Double, end: Double)] = []
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if let w = s.words, !w.isEmpty { words += w.map { ($0.text, $0.start, $0.end) } } else { words.append((s.text, s.start, s.end)) }
        }
        let tidy = { (list: [(text: String, start: Double, end: Double)]) in
            list.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let before = tidy(Array(words.filter { $0.end <= start + 0.25 }.suffix(3)))
        let after = tidy(Array(words.filter { $0.start >= end - 0.25 }.prefix(3)))
        return "\(before.isEmpty ? "(start)" : before) | \(after.isEmpty ? "(end)" : after)"
    }

    /// The plain-text report to send back: what the classifier heard and the long pauses, each with the words around
    /// it, and the labels it knows.
    static func report(title: String, duration: Double, events: [Event], pauses: [Pause], segments: [Segment],
                       labels: [String], build: String) -> String {
        var lines = ["Vocal sounds test: \(title) (\(clock(duration)))",
                     "Build \(build). Apple's sound classifier, \(Int(windowSeconds)) s windows, \(Int(overlap * 100))% overlap, confidence \(String(format: "%.2f", floor)) and up.",
                     "", "Sounds heard"]
        if events.isEmpty { lines.append("None") }
        for e in events {
            lines.append("\(clock(e.start)) to \(clock(e.end))  \(e.label)  \(String(format: "%.2f", e.confidence))  \(context(segments, start: e.start, end: e.end))")
        }
        lines += ["", "Long pauses (\(Int(pauseSeconds)) s or more between words)"]
        if pauses.isEmpty { lines.append("None") }
        for p in pauses { lines.append("\(clock(p.start)) to \(clock(p.end))  \(String(format: "%.1f", p.length)) s  \(context(segments, start: p.start, end: p.end))") }
        let known = labels.filter(isInteresting)
        lines += ["", "Labels the classifier knows in these groups (\(known.count) of \(labels.count))", known.isEmpty ? "None" : known.joined(separator: ", ")]
        return lines.joined(separator: "\n")
    }

    /// Collects the interesting labels from each window at or above the floor.
    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private let floor: Double
        private var _hits: [Hit] = []
        private var _error: Error?
        init(floor: Double) { self.floor = floor }

        var hits: [Hit] { lock.lock(); defer { lock.unlock() }; return _hits }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            let start = r.timeRange.start.seconds, end = CMTimeRangeGetEnd(r.timeRange).seconds
            let found = r.classifications.filter { $0.confidence >= floor && VocalSoundScan.isInteresting($0.identifier) }
            guard !found.isEmpty else { return }
            lock.lock()
            for c in found { _hits.append(Hit(label: c.identifier, start: start, end: end, confidence: c.confidence)) }
            lock.unlock()
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.lock(); _error = error; lock.unlock()
        }
    }
}

extension VocalSoundScan {
    /// Checks of the pure parts (merging, pauses, the clock), for the Mac and iPhone self-tests.
    static func selfChecks(_ check: (String, Bool) -> Void) {
        let merged = merge([Hit(label: "laughter", start: 1, end: 2, confidence: 0.5),
                            Hit(label: "laughter", start: 1.5, end: 2.5, confidence: 0.8),
                            Hit(label: "laughter", start: 5, end: 6, confidence: 0.4),
                            Hit(label: "sigh", start: 2, end: 3, confidence: 0.6)])
        check("vocal sounds: overlapping hits of one label merge, keeping the highest confidence",
              merged.first == Event(label: "laughter", start: 1, end: 2.5, confidence: 0.8))
        check("vocal sounds: far-apart hits stay separate, in time order",
              merged.map(\.label) == ["laughter", "sigh", "laughter"] && merged.last?.start == 5)
        let words = [WordSpan(text: "I", start: 0, end: 0.2), WordSpan(text: "thought", start: 0.3, end: 0.7),
                     WordSpan(text: "anyway", start: 3.5, end: 4)]
        let p = pauses([Segment(start: 0, end: 4, text: "I thought anyway", words: words)])
        check("vocal sounds: a 2.8 s gap between words is a long pause", p == [Pause(start: 0.7, end: 3.5)])
        check("vocal sounds: lines without word timings use the gap between lines",
              pauses([Segment(start: 0, end: 1, text: "a"), Segment(start: 1.5, end: 2, text: "b"), Segment(start: 5, end: 6, text: "c")])
                == [Pause(start: 2, end: 5)])
        check("vocal sounds: the clock reads 1:05.3", clock(65.3) == "1:05.3")
        check("vocal sounds: laughter and crying_sobbing are interesting, speech isn't",
              isInteresting("belly_laugh") && isInteresting("crying_sobbing") && !isInteresting("speech"))
        check("vocal sounds: an event lists the three words before and after it",
              context([Segment(start: 0, end: 4, text: "I thought anyway", words: words)], start: 1, end: 3) == "I thought | anyway"
              && context([], start: 1, end: 2) == "(start) | (end)")
        let r = report(title: "Test", duration: 10, events: [], pauses: [], segments: [], labels: ["speech", "laughter"], build: "1")
        check("vocal sounds: the report says None when nothing was heard and lists the known labels",
              r.contains("Sounds heard\nNone") && r.hasSuffix("(1 of 2)\nlaughter"))
    }
}
