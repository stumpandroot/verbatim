import SwiftUI

/// The Summary block at the top of a transcript (Mac and iPhone): an editorial section header that folds the block,
/// the overview, up to 5 key points, and the AI label. Edit makes it the person's own (automatic summaries never
/// replace it then); Regenerate asks before replacing an edited one.
///
/// Hidden while there's nothing to show and Apple Intelligence can't run here: the Summarize action says why.
struct SummaryBlock: View {
    var transcript: Transcript
    /// Smaller type and spacing for iPhone.
    var compact = false
    /// Runs the summary; `true` replaces a summary the person edited.
    var onSummarize: (_ replacingEdits: Bool) -> Void
    /// Saves the person's edit; nil removes the summary.
    var onSave: (TranscriptSummary?) -> Void

    @ObservedObject private var center = SummaryCenter.shared
    @AppStorage("summary.collapsed") private var collapsed = false
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmReplace = false
    @Environment(\.limitMotion) private var limitMotion

    @MainActor static func shows(_ t: Transcript, center: SummaryCenter) -> Bool {
        guard t.status == .ready else { return false }
        if t.summary != nil { return true }
        guard Summarizer.available else { return false }
        return center.isRunning(t.id) || center.failures[t.id] != nil
    }

    private var bodySize: CGFloat { compact ? 16 : 15 }
    private var animation: Animation { limitMotion ? Motion.fade : Motion.settle }

    var body: some View {
        if Self.shows(transcript, center: center) {
            VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                header
                if !collapsed {
                    content.transition(.opacity)
                }
            }
            .padding(.bottom, compact ? 14 : 18)
            .confirmationDialog("Replace your edited summary?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { onSummarize(true) }
                Button("Keep mine", role: .cancel) {}
            } message: {
                Text("Apple Intelligence writes a new summary, and your edits are gone.")
            }
        }
    }

    private var running: Bool { center.isRunning(transcript.id) }

    private var header: some View {
        Button { withAnimation(animation) { collapsed.toggle() } } label: {
            EditorialSectionHeader(index: collapsed ? "Show" : "Hide", label: "Summary")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Summary")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(collapsed ? "Shows the summary" : "Hides the summary")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var content: some View {
        if editing {
            editor
        } else if let s = transcript.summary {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                if !s.overview.isEmpty {
                    Text(s.overview).font(.system(size: bodySize)).foregroundStyle(Ink.ink).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !s.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .top, spacing: 10) {
                                Diamond().fill(Ink.mute).frame(width: 5, height: 5).padding(.top, compact ? 8 : 7)
                                Text(p).font(.system(size: bodySize)).foregroundStyle(Ink.ink)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Key points")
                }
                footer(s)
            }
        } else if running {
            progressRow
        } else if let why = center.failures[transcript.id] {
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.system(size: compact ? 14 : 13)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
                if Summarizer.available {
                    Button("Try again") { onSummarize(false) }.buttonStyle(.plain)
                        .font(.system(size: compact ? 14 : 12.5, weight: .semibold)).foregroundStyle(Ink.iris)
                }
            }
        }
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progressText).font(.system(size: compact ? 14 : 13)).foregroundStyle(Ink.mute)
        }
    }

    private var progressText: String {
        if let p = center.progress[transcript.id], p > 0 { return "Writing a summary… \(Int(p * 100))%" }
        return "Writing a summary…"
    }

    private func footer(_ s: TranscriptSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if transcript.summaryByModel { AIGeneratedNote(text: AIGeneratedNote.summary) }
            if running {
                progressRow
            } else if let why = center.failures[transcript.id] {
                Text(why).font(.system(size: compact ? 13.5 : 12.5)).foregroundStyle(Ink.mute)
            }
            HStack(spacing: compact ? 18 : 14) {
                Button("Edit") { draft = s.plainText; withAnimation(animation) { editing = true } }
                if Summarizer.available, !running {
                    Button("Regenerate") {
                        if transcript.summaryIsEdited { confirmReplace = true } else { onSummarize(false) }
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: compact ? 14 : 12.5, weight: .semibold))
            .foregroundStyle(Ink.iris)
        }
        .padding(.top, 2)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An overview, then one key point per line starting with “- ”.")
                .font(.system(size: compact ? 13.5 : 12)).foregroundStyle(Ink.mute)
            TextEditor(text: $draft)
                .font(.system(size: bodySize)).lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(minHeight: compact ? 160 : 130)
                .padding(8)
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.hairline))
            HStack(spacing: compact ? 18 : 14) {
                Button("Save") {
                    let parsed = TranscriptSummary.parse(draft)
                    onSave(parsed.isEmpty ? nil : parsed)
                    withAnimation(animation) { editing = false }
                }
                .foregroundStyle(Ink.iris)
                Button("Cancel") { withAnimation(animation) { editing = false } }
                    .foregroundStyle(Ink.mute)
            }
            .buttonStyle(.plain)
            .font(.system(size: compact ? 14 : 12.5, weight: .semibold))
        }
    }
}

/// The per-transcript Summarize action's label and what it does, shared by the Mac's Actions menu and the iPhone's
/// toolbar menu. When Apple Intelligence can't run, the action explains why instead (`unavailableReason`).
enum SummaryAction {
    static func title(_ t: Transcript) -> String { t.summary == nil ? "Summarize" : "Regenerate summary" }
    static var unavailableReason: String? { Summarizer.available ? nil : Summarizer.unavailableReason }
}
