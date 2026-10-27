import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The trust features on the iPhone: Settings › Privacy (Local Only and Network activity), the provenance line and
// data path badge, Copy for AI, Fix a word… with Fix all, Allow this download, and the Dictionary's CSV. The rules
// are shared with the Mac (Model/NetworkActivity.swift, Model/Transcript+Trust.swift).

extension PhoneState {
    /// Copy for AI: the transcript under a header (title, date, duration, speakers, source, language).
    func copyForAI(_ t: Transcript) {
        UIPasteboard.general.string = t.copyForAI
        say("Copied for AI, with title, date, and source")
        Haptics.play(.copied)
    }
}

// MARK: - Settings › Privacy

/// The row in Settings › Sync and storage that opens Privacy.
struct PhonePrivacyRow: View {
    var bounce: AnyHashable = 0
    var action: () -> Void
    @ObservedObject private var model = NetworkActivityModel.shared
    var body: some View {
        Button(action: action) {
            SettingsRow(icon: "hand.raised", tint: Ink.sageTint, art: .iconPrivacy, title: "Privacy",
                        subtitle: model.localOnly ? "Local Only is on. Nothing leaves this iPhone except iCloud sync." : "No account, no analytics. See what used the network.",
                        bounce: bounce) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
    }
}

struct PhonePrivacyScreen: View {
    @ObservedObject private var model = NetworkActivityModel.shared

