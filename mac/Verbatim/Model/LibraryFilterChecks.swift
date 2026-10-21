import Foundation

/// Pure checks for the Library's type and platform filters and for Add from Library, run by both self-tests
/// (UITest on Mac, PhoneUITest on iPhone). Builds transcripts in memory only; nothing is saved.
enum LibraryFilterChecks {
    static func run(_ check: (String, Bool) -> Void) {
        // Platform names from extractor keys, hosts, and site names.
        check("platform names", Platform.name("Youtube") == Platform.youTube && Platform.name("m.tiktok.com") == Platform.tikTok
              && Platform.name("www.instagram.com") == Platform.instagram && Platform.name("x.com") == Platform.x
              && Platform.name("twitter.com") == Platform.x && Platform.name("podcasts.apple.com") == Platform.applePodcasts
              && Platform.name("TwitchVod") == Platform.twitch && Platform.name("vimeo.com") == Platform.vimeo
              && Platform.name("https://youtu.be/abc") == Platform.youTube && Platform.name("example.com") == nil && Platform.name("") == nil)

        func make(_ title: String, _ source: SourceKind, _ label: String, url: String? = nil) -> Transcript {
            var t = Transcript(title: title, source: source, sourceLabel: label, duration: 10, audioFileName: nil, model: "")
            if let url { t.link = LinkInfo(url: url); t.sourceURL = url }
            return t
        }
        let tiktok = make("Dance", .link, "tiktok.com", url: "https://www.tiktok.com/@a/video/1")
        let web = make("Article", .link, "example.com", url: "https://example.com/talk.mp3")
        let mov = make("Clip", .file, "MOV file")
        let mp3 = make("Interview", .file, "MP3 file")
        let memo = make("Memo", .voiceMemo, "Voice memo")
        let dict = make("Dictation", .dictation, "Dictation · Notes")
        let all = [tiktok, web, mov, mp3, memo, dict]

        check("platform of a transcript", Platform.of(tiktok) == Platform.tikTok && Platform.of(web) == Platform.otherWeb
              && Platform.of(mov) == Platform.localFile && Platform.of(mp3) == nil && Platform.of(memo) == nil)
        func ids(_ f: LibraryFilter, searching: Bool = false) -> Set<UUID> { Set(f.apply(all, searching: searching).map(\.id)) }
        check("videos: video files and video links", ids(LibraryFilter(source: .videos)) == [tiktok.id, mov.id])
        check("links: every link", ids(LibraryFilter(source: .links)) == [tiktok.id, web.id])
        check("audio files and voice memos", ids(LibraryFilter(source: .audioFiles)) == [mp3.id] && ids(LibraryFilter(source: .voiceMemos)) == [memo.id])
        check("dictations stay out of All unless searching or chosen",
              !ids(.all).contains(dict.id) && ids(.all, searching: true).contains(dict.id) && ids(LibraryFilter(source: .dictations)) == [dict.id])
        check("platform narrows a type", ids(LibraryFilter(source: .links, platform: Platform.tikTok)) == [tiktok.id]
              && ids(LibraryFilter(source: .videos, platform: Platform.localFile)) == [mov.id])
        let counts = LibraryFilter.all.sourceCounts(all, searching: false)
        check("type chips with no items are hidden", counts.first?.0 == .all && counts.first?.1 == 5
              && !counts.contains { $0.0 == .appAudio } && counts.contains { $0.0 == .videos && $0.1 == 2 })
        check("platform chips in order", LibraryFilter(source: .links).platformCounts(all, searching: false).map(\.0) == [Platform.tikTok, Platform.otherWeb]
              && LibraryFilter(source: .videos).platformCounts(all, searching: false).map(\.0) == [Platform.tikTok, Platform.localFile]
              && LibraryFilter(source: .voiceMemos).platformCounts(all, searching: false).isEmpty)
        check("filter round-trips through its stored form", LibraryFilter(raw: "videos|YouTube") == LibraryFilter(source: .videos, platform: Platform.youTube)
              && LibraryFilter(raw: LibraryFilter(source: .links, platform: Platform.x).raw).platform == Platform.x
              && LibraryFilter(raw: "voiceMemos|YouTube").platform == nil && LibraryFilter(raw: "nonsense") == .all)
        check("rows say what they are", LibraryFilter.describe(tiktok) == "TikTok" && LibraryFilter.describe(dict) == "Dictation"
              && LibraryFilter.describe(memo) == "Voice memo" && LibraryFilter.describe(mov) == "MOV file")

        // Add from Library: deleted and already-included transcripts are left out; another project's transcripts move.
        let project = UUID(), other = UUID()
        var inProject = make("Already in", .voiceMemo, "Voice memo"); inProject.projectId = project
        var elsewhere = make("Elsewhere", .voiceMemo, "Voice memo"); elsewhere.projectId = other
        var deleted = make("Deleted", .voiceMemo, "Voice memo"); deleted.deletedAt = Date()
        var tagged = make("Untitled", .voiceMemo, "Voice memo"); tagged.tags = ["Abolition"]
        let library = [inProject, elsewhere, deleted, tagged, memo]
        let listed = Set(ProjectAdd.candidates(library, project: project, query: "", text: { _ in "" }).map(\.id))
        check("add from library lists what isn't deleted or already in the project", listed == [elsewhere.id, tagged.id, memo.id])
        check("add from library searches tags", ProjectAdd.candidates(library, project: project, query: "abol", text: { _ in "" }).map(\.id) == [tagged.id])
        check("add from library searches text", ProjectAdd.candidates(library, project: project, query: "wagon",
                                                                      text: { $0.id == memo.id ? "the wagon shop" : "" }).map(\.id) == [memo.id])
        let plan = ProjectAdd.plan([inProject.id, elsewhere.id, deleted.id, memo.id], in: library, to: project)
        check("adding plans only real changes", Set(plan.keys) == [elsewhere.id, memo.id])
        check("undo knows each previous project", plan[elsewhere.id] == .some(other) && plan[memo.id] == .some(nil))
        check("only another project's transcripts move", ProjectAdd.moves(plan) == [elsewhere.id])
    }
}
