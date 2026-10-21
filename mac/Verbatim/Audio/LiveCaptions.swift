import SwiftUI
import Combine
import Speech

// MARK: - Live captions (shared by the Mac panel and the iPhone screen)
//
// Captions are live words (`LiveTranscriber`) laid out as lines: finished lines above, the line being spoken
// below with its newest word in persimmon. One `CaptionFeed` takes words from one or more sources (the Mac's
// microphone and an app's audio) and turns each into lines, labelled with a speaker when there's more than one.
// What's saved as a transcript always comes from the main engine (Parakeet or Whisper), never from these words.

/// One caption line. A line keeps its id when it moves from "current" to "finished".
struct CaptionLine: Identifiable, Equatable {
    let id: UUID
    var text: String
    /// "You", an app's name, or nil when there's only one source.
    var speaker: String?
}

/// Turns live words from one or more sources into caption lines. Main actor.
@MainActor
final class CaptionFeed: ObservableObject {
    /// Finished lines, oldest first. Kept to the last 200.
    @Published private(set) var history: [CaptionLine] = []
    /// Lines still being spoken: at most one per source, in the order sources were added.
    @Published private(set) var current: [CaptionLine] = []
    /// Called once for each line as it's finished (VoiceOver reads these, never the changing words).
    var onFinished: (@MainActor (CaptionLine) -> Void)?
    /// A line longer than this is broken at a word boundary even without a sentence end.
    var maxLineLength = 120
    /// A pause this long (no new words, nothing volatile) ends the line.
    var pauseToBreak: TimeInterval = 1.8

    private struct Source {
        var speaker: String?
        /// Characters of `settled` already turned into finished lines.
        var consumed = 0
        var words = LiveWords()
        var lineID = UUID()
        var lastChange = Date()
    }
    private var sources: [String: Source] = [:]
    private var order: [String] = []
    private static let historyLimit = 200

    /// Adds a source (or relabels it). `speaker` nil hides its label.
    func addSource(_ key: String, speaker: String?) {
        if sources[key] == nil { sources[key] = Source(speaker: speaker); order.append(key) }
        else { sources[key]?.speaker = speaker }
    }

    /// Finishes whatever the source had and forgets it.
    func removeSource(_ key: String) {
        finishPending(key, includeVolatile: true)
        sources[key] = nil
        order.removeAll { $0 == key }
        publishCurrent()
    }

    /// Finishes every source's line as it stands, volatile words included (the session is ending or changing).
    func finishAll() {
        for k in order { finishPending(k, includeVolatile: true) }
        publishCurrent()
    }

    func reset() {
        sources = [:]; order = []
        if !history.isEmpty { history = [] }
        if !current.isEmpty { current = [] }
    }

    /// New words from a source. Empty words (a new session) start over without losing finished lines.
    func update(_ key: String, words: LiveWords) {
        guard var s = sources[key] else { return }
        if words.isEmpty {
            s.consumed = 0; s.words = words; s.lineID = UUID()
            sources[key] = s
            publishCurrent()
            return
        }
        if words != s.words { s.lastChange = Date() }
        s.words = words
        // The fallback recognizer may revise its settled words a little; never read past the end.
        s.consumed = min(s.consumed, words.settled.count)
        sources[key] = s
        breakSettled(key)
        publishCurrent()
    }

    /// Call about twice a second: a pause ends the line being spoken.
    func tick(now: Date = Date()) {
        var changed = false
        for k in order {
            guard let s = sources[k], now.timeIntervalSince(s.lastChange) >= pauseToBreak,
                  s.words.volatile.trimmingCharacters(in: .whitespaces).isEmpty, !pending(s).isEmpty else { continue }
            finishPending(k, includeVolatile: false)
            changed = true
        }
        if changed { publishCurrent() }
    }

    /// Made-up lines for screenshots (UI test mode only).
    func seed(history: [CaptionLine], current: [CaptionLine]) {
        self.history = history
        self.current = current
    }

    // MARK: Splitting

    private func pending(_ s: Source) -> String {
        let settled = s.words.settled
        guard s.consumed < settled.count else { return "" }
        return String(settled[settled.index(settled.startIndex, offsetBy: s.consumed)...])
    }

