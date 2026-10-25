import Foundation

extension PhoneState {
    /// verbatim://transcript/<id>, from the Recent recordings widget (VerbatimWidgets/HomeWidgets.swift): opens that
    /// transcript. True when it was a widget link. Record and Dictate run App Intents instead, so the iPhone gets no
    /// other widget links.
    func handleWidgetLink(_ url: URL) -> Bool {
        guard case .transcript(let id)? = WidgetLink(url: url) else { return false }
        openFromWidget(id, tries: 20)
        return true
    }

    /// The library may still be loading when a widget launches Verbose, so this waits up to 5 seconds for the
    /// transcript before saying it's gone.
    private func openFromWidget(_ id: UUID, tries: Int) {
        if let t = store.transcript(id), t.deletedAt == nil {
            Log.note("widget: opened a transcript")
            open(id)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.openFromWidget(id, tries: tries - 1) }
        } else {
            say("That recording isn't in your library anymore.")
        }
    }
}
