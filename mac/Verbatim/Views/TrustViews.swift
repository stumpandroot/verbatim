import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The trust features' Mac views: Settings › Privacy (Local Only, Spotlight, Network activity), the After pasting
// row, the data path badge, Fix all, Copy for AI, Export as Markdown files, and the Dictionary's CSV menu. Tokens,
// BrandArt, and sentence case per mac/DESIGN.md; nothing here sits on a material.

// MARK: - Settings search entries

extension SettingsIndex {
    static let trustEntries: [SettingsEntry] = [
        .init("privacy.statement", .privacy, "No account, no analytics", PrivacyStatement.text, keywords: "privacy data tracking telemetry account"),
        .init("privacy.localOnly", .privacy, "Local Only", PrivacyStatement.localOnlyDetail, keywords: "offline airplane network internet block cloud privacy"),
        .init("privacy.spotlight", .privacy, "Show transcripts in Spotlight", "Titles, words, and dates are indexed on this Mac, so Spotlight finds what was said. Turning this off removes them from Spotlight.", keywords: "search index finder corespotlight"),
        .init("privacy.activity", .privacy, "Network activity", "Every time Verbatim used the network: when, why, and the host. Never what was sent. The last 500 are kept on this Mac.", keywords: "log requests hosts connections downloads privacy"),
        .init("dictate.autoSend", .dictate, "After pasting, press", "Return or ⌘Return sends the message once a dictation lands. Never in a password field.", keywords: "send enter return submit auto message chat"),
    ]
}

// MARK: - Settings › Privacy

struct PrivacySettingsPane: View {
    @ObservedObject private var model = NetworkActivityModel.shared
    @State private var spotlight = SpotlightIndex.enabled

    var body: some View {
        SettingsPane(tab: .privacy) {
            SettingsGroup {
                SettingsRow("privacy.statement")
            }
            SettingsGroup(title: "Network", footer: PrivacyStatement.iCloudNote) {
                SettingsToggleRow("privacy.localOnly", isOn: $model.localOnly)
                SettingsToggleRow("privacy.spotlight", isOn: Binding(get: { spotlight }, set: { v in
                    spotlight = v
                    SpotlightIndex.shared.setEnabled(v)
                }))
            }
            SettingsGroup(title: "Network activity") {
                SettingsRow("privacy.activity", detail: activityDetail) {
                    Button("Clear") { model.clear() }
                        .buttonStyle(.brandSecondary).disabled(model.events.isEmpty)
                }
                if model.events.isEmpty {
                    Text("Nothing yet. Verbatim hasn't used the network on this Mac since the list was cleared.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { RowRule() }
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.events) { e in NetworkEventRow(event: e) }
                    }
                }
            }
        }
        .onAppear { model.reload(); spotlight = SpotlightIndex.enabled }
    }

    private var activityDetail: String {
        let n = model.events.count
        let base = SettingsIndex.entry("privacy.activity")?.detail ?? ""
        return n == 0 ? base : base + " \(n) listed."
    }
}

