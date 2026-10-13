# Verbatim for Mac (SwiftUI)

The native app, built from the Listening Desk design and the Oct 13 research dossier. Capture: voice memos, files, links (bundled yt-dlp), app audio (ScreenCaptureKit). Transcription on this Mac: Parakeet via FluidAudio (default, word timings) or Whisper via WhisperKit; offline speaker diarization; Dictionary with reviewable fixes; projects; TXT/SRT/VTT/Markdown/JSON export; menu bar recorder.

## Build locally

1. `brew install xcodegen`
2. `cd mac && xcodegen generate`
3. Open `Verbatim.xcodeproj` and run, or `bash build.sh` for a DMG in `dist/`.

Requires Xcode 16 and macOS 14 or later. Models download once into `~/Library/Application Support/Verbatim/models`.

## Layout

- `project.yml` — XcodeGen spec (targets, Info.plist keys, entitlements, package dependency)
- `Verbatim/App` — app entry and `AppState` (navigation, recording, transcription queue)
- `Verbatim/Model` — `Transcript`, `Store` (one JSON per transcript in Application Support)
- `Verbatim/Audio` — `Recorder` (16 kHz WAV with meters), `Player`, `AppAudioCapture` (ScreenCaptureKit)
- `Verbatim/Transcription` — `Engine` (protocols, presets), `FluidEngine` (Parakeet + diarizer), `WhisperEngine`
- `Verbatim/Sources` — `LinkFetcher` (yt-dlp helper in Contents/Helpers)
- `Verbatim/Export` — TXT, SRT, VTT
- `Verbatim/Views` — `Theme` (warm paper palette, five springs, tilt card), `Verbie`, `ContentView`, `HomeView`, `TranscriptView`, `SettingsView`

## Next

- Benchmark set (25 files) per the dossier, then lock the preset mapping
- Cleaned / Summary / Review with source-linked claims (Apple Foundation Models, MLX fallback)
- Notes with photos and links; Send to Apple Notes
- Rive rig for Verbie

## Licenses bundled

- yt-dlp standalone macOS binary (Unlicense; bundles Python, PSF license). See the yt-dlp README's licensing note before shipping.
- FluidAudio (Apache 2.0) and its model weights; Argmax OSS (MIT). Model licenses are per checkpoint; check before release.
