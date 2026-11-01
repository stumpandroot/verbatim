import Foundation

/// The words calendar's rules (WordsCalendar.swift), run by mac/tools/test-words-calendar.sh and both self-tests.
enum WordsCalendarChecks {
    static func run(_ check: (String, Bool) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US")
        cal.firstWeekday = 1
        func at(_ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0, year: Int = 2026) -> Date {
            cal.date(from: DateComponents(year: year, month: m, day: d, hour: h, minute: min))!
        }
        func dict(_ date: Date, _ words: Int, seconds: Double = 60, raw: String = "", said: String = "", place: String? = nil) -> WordsEntry {
            WordsEntry(date: date, words: words, seconds: seconds, raw: raw, said: said, place: place)
        }
        func rec(_ date: Date, _ kind: String, _ tone: WordsRecording.Tone, said: String = "") -> WordsEntry {
            WordsEntry(date: date, said: said, recording: WordsRecording(id: UUID(), title: kind, kind: kind, tone: tone, duration: 300))
        }

        // Shading and short counts.
        check("words calendar: shades", [0, 1, 249, 250, 749, 750, 1499, 1500, 9000].map(WordsCalendar.level) == [0, 1, 1, 2, 2, 3, 3, 4, 4])
        check("words calendar: short counts", [0, 420, 1000, 1240, 1960, 12_400].map(WordsCalendar.short) == ["", "420", "1k", "1.2k", "2k", "12k"])

        // October 2026 starts on a Thursday: four blanks in a Sunday-first calendar, 31 days.
        let now = at(10, 30, 20)
        let entries: [WordsEntry] = [
            dict(at(10, 1), 400), dict(at(10, 2), 300), dict(at(10, 3), 200),
            dict(at(10, 7, 9), 2000, seconds: 900), dict(at(10, 7, 15), 310, seconds: 120),
            rec(at(10, 8, 10), "Meeting", .persimmon),
            dict(at(10, 9), 100), dict(at(10, 10), 100),
            dict(at(10, 30, 7, 30), 3120, seconds: 1300),
            dict(at(10, 31), 999),              // after now: the future doesn't count
            dict(at(9, 30), 5000),              // another month
        ]
        let m = WordsCalendar.month(containing: at(10, 15), entries: entries, now: now, calendar: cal)
        check("words calendar: the month's grid", m.leading == 4 && m.days.count == 31 && m.weekdayInitials == ["S", "M", "T", "W", "T", "F", "S"])
        check("words calendar: totals count only days so far", m.words == 400 + 300 + 200 + 2310 + 100 + 100 + 3120 && m.daysSoFar == 30)
        check("words calendar: today and the days to come", m.days[29].isToday && m.days[30].isFuture && !m.days[28].isFuture)
        check("words calendar: a recording is a day talked, with no words", m.days[7].words == 0 && m.days[7].recordings.count == 1 && m.days[7].talked)
        check("words calendar: days talked", m.daysTalked == 8)
        check("words calendar: best day", m.best?.words == 3120 && cal.component(.day, from: m.best!.start) == 30)
        check("words calendar: the longest run goes through a recorded day",
              m.longestRun?.days == 4 && cal.component(.day, from: m.longestRun!.from) == 7 && cal.component(.day, from: m.longestRun!.to) == 10)
        let early = WordsCalendar.longestRun(Array(m.days.prefix(6)))
        check("words calendar: a run ends at a quiet day", early?.days == 3 && cal.component(.day, from: early!.to) == 3)
        check("words calendar: the busiest weekday and hour",
              m.busiestWeekday.map { m.weekdayInitials[$0] } == "F" && m.busiestHour == 7)
        let quiet = WordsCalendar.month(containing: at(10, 15), entries: [dict(at(10, 2), 50)], now: now, calendar: cal)
        check("words calendar: no rhythm with too little to go on", quiet.busiestWeekday == nil && quiet.busiestHour == nil && quiet.daysTalked == 1)
        let empty = WordsCalendar.month(containing: at(10, 15), entries: [], now: now, calendar: cal)
        check("words calendar: an empty month", empty.words == 0 && empty.best == nil && empty.longestRun == nil && empty.daysTalked == 0)
        var monday = cal; monday.firstWeekday = 2
        let mondayFirst = WordsCalendar.month(containing: at(10, 15), entries: [], now: now, calendar: monday)
        check("words calendar: a Monday-first region", mondayFirst.leading == 3 && mondayFirst.weekdayInitials.first == "M")

        // A day opened.
        let dayEntries: [WordsEntry] = [
            dict(at(10, 30, 8, 24), 120, said: "Send the invoice to the print shop", place: "Mail"),
            dict(at(10, 30, 9, 6), 260, said: "The invoice for the shoot, and the shoot schedule", place: "Mail"),
            dict(at(10, 30, 15), 140, said: "Lighting for Thursday", place: "Messages"),
            rec(at(10, 30, 7, 42), "Brain dump", .butter, said: "Invoice, shoot, props, props, Thursday"),
            rec(at(10, 30, 23, 15), "Journal entry", .petal),
        ]
        let detail = WordsCalendar.detail(at(10, 30), entries: dayEntries, now: now, calendar: cal)
        check("words calendar: a day's totals", detail.day.words == 520 && detail.day.dictations == 3 && detail.day.recordings.count == 2)
        check("words calendar: a day's marks in time order", detail.marks.map { ($0.hour * 100).rounded() } == [770, 840, 910, 1500, 2325] && detail.marks.first?.tone == .butter && detail.marks[1].tone == nil)
        check("words calendar: the timeline widens past 10 PM", detail.fromHour == 6 && detail.toHour == 24)
        check("words calendar: a day's recordings", detail.recordings.map(\.recording.kind) == ["Brain dump", "Journal entry"])
        check("words calendar: where words went", detail.places == [.init(name: "Mail", words: 380), .init(name: "Messages", words: 140)])
        check("words calendar: words said most", detail.topWords.map(\.word) == ["invoice", "shoot", "props", "Thursday"] && detail.topWords.map(\.count) == [3, 3, 2, 2])
        check("words calendar: small words and one-offs left out", WordsCalendar.topWords(["the the the and and um um it's it's", "once"]).isEmpty)
        check("words calendar: a word said with and without a capital shows lowercase", WordsCalendar.topWords(["Shoot shoot"]).first?.word == "shoot")

        // A year.
        let y = WordsCalendar.year(containing: at(10, 15), entries: entries, now: now, calendar: cal)
        check("words calendar: a year of months", y.months.count == 12 && y.words == m.words + 5000 && y.bestMonth == 9)
        check("words calendar: an empty year has no best month", WordsCalendar.year(containing: at(3, 1), entries: [], now: now, calendar: cal).bestMonth == nil)

        // Lengths and the shelf.
        check("words calendar: lengths", [100, 260, 3000, 7500, 31_230, 60_000, 212_480].map(WordsCalendar.equivalent)
              == [nil, "about a page", "about 12 pages", "about a short story", "about a novella", "about a novel", "about four novels"])
        check("words calendar: the shelf", WordsCalendar.shelfProgress(31_230).filled == 2 && WordsCalendar.shelfProgress(31_230).next?.name == "Novel"
              && WordsCalendar.shelfProgress(31_230).remaining == 18_770 && WordsCalendar.shelfProgress(400_000).next == nil)
        check("words calendar: articles", WordsCalendar.shelf.map(\.withArticle) == ["a short story", "a novella", "a novel", "a long novel", "an epic", "a trilogy"])
        let line = WordsCalendar.lengthLine(31_230, monthName: "October")
        check("words calendar: the month's length card", line?.title == "October is a novella." && line?.detail == "\(18_770.formatted()) more words make a novel.")
        check("words calendar: a short month's length card", WordsCalendar.lengthLine(3000, monthName: "May")?.title == "May is 12 pages long."
              && WordsCalendar.lengthLine(240, monthName: "May") == nil && WordsCalendar.lengthLine(310_000, monthName: "May")?.detail == nil)

        // Fillers.
        let filler = [dict(at(10, 2), 6, raw: "Um so, you know, um, the uh invoice. Like it's like done", said: "So the invoice. Like it's done"),
                      dict(at(10, 3), 2, raw: "um um okay", said: "Okay")]
        let removed = WordsCalendar.fillersRemoved(filler)
        check("words calendar: filler words taken out", removed.map(\.word) == ["um", "like", "uh", "you know"] && removed.map(\.count) == [4, 1, 1, 1])
        check("words calendar: no fillers without a before", WordsCalendar.fillersRemoved([dict(at(10, 2), 4, said: "um um")]).isEmpty)

        // Talking versus typing, pace, longest.
        let tvt = WordsCalendar.typingVersusTalking(words: 4000, seconds: 1800, typingWPM: 40)
        check("words calendar: talking versus typing", tvt.typing == 6000 && tvt.talking == 1800 && tvt.saved == 4200)
        check("words calendar: pace", WordsCalendar.pace(words: 141, seconds: 60) == 141 && WordsCalendar.pace(words: 50, seconds: 19) == nil)
        let weekly = WordsCalendar.weeklyPace([dict(at(10, 28), 280, seconds: 120), dict(at(10, 20), 130, seconds: 60), rec(at(10, 28), "Meeting", .persimmon)], now: now, weeks: 3, calendar: cal)
        check("words calendar: pace by week", weekly == [nil, 130, 140])
        check("words calendar: longest dictation", WordsCalendar.longest(entries)?.words == 3120 && WordsCalendar.longest([dict(at(10, 2), 9, seconds: 5)]) == nil)

        // Time of day.
        let tod = WordsCalendar.timeOfDay([dict(at(10, 2, 8), 620), dict(at(10, 2, 14), 200), dict(at(10, 2, 20), 180), dict(at(10, 2, 3), 0)], calendar: cal)
        check("words calendar: time of day", tod?.leader == .morning && tod.map { abs($0.share - 0.62) < 0.0001 } == true && tod?.bins.count == 9 && tod?.bins[1] == 620 && tod?.bins[7] == 180)
        check("words calendar: too little for a time of day", WordsCalendar.timeOfDay([dict(at(10, 2, 8), 199)], calendar: cal) == nil)
        check("words calendar: the time of day's words", WordsCalendar.talkTimeText(leader: .morning, share: 0.62) == ("Morning talker", "62% of your words come before noon")
              && WordsCalendar.talkTimeText(leader: .evening, share: 0.405).title == "Evening talker")

        // What you recorded.
        let kinds = WordsCalendar.kindCounts(dayEntries + [rec(at(10, 4), "Brain dump", .butter)])
        check("words calendar: what you recorded", kinds.map(\.kind) == ["Brain dump", "Journal entry"] && kinds.map(\.count) == [2, 1] && kinds.first?.tone == .butter)

        // Milestones.
        let big = [dict(at(10, 1), 15_000), dict(at(10, 20), 6_000), dict(at(10, 30), 1_000), rec(at(10, 30), "Meeting", .persimmon)]
        let ms = WordsCalendar.milestone(big, seen: 0)
        check("words calendar: a milestone and the day it passed", ms?.book.name == "Novella" && ms.map { cal.component(.day, from: $0.on) } == 20)
        check("words calendar: a milestone shows once", WordsCalendar.milestone(big, seen: 20_000) == nil && WordsCalendar.milestone([dict(at(10, 1), 100)], seen: 0) == nil)
        check("words calendar: the milestone's title", WordsCalendar.milestoneTitle(WordsCalendar.shelf[4]) == "\(200_000.formatted()) words. That\u{2019}s an epic.")
        check("words calendar: counting words", WordsCalendar.count("Send it — now, 3 times!") == 5)
    }
}
