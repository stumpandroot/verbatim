import SwiftUI
import UIKit

/// The transcript actions as menu items (TranscriptActions.builtIn): Make a plan, Journal entry, Write a draft,
/// Study notes, Key points.
struct PhoneActionItems: View {
    var pick: (TranscriptActionSpec) -> Void
    var body: some View {
        ForEach(TranscriptActions.builtIn) { a in
            Button { pick(a) } label: { Label(a.name, systemImage: a.symbol) }
        }
    }
}

/// Runs a transcript action on the Original text with corrections and shows the result, marked as Apple
/// Intelligence's, before anything is kept. Edit it, copy it, share it, or save it as a note; closing is the undo.
struct PhoneActionSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    let action: TranscriptActionSpec
    let transcript: Transcript

    @State private var result = ""
    @State private var phase: Phase = .running
    @State private var part = ""
    @State private var failure: String? = nil
    @State private var skipped = ""
    @State private var runID = 0
    @State private var job: Task<Void, Never>? = nil
    @FocusState private var editing: Bool

    enum Phase { case running, done, failed }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: action.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk)
                        .frame(width: 34, height: 34).background(PhoneInk.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.name).lookSerif(22).foregroundStyle(.lookInk)
                        Text("From the original transcript · \(words.formatted()) words").font(.system(size: 13)).foregroundStyle(.lookMute)
                    }
                    Spacer(minLength: 0)
                }
                Group {
                    switch phase {
                    case .running:
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(part.isEmpty ? "Working on your iPhone…" : part).font(.system(size: 14)).foregroundStyle(.lookMute)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .done:
                        VStack(alignment: .leading, spacing: 0) {
                            // A solid marked strip, so the result never reads as the transcript.
                            HStack(spacing: 7) {
                                ArtIcon(art: .iconAI, size: 14)
                                Text(TranscriptActions.madeByLabel).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.lookAccentText)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Rectangle().fill(.lookWash))
                            .accessibilityElement(children: .combine)
                            if !skipped.isEmpty {
                                Text(skipped).font(.system(size: 12.5)).foregroundStyle(.lookMute)
                                    .padding(.horizontal, 12).padding(.top, 6)
                            }
                            TextEditor(text: $result)
                                .font(.system(size: 16)).scrollContentBackground(.hidden)
                                .focused($editing)
                                .padding(8)
                                .accessibilityLabel("Result, editable. \(TranscriptActions.madeByLabel)")
                        }
                        .background(.lookReader, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(.lookHairline))
                    case .failed:
                        VStack(spacing: 8) {
                            Text("Couldn't run this action").lookSerif(19).foregroundStyle(.lookInk)
                            Text(failure ?? "Apple's on-device model didn't answer. Try again.")
                                .font(.system(size: 14)).foregroundStyle(.lookMute).multilineTextAlignment(.center)
                            Button("Try again") { start() }.buttonStyle(.phoneSecondary).padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                if phase == .done {
                    Text("Apple Intelligence can be wrong. Edit the result before you keep it.")
                        .font(.system(size: 12.5)).foregroundStyle(.lookMute)
                    HStack(spacing: 10) {
                        Button { UIPasteboard.general.string = result; app.say("Copied"); dismiss() } label: {
                            Label("Copy", art: .iconCopy).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.phonePrimary)
                        ShareLink(item: result) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(.phoneSecondary)
                        Button {
                            app.store.addNote(Note(text: result, aiAction: action.name), to: transcript.id)
                            app.say("Saved as a note"); dismiss()
                        } label: { Label("Save as note", art: .iconNotes).frame(maxWidth: .infinity) }
                        .buttonStyle(.phoneSecondary)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(20)
            .phonePage()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { stop(); dismiss() } }
                if phase == .done {
                    ToolbarItem(placement: .primaryAction) { Button("Redo") { start() } }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } }
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var words: Int { Summarizer.wordCount(TranscriptActions.sourceLines(transcript, timestamps: false)) }

    private func stop() { runID += 1; job?.cancel(); job = nil }

    private func start() {
        stop()
        let id = runID
        phase = .running; part = ""; failure = nil; skipped = ""
        let a = action, t = transcript
        job = Task { @MainActor in
            do {
                let out = try await TranscriptActions.run(instruction: a.instruction, extracts: a.extracts, timestamps: a.timestamps, on: t) { i, n in
                    Task { @MainActor in if id == runID { part = n > 1 ? "Part \(i) of \(n)" : "" } }
                }
                guard id == runID else { return }
                result = out.text
                skipped = out.skippedParts > 0 ? "Apple Intelligence declined \(out.skippedParts) of \(out.totalParts) parts, so their words aren't in this result." : ""
                phase = .done
            } catch {
                guard id == runID, !(error is CancellationError) else { return }
                failure = (error as? LocalizedError)?.errorDescription
                phase = .failed
            }
        }
    }
}
