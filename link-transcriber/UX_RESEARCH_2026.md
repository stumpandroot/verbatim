# Verbatim — iPhone UX/UI research and product direction
**Research date:** October 7, 2026  
**Research type:** Desk research: Apple's design guidelines, App Store product listings and reviews, public community discussions, and usability principles. This is **not** user testing, an App Store ranking analysis, or a statistically representative survey.

## Executive recommendation
Build a tool that feels **joyful at the moment of input and completion, precise during reading**. The user's primary job is not to admire a dashboard; it is to go from a video link to useful, verifiable words in as few steps as possible.

Product principle: **Original words stay original.** AI cleanup, summaries, and review warnings are explicitly derivative views, not corrections silently inserted into the source transcript.

## Competitive study — patterns worth borrowing, not appearances

| App | App Store snapshot (US, 7 Oct 2026) | What stands out | Translation into Verbatim |
| --- | --- | --- | --- |
| **Otter** | 4.8/5, about 83K ratings | Search, editing, highlights, playback at variable speeds, tap-to-jump text, summaries, export, speaker labels | Build source-linked timestamps, quick copy/export, corrections, and eventually player/text synchronization. |
| **Structured** | 4.8/5, about 167K ratings | Strong information hierarchy and visual timeline; one obvious next step | Use a simple three-part hierarchy: add video → process → read/use. |
| **Tiimo** | 4.6/5, about 21K ratings; Apple's 2025 iPhone App of the Year per listing | Warm, calm color, friendly language, visual focus, reduction of mental overhead | Friendly brand, minimal choices up front, gentle supportive loading experience. |
| **Duolingo** | 4.7/5, about 5.5M ratings | Satisfying feedback, lively character/motion, bite-size interaction | Use springy microfeedback for paste, recognized link, completed task; **avoid** streaks and points. |
| **Captions** | 4.7/5, about 38K ratings | Fast creative output and mobile-first editing | Optimize exports and post-processing for working creators. |
| **Notta** | 4.1/5, about 1.4K ratings | Multi-language transcription, summaries, templates, device sync | Later: saved output templates; clear paid limitations and accessibility. |

The ratings above are **not a usability score** and may fluctuate; the comparisons draw on publicly listed features and selected reviews, not controlled A/B testing.

Sources:
- Otter: https://apps.apple.com/us/app/otter-transcribe-voice-notes/id1276437113
- Structured: https://apps.apple.com/us/app/structured-daily-planner-todo/id1499198946
- Tiimo: https://apps.apple.com/us/app/tiimo-to-do-list-planner/id1480220328
- Duolingo: https://apps.apple.com/us/app/duolingo-language-lessons/id570060128
- Captions: https://apps.apple.com/us/app/captions-ai-edits-your-video/id1541407007
- Notta: https://apps.apple.com/us/app/notta-transcribe-voice-to-text/id1480649572

## More relevant design-award references

Apple's 2025 Design Awards singled out **CapWords** for playful transformation feedback and **Speechify** for accessible reading (Dynamic Type, VoiceOver, low cognitive load). Apple's 2025 finalist **iA Writer** emphasizes distraction-free text workflows and intuitive gestures. Verbatim should combine these principles: lively capture-to-text transformation, then a quiet reading surface.

Sources: https://developer.apple.com/design/awards/2025/ and https://www.apple.com/newsroom/2025/06/apple-unveils-winners-and-finalists-of-the-2025-apple-design-awards/

## What users want — findings and hypotheses

**Supported by recurring app features and selected public user feedback:**
1. **Accuracy that can be checked.** Users need readable text but also access to actual source wording, timestamps, and speaker/context information. Otter emphasizes tap-to-jump and text highlight during audio playback.
2. **Answers and summaries they can trust.** Public discussion includes a complaint about misassigned speakers leading to incorrect AI action items. The safe pattern is original transcript → cleaned interpretation → cited takeaways, with uncertainty shown.
3. **Quick exporting and ownership of results.** TXT/SRT/VTT plus ordinary copy/paste are baseline; iOS share-sheet output would reduce friction for creators.
4. **Clear processing status.** If captions are available, use them; if not, try audio. Explain the distinction and why some platform links fail.
5. **Simple pricing and dependable access.** Some reviewed products attract complaints about billing/plan differences or paid access failure; Verbatim should make limits obvious if it later charges.

**Hypotheses to validate through user testing (not proved by the desk research):**
- People will prefer pasting a URL to registering first, on their first visit.
- The first useful result should be visible without asking them to choose a mode before transcription.
- Users on iPhone will frequently arrive from another app's Share menu rather than copying a URL manually.
- People will find side-by-side source/edit comparison useful when preparing publishable quotes.

Community signal examples:
- Speaker confusion / erroneous action items: https://www.reddit.com/r/ProductivityApps/comments/1klofik
- Unclear transcription service plan limits (individual anecdote): https://www.reddit.com/r/ProductivityApps/comments/1nq3427/
- Notta review examples / frustration about subscriptions: https://apps.apple.com/us/app/notta-transcribe-voice-to-text/id1480649572?platform=iphone&see-all=reviews

## iPhone interaction and visual motion rules

