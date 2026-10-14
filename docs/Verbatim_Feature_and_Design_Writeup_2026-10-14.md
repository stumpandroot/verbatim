# Verbatim: features, style, and code

A reference for reviewers. Everything here describes build 31 of the native Mac app (repo `stumpandroot/verbatim`, folder `mac/`), as of October 14, 2026. Paste it into any model or hand it to a person and ask for feedback on any section.

**Maker:** Tim Medina, Stump & Root Co. (Strasburg, PA). Verbatim is one of several Mac apps sold under the Green Launch label.

---

## 1. What Verbatim is

Verbatim is a Mac app that turns speech into text and keeps it on the Mac. Four ways in:

1. **Voice note.** Record from the microphone.
2. **Dictate.** Hold a key in any app, speak, release. The words paste where the cursor is.
3. **Bring in a file or a link.** Drop an audio or video file, or paste a YouTube or other video link.
4. **Capture app audio.** Record what another app is playing (a call, a webinar) without video.

Every transcript is stored as a JSON file in `~/Library/Application Support/Verbatim`. Models download once from Hugging Face and run on the Mac. Only fetching a link touches the internet.

**Positioning sentence:** Say it. Keep it.

**Who it's for:** people who talk through their thinking and want it kept as text without a subscription, an account, or a cloud. Solo operators, creatives, trades owners. Priced as a one-time purchase.

**Not trying to be:** a meeting bot (no calendar integration, no joining calls), a team product, a cloud service.

---

## 2. Screens

### 2.1 Window

One window, hidden title bar, unified toolbar. A 236-px sidebar on the left; the current screen fills the rest. Minimum window 980 × 640; opens at 1200 × 800. Content never pushes the sidebar off the window: each screen is pinned to the width it has and adapts inside it.

**Toolbar:** sidebar toggle (left), search field (right, searches titles and full text; typing switches to Library). On a transcript: Export menu, Notes toggle, text-size menu. No title pill in the center.

**Sidebar:** brand lockup (mark + "Verbatim"), then Home, Library, Dictionary (with a count badge once the Dictionary has entries). A Projects section with colored folders (coral, lime, iris, cycling), a "+" to add one, a hint when empty. A faint iris scribble sits in the bottom-left as decoration. Settings (⌘,) pinned to the bottom. The selected item is a white pill that slides between rows (matched geometry).

### 2.2 Home ("Color Pop")

Headline: **Make room for your thoughts.** with two small tick marks (coral and lime).

**Capture card** (lime, 26-px radius, the hero object):
- "Say it. Keep it." (36 pt rounded bold)
- A two-segment switch, **Voice note / Dictate**, iris pill slides between them.
- One line of copy that changes with the mode.
- Voice note mode: a 112-px coral record button with "Start recording" under it.
- Dictate mode: a white panel showing the current hotkey ("Hold right ⌥ Option") and whether Accessibility is granted, with an **Allow** button when it isn't. Shows the last dictated phrase.
- Verbie stands bottom-right, 150 × 230, tracking the pointer with his eyes.
- While recording the card swaps to a **Record panel**: live meter, elapsed time, Pause, Stop. While capturing app audio: app name, elapsed, Stop.

**Bring something in** card (lavender, to the right; stacks below the capture card in a narrow window):
- Link field with an arrow button. Submit fetches the audio with yt-dlp.
- **Import file** row (also a drop target; the hint changes to "Drop to transcribe").
- **Capture app audio** row, opens the app picker.

**Recent transcripts:** heading, filter chips (All / Recordings / Imports), "View all →" to Library. Up to six rows. Each row: source icon tile, title, meta line (source · duration · speaker count), a small waveform thumbnail drawn from the recording's real envelope, date, and a ⋯ menu (Open, Pin, Move to project, Retry transcription, Delete).

Footer: green dot, "Transcription runs on this Mac", info tooltip.

### 2.3 Library

Every transcript, grouped: Pinned first, then Today, Yesterday, then dated groups. Same rows as Home. The sidebar's project folders filter this view; the search field filters it too. Empty state shows Verbie with a line of copy.

