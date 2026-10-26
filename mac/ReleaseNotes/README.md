# Release notes

`ReleaseNotes.json` holds what each build of Verbose added. Both apps bundle it and show it in What's new:

- iPhone: tap the version at the bottom of Settings, or search Settings for What's new.
- Mac: choose Verbose › What's New…, click the version at the foot of the Settings sidebar, or click What's New… in
  Settings › Support and feedback.
- After an update to a build with notes, Home shows "What's new in build N" once (a banner on iPhone, a line on the
  Mac). Dismissing it or opening What's new stores the build in `releaseNotes.lastSeenBuild` (UserDefaults, per
  device). A new install starts at its own build, so it shows no note until the next update.
- The Mac's update window (Sparkle) and the build's GitHub release in `stumpandroot/verbose-updates` list the same
  title and items.

## The file

Newest first. Each entry has a `build` (a run number as a string), a `date` (`YYYY-MM-DD`), a `title`, and `items`.
The top entry's build is `"next"` and has no date: it collects the changes since the last build that shipped.
Stamped entries also have a `version`, such as `"1.0 beta"`; entries without one count as 1.0 beta. What's new groups
the builds under version headers, the newest version open and older ones closed. See [Versions](../VERSIONING.md).

```json
{ "build": "next", "title": "Version notes", "items": ["Tap the version at the bottom of Settings to see what changed in each build."] }
```

## Every user-visible change adds a bullet

In the same commit as the change, add one item to the `"next"` entry, and give the entry a short title if it has
none. Write in Google developer documentation style:

- Second person, active voice, present tense: "Tap the version to see what changed," not "Users can now tap…".
- Sentence case. End each item with a period.
- No exclamation points and no em dashes.
- Name the device when only one has the change ("Mac: …", "iPhone: …").
- Leave out internal work that nobody can see, unless it changes speed or reliability in a way people notice.

If the `"next"` entry is gone (see below), start a new one at the top.

## How a build gets its number

CI never commits to the file. Before the Mac build, the iPhone screenshot tour, and the TestFlight archive,
`.github/workflows/build-swift.yml` runs:

```sh
python3 ReleaseNotes/release_notes.py stamp ReleaseNotes/ReleaseNotes.json --build "$GITHUB_RUN_NUMBER"
```

That turns `"build": "next"` into the run number and adds today's date (UTC) and the version (project.yml's
`MARKETING_VERSION` and `VERBOSE_CHANNEL`, or `--version`) in the runner's checkout only, so the app in that build
names itself in What's new. The `updates` job reads the entry for the run number, or the `"next"`
entry in its own unstamped checkout, into the appcast item's description (HTML) and the release body (Markdown).
Without either, it falls back to the one-line "Beta build N of main." text.

## After a build ships

In a follow-up commit, set the `"next"` entry's `build` to that run's number, its `date` to the build's date, and its
`version` to the build's version. Start
a new `"next"` entry with the next user-visible change. A build that finds no `"next"` entry and none for its number
shows no note on Home, and its update shows the one-line text.

## Checks

- `python3 ReleaseNotes/release_notes.py check ReleaseNotes/ReleaseNotes.json` validates the file.
- `bash tools/test-release-notes.sh` (in check-swift's Linux tests) parses the file with the app's own parser
  (`Verbatim/Model/ReleaseNotes.swift`): valid structure, builds descending, at most one `"next"` and it first. It also
  stamps a copy and checks the HTML and Markdown renderings and the fallbacks.
- `bash tools/test-appcast.sh` checks that the notes reach the appcast and the GitHub release.
- Both apps' self-tests check the bundled file and take screenshots of What's new and Home's note in both looks.
