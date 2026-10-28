import SwiftUI

/// A transcript's Summary tab in the refined look (DESIGN.md §13), on the Mac and iPhone, in both look settings: the
/// overview in the serif reading text, the key points, Apple Intelligence's note, and Edit and Regenerate as accent
/// links. Edit makes it the person's own (automatic summaries never replace it then); Regenerate asks before replacing
/// an edited one. With no summary yet it offers Summarize, or says why Apple Intelligence can't write one here.
struct SummaryBlock: View {
    var transcript: Transcript
    /// Runs the summary; `true` replaces a summary the person edited.
    var onSummarize: (_ replacingEdits: Bool) -> Void
    /// Saves the person's edit; nil removes the summary.
    var onSave: (TranscriptSummary?) -> Void

    @ObservedObject private var center = SummaryCenter.shared
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmReplace = false

    init(transcript: Transcript, onSummarize: @escaping (_ replacingEdits: Bool) -> Void, onSave: @escaping (TranscriptSummary?) -> Void) {
        self.transcript = transcript; self.onSummarize = onSummarize; self.onSave = onSave
    }

    /// Whether there's a summary to show, or one being written or that failed: the Mac's side column and the
    /// iPhone's Summarize action read it.
    @MainActor static func shows(_ t: Transcript, center: SummaryCenter) -> Bool {
        guard t.status == .ready else { return false }
        if t.summary != nil { return true }
        guard Summarizer.available else { return false }
        return center.isRunning(t.id) || center.failures[t.id] != nil
    }

    private var running: Bool { center.isRunning(transcript.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if editing {
                editor
            } else if let s = transcript.summary, !s.isEmpty {
                summary(s)
            } else if running {
                progressRow
            } else if let why = center.failures[transcript.id] {
                Text(why).refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                if Summarizer.available { link("Try again") { onSummarize(false) } }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Replace your edited summary?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { onSummarize(true) }
            Button("Keep mine", role: .cancel) {}
        } message: {
            Text("Apple Intelligence writes a new summary, and your edits are gone.")
        }
    }

    private func summary(_ s: TranscriptSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !s.overview.isEmpty { ReadingText(s.overview) }
            if !s.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Key points").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Refined.played).frame(width: 6, height: 6)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                .accessibilityHidden(true)
                            ReadingText(p)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if transcript.summaryByModel {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    IconGlyph(art: .iconAI, size: 13, color: Refined.mute)
                    Text(AIGeneratedNote.summary).refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if running { progressRow } else if let why = center.failures[transcript.id] {
                Text(why).refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                link("Edit") { draft = s.plainText; editing = true }
                if Summarizer.available, !running {
                    link("Regenerate") { if transcript.summaryIsEdited { confirmReplace = true } else { onSummarize(false) } }
                }
            }
        }
    }

    /// No summary yet: Summarize, or why it can't run here.
    @ViewBuilder private var empty: some View {
        Text("No summary yet").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
        if let why = SummaryAction.unavailableReason {
            Text(why).refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Apple Intelligence writes an overview and the key points from the transcript, on this device.")
                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            Button("Summarize") { onSummarize(false) }
                .buttonStyle(RefinedActionStyle(kind: .strong))
                .disabled(transcript.status != .ready)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progressText).refinedFont(.body).foregroundStyle(Refined.dim)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        if let p = center.progress[transcript.id], p > 0 { return "Writing a summary\u{2026} \(Int(p * 100))%" }
        return "Writing a summary\u{2026}"
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        RefinedLink(title: title, action: action)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An overview, then one key point per line starting with \u{201C}- \u{201D}.").refinedFont(.meta).foregroundStyle(Refined.mute)
            TextEditor(text: $draft)
                .refinedFont(.body).foregroundStyle(Refined.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(8)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                .accessibilityLabel("Summary")
            HStack(spacing: 18) {
                link("Save") {
                    let parsed = TranscriptSummary.parse(draft)
                    onSave(parsed.isEmpty ? nil : parsed)
                    editing = false
                }
                link("Cancel") { editing = false }
            }
        }
    }
}

/// The per-transcript Summarize action's label and what it does, shared by the Mac's Actions menu and the iPhone's
/// toolbar menu. When Apple Intelligence can't run, the action explains why instead (`unavailableReason`).
enum SummaryAction {
    static func title(_ t: Transcript) -> String { t.summary == nil ? "Summarize" : "Regenerate summary" }
    static var unavailableReason: String? { Summarizer.available ? nil : Summarizer.unavailableReason }
}
