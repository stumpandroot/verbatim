import SwiftUI

// Your words calendar on iPhone (DESIGN.md §13, Your words calendar): where its numbers come from, its shared pieces, and the cards under
// the month (approved mockup "Verbose words calendar", board 4, cards A to G). The rules are in
// Verbatim/Model/WordsCalendar.swift.

// MARK: - From the library

extension WordsEntry {
    /// A dictation (its pasted words, its time talking, what cleanup took out, and where it went) or a recording you
    /// made (a dot on its day, ready or not: it was recorded that day). Imports, links, anything deleted, and dictations
    /// still transcribing don't count. A recording's words are read only for the day you open (`Store.wordsDay`).
    static func from(_ t: Transcript) -> WordsEntry? {
        guard t.deletedAt == nil else { return nil }
        if t.isDictation {
            guard t.status == .ready else { return nil }
            let said = t.flow?.pasted ?? t.text
            // The keyboard can't tell which app a dictation went to, only what kind of app (FlowInfo.category).
            let place = t.flow.flatMap { $0.category == .other ? nil : $0.category.title }
            return WordsEntry(date: t.createdAt, words: WordsCalendar.count(said), seconds: t.duration,
                              raw: t.flow?.raw ?? "", said: said, place: place)
        }
        guard t.source == .voiceMemo else { return nil }
        let rec = WordsRecording(id: t.id, title: t.title, kind: RecordingKind.refinedName(t.kind),
                                 tone: (t.kind?.refinedHue ?? RefinedRules.kindHue(nil)).wordsTone, duration: t.duration)
        return WordsEntry(date: t.createdAt, recording: rec)
    }

    /// Words you said most counts recordings only you speak in.
    static func isSolo(_ kind: RecordingKind?) -> Bool {
        switch kind { case nil, .note?, .idea?, .brainDump?, .journal?: return true; default: return false }
    }
}

/// What the cards under a month show, worked out once per month and day (`Store.wordsExtras`).
struct WordsExtras {
    var fillers: [(word: String, count: Int)] = []
    var paces: [Int?] = []
    var longest: WordsEntry? = nil
    var timeOfDay: (share: Double, bins: [Int], leader: WordsCalendar.TalkTime, leaderShare: Double)? = nil
    var kinds: [(kind: String, tone: WordsRecording.Tone, count: Int)] = []
    var isEmpty = true
}

extension Store {
    /// Every dictation and recording as the words calendar counts them, kept until the library changes.
    var wordsEntries: [WordsEntry] { memo("words-entries") { live.compactMap(WordsEntry.from) } }

    private static func wordsKey(_ what: String, _ start: Date, _ now: Date) -> String {
        "words-\(what)|\(Int(start.timeIntervalSinceReferenceDate))|\(dayKey(now))"
    }

    /// The month holding `date`, kept until the library changes or the day turns.
    func wordsMonth(_ date: Date, now: Date) -> WordsCalendar.Month {
        let start = WordsCalendar.monthInterval(date).start
        return memo(Self.wordsKey("month", start, now)) { WordsCalendar.month(containing: date, entries: wordsEntries, now: now) }
    }

    /// The year holding `date`, kept the same way.
    func wordsYear(_ date: Date, now: Date) -> WordsCalendar.Year {
        let start = Calendar.current.dateInterval(of: .year, for: date)?.start ?? date
        return memo(Self.wordsKey("year", start, now)) { WordsCalendar.year(containing: date, entries: wordsEntries, now: now) }
    }

    /// The cards under the month holding `date`: its entries so far, and pace for the five weeks up to its end (or today).
    func wordsExtras(_ date: Date, now: Date) -> WordsExtras {
        let interval = WordsCalendar.monthInterval(date)
        return memo(Self.wordsKey("extras", interval.start, now)) {
            let all = wordsEntries
            let list = all.filter { WordsCalendar.within(interval, $0.date) && $0.date <= now }
            guard !list.isEmpty else { return WordsExtras() }
            return WordsExtras(fillers: WordsCalendar.fillersRemoved(list),
                               paces: WordsCalendar.weeklyPace(all, now: min(now, interval.end.addingTimeInterval(-1))),
                               longest: WordsCalendar.longest(list), timeOfDay: WordsCalendar.timeOfDay(list),
                               kinds: WordsCalendar.kindCounts(list), isEmpty: false)
        }
    }

