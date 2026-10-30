import SwiftUI

// The transcript's sheets (DESIGN.md §13: Apple draws sheets), opened from the More menu (TranscriptScreen.swift):
// Find, Speakers, and Details. Standard sheets with a grabber, inset grouped lists, and system
// controls. The summary is the transcript's Summary tab (SummaryBlock.swift).

/// Find: the lines that contain what you type, with their times. A tap closes the sheet, plays from that line, and
/// scrolls the transcript to it.
struct TranscriptFindSheet: View {
    var transcript: Transcript
    var lines: [Segment]
    var onPick: (Segment) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var matches: [Segment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return lines.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        Section {
                            ForEach(matches) { s in
                                Button { onPick(s) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(s.start.timecode).font(.subheadline).monospacedDigit().foregroundStyle(Refined.mute)
                                        VStack(alignment: .leading, spacing: 2) {
                                            if transcript.speakers.count >= 2, let sp = transcript.speakerName(s.speaker) {
                                                Text(sp).font(.footnote.weight(.semibold)).foregroundStyle(Refined.mute)
                                            }
                                            Text(highlighted(s.text)).foregroundStyle(Refined.ink).lineLimit(3)
                                        }
                                    }
                                }
                                .accessibilityHint("Plays from \(s.start.timecode) and shows the line")
                            }
                        } header: {
                            Text(matches.count == 1 ? "1 line" : "\(matches.count) lines")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find in this transcript")
            .navigationTitle("Find")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var start = a.startIndex
        while start < a.endIndex, let r = a[start...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].font = .body.weight(.semibold)
            a[r].foregroundColor = Refined.accentText
            start = r.upperBound
        }
        return a
    }
}

/// Speakers: each speaker's name, which you can change, and how long they talk.
struct TranscriptSpeakersSheet: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    @State private var drafts: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let t = app.store.transcript(id) {
                    let talk = Self.talkTime(t)
                    Section {
                        ForEach(t.speakers) { sp in
                            HStack(spacing: 12) {
                                Text(String(sp.label.prefix(1)).uppercased())
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.white)
                                    .frame(width: 30, height: 30)
                                    .background(Color(uiColor: .systemGray), in: Circle())
                                    .accessibilityHidden(true)
                                TextField("Name", text: Binding(get: { drafts[sp.id] ?? sp.name }, set: { drafts[sp.id] = $0 }))
                                    .submitLabel(.done)
                                    .onSubmit { save(sp.id) }
                                    .accessibilityLabel("Name for \(sp.label)")
                                Spacer(minLength: 8)
                                Text((talk[sp.id] ?? 0).timecode).monospacedDigit().foregroundStyle(Refined.mute)
                                    .accessibilityLabel("Talks for \(RecorderPresentation.spoken(talk[sp.id] ?? 0))")
                            }
                        }
                    } footer: {
                        Text("Names you give here are remembered for that voice next time.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { drafts.keys.forEach(save); dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save(_ sid: String) {
        guard let name = drafts[sid] else { return }
        app.renameSpeaker(id, speaker: sid, to: name)
    }

    /// Seconds each speaker talks, from their lines.
    static func talkTime(_ t: Transcript) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in t.segments { if let sp = s.speaker { out[sp, default: 0] += max(0, s.end - s.start) } }
        return out
    }
}

/// Details: the kind and tags, when it was recorded, its project, and where it was transcribed (the data path and the
/// provenance line).
struct TranscriptDetailsSheet: View {
    @EnvironmentObject var app: PhoneState
    var id: UUID
    @State private var newTag = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let t = app.store.transcript(id) {
                    Section {
                        if t.kind != .dictation {
                            Picker("Kind", selection: Binding(get: { t.kind ?? .note }, set: { k in app.pickKind(k, for: t.id) })) {
                                ForEach(RecordingKind.pickable) { k in Text(k.label).tag(k) }
                            }
                        }
                        LabeledContent("Recorded", value: Formats.style(date: .medium, time: .short).string(from: t.createdAt))
                        if t.duration > 0 { LabeledContent("Length", value: HomeRecentStyle.length(t.duration)) }
                        if let lang = t.language { LabeledContent("Language", value: LanguageDetection.name(lang)) }
                        Picker("Project", selection: Binding(get: { t.projectId }, set: { v in app.store.update(t.id) { $0.projectId = v } })) {
                            Text("None").tag(UUID?.none)
                            ForEach(app.store.projects) { p in Text(p.name).tag(UUID?.some(p.id)) }
                        }
                    }
                    Section("Tags") {
                        ForEach(t.tags, id: \.self) { tag in Text(tag) }
                            .onDelete { idx in
                                let remove = idx.map { t.tags[$0] }
                                app.store.update(t.id) { $0.tags.removeAll { remove.contains($0) } }
                            }
                        TextField("Add a tag", text: $newTag)
                            .submitLabel(.done)
                            .onSubmit {
                                let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !tag.isEmpty, !t.tags.contains(tag) { app.store.update(t.id) { $0.tags.append(tag) } }
                                newTag = ""
                            }
                    }
                    if t.status == .ready {
                        Section("Where it was transcribed") {
                            Text(t.dataPathBadge)
                            Text(t.provenanceLine).font(.footnote).foregroundStyle(Refined.mute)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
