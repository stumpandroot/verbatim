import SwiftUI

/// Organizing transcripts, editing them, and Keep (saved audio, video, and stills).
extension AppState {
    // MARK: Organizing

    func move(_ ids: [UUID], to project: UUID?) {
        for id in ids { store.update(id) { $0.projectId = project } }
        let name = project.flatMap { p in store.projects.first { $0.id == p }?.name }
        toast = Toast(name.map { "Moved \(ids.count == 1 ? "1 transcript" : "\(ids.count) transcripts") to \($0)" } ?? "Removed from project")
        Sounds.play("Tink")
    }

    /// Adds Library transcripts to a project. A transcript is in one project at a time, so one from another project
    /// moves. Saves through the Store like every edit (iCloud carries it to the iPhone); Undo puts each one back.
    func addToProject(_ ids: [UUID], _ project: UUID) {
        let plan = ProjectAdd.plan(ids, in: store.transcripts, to: project)
        guard !plan.isEmpty, let name = store.projects.first(where: { $0.id == project })?.name else { return }
        for id in plan.keys { store.update(id) { $0.projectId = project } }
        let n = plan.count, moved = ProjectAdd.moves(plan).count
        let what = n == 1 ? "1 transcript" : "\(n) transcripts"
        toast = Toast(moved == 0 ? "Added \(what) to \(name)" : "Added \(what) to \(name), \(moved) from other projects", action: "Undo") { [weak self] in
            for (id, previous) in plan { self?.store.update(id) { $0.projectId = previous } }
        }
        Sounds.play("Tink")
    }

    func delete(_ ids: [UUID]) {
        // Moves to Recently Deleted (kept 30 days). Undo puts them straight back.
        for id in ids { coordinator.cancelIfActive(id); store.moveToTrash(id) }
        if case .transcript(let open) = screen, ids.contains(open) { go(.library) }
        toast = Toast(ids.count == 1 ? "Moved to Recently Deleted" : "Moved \(ids.count) to Recently Deleted", action: "Undo") { [weak self] in
            ids.forEach { self?.store.restore($0) }
        }
    }

    func restore(_ ids: [UUID]) {
        ids.forEach { store.restore($0) }
        toast = Toast(ids.count == 1 ? "Restored" : "Restored \(ids.count) transcripts")
    }

    /// Permanent. Only offered from Recently Deleted.
    func purge(_ ids: [UUID]) {
        for id in ids { if let t = store.transcript(id) { store.delete(t) } }
    }

    // MARK: Editing

    /// Replaces a word in one segment; with `remember`, teaches the Dictionary so future transcripts get it right.
    func correct(transcript id: UUID, segment sid: UUID, from: String, to: String, remember: Bool) {
        // Whole words only, recorded with where each went, so Undo restores exactly them (Transcript.correct).
        store.update(id) { $0.correct(segment: sid, from: from, to: to) }
        // The same word elsewhere in the transcript: offer Fix all (Views/TrustViews.swift).
        if let t = store.transcript(id) { FixAllOffer.shared.consider(t, heard: from, fix: to, remembered: remember) }
        if remember, let t = store.transcript(id) {
            store.remember(preferred: to, heardAs: from, from: t.title, project: projectScopedVocabulary ? t.projectId : nil)
            toast = Toast("\(to) added to Dictionary" + (projectScopedVocabulary && t.projectId != nil ? " for this project" : ""))
        } else if !remember {
            // Not remembered: counted, so the same fix made again becomes a Dictionary suggestion.
            EditLearner.record([(heard: from, fixed: to)])
        }
    }

    func addNote(transcript id: UUID, text: String, at: Double?, segment: UUID?, bookmark: Bool = false) {
        let note = Note(text: text, at: at, segmentId: segment, isBookmark: bookmark)
        store.addNote(note, to: id)
        toast = Toast(bookmark ? "Bookmarked \((at ?? 0).timecode)" : "Note added")
        if at != nil, let video = store.transcript(id)?.videoFile { grabFrames(id, video: video, only: [note.id]) }
    }

    func deleteNote(transcript id: UUID, note nid: UUID) {
        store.update(id) { $0.notes.removeAll { $0.id == nid } }
    }

    func renameSpeaker(transcript id: UUID, speaker sid: String, to name: String) {
        store.update(id) { t in
            // Any name works: first and last, initials, underscores. Only surrounding spaces are trimmed.
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = t.speakers.firstIndex(where: { $0.id == sid }), !clean.isEmpty { t.speakers[i].name = clean }
        }
        SpeakerVoices.remember(transcript: id, speaker: sid, name: name)
    }

    /// Use on a speaker name suggestion: renames the speaker the way a typed name does and keeps the suggestion,
    /// with its reasons, as used.
    func useSpeakerSuggestion(transcript id: UUID, _ s: SpeakerSuggestion) {
        renameSpeaker(transcript: id, speaker: s.speakerId, to: s.name)
        store.update(id) { $0.markSpeakerSuggestion(s.id, .accepted) }
    }

