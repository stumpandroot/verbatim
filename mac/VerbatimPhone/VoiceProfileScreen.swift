import SwiftUI

extension Notification.Name {
    /// UI tour: `true` opens Settings › Your voice in preview (step 2 with made-up progress); `false` closes it.
    static let verbatimShowVoiceProfile = Notification.Name("verbatimShowVoiceProfile")
}

/// Settings › Your voice: teach Verbatim your voice (intro, read aloud, result), then the switches that use it and
/// Delete voice profile. Shared recording and pieces are in VoiceEnrollment.swift.
struct VoiceProfileScreen: View {
    @StateObject private var model: VoiceEnrollment
    @ObservedObject private var status = VoiceProfileStatus.shared
    @AppStorage(VoiceProfile.dictationFilterKey) private var onlyMyVoice = false
    @AppStorage(VoiceProfile.labelYouKey) private var labelYou = true
    @State private var confirmingDelete = false
    /// Showing the saved profile (opened after enrolling before), rather than a step.
    @State private var overview: Bool
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.dismiss) private var dismiss

    init(preview: Bool = false) {
        _model = StateObject(wrappedValue: VoiceEnrollment(preview: preview))
        _overview = State(initialValue: !preview && VoiceProfileStatus.shared.isEnrolled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            .animation(limitMotion ? Motion.fade : Motion.nav, value: model.step)
            .animation(limitMotion ? Motion.fade : Motion.nav, value: overview)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Your voice")
        .navigationBarTitleDisplayMode(.inline)
        // The eyebrow and serif title sit on the paper, as on every Settings page; the bar stays empty.
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .onDisappear { model.cancel() }
        .sensoryFeedback(trigger: isGoodResult) { _, good in good ? Haptics.feedback(.milestone) : nil }
    }

    private var isGoodResult: Bool {
        if case .result(let r) = model.step { return r.hint == .good }
        return false
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(overview ? "Your voice" : "Your voice · step \(model.step.number) of 3").refinedFont(.meta).foregroundStyle(Refined.mute)
            Text(title).font(.system(size: 36, design: .serif)).foregroundStyle(Refined.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.system(size: 15)).foregroundStyle(Refined.dim).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        if overview { return status.isEnrolled ? "Verbose knows your voice." : "Teach Verbose your voice." }
        switch model.step {
        case .intro: return "Teach Verbose your voice."
        case .reading: return "Read this aloud."
        case .analyzing: return "Listening back…"
        case .result(let r): return r.hint == .good ? "All set." : (r.isEnrolled ? "Nearly there." : "Read a little more.")
        case .failed: return "That didn't work."
        }
    }

    private var detail: String? {
        if overview { return "Your voice profile stays on this iPhone. It isn't synced to iCloud or sent anywhere." }
        switch model.step {
        case .intro:
            return "Verbose learns how you sound so it keeps only your voice in dictation and marks your lines as “You” in transcripts. You'll read three short passages, about 30 seconds in all."
        case .reading:
            return "Verbose learns how you sound so it keeps only your voice in dictation. Your voice profile stays on this iPhone."
        case .analyzing:
            return "Verbose is learning your voice on this iPhone. The first time, a small model downloads."
        case .result: return nil
        case .failed(let message): return message
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if overview {
            VoiceQualityPanel(line: status.line, compact: true)
            controls
        } else {
            switch model.step {
            case .intro:
                privacyCard
            case .reading:
                VoicePassageCard(model: model, size: 22)
                if let q = status.quality, status.isEnrolled || status.isPartial, q > 0 {
                    // Reading more: how well it knows you so far.
                    VoiceQualityPanel(line: status.line, compact: true)
                }
            case .analyzing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Learning your voice…").font(.system(size: 15)).foregroundStyle(Refined.mute)
                }
                .padding(.top, 8)
            case .result(let r):
                VoiceQualityPanel(line: VoiceEnrollment.line(for: r), compact: true)
                controls
            case .failed:
                EmptyView()
            }
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VoiceRingsMark(lineWidth: 2.4, color: Refined.ink).frame(width: 48, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Stays on this iPhone").font(.system(size: 16, weight: .semibold)).foregroundStyle(Refined.ink)
                Text("Your voice profile is saved only here. It isn't synced to iCloud or sent anywhere, and you can delete it any time.")
                    .font(.system(size: 14)).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.tile)
    }

    /// The switches that use the profile and Delete voice profile, confirmed in place.
    private var controls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(title: "Only keep my voice in dictation",
                              subtitle: status.isEnrolled ? "Other voices nearby are left out." : "Available once Verbose knows your voice.",
                              isOn: $onlyMyVoice)
                .disabled(!status.isEnrolled)
            SettingsDivider()
            SettingsToggleRow(title: "Label my lines as “You”",
                              subtitle: "New transcripts name your speaker You.", isOn: $labelYou)
                .disabled(!status.isEnrolled)
            if status.isEnrolled || status.isPartial {
                SettingsDivider()
                if confirmingDelete {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Delete your voice profile from this iPhone?").font(.system(size: 16, weight: .semibold)).foregroundStyle(Refined.ink)
                        Text("Transcripts stop naming you You. You can set it up again any time.")
                            .font(.system(size: 14)).foregroundStyle(Refined.mute)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("Cancel") { confirmingDelete = false }.buttonStyle(RefinedActionStyle(kind: .quiet))
                            Button("Delete") {
                                status.delete()
                                confirmingDelete = false
                                overview = false
                                model.backToIntro()
                            }
                            .buttonStyle(RefinedActionStyle(kind: .strong))
                            .accessibilityLabel("Delete voice profile")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button { confirmingDelete = true } label: {
                        SettingsRow(hue: .persimmon, art: .iconDeleteAll, title: "Delete voice profile", danger: true) { EmptyView() }
                    }
                    .buttonStyle(SettingsRowPress())
                }
            }
        }
        .cardSurface(radius: Radius.tile)
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 10) {
            if overview {
                HStack(spacing: 10) {
                    Button("Start over") { overview = false; model.start() }.buttonStyle(RefinedActionStyle(kind: .quiet))
                    Button("Read more") { overview = false; model.readMore() }.buttonStyle(RefinedActionStyle(kind: .strong))
                }
            } else {
                switch model.step {
                case .intro:
                    Button("Start") { model.start() }.buttonStyle(RefinedActionStyle(kind: .strong))
                case .reading:
                    VoiceProgress(model: model, centered: true)
                    VoiceRecordButton(model: model, size: 72)
                        .padding(.top, 6)
                    if model.isPaused {
                        Button("Finish now") { model.finishNow() }.buttonStyle(RefinedActionStyle(kind: .quiet))
                    }
                case .analyzing:
                    EmptyView()
                case .result:
                    HStack(spacing: 10) {
                        Button("Read more") { model.readMore() }.buttonStyle(RefinedActionStyle(kind: .quiet))
                        Button("Done") { dismiss() }.buttonStyle(RefinedActionStyle(kind: .strong))
                    }
                case .failed:
                    Button("Try again") { model.start() }.buttonStyle(RefinedActionStyle(kind: .strong))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
        .background(Refined.paper)
    }
}