    /// A day opened from the calendar, with the words of its recordings only you speak in.
    func wordsDay(_ day: Date, now: Date) -> WordsCalendar.DayDetail {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        return memo(Self.wordsKey("day", start, now)) {
            let list = wordsEntries.filter { cal.isDate($0.date, inSameDayAs: start) }.map { e -> WordsEntry in
                guard let r = e.recording, let t = transcript(r.id), WordsEntry.isSolo(t.kind) else { return e }
                var e = e
                e.said = t.segments.map(\.text).joined(separator: " ")
                return e
            }
            return WordsCalendar.detail(start, entries: list, now: now, calendar: cal)
        }
    }
}

extension RefinedHue {
    var wordsTone: WordsRecording.Tone {
        switch self {
        case .persimmon, .neutral: return .persimmon
        case .butter: return .butter
        case .sage: return .sage
        case .petal: return .petal
        }
    }
}

extension WordsRecording.Tone {
    var fill: Color {
        switch self {
        case .persimmon: return Refined.persimmon
        case .butter: return Refined.butter
        case .sage: return Refined.sage
        case .petal: return Refined.petal
        }
    }
}

// MARK: - Shared pieces

enum WordsText {
    /// "Friday, October 30".
    static func day(_ d: Date) -> String { Formats.pattern("EEEE, MMMM d").string(from: d) }
    /// "Oct 30".
    static func short(_ d: Date) -> String { Formats.pattern("MMM d").string(from: d) }
    /// "October 2026".
    static func month(_ d: Date) -> String { Formats.pattern("MMMM yyyy").string(from: d) }
    /// "October".
    static func monthName(_ d: Date) -> String { Formats.pattern("MMMM").string(from: d) }
    /// "9 AM".
    static func hour(_ h: Int) -> String {
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(h < 12 ? "AM" : "PM")"
    }
    /// "Oct 19 to 23", "Oct 30 to Nov 2", or "Oct 30".
    static func run(_ r: WordsCalendar.Run, calendar: Calendar = .current) -> String {
        if r.days == 1 { return short(r.from) }
        let b = calendar.isDate(r.from, equalTo: r.to, toGranularity: .month) ? Formats.pattern("d").string(from: r.to) : short(r.to)
        return "\(short(r.from)) to \(b)"
    }
    /// "6:12".
    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    static func words(_ n: Int) -> String { n == 1 ? "1 word" : "\(n.formatted()) words" }
}

/// A card in the calendar's look: the off-white card with its padding.
struct WordsCard<Content: View>: View {
    var fill: Color = Refined.card
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .refinedSurface(fill, radius: RefinedPlatform.radius(.card))
    }
}

/// A big number and what it counts: "22 of 31", "Days you talked".
struct WordsStat: View {
    var label: String
    var value: String
    var unit: String? = nil
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).refinedFont(.meta).foregroundStyle(Refined.mute)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 24, weight: .bold)).monospacedDigit().foregroundStyle(Refined.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).refinedFont(.hint).foregroundStyle(Refined.dim) }
            }
            if let detail { Text(detail).refinedFont(.meta).foregroundStyle(Refined.dim).lineLimit(2) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .combine)
    }
}

