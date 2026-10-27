# Release notes

`ReleaseNotes.json` holds what each build of Verbose added, sorted by platform. Both apps bundle it and show it in
What's new:

- iPhone: tap the version at the bottom of Settings, or search Settings for What's new.
- Mac: choose Verbose › What's New…, click the version at the foot of the Settings sidebar, or click What's New… in
  Settings › Support and feedback.
- After an update to a build with notes, Home shows "What's new in build N" once (a banner on iPhone, a line on the
  Mac). Dismissing it or opening What's new stores the build in `releaseNotes.lastSeenBuild` (UserDefaults, per
  device). A new install starts at its own build, so it shows no note until the next update.

Each place leads with its own platform:

| Place | Order |
|---|---|
| What's new on iPhone | iPhone, then Apple Watch. The Mac's items fold under one collapsed "Also on Mac" row. |
| What's new on the Mac | Mac. The iPhone and Apple Watch items fold under "Also on iPhone and Apple Watch". |
| The Mac's update window (Sparkle, HTML) | Mac, then "Also on iPhone and Apple Watch" (lines only). |
| The GitHub release in `stumpandroot/verbose-updates` (Markdown) | Mac, iPhone, and Apple Watch headings. A change for two platforms is under both. |
| TestFlight's What to Test (plain text) | iPhone, Apple Watch, then "Also on Mac", within 4,000 characters. |

A change for both apps shows in each app's own section, written once in the file. In What's new, a line with a
detail is a button: tap or click it to open the detail in place. The "Also on" label names only the platforms it
holds, such as "Also on iPhone" when a build has no Apple Watch changes.

## The file

Newest first. Each entry has a `build` (a run number as a string), a `date` (`YYYY-MM-DD`), a `title`, and `items`.
The top entry's build is `"next"` and has no date: it collects the changes since the last build that shipped.
Stamped entries also have a `version`, such as `"1.0 beta"`; entries without one count as 1.0 beta. What's new groups
the builds under version headers, the newest version open and older ones closed. See [Versions](../VERSIONING.md).

Each item is an object:

```json
{ "platforms": ["iphone"], "text": "Tap Record to start a voice note.", "detail": "Touch and hold still opens Record as." }
```

- `platforms`: one or more of `iphone`, `mac`, and `watch`. Use `["iphone", "mac"]` for a change in both apps.
- `text`: one line of about 12 words, at most 90 characters.
- `detail` (optional): one sentence, at most 200 characters, shown when someone taps or clicks the line. Most items
  have none.

Entries from before platforms were recorded keep their items as strings. A prefix such as "Mac:", "iPhone:", "Apple
Watch:", "Mac and iPhone:", or "Mac Home:" gives a string's platforms and comes off the line under the heading ("Mac
Home: the tile" shows as "Home: the tile" under Mac); a string with no prefix counts as both apps. Strings are valid
only in numbered entries, never in `"next"`.

## Every user-visible change adds an item

In the same commit as the change, add one item to the `"next"` entry, and give the entry a short title if it has
none: sentence case, with no platform prefix unless the build ships on one platform only ("iPhone only: haptics").

Write the item in Google developer documentation style:

- Lead with what you can do or what changed. Second person, active voice, present tense: "Tap the version to see what
  changed," not "Users can now tap…".
- Sentence case, a period at the end, and serial commas.
- No em dashes and no exclamation points.
- No "just," "simply," "easily," "currently," "soon," "latest," or "now."
- No platform prefix in the text; `platforms` says it, and the heading shows it.
- One change per item. Gather small fixes into one "Smaller fixes." item per platform, its detail listing them
  briefly.
- Aim for 5 to 12 items per platform in a build; combine related changes.
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

## TestFlight's What to Test

After the TestFlight job uploads the iPhone app, its "Set TestFlight's What to Test from the release notes" step
renders the stamped entry with `release_notes.py notes --format testflight` and passes it to
`testflight_what_to_test.py`. That script waits until App Store Connect has processed the build (up to 20 minutes),
then creates or updates the build's en-US `betaBuildLocalizations` with the text, signing its own App Store Connect
API token with the key the upload uses (`ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8`).

The step never fails the build. When App Store Connect is slow or refuses the call, the step logs a warning and the
text it tried to set, and you can paste that text in App Store Connect › TestFlight. When the text runs over 4,000
characters, the details go first, then the Mac's lines from the end, with "And more." in their place.

## After a build ships

In a follow-up commit, set the `"next"` entry's `build` to that run's number, its `date` to the build's date, and its
`version` to the build's version. Start a new `"next"` entry with the next user-visible change. A build that finds no
`"next"` entry and none for its number shows no note on Home, and its update shows the one-line text.

## Checks

- `python3 ReleaseNotes/release_notes.py check ReleaseNotes/ReleaseNotes.json` validates the file: titles and items
  present, numbered builds descending, at most one `"next"` and it first, and for each object item, valid
  `platforms`, `text` of at most 90 characters, `detail` of at most 200, a period at the end, no "Mac:"-style prefix,
  and no em dash or exclamation point. A string item in `"next"` fails.
- `bash tools/test-release-notes.sh` (in check-swift's Linux tests) parses the file with the app's own parser
  (`Verbatim/Model/ReleaseNotes.swift`) and checks the same rules. It compares how the apps and `release_notes.py` sort
  every build by platform (`ReleaseNotes.summary` and `summary`: one order for every place), stamps a copy, and checks
  the HTML, Markdown, and TestFlight renderings, the fallbacks, and the What to Test script against a stand-in for
  App Store Connect.
- `bash tools/test-appcast.sh` checks that the notes reach the appcast and the GitHub release.
- Both apps' self-tests check the bundled file and the platform order, open a detail and the "Also on" row, and take
  screenshots of What's new and Home's note in both looks.
