import SwiftUI

/// Progress text for running jobs ("Downloading 42%", "Transcribing 61%", "Track 2 of 3 · 41%"), set several times a
/// second while a file transcribes, imports, or downloads (`Store.setStage`). Its own object, as `PlayerClock` is for
/// the playhead: a tick re-renders only the progress text and bars that draw it (`LiveStage`), never the screens that
/// read the library. A live stage is display-only, as `setStage` always was: the Store folds it back into its
/// transcript before the next saved change (`Store.update`), so what's written and synced is unchanged.
@MainActor
final class StageClock: ObservableObject {
    static let shared = StageClock()
    /// Live stages by transcript; an entry is newer than that transcript's own `stage`.
    @Published private(set) var stages: [UUID: String] = [:]

    func stage(_ id: UUID) -> String? { stages[id] }

    /// `t` with its live stage, when one is ticking.
    func applied(to t: Transcript) -> Transcript {
        guard let s = stages[t.id], s != t.stage else { return t }
        var c = t
        c.stage = s
        return c
    }

    func set(_ id: UUID, _ stage: String) {
        if stages[id] != stage { stages[id] = stage }
    }

    /// Removes and returns the live stage, publishing only when there was one.
    @discardableResult func take(_ id: UUID) -> String? {
        guard stages[id] != nil else { return nil }
        return stages.removeValue(forKey: id)
    }

    func removeAll() {
        if !stages.isEmpty { stages = [:] }
    }
}

/// Draws `content` with the transcript's live progress stage (StageClock). Only this view observes the clock, so a
/// progress tick re-renders the text or bar inside it and nothing around it. Wrap just the part that shows the stage.
struct LiveStage<Content: View>: View {
    @ObservedObject private var clock = StageClock.shared
    private let transcript: Transcript
    private let content: (Transcript) -> Content

    init(_ transcript: Transcript, @ViewBuilder content: @escaping (Transcript) -> Content) {
        self.transcript = transcript
        self.content = content
    }

    var body: some View { content(clock.applied(to: transcript)) }
}