    var body: some View {
        List {
            Section {
                Text(PrivacyStatement.text).font(.system(size: 15)).foregroundStyle(.lookInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: $model.localOnly) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local only").font(.system(size: 16, weight: .semibold))
                        Text(PrivacyStatement.localOnlyDetail).font(.system(size: 13)).foregroundStyle(.lookMute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(PhoneInk.switchOn)
            } footer: {
                Text("iCloud sync is Apple's and isn't listed here. Turn it on or off in Settings › Sync and storage.")
            }
            Section {
                if model.events.isEmpty {
                    Text("Nothing yet. Verbose hasn't used the network on this iPhone since the list was cleared.")
                        .font(.system(size: 14)).foregroundStyle(.lookMute)
                } else {
                    ForEach(model.events) { e in PhoneNetworkEventRow(event: e) }
                }
            } header: {
                HStack {
                    Text("Network activity")
                    Spacer()
                    if !model.events.isEmpty { Button("Clear") { model.clear() }.font(.system(size: 14, weight: .semibold)) }
                }
            } footer: {
                Text("When, why, and the host. Never what was sent. The last 500 are kept on this iPhone.")
            }
        }
        .scrollContentBackground(.hidden)
        .phonePage()
        .navigationTitle("Privacy")
        .onAppear { model.reload() }
    }
}

struct PhoneNetworkEventRow: View {
    var event: NetworkEvent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.purpose.label).font(.system(size: 15, weight: .medium)).foregroundStyle(.lookInk)
                Text(event.host.isEmpty ? "Unknown host" : event.host).font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(NetworkActivityModel.when(event.date)).font(.system(size: 13)).foregroundStyle(.lookMute).monospacedDigit()
                if event.refused {
                    Text("Refused by Local Only").font(.system(size: 12, weight: .medium)).foregroundStyle(.lookAccentText)
                } else if let b = ByteText.format(event.bytes) {
                    Text(b).font(.system(size: 12)).foregroundStyle(.lookMute).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Provenance

/// Under the title: the data path chip ("Local audio · local text"). Tap it for the details: "Team call.m4a · Parakeet
/// v3 · English · Oct 22, 2026 at 2:02 AM". The engine and exact time stay off the reading surface until you ask.
struct PhoneProvenanceLine: View {
    var transcript: Transcript
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    IconGlyph(art: .iconPrivacy, size: 12, color: Ink.dim)
                    Text(transcript.dataPathBadge).font(.system(size: 12.5)).foregroundStyle(.lookDim)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.lookMute)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Ink.ink.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Data path: \(transcript.dataPathBadge)")
            .accessibilityValue(open ? "Details shown" : "")
            .accessibilityHint(open ? "Hides the details." : "Shows the source, engine, and time.")
            if open {
                Text(transcript.provenanceLine).font(.system(size: 13)).foregroundStyle(.lookMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Local Only: Allow this download

struct PhoneAllowDownloadButton: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var body: some View {
        if LocalOnlyRefusal.isModelRefusal(transcript.error) {
            Button("Allow this download") {
                // Model downloads only, for the next 10 minutes; Local Only stays on for everything else.
                LocalOnly.allowModelDownloads()
                app.retry(transcript)
            }
            .buttonStyle(.phoneSecondary)
        }
    }
}

// MARK: - Fix a word… and Fix all

extension View {
    /// Fix a word… on a line: the word as heard and its right spelling. The line changes through the corrections
    /// layer (undoable in Review), then Fix all offers the same word elsewhere.
    func phoneFixWord(_ segment: Binding<Segment?>, transcriptID: UUID) -> some View {
        modifier(PhoneFixWord(segment: segment, transcriptID: transcriptID))
    }
}

private struct PhoneFixWord: ViewModifier {
    @EnvironmentObject var app: PhoneState
    @Binding var segment: Segment?
    var transcriptID: UUID
    @State private var heard = ""
    @State private var fix = ""

    func body(content: Content) -> some View {
        content.alert("Fix a word", isPresented: Binding(get: { segment != nil }, set: { if !$0 { segment = nil } })) {
            TextField("As heard", text: $heard).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Correct spelling", text: $fix).autocorrectionDisabled()
            Button("Cancel", role: .cancel) { reset() }
            Button("Fix") { apply() }
        } message: {
            Text(segment.map { "“\(String($0.text.prefix(80)))”" } ?? "")
        }
    }

    private func reset() { heard = ""; fix = ""; segment = nil }

    private func apply() {
        defer { reset() }
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines), f = fix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = segment, !h.isEmpty, !f.isEmpty, h != f else { return }
        // The word as it's written in the line (any case), so the fix keeps its case.
        guard let r = CorrectEverywhere.ranges(of: h, in: s.text).first else { app.say("“\(h)” isn't in that line."); return }
        let found = (s.text as NSString).substring(with: r)
        app.store.update(transcriptID) { $0.correct(segment: s.id, from: found, to: CorrectEverywhere.casePreserved(f, for: found)) }
        // Not remembered: counted, so the same fix made again becomes a Dictionary suggestion.
        EditLearner.record([(heard: found, fixed: f)])
        if let t = app.store.transcript(transcriptID) { FixAllOffer.shared.consider(t, heard: h, fix: f, remembered: false) }
    }
}

struct PhoneFixAllBanner: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var fix = FixAllOffer.shared
    var transcriptID: UUID

    var body: some View {
        if let o = fix.offer, o.transcript == transcriptID {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(CorrectEverywhere.bannerText(heard: o.heard, count: o.count)).font(.system(size: 15)).foregroundStyle(.lookInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button { fix.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.lookMute) }
                        .accessibilityLabel("Dismiss")
                }
                HStack(spacing: 10) {
                    Button(CorrectEverywhere.buttonTitle(o.count)) {
                        let n = app.store.fixEverywhere(o.transcript, heard: o.heard, fix: o.fix)
                        fix.dismiss()
                        app.say(n == 1 ? "Fixed 1 more place. Undo it in Review." : "Fixed \(n) more places. Undo any in Review.")
                    }
                    .buttonStyle(.phoneSecondary)
                    if o.offerDictionary {
                        Button("Add to Dictionary") {
                            let title = app.store.transcript(o.transcript)?.title ?? "Added on iPhone"
                            app.store.remember(preferred: o.fix, heardAs: o.heard, from: title)
                            app.say("\(o.fix) added to Dictionary")
                            var next = o; next.offerDictionary = false
                            fix.offer = next
                        }
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.lookDim)
                    }
                }
            }
            .padding(14)
            .background(Ink.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.lookHairline))
        }
    }
}

// MARK: - Dictionary CSV

struct PhoneDictionaryCSVSection: View {
    @EnvironmentObject var app: PhoneState
    @State private var importing = false
    @State private var shareURL: URL? = nil

    var body: some View {
        Section {
            Button("Import CSV…") { importing = true }
            Button("Export CSV…") { export() }.disabled(app.store.dictionary.isEmpty)
        } header: {
            Text("Spreadsheet")
        } footer: {
            Text("Columns: heard, replacement, enabled, project, learned_from, created. Words already in your Dictionary are skipped.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                app.say("Couldn't read that file."); return
            }
            app.say(app.store.importDictionaryCSV(text).summary)
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }

    private func export() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Verbose Dictionary.csv")
        do {
            try app.store.dictionaryCSV().write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
        } catch {
            app.say("Couldn't export: \(error.localizedDescription)")
        }
    }
}