**Navigation:** Keep three primary destinations—**Home, Library, About**—plus a separate high-priority **New video** button. Avoid turning an action into a fourth ambiguous tab. Apple's tab guidance favors limited, labeled, stable tabs. https://developer.apple.com/design/human-interface-guidelines/tab-bars

**Animation:** Letter-by-letter logo enters on initial view without gating interaction. Colored sound bars pulse subtly. Input acknowledgment can pop 140–220ms; card taps 180–260ms; state transitions 220–400ms. These are design targets, not Apple-mandated durations. No bounce on selectable transcript text. Honor reduced motion. https://developer.apple.com/design/human-interface-guidelines/motion

**Progress:** Show the **current stage** and an accurate progress estimate only when measurable. Never pretend a time remaining. Allow users to leave a local process only with clear consequences; server-side background/push notifications require a hosted service. https://developer.apple.com/design/human-interface-guidelines/progress-indicators

**Accessibility:** Use comfortable text sizing, legible contrast, labeled controls, tap targets near or above 44 points for principal actions, focus states, and readable content independent of color. This prototype has improved its mobile text sizes but still needs full Dynamic Type / VoiceOver and accessibility testing for a native app. https://developer.apple.com/design/human-interface-guidelines/accessibility

**Reading:** Stable type, text selection, search and copy, timestamps as optional navigation, visual separation between verified source and AI interpretation. https://developer.apple.com/design/human-interface-guidelines/text-views

**Principles:** Nielsen Norman Group's core usability heuristics emphasize status visibility, easy exits, consistency, error prevention, and plain language. https://www.nngroup.com/articles/ten-usability-heuristics/

## What Verbatim should avoid

- Fake completion rates, pretend background execution, or optimistic platform-support claims.
- Silent rewriting of quotations or AI-generated details without review flags.
- Forced account creation before first transcription.
- Heavy mascot animations while the user is reading or searching.
- Generic identical sparkles across every button.
- A cluttered transcript workspace with five equally emphasized actions.
- Auto-play video/audio on first load.
- Tabs that disappear depending on state; if content doesn't exist yet, explain why.
- Uploading sensitive content to an AI provider without an explicit choice.
- Relying on color alone for errors, captions, or success.
- Destructive library actions without confirmation.

## What is implemented in the v5 update

- Integrated 14 custom icon PNGs across mobile and desktop, with a matching home-screen icon.
- Letter-stagger brand entrance and responsive pulsing waveform motif; reduced-motion support.
- Original sound-to-text graphic that organizes the home page without borrowing the reference app's character graphics.
- iPhone-first header, three labeled navigation destinations, prominent quick-add action.
- Mobile clipboard Paste button, supported-platform recognition, language selection, and visible errors.
- Original, Cleaned, Summary, Review views; original unchanged, AI optional; source provenance.
- Existing TXT/SRT/VTT export, copying, search, library, and timestamped source links retained.
- Interactive offline HTML demo clearly marked as a **sample**, alongside a separate functional backend app.

## Product roadmap (what to build next, not currently delivered)

### P0 — Reliability and usability before release
- Test real public/unlisted links across supported platforms on device/network, including failures.
- Create native iOS **Share Extension** or equivalent share-to-Verbatim handoff.
- Test VoiceOver, dynamic type at 200%, text contrast, reduced motion, and iPhone safe areas.
- Add clearly labeled cancellation/queue messaging, retry, and offline/unavailable error states.
- Secure processing/storage policy and meaningful transcript deletion controls for any hosted version.

### P1 — Features users can feel
- Embedded player synced to transcript; tapping a segment seeks the actual video.
- Inline transcript correction and speaker-name editing while preserving original history.
- Grounded Ask the Video with citations linking answers to moments; no unsupported claims.
- Share/export through native iOS sheet to Files, Notes, and other apps.
- Library search, sensible collections, and titles that remain searchable.

### P2 — Differentiating workflow features
- Custom summary formats (tutorial steps, sermon notes, podcast show notes, research brief).
- Side-by-side original vs cleaned on desktop, quick compare gesture on iPhone.
- Multi-language translated output with original always available.
- Batch links and long-video chapters.
- Secure device sync, notification when processing finishes, and background jobs when hosted.

## Practical usability test script (five first-time testers)

Recruit five people who regularly save videos (e.g., student, creator, educator, professional researcher, general user). This is a **proposed** test, not research already conducted.

1. Give them a video URL; ask them to get a clean transcript without coaching. Track whether they find the main action in 10 seconds.
2. Ask them to find the exact wording spoken around 2:00. Track timestamp navigation and confidence.
3. Have them compare the raw and cleaned transcript and identify which is authoritative.
4. Ask them to share three takeaways via Messages or Notes. Count taps and confusion.
5. Simulate a blocked/private video link. Ask what happened and what they would try next.

Record completion success, time, mis-taps, and perceived trust on a 1–5 scale. Iterate the confusing flow before shipping.

## Important implementation limits

This v5 deliverable is a **mobile-responsive web application**, not an App Store-distributed native iPhone app. It needs a reachable backend for live transcription, and saved-library items are browser-local. Some platform videos require sign-in or block caption/audio extraction. The demo page uses illustrative sample data, not live video processing. App Store native haptics, system-wide Share Extension, offline transcription, and background completion notifications are roadmap items, not shipped features.