    /// Dismiss: the suggestion hides and isn't made again.
    func dismissSpeakerSuggestion(transcript id: UUID, _ s: SpeakerSuggestion) {
        store.update(id) { $0.markSpeakerSuggestion(s.id, .dismissed) }
    }

    func assign(transcript id: UUID, segment seg: UUID, to speaker: String?) {
        store.update(id) { t in
            if let i = t.segments.firstIndex(where: { $0.id == seg }) { t.segments[i].speaker = speaker }
        }
    }

    // MARK: Keep

    /// Saves the link's video as an MP4 in the Keep folder. Notes with a moment get a still once it lands.
    func keepVideo(_ id: UUID) {
        guard let t = store.transcript(id), keeping[id] == nil else { return }
        guard let url = t.linkInfo?.url ?? t.sourceURL else { toast = Toast("Only link transcripts have a video to keep."); return }
        guard !CloudShareLink.isCloudLink(url) else { toast = Toast("Keep works with video sites. Download a cloud file from where it's shared."); return }
        guard LinkFetcher.helperURL != nil else { toast = Toast("Keeping video needs the yt-dlp helper, which this build is missing."); return }
        keeping[id] = "Keeping video"
        let gate = ProgressGate()
        let title = t.title
        Task {
            do {
                let out = try await Keep.video(link: url, title: title) { s in
                    if gate.shouldPublish(s) { Task { @MainActor in if self.keeping[id] != nil { self.keeping[id] = s } } }
                }
                keeping[id] = nil
                store.update(id) { $0.keptVideo = out.path }
                toast = Toast("Kept “\(out.lastPathComponent)”", action: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                grabFrames(id, video: out)
            } catch {
                keeping[id] = nil
                toast = Toast("Couldn't keep the video: \(error.localizedDescription)")
            }
        }
    }

    /// Copies the transcript's audio to the Keep folder (M4A for links, recordings, and imports).
    func keepAudio(_ id: UUID) {
        guard let t = store.transcript(id), let src = store.audioURL(for: t) else { toast = Toast("That transcript's audio is missing."); return }
        do {
            let out = try Keep.destination(title: t.title, ext: src.pathExtension.isEmpty ? "m4a" : src.pathExtension)
            try FileManager.default.copyItem(at: src, to: out)
            store.update(id) { $0.keptAudio = out.path }
            toast = Toast("Kept “\(out.lastPathComponent)”", action: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
        } catch {
            toast = Toast("Couldn't keep the audio: \(error.localizedDescription)")
        }
    }

    func showKept(_ path: String?) {
        guard let path, FileManager.default.fileExists(atPath: path) else { toast = Toast("That file has moved or been deleted."); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Stills for notes pinned to a moment that don't have one yet (or just `only`).
    func grabFrames(_ id: UUID, video: URL, only: Set<UUID>? = nil) {
        guard let t = store.transcript(id) else { return }
        let wanted = t.notes.filter { n in n.at != nil && (only.map { $0.contains(n.id) } ?? (n.frameFile == nil)) }
        guard !wanted.isEmpty else { return }
        Task {
            for n in wanted {
                guard let at = n.at, let file = await Keep.frame(from: video, at: at, name: n.id.uuidString) else { continue }
                store.update(id) { t in if let i = t.notes.firstIndex(where: { $0.id == n.id }) { t.notes[i].frameFile = file } }
            }
        }
    }

    /// Fills in missing stills for every transcript with a video on this Mac. Runs once at launch.
    func backfillFrames() {
        for t in store.live where t.notes.contains(where: { $0.at != nil && $0.frameFile == nil }) {
            if let v = t.videoFile { grabFrames(t.id, video: v) }
        }
    }
}

extension AppState {
    /// Settings › Storage › Delete All Data: every transcript and dictation (Recently Deleted too) with its audio
    /// and stills, projects, the Dictionary, snippets, Activity, the Thought pad, downloads, speech models, and the
    /// "Before iCloud" backup. Uses the Store's own delete paths, so iCloud removes the files on every device.
    func deleteAllData() {
        // A recording in progress would be deleted while it's still being written.
        guard !recorder.isRecording, !capture.isCapturing else { toast = Toast("Stop the current recording first."); return }
        dictation.cancel(quiet: true)
        player.stop()
        coordinator.cancelAll()   // once, so cancelling one job doesn't start the next queued one
        for t in store.transcripts { store.delete(t) }
        store.projects = []
        store.dictionary = []
        FlowSettings.shared.snippets = []
        ActivityLog.shared.reset()
        SiteLog.shared.reset()
        ThoughtPad.shared.clear()
        store.removeAllFiles()
        goHome()
        toast = Toast("Deleted everything")
        Log.note("delete all data")
    }
}