### 2.4 Transcript ("Listening Desk" reading + "Soft Instrument" controls)

Left, a reading column (max 680 px):
- Editable title (30 pt rounded bold), meta line (source · duration · speakers · "Open source" link for link imports).
- Mode capsule: **Original / Cleaned / Summary / Review**, plus "Original preserved ⓘ".
- Lines: timestamp in a 48-px monospaced gutter, speaker name shown only when the speaker changes (colored dot, menu to reassign or rename), then the text. Click a line to select it (iris bar at left). Right-click: Correct "word"…, Note on this passage, Play from here. The line that's playing gets an iris tint.
- **Cleaned** is a deterministic light cleanup (removes um/uh/you know/I mean/like/sort of/kind of, fixes double spaces, capitalizes). No model.
- **Review** lists every correction (dictionary and manual) with an Undo per item.
- **Summary** is a placeholder for a local-LLM summary with source-linked lines. Not built yet.
- Correction popover: replacement text, a "Remember in Dictionary" toggle (on by default). Project-scoped when that setting is on.

Bottom of the column, floating: the **player dock** (shows only when the transcript has audio). Iris play button, current time, a **wave track** built from the real audio envelope with a progress mask and bookmark ticks, click-to-seek, speed menu (0.75×–2×), bookmark button. Keys: space play/pause, ← → skip 5 s, B bookmark.

Right, a 300-px **Notes panel** (toggle in toolbar): "Add note… (click a line to link it)" field, notes as colored cards (passage-linked notes show the timestamp and jump to it), bookmarks look like notes with a flag. A **Details** disclosure at the bottom holds the project picker, engine/model used, and Delete.

Export menu: TXT, SRT, VTT, Markdown, JSON. Speakers and provenance (engine, model, date) included where the format allows.

### 2.5 Dictionary

Explanation copy, search field, **Add word** (preferred spelling + comma-separated "heard as" forms). A table: Preferred spelling (pill), Heard as, Learned from (transcript title or "Added by you", plus "Only in <project>" when scoped), on/off switch. Right-click to delete. Empty state with Verbie.

### 2.6 Settings

Four tabs.
- **General:** Show in menu bar, Sounds, Show the welcome card on Home.
- **Transcription:** Quality preset (Fast / Balanced / High accuracy / Advanced). Advanced exposes engine + model. Identify speakers. Apply Dictionary to new transcripts.
- **Dictate:** Dictate anywhere on/off. Hold-to-talk key: right ⌥, right ⌘, Fn/🌐, or ⌃⌥ Space. Accessibility status with Allow… and Open System Settings. Project vocabulary on/off.
- **Storage:** Reveal transcripts and audio, models, and launch log in Finder; shows the path.

### 2.7 Menu bar panel

Optional. Record a voice memo or capture an app from anywhere; shows the live recording state with Pause/Stop; last transcript; Open Verbatim; Quit. ⌥⇧R records while the app runs.

### 2.8 Dictate pill

A floating, non-activating 360 × 64 dark panel at the bottom-center of the screen while the hotkey is held: Verbie listening, a white live meter, "Listening / Release to paste into <App>". Switches to "Writing into <App>…" with a spinner while transcribing. Fades in 180 ms, out 200 ms.

---

## 3. How the features work

### 3.1 Recording (voice note)

`Audio/Recorder.swift`. An `AVAudioEngine` input tap (2048-frame buffers). On the audio thread, `RecordingWriter` converts each buffer to 16 kHz mono Int16 with `AVAudioConverter`, writes a WAV, computes RMS, and maps it to a perceptual level `min(1, pow(rms × 4, 0.6))`. The UI meter updates every 70 ms with the peak since the last update, so bars follow the voice. Pause stops writing but keeps the engine running. Stop returns `(url, duration, envelope)`; the envelope (120 buckets) becomes the row thumbnail and the player wave. Recordings under 0.5 s are discarded.

Microphone permission: first use shows a mic sheet explaining why; "Not now" dismisses.

### 3.2 Transcription pipeline

`App/AppState.swift` → `run(id)`:

