# Versions

One version covers both apps, Mac and iPhone, and every extension they carry. The apps show it at the bottom of
Settings, in About, and in What's new as "Version 1.0 beta (217)": the marketing version, the channel, and the build
number.

## The rules

- Betas are "1.0 beta" until launch.
- The App Store release is 1.0, with no channel.
- After launch, the middle number marks new features (1.1, 1.2) and the last number marks fixes only (1.1.1).
- The build number is the CI run number, so it always climbs. It never resets when the version changes.
- Each shipped build gets a git tag (see [Tags](#tags)).

## Where the version lives

`mac/project.yml`, project-level `settings.base`:

| Setting | Value | Becomes |
|---|---|---|
| `MARKETING_VERSION` | `"1.0"` | `CFBundleShortVersionString` in every target. Numbers and dots only, because App Store Connect rejects anything else. |
| `VERBOSE_CHANNEL` | `beta` | `VerboseChannel` in both apps' Info.plist. Empty for a release. |
| `CURRENT_PROJECT_VERSION` | the run number (CI sets it) | `CFBundleVersion` |

No target sets its own `MARKETING_VERSION`; extensions must match the app, and `bash tools/test-release-notes.sh`
fails if a target overrides it. In code, `AppVersion` (`Verbatim/Model/ReleaseNotes.swift`) reads these keys and
builds the labels.

## How to bump the version

1. In `mac/project.yml`, change `MARKETING_VERSION` (for example, to `"1.1"`) and set `VERBOSE_CHANNEL` (`beta` for
   test builds, `""` for a release).
2. Add a bullet to the `"next"` entry in `ReleaseNotes/ReleaseNotes.json` if the change is visible.
3. Push to main. The next build stamps its release notes with the new version, so What's new starts a new version
   group and closes the older ones.

For launch, set `VERBOSE_CHANNEL` to `""` and leave `MARKETING_VERSION` at `"1.0"`.

## Tags

After a build of main succeeds, the `tag` job in `.github/workflows/build-swift.yml` tags the built commit
`v<marketing version>-b<run number>`, for example `v1.0-b217`. The run's Mac DMG, iPhone tour, and TestFlight
upload all share that run number. The tag leaves out the channel, because the run number already identifies the
build. The weekly bench run ships nothing, so it gets no tag.

Older builds have `beta-<run number>` releases in `stumpandroot/verbose-updates`; those stay as they are.
A `mac-v*` tag (for example, `mac-v1.1.0`) still publishes a Sparkle release with the version it names.

## Release notes and updates

- `release_notes.py stamp` records the version (for example, `"version": "1.0 beta"`) with the build number. Entries
  without a version count as 1.0 beta. See [Release notes](ReleaseNotes/README.md).
- The Sparkle feed's `sparkle:shortVersionString` is "1.0 beta", so the update window reads "Verbose 1.0 beta (217)".
  Sparkle compares only `sparkle:version`, the build number, so updates keep working when the version changes. See
  [Automatic updates](Updates/README.md).
