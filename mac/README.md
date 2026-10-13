# Verbatim for Mac (SwiftUI)

The native app, built from the Listening Desk design. Slice 1: Home, voice memos, file import, on-device transcription with WhisperKit, transcript view with playback, TXT/SRT/VTT export, menu bar recorder.

## Build locally

1. `brew install xcodegen`
2. `cd mac && xcodegen generate`
3. Open `Verbatim.xcodeproj` and run, or `bash build.sh` for a DMG in `dist/`.

Requires Xcode 16 and macOS 14 or later. Models download once into `~/Library/Application Support/Verbatim/models`.

## Layout

- `project.yml` — XcodeGen spec (targets, Info.plist keys, entitlements, package dependency)
- `Verbatim/App` — app entry and `AppState` (navigation, recording, transcription queue)
- `Verbatim/Model` — `Transcript`, `Store` (one JSON per transcript in Application Support)
- `Verbatim/Audio` — `Recorder` (16 kHz WAV with meters), `Player`
- `Verbatim/Transcription` — `Transcriber` (WhisperKit pipeline)
- `Verbatim/Export` — TXT, SRT, VTT
- `Verbatim/Views` — `Theme` (warm paper palette, five springs, tilt card), `Verbie`, `ContentView`, `HomeView`, `TranscriptView`, `SettingsView`

## Next slices

2. Links (yt-dlp sidecar) and app audio capture
3. Dictionary with learn-from-correction; notes with photos and links
4. Send to Apple Notes; Rive rig for Verbie
