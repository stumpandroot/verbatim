import Foundation

extension PhoneState {
    /// verbatim://transcript/<id>, from the Recent recordings widget (VerbatimWidgets/HomeWidgets.swift): opens that
    /// transcript. verbatim://thought, from a thought in Today's thoughts: opens today's Thoughts page.
    /// verbatim://newthought opens today's Thoughts page too, without starting the microphone: any app or web page can
    /// open a link (security review IPH-15, October 31, 2026), and the iPhone's widgets start a thought with the
    /// unlock-protected `NewThoughtIntent`. True when it was a widget link. Record and Dictate run App Intents.
    func handleWidgetLink(_ url: URL) -> Bool {
        switch WidgetLink(url: url) {
        case .transcript(let id)?:
            openFromWidget(id, tries: 20)
        case .thought?:
            Log.note("widget: opened today's Thoughts page")
            openThoughtPage()
        case .newThought?:
            Log.note("widget: a New thought link opened today's Thoughts page without starting the microphone")
            openThoughtPage()
        default:
            return false
        }
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