1. Pick engine and model from the preset (or Advanced choice).
2. `engine.transcribe(url:model:progress:)` on a detached task. Progress strings ("Downloading Parakeet v3 42%", "Loading", "Transcribing", "Finding speakers", "Applying Dictionary") show on the row and the transcript header.
3. If **Identify speakers** is on and there's more than one segment: FluidAudio offline diarization → `SpeakerAssigner` gives each segment the speaker with the most overlap, labels them S1, S2… in order of appearance, display names "Speaker 1", "Speaker 2".
4. Keep the engine output as `original`. Copy to `segments` and apply the Dictionary (`DictionaryApplier`): whole-word, case-insensitive, Unicode-aware regex per "heard as" form; each replacement is recorded as a `Correction` with `byDictionary: true`. Project-scoped entries only apply to transcripts in that project.
5. Compute the waveform envelope from the file if the transcript doesn't have one (imports, links).
6. Save: status `ready`, auto-title from the first eight words if the title is still the default, play the "Tink" sound, show a toast with **Open**.

Failures set `status = failed` with a readable `error` and a Retry action. A transcript found `processing` at launch is marked failed with "Interrupted before it finished."

### 3.3 Engines

`Transcription/Engine.swift` defines `TranscriptionEngine` and `DiarizationEngine` protocols so engines are swappable.

- **FluidEngine** (`FluidAudio` 0.17.7, NVIDIA Parakeet TDT via CoreML): models `redux` (~220 MB, fastest), `v3` (25 languages, default), `v2` (English), `ultra` (best). Returns word timings; `Engines.segments(fromWords:)` splits into sentence-ish segments at punctuation (≥6 words), pauses over 1.2 s, or 28 words.
- **WhisperEngine** (`argmax-oss-swift` 1.1.0, WhisperKit): `base`, `small`, `large-v3_turbo` (1.6 GB). Alternate for languages Parakeet misses.
- **FluidDiarizer** (FluidAudio `OfflineDiarizerManager`).

Presets: Fast = Parakeet Redux, Balanced = Parakeet v3, High accuracy = Parakeet Ultra, Advanced = pick.

### 3.4 Links

`Sources/LinkFetcher.swift` runs a bundled `yt-dlp` (pinned 2026.08.19, in `Contents/Helpers`) to download audio only, then the file goes through the same pipeline with `source = .link` and the original URL kept for "Open source".

### 3.5 App audio capture

`Audio/AppAudioCapture.swift` uses ScreenCaptureKit (`SCStream`, audio only, no video kept). Needs the Screen & System Audio Recording permission; the error toast says where to grant it. The app picker lists running apps with windows.

### 3.6 Dictate

`App/Dictation.swift`, `DictationController`:

- Needs Accessibility (to see the key globally and to press ⌘V in the other app). `AXIsProcessTrusted()` is polled every 2 s on the settings tab; monitors refresh when it flips.
- Global + local `NSEvent` monitors watch `flagsChanged` (right ⌥ keyCode 61, right ⌘ 54, Fn 63) or `keyDown`/`keyUp` for ⌃⌥ Space.
- Key down: remember the frontmost app, start its own `Recorder` into the downloads folder, show the pill, play "Pop".
- Key up: stop. Under 0.5 s → discard. Otherwise transcribe with the current engine, apply the Dictionary, join the text, delete the WAV.
- Deliver: save the clipboard, put the text (plus a trailing space) on it, activate the target app, post ⌘V via `CGEvent` after 150 ms, play "Tink", restore the clipboard 600 ms later.
- Nothing is read from other apps.

### 3.7 Notes and bookmarks

`Note { text, at?, segmentId?, isBookmark }` on each transcript. Notes added from the panel link to the selected line. B (or the dock button) adds a bookmark at the current time with the first 60 characters of that line as its text. Bookmarks draw as ticks on the wave track.

### 3.8 Projects and vocabulary

Projects are folders (`Project { name, colorIndex }`). A transcript belongs to at most one. The sidebar folder filters Library. With **Project vocabulary** on, corrections remembered from a transcript in a project only apply inside that project; otherwise they're global.

### 3.9 Recovery

