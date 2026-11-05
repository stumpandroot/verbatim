# Interface sounds

Verbose's interface sounds, picked by ear by the owner on November 5, 2026. Each file is the sound for one moment (DESIGN.md §7, Sounds; `Model/SoundRules.swift`). Both apps bundle them; `Audio/SoundPlayer.swift` plays them.

- Format: Core Audio Format (`.caf`), 16-bit linear PCM, 48 kHz, mono, converted losslessly from the picked WAV files (the samples are identical).
- Levels: loudness-matched relative to each other before they were picked. The apps play every file at its own level, at volume 1.
- Licenses: every file is either CC0 1.0 (public domain dedication, no credit required) or original work made for Verbose. Nothing here needs attribution in the app.

| File | Moment | Length | Source | License |
|---|---|---|---|---|
| `dictation-start.caf` | Dictation starts listening; a thought starts | 91 ms | Made for Verbose (synthesized in Python) | Original; no third-party material |
| `dictation-stop.caf` | Dictation stops listening | 91 ms | Made for Verbose (synthesized in Python) | Original; no third-party material |
| `dictation-pasted.caf` | Dictation's words were pasted or inserted | 187 ms | [SFX Kit by Wyzowl: `sounds/tones/tone-step-5.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/tones/tone-step-5.wav) | CC0 1.0 |
| `dictation-cancel.caf` | Dictation cancelled | 94 ms | Made for Verbose (synthesized in Python) | Original; no third-party material |
| `thought-saved.caf` | A thought was saved | 204 ms | [SFX Kit by Wyzowl: `sounds/notifications/notification-message-out-soft.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/notifications/notification-message-out-soft.wav) | CC0 1.0 |
| `recording-start.caf` | A recording you started: a voice note, a meeting, a call, app audio | 383 ms | Made from three SFX Kit by Wyzowl files: [`sounds/tones/tone-step-3.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/tones/tone-step-3.wav), [`sounds/tones/tone-step-5.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/tones/tone-step-5.wav), and [`sounds/impacts/impact-light-firm.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/impacts/impact-light-firm.wav) | CC0 1.0 |
| `recording-stop.caf` | A recording stops | 395 ms | Made from the same three SFX Kit by Wyzowl files: [`sounds/tones/tone-step-5.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/tones/tone-step-5.wav), [`sounds/tones/tone-step-3.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/tones/tone-step-3.wav), and [`sounds/impacts/impact-light-firm.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/impacts/impact-light-firm.wav) | CC0 1.0 |
| `auto-call.caf` | A call recording started on its own | 465 ms | [SFX Kit by Wyzowl: `sounds/notifications/notification-success-soft.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/notifications/notification-success-soft.wav) | CC0 1.0 |
| `transcription-done.caf` | A recording's transcript is ready | 615 ms | [SFX Kit by Wyzowl: `sounds/notifications/notification-success-warm.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/notifications/notification-success-warm.wav) | CC0 1.0 |
| `summary-ready.caf` | A summary is written | 798 ms | [SFX Kit by Wyzowl: `sounds/logo-stings/sting-warm-short.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/logo-stings/sting-warm-short.wav) | CC0 1.0 |
| `error.caf` | Something failed that you need to act on | 262 ms | [SFX Kit by Wyzowl: `sounds/notifications/notification-failure-knock.wav`](https://github.com/wyzowl/sfx-kit/blob/92780e7ab0cdfb557497a988089c47f46e8c7412/sounds/notifications/notification-failure-knock.wav) | CC0 1.0 |

SFX Kit by Wyzowl is dedicated to the public domain under CC0 1.0 (the repository's LICENSE; its README says "Free for any use, commercial or not: CC0, no credit required"). The links point to the exact commit the files came from.

To add or replace a sound, keep the file 48 kHz mono 16-bit, match its loudness to the set by ear, and update its length in `SoundMoment.seconds`, this table, and DESIGN.md §7. `mac/tools/test-sounds.sh` checks that every moment has a file here and a row in this table.
