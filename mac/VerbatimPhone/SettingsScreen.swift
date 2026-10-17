import SwiftUI

/// About me: a few lines of context, kept only on this iPhone (UserDefaults, never synced).
enum Profile {
    static let aboutMeKey = "profile.aboutMe"
    static let aboutMeLimit = 300
}

/// Settings: grouped cards with tinted icon tiles, mono section headers, and the version at the foot.
/// Personalization, Transcription, Sync and data, Support, and the Welcome tour.
struct SettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.openURL) private var openURL
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage(MotionPreference.key) private var motionLimited = false
    /// Groups stagger in when you switch to Settings.
    @State private var seen = SeenRows()
    @State private var entrance = 0
    /// Tap counts per row: each change gives that row's icon one small bounce.
    @State private var bumps: [String: Int] = [:]
    @State private var showDictionary = false
    @State private var showAboutMe = false
    @State private var exporting = false
    @State private var exportURL: URL? = nil
    @State private var confirmDelete = false
    @State private var confirmDeleteFinal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(Ink.serif(36)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 8)
                    .riseIn("title", index: 0, seen: seen, epoch: entrance)
                group(1, "Personalization") { personalization }
                group(2, "Transcription", footer: "Transcription runs on this iPhone. The first time, the model downloads once (about 200–600 MB). Links are fetched by your Mac.") { transcription }
                group(3, "Sync and data") { syncAndData }
                group(4, "Support") { support }
                group(5, "Welcome tour") { tour }
                footer
                    .padding(.top, 30)
                    .riseIn("footer", index: 6, seen: seen, epoch: entrance)
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .tabEntrance(.settings) { seen.entered(); entrance += 1 }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Settings")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showDictionary) { DictionaryScreen() }
        .navigationDestination(isPresented: $showAboutMe) { AboutMeScreen() }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .alert("Delete all data?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                // The second question waits for the first alert to finish closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmDeleteFinal = true }
            }
        } message: {
            Text(Cloud.enabled
                 ? "This removes your transcripts, recordings, projects, and Dictionary from this iPhone and from iCloud, so they're gone from your Mac too. It can't be undone."
                 : "This removes your transcripts, recordings, projects, and Dictionary from this iPhone. It can't be undone.")
        }
        .alert(deleteTitle, isPresented: $confirmDeleteFinal) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) { app.deleteAllData() }
        } message: {
            Text(deleteDetail)
        }
    }

    // MARK: Groups

    @ViewBuilder private var personalization: some View {
        SettingsRow(icon: "globe", tint: Ink.sageTint, title: "Language") {
            SettingsValue(app.preset == .english ? "English" : "Automatic")
        }
        .accessibilityElement(children: .combine)
        SettingsDivider()
        SettingsRow(icon: "waveform", tint: Ink.persimmonTint, title: "Your voice", subtitle: "Recognize you in recordings") {
            SettingsValue("Soon")
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not available yet")
        SettingsDivider()
        Button { bump("me"); showAboutMe = true } label: {
            SettingsRow(icon: "person", tint: Ink.petalTint, title: "About me", subtitle: "Context for titles and summaries", bounce: bumps["me", default: 0]) {
                SettingsValue(aboutMe.isEmpty ? "Add" : "Added"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        Button { bump("dict"); showDictionary = true } label: {
            SettingsRow(icon: "book.closed", tint: Ink.sageTint, title: "Dictionary", subtitle: "Names and words to spell your way", bounce: bumps["dict", default: 0]) {
                SettingsValue("\(app.store.dictionary.count)"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        SettingsRow(icon: "text.alignleft", tint: Ink.persimmonTint, title: "Summaries", subtitle: "For recordings over 5 minutes") {
            SettingsValue("Soon")
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not available yet")
        SettingsDivider()
        Menu {
            Picker("Appearance", selection: $app.appearance) {
                Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
        } label: {
            SettingsRow(icon: "moon", tint: Ink.petalTint, title: "Appearance", bounce: app.appearance) {
                SettingsValue(app.appearance == "light" ? "Light" : app.appearance == "dark" ? "Dark" : "Match system"); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        SettingsToggleRow(icon: "tortoise", tint: Ink.sageTint, title: "Limit animation",
                          subtitle: "Fades instead of movement; illustrations stay still.", isOn: $motionLimited)
    }

    @ViewBuilder private var transcription: some View {
        Menu {
            Picker("Quality", selection: $app.presetRaw) {
                ForEach(QualityPreset.allCases.filter { $0 != .advanced }) { p in Text(p.title).tag(p.rawValue) }
            }
        } label: {
            SettingsRow(icon: "chart.line.uptrend.xyaxis", tint: Ink.sageTint, title: "Quality", subtitle: app.preset.note, bounce: app.presetRaw) {
                SettingsValue(app.preset.title); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        SettingsToggleRow(icon: "person.2", tint: Ink.persimmonTint, title: "Identify speakers", isOn: $app.identifySpeakers)
        SettingsDivider()
        SettingsToggleRow(icon: "checkmark", tint: Ink.sageTint, title: "Apply Dictionary", isOn: $app.applyDictionary)
    }

    @ViewBuilder private var syncAndData: some View {
        SettingsRow(icon: Cloud.enabled ? "icloud" : "icloud.slash", tint: Ink.sageTint,
                    title: Cloud.enabled ? "Syncing with iCloud" : "iCloud is off",
                    subtitle: Cloud.enabled
                        ? "Transcripts, notes, bookmarks, projects, and the Dictionary match your Mac. Audio from the other device downloads when you play it."
                        : "Sign in to iCloud in the Settings app to sync with your Mac. Until then, everything stays on this iPhone.",
                    subtitleLines: nil) { EmptyView() }
            .accessibilityElement(children: .combine)
        SettingsDivider()
        Button {
            bump("export")
            exporting = true
            Task {
                exportURL = await app.exportEverything()
                exporting = false
            }
        } label: {
            SettingsRow(icon: "square.and.arrow.down", tint: Ink.petalTint, title: "Export everything", subtitle: "Markdown and JSON in one zip", bounce: bumps["export", default: 0]) {
                if exporting { ProgressView().controlSize(.small) } else { SettingsChevron() }
            }
        }
        .buttonStyle(SettingsRowPress())
        .disabled(exporting)
        SettingsDivider()
        Button { bump("delete"); confirmDelete = true } label: {
            SettingsRow(icon: "trash", tint: Ink.persimmonTint, title: "Delete all data", bounce: bumps["delete", default: 0], danger: true) { EmptyView() }
        }
        .buttonStyle(SettingsRowPress())
    }

    @ViewBuilder private var support: some View {
        Button { bump("support"); if let u = Links.mail(subject: "Verbatim support") { openURL(u) } } label: {
            SettingsRow(icon: "bubble.left", tint: Ink.sageTint, title: "Contact support", bounce: bumps["support", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        Button { bump("feedback"); if let u = Links.mail(subject: "Verbatim feedback") { openURL(u) } } label: {
            SettingsRow(icon: "pencil", tint: Ink.persimmonTint, title: "Share feedback", bounce: bumps["feedback", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        Button { bump("privacy"); openURL(Links.privacy) } label: {
            SettingsRow(icon: "lock", tint: Ink.petalTint, title: "Privacy policy", bounce: bumps["privacy", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        Button { bump("terms"); openURL(Links.terms) } label: {
            SettingsRow(icon: "doc.text", tint: Ink.sageTint, title: "Terms of use", bounce: bumps["terms", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        SettingsDivider()
        ShareLink(item: Links.base) {
            SettingsRow(icon: "square.and.arrow.up", tint: Ink.persimmonTint, title: "Share Verbatim", bounce: bumps["share", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .simultaneousGesture(TapGesture().onEnded { bump("share") })
    }

    @ViewBuilder private var tour: some View {
        SettingsToggleRow(icon: "sparkles", tint: Ink.petalTint, title: "Show it when Verbatim opens",
                          isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0; app.objectWillChange.send() }))
        SettingsDivider()
        Button { bump("tour"); app.showOnboarding = true } label: {
            SettingsRow(icon: "play.rectangle", tint: Ink.sageTint, title: "Show Tour", bounce: bumps["tour", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
    }

    private var footer: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return VStack(spacing: 6) {
            Text("Version \(version) (\(build))")
            Text("Verbatim · Stump & Root Co.")
        }
        .textCase(.uppercase)
        .font(Ink.mono(12)).tracking(1).foregroundStyle(Ink.mute)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Helpers

    private func group<Rows: View>(_ index: Int, _ title: String, footer: String? = nil, @ViewBuilder _ rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Ink.mono(12, weight: .medium)).tracking(2).foregroundStyle(Ink.dim)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { rows() }
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.hairline))
            if let footer {
                Text(footer).font(.system(size: 13)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 26)
        .riseIn("group-\(index)", index: index, seen: seen, epoch: entrance)
    }

    private func bump(_ key: String) { bumps[key, default: 0] += 1 }

    private var deleteTitle: String {
        let n = app.store.transcripts.count
        return n == 1 ? "Delete 1 transcript?" : "Delete \(n) transcripts?"
    }

    private var deleteDetail: String {
        let n = app.store.transcripts.count, p = app.store.projects.count, w = app.store.dictionary.count
        let things = n == 1 ? "the 1 transcript" : "all \(n) transcripts"
        let projects = p == 1 ? "1 project" : "\(p) projects"
        let words = w == 1 ? "1 Dictionary word" : "\(w) Dictionary words"
        return "Verbatim deletes \(things) (Recently Deleted too) with their audio, plus \(projects) and \(words), for good."
    }
}

// MARK: - Rows

/// The icon tile and the text of a settings row. The icon bounces once each time `bounce` changes.
struct SettingsLabel: View {
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var bounce: AnyHashable = 0
    var danger = false
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(danger ? Ink.accentText : Ink.ink)
                    .symbolEffect(.bounce, value: bounce)
                    .symbolEffectsRemoved(limitMotion)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17)).foregroundStyle(danger ? Ink.accentText : Ink.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Ink.mute)
                        .lineLimit(subtitleLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
        }
    }
}

/// One settings row: icon tile, title and subtitle, then a value, chevron, or control.
struct SettingsRow<Trailing: View>: View {
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var bounce: AnyHashable = 0
    var danger = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(icon: icon, tint: tint, title: title, subtitle: subtitle, subtitleLines: subtitleLines, bounce: bounce, danger: danger)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

/// A row with a switch that settles with a small spring. The icon bounces when it changes.
struct SettingsToggleRow: View {
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(icon: icon, tint: tint, title: title, subtitle: subtitle, bounce: isOn)
        }
        .toggleStyle(SpringSwitchStyle())
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 54)
    }
}

struct SettingsValue: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 16)).foregroundStyle(Ink.mute).lineLimit(1) }
}

struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.mute).accessibilityHidden(true)
    }
}

/// Marks a row that opens a menu of choices.
struct SettingsMenuMark: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute).accessibilityHidden(true)
    }
}

/// The hairline between rows, inset past the icon tile.
struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 56) }
}

/// Rows highlight while pressed (a color change, not movement).
struct SettingsRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Ink.ink.opacity(configuration.isPressed ? 0.05 : 0))
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - About me

/// A few lines of context (up to 300 characters) for wording titles and summaries. Stays on this iPhone.
struct AboutMeScreen: View {
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if aboutMe.isEmpty {
                        Text("For example: I'm a teacher. I record lessons and parent meetings, and often mention Room 12 and the spring fair.")
                            .font(.system(size: 16)).foregroundStyle(Ink.faint)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $aboutMe)
                        .focused($focused)
                        .font(.system(size: 16)).foregroundStyle(Ink.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .accessibilityLabel("About me")
                }
                .padding(10)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.hairline))
                .onChange(of: aboutMe) { _, v in
                    if v.count > Profile.aboutMeLimit { aboutMe = String(v.prefix(Profile.aboutMeLimit)) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Stays on this iPhone. Verbatim will use it on device to word titles and summaries.")
                        .font(.system(size: 13)).foregroundStyle(Ink.mute)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(aboutMe.count)/\(Profile.aboutMeLimit)").font(Ink.mono(12)).foregroundStyle(Ink.mute)
                        .accessibilityLabel("\(aboutMe.count) of \(Profile.aboutMeLimit) characters")
                }
                .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("About me")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if aboutMe.isEmpty { focused = true } }
    }
}