    /// Finishes each complete sentence in the settled words, and breaks an over-long run at a word boundary.
    private func breakSettled(_ key: String) {
        guard var s = sources[key] else { return }
        var rest = Substring(pending(s))
        while true {
            let lead = rest.prefix { $0 == " " }.count
            let body = rest.dropFirst(lead)
            guard !body.isEmpty else { break }
            var cut: String.Index? = nil
            var i = body.startIndex
            while i < body.endIndex {
                let c = body[i]
                let next = body.index(after: i)
                if ".?!…".contains(c), next == body.endIndex || body[next] == " " { cut = next; break }
                i = next
            }
            if cut == nil, body.count > maxLineLength {
                let limit = body.index(body.startIndex, offsetBy: maxLineLength)
                cut = body[..<limit].lastIndex(of: " ") ?? limit
            }
            guard let end = cut else { break }
            let line = body[..<end].trimmingCharacters(in: .whitespaces)
            s.consumed += lead + body.distance(from: body.startIndex, to: end)
            if !line.isEmpty { finish(line, source: &s) }
            rest = body[end...]
        }
        sources[key] = s
    }

    private func finishPending(_ key: String, includeVolatile: Bool) {
        guard var s = sources[key] else { return }
        let text = includeVolatile ? LiveWords.join(pending(s), s.words.volatile) : pending(s).trimmingCharacters(in: .whitespaces)
        s.consumed = s.words.settled.count
        if includeVolatile { s.words.volatile = "" }
        if !text.isEmpty { finish(text, source: &s) }
        sources[key] = s
    }

    private func finish(_ text: String, source s: inout Source) {
        let line = CaptionLine(id: s.lineID, text: text, speaker: s.speaker)
        s.lineID = UUID()
        history.append(line)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        onFinished?(line)
    }

    private func publishCurrent() {
        let lines: [CaptionLine] = order.compactMap { k in
            guard let s = sources[k] else { return nil }
            let text = LiveWords.join(pending(s), s.words.volatile)
            return text.isEmpty ? nil : CaptionLine(id: s.lineID, text: text, speaker: s.speaker)
        }
        if lines != current { current = lines }
    }

    /// The end of `text`, at most `limit` characters, starting at a word, with an ellipsis when cut.
    static func tail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var cut = text.suffix(limit)
        if let space = cut.firstIndex(of: " ") { cut = cut[cut.index(after: space)...] }
        return "…" + cut
    }
}

// MARK: - Preferences

enum CaptionSize: String, CaseIterable, Identifiable {
    case small, medium, large
    static let key = "captions.size"
    var id: String { rawValue }
    var title: String { switch self { case .small: return "Small"; case .medium: return "Medium"; case .large: return "Large" } }
    /// The current line on the Mac panel; older lines are smaller.
    var mac: CGFloat { switch self { case .small: return 21; case .medium: return 26; case .large: return 32 } }
    /// The current line on the iPhone screen.
    var phone: CGFloat { switch self { case .small: return 28; case .medium: return 34; case .large: return 42 } }
    var next: CaptionSize { switch self { case .small: return .medium; case .medium: return .large; case .large: return .small } }
    static var saved: CaptionSize { CaptionSize(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .medium }
}

enum CaptionPrefs {
    /// Mac: show the elapsed time in the panel's header.
    static let timecodeKey = "captions.timecode"
    /// Mac: the panel also shows over full-screen apps.
    static let aboveFullScreenKey = "captions.aboveFullScreen"
    static var showsTimecode: Bool { UserDefaults.standard.object(forKey: timecodeKey) as? Bool ?? true }
    static var aboveFullScreen: Bool { UserDefaults.standard.object(forKey: aboveFullScreenKey) as? Bool ?? true }
}

/// The language captions listen for. Defaults to the system language.
enum CaptionLanguage {
    static let key = "captions.language"
    static let choices = ["en-US", "en-GB", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "pt-BR", "nl-NL", "ja-JP", "ko-KR", "zh-CN"]