At launch `Store.recoverOrphans()` looks for audio files with no transcript JSON (the app died mid-recording) and creates a failed "Recovered recording" entry with Retry.

### 3.10 Search

The toolbar field filters by title and full text (`AppState.filtered`); any non-empty query navigates to Library.

---

## 4. Style

### 4.1 Principles

- **Expressive capture, calm reading.** Color, motion, and Verbie live on Home and around recording. The transcript is quiet paper.
- **Clear over clever.** Copy says what happens ("Transcription runs on this Mac"). Fixes are never silent: every Dictionary replacement is listed under Review.
- **Nothing runs when nothing happens.** Idle CPU is 0% on macOS 26. No SwiftUI timers or repeat-forever animations; continuous motion is Core Animation.
- **One tool per job.** One window, one search field, one capture card.

### 4.2 Tokens (`Views/Theme.swift`)

| Token | Hex | Use |
|---|---|---|
| paper | #FAF7F2 | window background (warm, not grey) |
| side | #F1EDFA | sidebar |
| ink | #2A2622 | text, dark buttons |
| dim / mute | #6B6459 / #857D70 | secondary / tertiary text |
| iris | #6F5AF0 | selection, links, play, Dictate accent |
| irisTint | #EEE9FF | playing-line tint |
| coral | #FF7C5C | record, speaker 2, waveform |
| lime | #B7E26A | capture card, "allowed" state |
| limeDeep | #1F3A0A | text on lime |
| hairline | black 7% | borders |

Type: SF Pro, rounded design for display sizes (34–36 pt headlines, 30 pt transcript title, 22 pt section heads). Body 13.5–15 pt. Timestamps SF Mono 12 pt. Corner radii: 26 (hero), 22 (secondary card), 14 (rows), 12 (fields), 60 (record button).

### 4.3 Motion (`Motion` springs)

| Name | Spring | Use |
|---|---|---|
| touch | 0.15 s, bounce 0 | hover enter, press |
| settle | 0.35 s, 0.05 | screen slides, panels, lists |
| snap | 0.30 s, 0.25 | segmented switches, selection |
| bounce | 0.50 s, 0.40 | entrance stagger, hover release |
| hero | 0.70 s, 0.35 | big reveals |

- **Screen transitions** slide by direction: push from the right for a transcript, pop back to the right, up/down by sidebar order. A screen that's entering or leaving can't be clicked.
- **Entrance stagger:** each block fades up 6 px with a 35 ms step.
- **Hover:** rows and tiles tilt up to 4° toward the pointer with a soft radial spotlight and a 2-px lift (`CardButton`). The capture card gets the spotlight and lift but not the rotation (controls inside a 3D-rotated card lose clicks on macOS 26).
- **Press:** scale 0.97 on real buttons (`PressStyle`).
- **Sounds:** "Pop" on record start, "Tink" on transcript ready. Off with Reduce Motion or the Sounds setting.
- Reduce Motion disables tilt, stagger offsets, and sounds.

### 4.4 Verbie

The mascot: a purple pill-shaped character with white eyes, a smile, thin rubber-hose arms with round hands, short legs, and a shadow. Drawn with `CAShapeLayer`s in `Views/Verbie.swift`; proportions and arm geometry come from the HTML prototype rig (`verbie-rig.js`).

- **Idle:** breathes (scale), sways, blinks on a randomized interval, eyes track the pointer (NSEvent local monitor).
- **Poses** (arm angles, hand rotation, lean): ready, listening, receiving (file drop), working, saved, paused, permission, interrupted, nothing (empty states). Pose changes animate with Core Animation springs; `pop()` bounces on arrival.
- Appears on Home (150 × 230), in empty states (54 × 72 to 96 × 130), and in the Dictate pill (30 × 42).
- Known issue: the arm rendering at Home size doesn't match the prototype yet (one hand reads as a coral blob, the other arm reaches off to the side). Under review.

---

## 5. Code

### 5.1 Stack

