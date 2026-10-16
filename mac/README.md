# Verbatim for Mac and iPhone (SwiftUI)

The native app, built from the Listening Desk design and the Oct 13 research dossier. Capture: voice memos, files, links (bundled yt-dlp), app audio (ScreenCaptureKit). Transcription on this Mac: Parakeet via FluidAudio (default, word timings) or Whisper via WhisperKit; offline speaker diarization; Dictionary with reviewable fixes; projects; TXT/SRT/VTT/Markdown/JSON export; menu bar recorder.

## Build locally

1. `brew install xcodegen`
2. `cd mac && xcodegen generate`
3. Open `Verbatim.xcodeproj` and run, or `bash build.sh` for a DMG in `dist/`.

Requires Xcode 16 and macOS 14 or later. Models download once into `~/Library/Application Support/Verbatim/models`.

## Run on your iPhone and Mac with iCloud sync

1. In Terminal: `cd mac && ./setup.sh`. It uses the Stump & Root team ID (VK9YQY88Q9) by default. The script installs XcodeGen if needed, gets the Harper libraries and the link helper, writes `Local.xcconfig`, and opens the project.
2. In Xcode, choose the **VerbatimPhone** scheme, plug in your iPhone (or pick it over Wi-Fi), and press Run (⌘R). The first time, Xcode registers the iCloud container `iCloud.co.stumpandroot.verbatim` for your team; accept its prompts.
3. Choose the **Verbatim** scheme and My Mac, and press Run. Running from Xcode adds the iCloud entitlement to the Mac app; DMG builds from CI don't sync.
4. On the iPhone, the first time you open the app, enable Developer Mode if iOS asks (Settings > Privacy & Security > Developer Mode).

How sync works:

- Transcripts, notes, bookmarks, document edits, projects, the Dictionary, and stills live in Verbatim's private iCloud folder. Both apps read and write the same files.
- The first Mac launch with iCloud copies your existing library into iCloud and keeps the originals in `~/Library/Application Support/Verbatim/Before iCloud`.
- Audio recorded on one device downloads on the other when you first play it.
- Each device transcribes only what it recorded or imported. The other device shows "Transcribing on …".
- Links added on the iPhone wait for a Mac running Verbatim, which fetches the audio and transcribes it.
- If both devices edit the same transcript while offline, the most recent edit wins. The original engine output is never edited.

## Layout

- `project.yml` — XcodeGen spec (targets, Info.plist keys, entitlements, package dependency)
- `Verbatim/App` — app entry and `AppState` (navigation, recording, transcription queue)
- `Verbatim/Model` — `Transcript`, `Store` (one JSON per transcript in Application Support)
- `Verbatim/Audio` — `Recorder` (16 kHz WAV with meters), `Player`, `AppAudioCapture` (ScreenCaptureKit)
- `Verbatim/Transcription` — `Engine` (protocols, presets), `FluidEngine` (Parakeet + diarizer), `WhisperEngine`
- `Verbatim/Sources` — `LinkFetcher` (yt-dlp helper in Contents/Helpers)
- `Verbatim/Export` — TXT, SRT, VTT
- `Verbatim/Views` — `Tokens` (shared palette and type), `Brand` (shared artwork and components), `Theme` (Mac components), `ContentView`, `HomeView`, `TranscriptView`, `SettingsView`
- `Verbatim/Model/CloudSync.swift` — watches the iCloud folder and feeds changes into the Store
- `VerbatimPhone` — the iPhone app; shares Model, Transcription, Document, Audio, Export, Tokens, and Brand with the Mac

## Next

- Benchmark set (25 files) per the dossier, then lock the preset mapping
- Cleaned / Summary / Review with source-linked claims (Apple Foundation Models, MLX fallback)
- Notes with photos and links; Send to Apple Notes
- Rive rig for Verbie

## Licenses bundled

- yt-dlp standalone macOS binary (Unlicense; bundles Python, PSF license). See the yt-dlp README's licensing note before shipping.
- FluidAudio (Apache 2.0) and its model weights; Argmax OSS (MIT). Model licenses are per checkpoint; check before release.
