// brand: native file
import SwiftUI

/// Home in Premium Native (mockup "premium", section 01), under the large title "Home" and the account button: the
/// date, This week as a persimmon gradient card (the words in big SF Pro Rounded, a seven-day mini chart with today
/// in white, and the time saved and recordings in one line), a row of four soft tiles, and the recent recordings as
/// Voicenotes-style items. The Record card is hidden unless Settings › Appearance turns it on; the floating record
/// button stands in for it. Same actions as Verbose style.
struct PremiumHome: View {
    @EnvironmentObject var app: PhoneState
    var now: Date
    @ObservedObject private var flow = FlowSettings.shared
    /// Settings › Appearance › Show the Record card on Home (Native only). Off by default.
    @AppStorage(PremiumHome.recordCardKey) private var showRecordCard = false
    @ScaledMetric(relativeTo: .largeTitle) private var bigNumber: CGFloat = 58

    static let recordCardKey = "home.premium.recordCard"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomeGreeting.dateLine(now)).font(.system(size: 15)).foregroundStyle(NativeInk.secondary)
                .id("home-top")
                .accessibilityAddTraits(.isHeader)
            WhatsNewBanner(top: 14) { HomeScreen.openWhatsNew(app) }
            weekCard.padding(.top, 18)
            if showRecordCard { recordCard.padding(.top, 12) }
            tiles.padding(.top, 12)
            recent.padding(.top, 28).id("home-recent")
        }
    }

    // MARK: This week

    /// Big numbers sit in the card's top third (3:1 is enough for them); every smaller line sits lower, where white
    /// measures 4.5:1 or better (PremiumRules, mac/tools/test-premium-phone.sh). Opens You.
    private var weekCard: some View {
        let week = HomeWeek(HomeCounts.entries(fromDictations: app.store.live), now: now)
        let saved = HomeScreen.savedLabel(week.secondsSaved(typingWPM: flow.typingWPM))
        let recordings = Self.recordingsThisWeek(app.store.live, now: now)
        let foot = "\(saved) saved typing · \(HomeCounts.countLabel(recordings, "recording", "recordings"))"
        return Button { HomeScreen.openProfile(app) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Text(week.words.formatted()).font(PremiumStyle.number(min(bigNumber, 76)))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 8)
                    PremiumWeekChart(week: week)
                }
                Text("words dictated").font(.system(size: 17, weight: .semibold)).padding(.top, 2)
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    Text("This week · \(foot)").font(.system(size: 14, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
            }
            .padding(.leading, 20).padding(.trailing, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
            .premiumCard(.persimmon)
            .onAppear { HomeScreen.recordCardsOnScreen.insert(.native) }
            .onDisappear { HomeScreen.recordCardsOnScreen.remove(.native) }
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(HomeCounts.countLabel(week.words, "word", "words")) dictated, \(saved) saved typing, \(HomeCounts.countLabel(recordings, "recording", "recordings")).")
        .accessibilityHint("Opens your You page, with the whole week.")
        .accessibilityIdentifier("home.week.premium")
    }

    /// Recordings, imports, and links made this calendar week (dictations count on their own).
    static func recordingsThisWeek(_ items: [Transcript], now: Date, calendar: Calendar = .current) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return items.filter { !$0.isDictation && week.contains($0.createdAt) }.count
    }

    // MARK: Record (optional)

    private var recordCard: some View {
        Button { app.requestRecord() } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record").font(.title2.bold()).foregroundStyle(NativeInk.label)
                    Text("Ready · \(HomeScreen.currentMic())").font(.subheadline).foregroundStyle(NativeInk.secondary).lineLimit(1)
                    Text("Keeps recording with the screen locked").font(.footnote).foregroundStyle(NativeInk.secondary)
                        .padding(.top, 4)
                }
                Spacer(minLength: 8)
                Circle().fill(PremiumStyle.disc).frame(width: 48, height: 48)
                    .padding(4).background(PremiumStyle.ring, in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumSoftCard(radius: 26)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityLabel("Record")
        .accessibilityHint("Starts a voice note. It keeps recording with the screen locked.")
        .accessibilityIdentifier("home.record.native")
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 10) {
            Button { app.homePath.append(DictationsRoute()) } label: { tile("Dictate", symbol: "mic") }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Opens your dictations and how to use the Verbose keyboard.")
            Menu {
                Button("Choose from Photos") { app.showPhotoPicker = true }
                Button("Choose files…") { app.showImporter = true }
                Button("Paste a link") { app.showLinkSheet = true }
            } label: { tile("Import", symbol: "square.and.arrow.down") }
            .menuStyle(.button)
            .buttonStyle(PhoneCardPress())
            .accessibilityHint("Choose a video from Photos, audio or video files, or paste a link to transcribe.")
            .accessibilityAction(named: "Paste a link") { app.showLinkSheet = true }
            Button { app.showPlayingSheet = true } label: { tile("What's playing", symbol: "speaker.wave.2") }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Transcribes sound from TikTok or any app.")
            Button { app.requestCaptions() } label: { tile("Live captions", symbol: "captions.bubble") }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Shows what's said in the room as captions.")
        }
    }

    /// A soft white tile: the symbol in a tinted circle over a short name.
    private func tile(_ title: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(NativeInk.accent)
                .frame(width: 38, height: 38)
                .background(PremiumInk.accentSoft, in: Circle())
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(NativeInk.label)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 86)
        .premiumSoftCard(radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Recent recordings

    private var recent: some View {
        let items = Array(app.store.live.lazy.filter { !$0.isDictation }.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            PremiumSectionHeader(title: "Recent recordings", action: "Library") { app.tab = .library }
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record something new.").font(.body.weight(.semibold)).foregroundStyle(NativeInk.label)
                    Text("Recordings and imports land here, and on your Mac.").font(.subheadline).foregroundStyle(NativeInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    PremiumRecordingItem(transcript: t, now: now, showsDivider: i < items.count - 1)
                }
            }
        }
    }
}

/// Seven small bars for the week, today in white, other days with words in a soft white, and the rest as stubs,
/// over the day letters. Text is solid white (no opacity), so it keeps its contrast.
struct PremiumWeekChart: View {
    var week: HomeWeek
    private static let height: CGFloat = 50

    var body: some View {
        let heights = PremiumRules.barHeights(week.days.map(\.words), future: week.days.map(\.isFuture), maxHeight: Double(Self.height))
        let letters = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { i, day in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(heights[i] == nil ? 0.18 : day.isToday ? 1 : 0.4))
                        .frame(width: 9, height: CGFloat(heights[i] ?? 4))
                        .frame(height: Self.height, alignment: .bottom)
                    Text(letters[(Calendar.current.component(.weekday, from: day.start) - 1) % letters.count])
                        .font(.system(size: 10, weight: day.isToday ? .heavy : .semibold))
                        .frame(width: 11)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