- Swift 5, SwiftUI + AppKit, macOS 14+, universal binary (arm64 + x86_64).
- XcodeGen (`project.yml`) generates the project. No storyboards.
- Packages: `FluidAudio` 0.17.7 (Parakeet ASR + diarization), `argmax-oss-swift` 1.1.0 (WhisperKit).
- Helper: `yt-dlp` standalone binary bundled and signed with the app.
- Entitlements: audio input, hardened runtime with unsigned executable memory and library validation off (needed by the CoreML/ML runtimes), JIT off.
- 4,139 lines of Swift across 26 files.

### 5.2 File map

```
mac/
  project.yml, build.sh                  XcodeGen spec; universal build, sign, DMG, notarize
  Verbatim/
    App/
      VerbatimApp.swift     WindowGroup, commands (⌘N, ⌥⇧R, ⌘F), Settings scene, MenuBarExtra
      AppState.swift        all app state, navigation, recording, pipeline, actions (356 lines)
      Changed.swift         @Changed property wrapper (publishes only on real change)
      Dictation.swift       hold-to-talk controller + floating pill
      UITest.swift          in-app UI self-test (CI gate)
      Log.swift             os_log + ~/Library/Logs/Verbatim/native.log
    Audio/
      Recorder.swift        AVAudioEngine recorder, 16 kHz WAV writer, meter, envelope
      Player.swift          AVAudioPlayer with rate and seek
      AppAudioCapture.swift ScreenCaptureKit audio-only capture
    Model/
      Transcript.swift      Transcript, Segment, WordSpan, Speaker, Correction, Note, Project
      Dictionary.swift      DictionaryEntry, DictionaryApplier
      Store.swift           JSON-per-transcript store, projects, dictionary, recovery, grouping
    Transcription/
      Engine.swift          protocols, presets, engine registry, word→segment splitter
      FluidEngine.swift     Parakeet ASR, diarizer, SpeakerAssigner
      WhisperEngine.swift   WhisperKit
    Sources/LinkFetcher.swift   yt-dlp process wrapper
    Export/Exporter.swift       TXT / SRT / VTT / MD / JSON
    Views/
      Theme.swift           tokens, springs, CardButton, TapArea, TiltCard, PressStyle, StaggerIn, Sounds
      ContentView.swift     sidebar, screen router, transitions, toast, mic sheet, app picker, export menu
      HomeView.swift        Color Pop Home
      LibraryView.swift
      TranscriptView.swift  reading column, modes, player dock, notes panel
      DictionaryView.swift
      SettingsView.swift    settings tabs + menu bar panel
      Verbie.swift          Core Animation mascot
      Meter.swift           CALayer level meter
```

### 5.3 State model

One `AppState` (`ObservableObject`, main actor) owns `Store`, `Recorder`, `Player`, `AppAudioCapture`, and `DictationController`, and forwards their `objectWillChange`. Views read it through `@EnvironmentObject`.

