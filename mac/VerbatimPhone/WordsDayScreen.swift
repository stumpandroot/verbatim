import SwiftUI

// A day from the words calendar (DESIGN.md §13, Your words calendar; mockup board 2): its words, how many dictations and recordings, the
// time saved, a line through the day with a dot for each (sized by words, colored by kind), the recordings (each opens),
// where the words went, the words you said most, and the same day a month before.

struct WordsDayScreen: View {
    var day: Date
    @Environment(PhoneState.self) var app
    @ObservedObject private var flow = FlowSettings.shared

    static var onScreen = 0

    var body: some View {
        let store = app.store
        let now = Date()
        let d = store.wordsDay(day, now: now)
        let month = store.wordsMonth(day, now: now)
        let isBest = month.best?.start == d.day.start && d.day.words > 0
        let saved = WordsCalendar.typingVersusTalking(words: d.day.words, seconds: d.day.seconds, typingWPM: flow.typingWPM).saved
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your words").refinedFont(.meta).foregroundStyle(Refined.mute)
                    Text(WordsText.day(day)).refinedFont(.largeTitle).foregroundStyle(Refined.ink)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.day.words.formatted()).scaledFont(40, weight: .bold).monospacedDigit().foregroundStyle(Refined.ink)
                    Text((d.day.words == 1 ? "word" : "words") + (isBest ? ", your best day this month" : ""))
                        .refinedFont(.hint).foregroundStyle(Refined.dim)
                }
                .accessibilityElement(children: .combine)
                WordsFlow(spacing: 8) {
                    if d.day.dictations > 0 { chip(d.day.dictations == 1 ? "1 dictation" : "\(d.day.dictations) dictations") }
                    if !d.day.recordings.isEmpty { chip(d.day.recordings.count == 1 ? "1 recording" : "\(d.day.recordings.count) recordings") }
                    if saved >= 60 {
                        Text("\(HomeWeek.savedText(saved)) saved").refinedFont(.chip, weight: .semibold).foregroundStyle(Refined.sageText)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(Refined.sageTint, in: Capsule())
                    }
                }
                if !d.marks.isEmpty { timeline(d) }
                if !d.recordings.isEmpty { recordings(d) }
                if !d.places.isEmpty { places(d) }
                if !d.topWords.isEmpty { topWords(d) }
                monthAgo(now: now)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle(Formats.pattern("MMM d").string(from: day))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Self.onScreen += 1 }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
    }

    private func chip(_ s: String) -> some View {
        Text(s).refinedFont(.chip).foregroundStyle(Refined.ink)
            .padding(.horizontal, 12).padding(.vertical, 6).background(Refined.card, in: Capsule())
    }

    private func timeline(_ d: WordsCalendar.DayDetail) -> some View {
        let span = Double(max(1, d.toHour - d.fromHour))
        let ticks = (0...4).map { d.fromHour + Int((span * Double($0) / 4).rounded()) }
        return WordsCard {
            Text("Through the day").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Refined.rail).frame(height: 2)
                    ForEach(Array(d.marks.enumerated()), id: \.offset) { _, m in
                        let size = 8 + CGFloat(min(m.words, 750)) / 750 * 20 + (m.tone == nil ? 0 : 6)
                        Circle().fill(m.tone?.fill ?? Refined.faint)
                            .overlay(Circle().stroke(Refined.card, lineWidth: 2))
                            .frame(width: size, height: size)
                            .position(x: g.size.width * CGFloat((m.hour - Double(d.fromHour)) / span), y: g.size.height / 2)
                    }
                }
            }
            .frame(height: 44)
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { i, h in
                    Text(WordsText.hour(h % 24)).refinedFont(.caption).foregroundStyle(Refined.mute)
                    if i < ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
            legend(d)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Through the day: " + d.marks.map { m in
            let minutes = Int((m.hour * 60).rounded())
            let c = DateComponents(hour: minutes / 60, minute: minutes % 60)
            let time = Calendar.current.date(from: c).map { Formats.pattern("h:mm a").string(from: $0) } ?? ""
            return m.tone == nil ? "\(time), dictation, \(WordsText.words(m.words))" : "\(time), recording"
        }.joined(separator: "; "))
    }

    private func legend(_ d: WordsCalendar.DayDetail) -> some View {
        var seen: [String] = []
        var items: [(String, Color)] = []
        if d.marks.contains(where: { $0.tone == nil }) { items.append(("Dictation", Refined.faint)) }
        for r in d.recordings where !seen.contains(r.recording.kind) {
            seen.append(r.recording.kind); items.append((r.recording.kind, r.recording.tone.fill))
        }
        return WordsFlow(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 5) { Circle().fill(it.1).frame(width: 8, height: 8); Text(it.0) }
                    .refinedFont(.caption).foregroundStyle(Refined.mute)
            }
        }
    }

    private func recordings(_ d: WordsCalendar.DayDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Recordings")
            PaperCard {
                ForEach(Array(d.recordings.enumerated()), id: \.offset) { i, r in
                    if i > 0 { PaperDivider(leading: 60) }
                    Button { app.open(r.recording.id) } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(r.recording.tone.fill)
                                .frame(width: 34, height: 34)
                                .overlay(IconGlyph(art: Self.art(r.recording.kind), size: 18, color: Refined.onFill))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.recording.title).refinedFont(.rowTitle).foregroundStyle(Refined.ink).lineLimit(2)
                                Text("\(r.recording.kind) \u{00B7} \(Formats.pattern("h:mm a").string(from: r.at)) \u{00B7} \(WordsText.clock(r.recording.duration))")
                                    .refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                            }
                            Spacer(minLength: 8)
                            SettingsChevron()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRowPress())
                    .accessibilityHint("Opens the recording.")
                }
            }
        }
    }

    /// The glyph for a kind as the calendar names it ("Brain dump", "Meeting").
    static func art(_ kind: String) -> BrandArt {
        switch kind {
        case "Meeting": return .iconSpeakers
        case "Interview": return .iconQuote
        case "Journal", "Journal entry": return .iconNotes
        case "Talk": return .iconVoice
        case "Brain dump": return .iconBrainDump
        case "Audio only": return .iconAudio
        case "Thought", "Thoughts": return .iconThought
        default: return .iconMic
        }
    }

    private func places(_ d: WordsCalendar.DayDetail) -> some View {
        let top = Double(max(1, d.places.first?.words ?? 1))
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Where your words went")
            WordsCard {
                ForEach(d.places, id: \.name) { p in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(p.name).refinedFont(.hint).foregroundStyle(Refined.ink)
                            Spacer(minLength: 8)
                            Text(p.words.formatted()).refinedFont(.hint).monospacedDigit().foregroundStyle(Refined.dim)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Refined.heat[0])
                                Capsule().fill(Refined.heat[3]).frame(width: max(8, g.size.width * CGFloat(Double(p.words) / top)))
                            }
                        }
                        .frame(height: 8)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(p.name), \(WordsText.words(p.words))")
                }
            }
        }
    }

    private func topWords(_ d: WordsCalendar.DayDetail) -> some View {
        let top = d.topWords.first?.count ?? 1
        let fills = [Refined.persimmonTint, Refined.butterTint, Refined.sageTint]
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Words you said most")
            WordsFlow(spacing: 8) {
                ForEach(Array(d.topWords.enumerated()), id: \.offset) { i, w in
                    let size: CGFloat = w.count >= top ? 20 : w.count * 3 >= top * 2 ? 18 : 16
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(w.word).scaledFont(size, weight: .semibold).foregroundStyle(Refined.ink)
                        Text("\(w.count)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.dim)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(fills[min(2, i / 2)], in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(w.word), \(w.count) times")
                }
            }
            Text("Leaves out small words like \u{201C}the\u{201D} and \u{201C}and\u{201D}. Worked out on this iPhone.")
                .refinedFont(.caption).foregroundStyle(Refined.mute).padding(.horizontal, 4)
        }
    }

    private func monthAgo(now: Date) -> some View {
        Group {
            if let back = Calendar.current.date(byAdding: .month, value: -1, to: day) {
                let b = app.store.wordsDay(back, now: now).day
                if b.talked {
                    WordsCard {
                        Text("A month ago, \(Formats.pattern("MMMM d").string(from: back))").refinedFont(.meta).foregroundStyle(Refined.mute)
                        Text([WordsText.words(b.words), b.recordings.isEmpty ? nil : (b.recordings.count == 1 ? "1 recording" : "\(b.recordings.count) recordings")]
                            .compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
