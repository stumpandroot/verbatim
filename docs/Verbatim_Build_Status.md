## Build status (October 14, 2026)

The native Mac app exists and builds green on a macOS 26 CI runner (repo `stumpandroot/verbatim`, folder `mac/`; latest DMG on the `ci-screens` branch). Every build runs an in-app UI self-test and a screenshot tour.

| Area | Decision or state |
|---|---|
| Engines | Parakeet (FluidAudio) by default (Parakeet v2, English only, for anyone who never picks a preset), WhisperKit as alternate; presets English only / Fast / Balanced / High accuracy / Advanced |
| Design direction | Editorial: New York serif for the Home headline, section titles, and note titles; SF Pro elsewhere. Glass for navigation and controls (system sidebar material with lavender tint, capture toolbar, player, menus); paper for words (transcripts, note cards). Replaced the earlier "Color Pop" lime capture card |
| Highlights | Saved passage = lime (persistent); playing passage = iris (moves); hover = light iris (temporary) |
| Transcript modes | Transcript (timecodes, speakers only when 2+), Document, Review. Summary hidden until built |
| Document view | Paragraphs, no timecodes, editable; Harper (Apache-2.0, built from source as a universal static library) for spelling and grammar underlines with Accept / Ignore / Accept all; Clean up (None / Light / Medium / High) and Tone (As spoken / Casual / Professional / Concise) via Apple's on-device Foundation Model on macOS 26, paragraph by paragraph; Undo history and Reset |
| Copy and Export | Copy button (⌘⇧C) and Export panel with Otter-style options (Document or Transcript, speaker names, timecodes, one paragraph, footer); Plain text, Markdown, Word, SRT, VTT, JSON |
| Dictate | Hold-to-talk (right ⌥ default), floating pill, paste into the front app; every dictation is kept in Library; Copy last dictation |
| Microphone | Source picker (built-in, USB, AirPods, Continuity iPhone, System default) in Settings and on the recording panel; fresh audio engine per recording so the input device is released on Stop |
| Reliability fixes | macOS 26 render loop (`@Changed`), click-twice bug (navigation as one published value, no `withAnimation`), stuck views (all removals instant), recorder and player clocks isolated from the window |

Open: toggle-to-record dictation, snippets, source-linked Summary, Verbie's arms at Home size, brand refresh (prompt delivered to Tim), signing and notarization, and the name (see Risks).