Every piece of state is declared with `@Changed` instead of `@Published`/`@AppStorage`. `@Changed` publishes only when the value differs and can mirror to `UserDefaults`. This exists because SwiftUI scenes on macOS 26 write bindings back on every update (MenuBarExtra's `isInserted`, the search field); a plain `@Published` re-announces an unchanged value, the App body re-evaluates, and the app spins at 100% CPU with a beachball. That was the first bug found on a real Mac and is why CI runs on macOS 26.

Navigation is a `Screen` enum (`home`, `library`, `transcript(UUID)`, `dictionary`) plus a `direction` that picks the transition.

### 5.4 Data

`~/Library/Application Support/Verbatim/`
- `transcripts/<uuid>.json` — one file per transcript (pretty-printed, sorted keys, ISO-8601 dates).
- `audio/<date>.wav|m4a|…` — the recording or imported file.
- `models/` — downloaded ML models.
- `downloads/` — link fetches and dictation temp files.
- `projects.json`, `dictionary.json`.

`Transcript` fields: id, title, createdAt, source (voiceMemo | file | link | app), sourceLabel, sourceURL, duration, audioFileName, original (engine output), segments (corrected), speakers, corrections, notes, waveform (120 floats), projectId, tags, pinned, engine, model, language, status (processing | ready | failed), stage, error.

### 5.5 Hit-testing on macOS 26

Three workarounds, all in `Theme.swift`, each found by the self-test:

- `CardButton`: the tilted visuals sit underneath with hit-testing off; a flat overlay with `onContinuousHover` + a zero-distance `DragGesture` takes the click. A plain `Button` under `rotation3DEffect` loses clicks.
- `TapArea`: sidebar items and chips use a direct gesture instead of `Button`, which needed two clicks.
- `ScreenSlide`: custom transition modifier that sets `allowsHitTesting(false)` while a screen is entering or leaving. An outgoing screen could linger invisibly and swallow clicks ("I have to click twice").

### 5.6 Build and CI

`mac/build.sh`: xcodegen → fetch pinned yt-dlp → `xcodebuild` Release universal → bundle and sign the helper → sign the app (Developer ID when present, ad-hoc otherwise) → DMG → notarize when a `verbatim-notary` profile exists.

`.github/workflows/build-swift.yml` runs on a **macos-26** runner (same OS as Tim's Mac):

1. Build the DMG.
2. Launch the app with `VERBATIM_UITEST=1`, wait, screenshot the transcript, sample CPU three times, run `sample`, screenshot Home, copy `native.log`, any crash report, and the os_log.
3. Push everything (including the DMG) to the `ci-screens` branch, since artifact storage isn't reachable from the dev environment.
4. **Gate:** fail the build if the self-test logs any `UITEST FAIL` or didn't finish.

### 5.7 In-app UI self-test

`App/UITest.swift`. With `VERBATIM_UITEST=1` the app seeds a two-speaker transcript, then synthesizes real `NSEvent` mouse moves and clicks at the recorded frames of tagged controls (`.uiTarget("row-0")`, `"side-library"`, `"mode-dictate"`, `"tile-record"`, …), scrolling them into view first. Eleven steps: open a row, each sidebar item, mode switch both ways, record tile (expects the mic sheet or a recording), Not now, app tile opens the picker, row again. Each step logs PASS/FAIL plus the view under the click, so a hit-testing regression is readable from the log. This is what caught every click bug above.

### 5.8 Logging

`Log.note()` writes to os_log and `~/Library/Logs/Verbatim/native.log` with launch-relative timestamps. Settings › Storage reveals it. A hang or crash report plus this log is enough to diagnose remotely.

---

## 6. Known gaps and open questions

Things that are not done, or that a reviewer should push on:

1. **Summary mode** is a placeholder. Plan: a small local LLM producing a summary where each line links to its source passages. Which model, and whether to ship one or let people choose, is open.
2. **Verbie's arms** at Home size don't match the sheet. Options: tune the Core Animation rig, or move the character to Rive.
3. **Speaker rename** menu item is wired but the rename field isn't.
4. **Cleaned** is rule-based. Good enough for fillers; won't fix grammar.
5. **No signing yet.** Builds are ad-hoc signed; Gatekeeper warns. Developer ID + notarization are in the build script and run once the certificate secrets exist.
6. **Dictate** is untested beyond the author's machine. Questions: is right ⌥ the right default? Should there be a toggle (tap to start, tap to stop) in addition to hold? Should it insert via Accessibility API instead of ⌘V where possible?
7. **Transcript spacing** was just tightened; needs eyes on a long real transcript.
8. **Onboarding** is one sheet for the mic. No first-run tour.
9. **macOS 26 toolbar** groups items into glass pills; the Export/Notes/AA cluster could be tidier.
10. **Send to Apple Notes / Markdown to clipboard** are not built; export is file-based.
11. **Pricing and licensing** are handled outside the app (Green Launch license service); the app doesn't check a license yet.

---

## 7. Questions for reviewers

- Does Home read as one clear primary action, or do the capture card and the Bring-in card compete?
- Is "Original / Cleaned / Summary / Review" the right set of modes, and are those the right names?
- Is a transcript-with-notes the right core object, or should notes be a separate thing?
- Dictate: what would make you trust it enough to use it in email?
- Where is the copy unclear?
- What's missing that would make you pay once for this instead of subscribing to something?