/// One request: what it was for, the host, when, its size, and whether Local Only refused it.
struct NetworkEventRow: View {
    var event: NetworkEvent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.purpose.label).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
                Text(event.host.isEmpty ? "Unknown host" : event.host).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(NetworkActivityModel.when(event.date)).font(.system(size: 12.5)).foregroundStyle(Ink.mute).monospacedDigit()
                if event.refused {
                    HStack(spacing: 4) {
                        IconGlyph(art: .iconPrivacy, size: 12, color: Ink.accentText)
                        Text("Refused by Local Only").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.accentText)
                    }
                } else if let b = ByteText.format(event.bytes) {
                    Text(b).font(.system(size: 12)).foregroundStyle(Ink.mute).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { RowRule() }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings › Dictation › After pasting

struct AutoSendSettingsRow: View {
    @AppStorage(AutoSend.keyKey) private var key = AutoSend.Key.nothing.rawValue
    @AppStorage(AutoSend.scopeKey) private var scope = AutoSend.Scope.chats.rawValue

    var body: some View {
        SettingsRow("dictate.autoSend", detail: detail) {
            HStack(spacing: 8) {
                Picker("After pasting, press", selection: $key) {
                    ForEach(AutoSend.Key.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
                if key != AutoSend.Key.nothing.rawValue {
                    Picker("In", selection: $scope) {
                        ForEach(AutoSend.Scope.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var detail: String {
        let k: AutoSend.Key = AutoSend.Key(rawValue: key) ?? .nothing
        guard k != .nothing else { return "Nothing is pressed: you send the message yourself." }
        let where_ = (AutoSend.Scope(rawValue: scope) ?? .chats) == .chats
            ? "in chat and work apps such as Messages, Slack, and Teams"
            : "in every app, including email and terminals"
        return "Verbatim presses \(k.title) after a dictation pastes \(where_). Never in a password field, and never when the paste didn't land."
    }
}

// MARK: - Data path badge and details

/// "Local audio · local text" in a neutral pill, with the privacy glyph.
struct DataPathBadge: View {
    var transcript: Transcript
    var body: some View {
        HStack(spacing: 5) {
            IconGlyph(art: .iconPrivacy, size: 12, color: Ink.dim)
            Text(transcript.dataPathBadge).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Ink.ink.opacity(0.06), in: Capsule())
        .help(transcript.dataLeftDevice
              ? "Something left this Mac for this transcript: a link download or cloud cleanup. Transcription itself ran on this device."
              : "Recorded or imported here, transcribed on this device. Nothing about it left your devices, except iCloud sync when it's on.")
        .accessibilityLabel("Data path: \(transcript.dataPathBadge)")
    }
}

// MARK: - Fix all

/// After a correction, when the same word appears elsewhere: "“teh” appears 4 more times." Fix all 4 · Add to Dictionary.
struct FixAllBanner: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var fix = FixAllOffer.shared
    var transcriptID: UUID

    var body: some View {
        if let o = fix.offer, o.transcript == transcriptID {
            HStack(spacing: 12) {
                Text(CorrectEverywhere.bannerText(heard: o.heard, count: o.count))
                    .font(.system(size: 13)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(CorrectEverywhere.buttonTitle(o.count)) { fixAll(o) }.buttonStyle(.brandSecondary)
                if o.offerDictionary {
                    Button("Add to Dictionary") { addToDictionary(o) }.buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
                }
                Button { fix.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.mute) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Ink.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.hairline))
            .transition(.opacity)
        }
    }

    private func fixAll(_ o: FixAllOffer.Offer) {
        let n = app.store.fixEverywhere(o.transcript, heard: o.heard, fix: o.fix)
        fix.dismiss()
        app.toast = Toast(n == 1 ? "Fixed 1 more place. Undo it in Review." : "Fixed \(n) more places. Undo any of them in Review.", action: "Review") {
            NotificationCenter.default.post(name: .verbatimShowMode, object: TranscriptView.Mode.review.rawValue)
        }
    }

    private func addToDictionary(_ o: FixAllOffer.Offer) {
        guard let t = app.store.transcript(o.transcript) else { return }
        let scoped = app.projectScopedVocabulary ? t.projectId : nil
        app.store.remember(preferred: o.fix, heardAs: o.heard, from: t.title, project: scoped)
        app.toast = Toast("\(o.fix) added to Dictionary" + (scoped != nil ? " for this project" : ""))
        var next = o; next.offerDictionary = false
        fix.offer = next
    }
}

// MARK: - Local Only: Allow this download

/// On a transcript that failed because Local Only refused its model download.
struct AllowDownloadButton: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        if LocalOnlyRefusal.isModelRefusal(transcript.error) {
            Button("Allow this download") {
                // Model downloads only, for the next 10 minutes; Local Only stays on for everything else.
                LocalOnly.allowModelDownloads()
                app.retry(transcript)
            }
            .buttonStyle(.brandSecondary)
            .help("Downloads the model once, then Local Only goes back to refusing downloads.")
        }
    }
}

// MARK: - Copy for AI

@MainActor
enum CopyForAI {
    /// ⌥⇧⌘C on a transcript (⌥⌘C is Live captions).
    static func copy(_ t: Transcript, app: AppState) {
        guard t.status == .ready else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t.copyForAI, forType: .string)
        app.toast = Toast("Copied for AI, with title, date, and source")
        Sounds.done()
    }
}

// MARK: - Export as Markdown files

enum MarkdownBulkExport {
    /// Asks for a folder, then writes one Markdown note with properties per finished transcript. Returns how many.
    @MainActor @discardableResult
    static func run(_ list: [Transcript], app: AppState) -> Int {
        let ready = list.filter { $0.status == .ready }
        guard !ready.isEmpty else { app.toast = Toast("Nothing finished to export yet."); return 0 }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = ready.count == 1 ? "Choose a folder for the Markdown note." : "Choose a folder for \(ready.count) Markdown notes, one per transcript. Obsidian reads their properties."
        guard panel.runModal() == .OK, let dir = panel.url else { return 0 }
        let names = Dictionary(app.store.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let options = ExportOptions.saved
        var used = Set<String>()
        var written = 0, failed = 0
        for t in ready {
            let name = MarkdownNotes.fileName(t.title, used: &used) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            let text = t.markdownNote(projectName: t.projectId.flatMap { names[$0] }, options: options)
            do { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8); written += 1 }
            catch { failed += 1; Log.note("markdown export failed: \(error.localizedDescription)") }
        }
        app.toast = Toast(failed == 0 ? "Exported \(written) Markdown note\(written == 1 ? "" : "s")" : "Exported \(written); \(failed) couldn't be written",
                          action: "Show") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        return written
    }

    /// Everything in the Library (dictations stay in Dictations), newest first.
    @MainActor static func all(_ app: AppState) -> [Transcript] {
        app.store.live.filter { !$0.isDictation && $0.status == .ready }.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Dictionary CSV

struct DictionaryCSVMenu: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Menu {
            Button("Import CSV…") { importCSV() }
            Button("Export CSV…") { exportCSV() }.disabled(app.store.dictionary.isEmpty)
        } label: {
            Label("CSV", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Import words from a spreadsheet, or export your Dictionary: heard, replacement, enabled, project, learned_from, created")
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a CSV with heard and replacement columns. Words already in your Dictionary are skipped."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            app.toast = Toast("Couldn't read that file."); return
        }
        let report = app.store.importDictionaryCSV(text)
        Log.note("dictionary: imported CSV, added \(report.added), updated \(report.updated), skipped \(report.skipped), invalid \(report.invalid)")
        app.toast = Toast(report.summary)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Verbatim Dictionary.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.store.dictionaryCSV().write(to: url, atomically: true, encoding: .utf8)
            app.toast = Toast("Exported \(app.store.dictionary.count) words", action: "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            app.toast = Toast("Couldn't save the CSV: \(error.localizedDescription)")
        }
    }
}