/// Book spines on a shelf: filled ones in the kind colors, the rest dashed.
struct WordsSpines: View {
    var filled: Int
    var count = WordsCalendar.shelf.count
    var labels = true
    var scale: CGFloat = 1
    private static let tones: [WordsRecording.Tone] = [.persimmon, .sage, .petal, .butter, .persimmon, .sage]
    private static let heights: [CGFloat] = [64, 78, 92, 100, 112, 118]
    private static let widths: [CGFloat] = [26, 30, 36, 40, 46, 52]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6 * scale) {
            ForEach(0..<count, id: \.self) { i in
                let have = i < filled
                let shape = UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                ZStack {
                    if have { shape.fill(Self.tones[i % 6].fill) }
                    else { shape.stroke(Refined.faint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                    if labels {
                        Text(WordsCalendar.shelf[i].name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(have ? Refined.onFill : Refined.mute)
                            .fixedSize()
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: Self.widths[i] * scale, height: Self.heights[i] * scale)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The cards under the month

/// Cards A to F (the mockup's letters, not shown): each shows only when there's something to say.
struct WordsFunCards: View {
    var extras: WordsExtras
    var words: Int
    var seconds: Double
    var typingWPM: Int

    var body: some View {
        let fillers = extras.fillers, paces = extras.paces, longest = extras.longest, tod = extras.timeOfDay, kinds = extras.kinds
        VStack(alignment: .leading, spacing: 12) {
            if !fillers.isEmpty { cleanedUp(fillers) }
            if words > 0 { typingCard }
            if paces.compactMap({ $0 }).count >= 2 { paceCard(paces) }
            if longest != nil || tod != nil {
                HStack(alignment: .top, spacing: 10) {
                    if let longest { longestCard(longest) }
                    if let tod { timeCard(tod) }
                }
            }
            if !kinds.isEmpty { recordedCard(kinds) }
        }
    }

    // A: Cleaned up.
    private func cleanedUp(_ list: [(word: String, count: Int)]) -> some View {
        let total = list.reduce(0) { $0 + $1.count }
        return WordsCard {
            Text("Cleaned up").refinedFont(.meta).foregroundStyle(Refined.mute)
            (Text(total.formatted()).bold() + Text(total == 1 ? " filler word taken out" : " filler words taken out"))
                .refinedFont(.rowTitle).foregroundStyle(Refined.ink)
            WordsFlow(spacing: 6) {
                ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { _, f in
                    HStack(spacing: 4) {
                        Text(f.word).strikethrough(true, color: Refined.accentText).foregroundStyle(Refined.ink)
                        Text(f.count.formatted()).foregroundStyle(Refined.dim)
                    }
                    .refinedFont(.chip).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Refined.heat[0], in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cleaned up: \(total) \(total == 1 ? "filler word" : "filler words") taken out. " + list.prefix(5).map { "\($0.word), \($0.count)" }.joined(separator: "; "))
    }

    // B: Talking versus typing.
    private var typingCard: some View {
        let t = WordsCalendar.typingVersusTalking(words: words, seconds: seconds, typingWPM: typingWPM)
        let share = t.typing > 0 ? min(1, t.talking / t.typing) : 0
        return WordsCard {
            Text("Talking versus typing").refinedFont(.meta).foregroundStyle(Refined.mute)
            bar("Typing at \(typingWPM) wpm", HomeWeek.savedText(t.typing), share: 1, fill: Refined.waveRest)
            bar("Talking", HomeWeek.savedText(t.talking), share: share, fill: Refined.persimmon)
            if t.saved >= 60 {
                Text("\(HomeWeek.savedText(t.saved)) back.").refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.sageText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typing these words at \(typingWPM) words per minute would take \(HomeWeek.savedText(t.typing)). You talked for \(HomeWeek.savedText(t.talking)).")
    }

    private func bar(_ label: String, _ value: String, share: Double, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label); Spacer(minLength: 8); Text(value).monospacedDigit()
            }
            .refinedFont(.hint).foregroundStyle(Refined.ink)
            GeometryReader { g in
                Capsule().fill(fill).frame(width: max(12, g.size.width * share), height: 12)
            }
            .frame(height: 12)
        }
    }

    // C: Pace, week by week.
    private func paceCard(_ paces: [Int?]) -> some View {
        let known = paces.compactMap { $0 }
        let last = known.last ?? 0, first = known.first ?? 0
        let change = last > first ? "up from \(first)" : last < first ? "down from \(first)" : "steady"
        return WordsCard {
            Text("Your pace, week by week").refinedFont(.meta).foregroundStyle(Refined.mute)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(last) wpm").font(.system(size: 24, weight: .bold)).monospacedDigit().foregroundStyle(Refined.ink)
                Text(change).refinedFont(.meta).foregroundStyle(Refined.sageText)
            }
            WordsPaceLine(values: paces).frame(height: 56)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your pace, week by week: \(last) words per minute, \(change).")
    }

    // D: The longest dictation.
    private func longestCard(_ e: WordsEntry) -> some View {
        let place = e.place.map { " into \($0)" } ?? ""
        return WordsCard {
            Text("Longest").refinedFont(.meta).foregroundStyle(Refined.mute)
            Text(WordsText.clock(e.seconds)).font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(Refined.ink)
            Text("\(WordsText.words(e.words))\(place), \(Formats.pattern("EEEE, MMM d").string(from: e.date))")
                .refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // E: The time of day.
    private func timeCard(_ t: (share: Double, bins: [Int], leader: WordsCalendar.TalkTime, leaderShare: Double)) -> some View {
        let text = WordsCalendar.talkTimeText(leader: t.leader, share: t.leaderShare)
        let top = Double(max(1, t.bins.max() ?? 1))
        return WordsCard {
            Text(text.title).refinedFont(.meta).foregroundStyle(Refined.mute)
            Text("\(Int((t.leaderShare * 100).rounded()))%").font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(Refined.ink)
            Text(text.line.replacingOccurrences(of: "\(Int((t.leaderShare * 100).rounded()))% ", with: ""))
                .refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(t.bins.enumerated()), id: \.offset) { _, b in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Refined.heat[b == 0 ? 0 : Double(b) / top > 0.66 ? 4 : Double(b) / top > 0.33 ? 3 : 2])
                        .frame(height: max(3, 22 * CGFloat(Double(b) / top)))
                }
            }
            .frame(height: 22, alignment: .bottom)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text.title): \(text.line).")
    }

    // F: What you recorded.
    private func recordedCard(_ kinds: [(kind: String, tone: WordsRecording.Tone, count: Int)]) -> some View {
        WordsCard {
            Text("What you recorded").refinedFont(.meta).foregroundStyle(Refined.mute)
            GeometryReader { g in
                let total = Double(kinds.reduce(0) { $0 + $1.count })
                let gaps = CGFloat(max(0, kinds.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { i, k in
                        Rectangle().fill(k.tone.fill).opacity(Self.repeatOpacity(kinds, i))
                            .frame(width: max(4, (g.size.width - gaps) * CGFloat(Double(k.count) / total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { i, k in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(k.tone.fill).opacity(Self.repeatOpacity(kinds, i)).frame(width: 8, height: 8)
                        Text("\(Self.plural(k.kind)) \(k.count)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.ink)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("What you recorded: " + kinds.map { "\(Self.plural($0.kind)), \($0.count)" }.joined(separator: "; "))
    }

    /// A second kind in the same color is drawn lighter, so the two read apart.
    static func repeatOpacity(_ kinds: [(kind: String, tone: WordsRecording.Tone, count: Int)], _ i: Int) -> Double {
        kinds[..<i].contains { $0.tone == kinds[i].tone } ? 0.55 : 1
    }

    /// "Brain dumps", "Journal entries", "Thoughts".
    static func plural(_ kind: String) -> String {
        if kind.hasSuffix("y") && !kind.hasSuffix("ay") { return String(kind.dropLast()) + "ies" }
        if kind.hasSuffix("s") || kind == "Audio only" { return kind }
        return kind + "s"
    }
}

/// Pace as a line, oldest week on the left; a week with too little is skipped.
struct WordsPaceLine: View {
    var values: [Int?]
    var body: some View {
        GeometryReader { g in
            let known = values.compactMap { $0 }
            let lo = Double((known.min() ?? 0) - 4), hi = Double((known.max() ?? 1) + 4)
            let pts: [CGPoint] = values.enumerated().compactMap { i, v in
                guard let v else { return nil }
                let x = values.count > 1 ? g.size.width * CGFloat(i) / CGFloat(values.count - 1) : g.size.width / 2
                let y = g.size.height * (1 - CGFloat((Double(v) - lo) / max(1, hi - lo)))
                return CGPoint(x: min(max(x, 5), g.size.width - 5), y: min(max(y, 5), g.size.height - 5))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    for q in pts.dropFirst() { p.addLine(to: q) }
                }
                .stroke(Refined.played, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if let l = pts.last { Circle().fill(Refined.played).frame(width: 9, height: 9).position(l) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Chips that wrap onto more lines.
struct WordsFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

// MARK: - G: the milestone, shown once

struct WordsMilestoneCard: View {
    var book: WordsCalendar.Book
    var on: Date
    var seeShelf: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Milestone").refinedFont(.meta).foregroundStyle(Refined.muteOnInk)
            Text(WordsCalendar.milestoneTitle(book))
                .refinedFont(.transcriptTitle).foregroundStyle(Refined.paperFixed)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240, alignment: .leading)
            Text("You passed it on \(WordsText.day(on)).").refinedFont(.hint).foregroundStyle(Refined.paperFixed.opacity(0.85))
            Button(action: seeShelf) {
                Text("See your shelf").refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.inkFixed)
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .background(Refined.paperFixed, in: Capsule())
            }
            .buttonStyle(RefinedPress())
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            WordsSpines(filled: 6, count: 5, labels: false, scale: 0.62)
                .rotationEffect(.degrees(-8))
                .offset(x: 14, y: -6)
        }
        .background(Refined.inkFixed)
        .clipShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("words.milestone")
    }
}