    static var current: String {
        get { UserDefaults.standard.string(forKey: key) ?? Locale.current.identifier(.bcp47) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var locale: Locale { Locale(identifier: current) }

    /// The choices, with the system language first when it isn't one of them.
    static var all: [String] {
        let system = Locale.current.identifier(.bcp47)
        return choices.contains(system) ? choices : [system] + choices
    }

    /// "English", for the chip.
    static func shortName(_ id: String) -> String {
        let code = Locale(identifier: id).language.languageCode?.identifier ?? id
        return (Locale.current.localizedString(forLanguageCode: code) ?? id).capitalized(with: Locale.current)
    }

    /// "English (United Kingdom)", for the menu.
    static func fullName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id)?.capitalized(with: Locale.current) ?? id
    }
}

/// Speech recognition permission, needed only where live words fall back to SFSpeechRecognizer (before macOS 26
/// and iOS 26). Asks once; returns at once on later systems.
enum CaptionPermission {
    static func ensureSpeech() async {
        if #available(macOS 26.0, iOS 26.0, *) { return }
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
        }
    }

    /// Reads a finished line aloud with VoiceOver (and other assistive tech), at most once per line.
    @MainActor static func announce(_ line: CaptionLine) {
        let text = line.speaker.map { "\($0): \(line.text)" } ?? line.text
        AccessibilityNotification.Announcement(text).post()
    }
}

// MARK: - Drawing

/// The colophon: three rings tangent at the bottom, the smallest filled. Decorative.
struct CaptionRingsMark: View {
    var color: Color = Ink.persimmon
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func ring(_ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: ox + (50 - r) * s, y: oy + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            let style = StrokeStyle(lineWidth: max(1, 8 * s))
            ctx.stroke(ring(50, 42), with: .color(color), style: style)
            ctx.stroke(ring(62, 30), with: .color(color), style: style)
            ctx.fill(ring(74, 18), with: .color(color))
            ctx.stroke(ring(74, 18), with: .color(color), style: style)
        }
        .accessibilityHidden(true)
    }
}

/// Caption lines, bottom-aligned: older lines smaller and fainter, the current line large with its newest word
/// in persimmon. VoiceOver reads finished lines only; the changing line is hidden from it.
struct CaptionLinesView: View {
    @ObservedObject var feed: CaptionFeed
    /// The current line's size.
    var size: CGFloat
    /// Older lines' sizes and colors, nearest first; also how many older lines show.
    var older: [(CGFloat, Color)]
    var showSpeakers: Bool
    var spacing: CGFloat
    /// Characters of the current line to show (its end).
    var currentLimit = 160
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        let past = Array(feed.history.suffix(older.count))
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(past.enumerated()), id: \.element.id) { i, line in
                let style = older[min(older.count - 1, past.count - 1 - i)]
                lineText(line, size: style.0, color: style.1, highlight: false)
                    .transition(limitMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
            ForEach(feed.current) { line in
                lineText(line, size: size, color: Ink.ink, highlight: true)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(limitMotion ? Motion.fade : Motion.settle, value: feed.history.last?.id)
    }

    private func lineText(_ line: CaptionLine, size: CGFloat, color: Color, highlight: Bool) -> some View {
        let text = highlight ? CaptionFeed.tail(line.text, limit: currentLimit) : line.text
        var out = Text("")
        if showSpeakers, let who = line.speaker {
            out = Text(who.uppercased()).font(Ink.mono(11, weight: .medium)).tracking(1.4).foregroundColor(Ink.mute) + Text("  ")
        }
        if highlight, let space = text.lastIndex(of: " ") {
            out = out + Text(String(text[..<space]) + " ").foregroundColor(color)
                + Text(String(text[text.index(after: space)...])).foregroundColor(Ink.accentText)
        } else if highlight {
            out = out + Text(text).foregroundColor(Ink.accentText)
        } else {
            out = out + Text(text).foregroundColor(color)
        }
        return out
            .font(Ink.serif(size))
            .lineSpacing(size * 0.12)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line.speaker.map { showSpeakers ? "\($0): \(line.text)" : line.text } ?? line.text)
    }
}

/// "12:04" (or "1:02:03" past an hour), for caption headers.
func captionClock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
