# VERBATIM
## Research dossier and recommended product specification
**Prepared October 13, 2026 · Mac-only · One-time purchase · Stump & Root / GreenLaunch**

### Executive decision

**Position Verbatim as the offline-first Mac workspace for transcription, voice notes, and practical transcript editing.** Its advantage should be reliable local processing and unusually good organization of the resulting words, not a claim that one model will always beat every competitor.

**Recommended stack to prototype:** [FluidAudio](https://github.com/FluidInference/FluidAudio) for local Parakeet-family transcription, voice activity detection and offline speaker diarization; [Argmax Open-Source SDK / WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) or [whisper.cpp](https://github.com/ggml-org/whisper.cpp) as a complementary Whisper-based engine; Apple's [Foundation Models](https://developer.apple.com/documentation/FoundationModels) when available for local cleanup and structured summaries, with an optional [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) model fallback.

The main strategic principle: **transcription, speaker labeling, cleanup and summarization are four different processes. Keep them separate in both code and UI.** The original transcript must remain recoverable even if an AI-generated cleaned version is wrong.

### 1. Product definition and user jobs

Verbatim currently accepts video links, local files and voice input; produces Original, Cleaned, Summary and Review views; and needs searchable timestamps, a library and TXT/SRT/VTT exports. Preserve these strengths instead of replacing them with a generalized meeting-assistant product.

**Primary jobs:**

1. **Creator's research:** paste a supported video link or load a downloaded recording, transcribe it, find useful quotes and navigate back to the source timecode.
2. **Client interviews:** import a 30-90-minute recording, identify speakers, clean the transcription and export notes without distorting quotations.
3. **Voice notes:** capture an idea, get a plain transcript and optionally a concise actionable summary.
4. **Video production:** extract caption-ready SRT/VTT with verified timestamps and easy text correction.
5. **Meeting follow-through:** find decisions, action items and named people, with pointers to the actual supporting transcript passages.

**Core promise:** "Record, transcribe, find, and use the words that matter. Your recordings stay on your Mac by default."

### 2. Competitive landscape

| Product | Verified features / positioning | What Verbatim should learn |
|---|---|---|
| [MacWhisper](https://macwhisper.com/) | On-device transcription, selectable models, speaker recognition and extensive export formats | Table stakes are already high. Win on everyday transcript organization and source-backed review, not merely offline transcription. |
| [MacWhisper speaker recognition](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper) | Recognizes and groups speakers with compatible local WhisperKit models; names are editable | Speaker assignment must be correctable by people. |
| [MacWhisper export CLI](https://docs.macwhisper.com/article/57-macwhisper-command-line-tool) | TXT, SRT, VTT, CSV and advanced structured/timecoded output | Export reliability, timestamps and editing fidelity are expected professional capabilities. |
| [Argmax OSS](https://github.com/argmaxinc/argmax-oss-swift) | WhisperKit plus SpeakerKit under an open-source Swift framework | Can provide a complementary, fully local implementation and benchmark engine. |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apple-native Core ML ASR, VAD and diarization with a broad local model catalog | A credible primary SDK to prototype, though benchmark its models on your actual material. |

**Likely differentiation:** pleasant Mac-first workflow for people who frequently move between a video, transcript, searchable archive and reusable written notes. Do not assume that 'offline' alone differentiates Verbatim; MacWhisper already offers offline processing by default for local models ([privacy documentation](https://docs.macwhisper.com/article/52-keeping-transcriptions-private)).

### 3. Model research: different engines for different situations

| Engine/model | Best candidate use | Strengths | Watch-outs |
|---|---|---|---|
| **FluidAudio + Parakeet Ultra** | First-choice benchmark for multilingual file transcription | Vendor documents a 25-language variant and recommends Ultra over v3 for certain accuracy/speed cases | Verify language support, exact checkpoint licensing, memory and long-form behavior on shipping Macs. |
| **FluidAudio + Parakeet TDT v3** | Default multilingual fallback | Proven Core ML integration and broad European language support | Proper nouns and English-only recall may favor other models. |
| **FluidAudio + Parakeet TDT v2** | English-specific accuracy comparison | English-specialized model; FluidAudio notes recall advantages in some settings | Does not replace multilingual option. |
| **FluidAudio + Parakeet Redux** | Smaller optional download | Vendor describes a ~220 MB download, on supported newer OS versions | Test whether quality is adequate before calling it the 'fast' preset. |
| **Argmax OSS WhisperKit** | Multilingual/accuracy fallback; independent benchmark | Open-source, Core ML/Apple Silicon; integrated SpeakerKit available | Different memory, conversion and first-run model-loading behavior. The Argmax OSS package replaces the old stand-alone WhisperKit as of 2026. |
| **whisper.cpp** | Cross-hardware fallback and controllable inference | Metal/Core ML, quantization, CPU support and mature C/C++ integration | Additional native packaging and complexity; not necessary to ship all engines. |
| **Apple Speech/SpeechAnalyzer** | Investigate as OS-managed fallback | System-managed model assets via AssetInventory | OS/language coverage and behavior differ; benchmark before selecting. |

**Do not choose by leaderboard alone.** The right comparison uses your own meeting recordings: multiple speakers, distant microphones, shop noise, brand names, technical terms, YouTube audio, and casual voice notes. FluidAudio's reported speed numbers are **developer benchmarks**, not promises for every device ([project](https://github.com/FluidInference/FluidAudio), [benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)).

**Model options presented to users should be intelligible:** "Fast", "Balanced", "High accuracy" and "Advanced: choose engine/model". Map these labels to tested configurations, not arbitrary model-size assumptions.

### 4. Offline speech-to-text architecture

Proposed processing chain:

1. **Input adapter:** microphone, file importer, or link source. Normalize metadata, language and user preferences.
2. **Source acquisition:** import or download only where permitted, into a controlled temporary location. Record source URL/filename and timestamp.
3. **Audio conversion:** use AVFoundation or a vetted local decoder to obtain consistent 16 kHz mono PCM (or another rate required by the model), with error reporting.
4. **Voice activity detection (VAD):** identify speech vs silence; ensure padding so first/last words aren't cut.
5. **Segmentation/chunking:** process long recordings in bounded-memory chunks with overlap where appropriate; carry exact offsets forward.
6. **ASR engine:** run chosen Core ML / Whisper model with offline cached weights.
7. **Word/time alignment:** collect word-level or segment-level timestamp evidence as supported. Never fabricate word-precise times from segment-only outputs.
8. **Speaker diarization:** classify speaker turns separately and associate them with ASR words/segments. Mark uncertain or overlapping assignments for review.
9. **Canonical transcript:** store an immutable initial recognition result, revisions as separate data, and the selected model/configuration/provenance.
10. **Post-processing:** optional cleanup, normalized punctuation and content summaries, derived from the canonical transcript with source references.
11. **Index/export:** searchable database, playback synchronization and deterministic TXT/SRT/VTT/MD/JSON outputs as appropriate.

**Engineering pattern:** define `TranscriptionEngine`, `DiarizationEngine` and `TranscriptRefinementEngine` protocols; normalize outputs into a model-independent timeline. This permits replacement of specific models without rewriting the UI or corrupting existing transcripts.

For very long files, choose file-streaming/memory-mapped APIs where possible; FluidAudio documents memory-mapped diarization ([guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)), and Argmax OSS documented incremental file loading in its August 2026 release ([release discussion](https://github.com/argmaxinc/argmax-oss-swift/discussions/522)).

### 5. Speaker identification: essential, but imperfect

Two concepts should not be confused:

- **Diarization:** which anonymous voice is speaking at each point? ('Speaker 1', 'Speaker 2').
- **Speaker identification:** which real person corresponds to that voice? ('Trent', 'Dave', 'Tim').

The first can be automated reasonably; the second often requires explicit user input, enrollment or correction. FluidAudio has an offline diarization pipeline based on Pyannote/WeSpeaker/VBx, as well as streaming options ([project documentation](https://github.com/FluidInference/FluidAudio), [getting started](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)). Argmax OSS also offers [SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift).

**Recommended UX:** speaker chips with editable names; clicking a speaker filters their turns; clicking an incorrect turn allows 'Assign to...' and optional 'Apply to similar turns'. Never silently merge or identify speakers across separate recordings without user choice. Explicitly show uncertainty and retain original IDs. Add opt-in known-speaker profiles only after consent and privacy design.

### 6. The four modes: use them deliberately

#### Original

Unaltered ASR text linked to its time spans and source recording; users may make corrections, but the original recognition output remains available in revision history. Show speaker turns and exact timestamps.

#### Cleaned

One-click readability pass: punctuation, paragraph breaks, obvious fillers and repeated phrases. **Must not change facts, names, numbers, negations, or meaning.** Offer at least 'Light cleanup' and 'Polished prose' and show a before/after diff. Mark every transformation as edited text, not verbatim quotation.

#### Summary

Short overview, key topics, decisions, action items and unanswered questions. Each factual claim or quote should link to the supporting segment(s) with timecodes. Add simple templates for "Meeting", "Interview", "Lecture/Video", and "Voice note" rather than a complicated prompt-builder.

#### Review

A verification workspace: original and cleaned transcript side by side, confidence/uncertainty flags, important proper nouns, misattributed speakers, audio playback at the relevant timestamp, and a list of changes to accept/reject. This should be a **real editing function**, not just a fourth tab containing an AI explanation.

### 7. Local cleanup and summarization

**First candidate:** Apple's [Foundation Models framework](https://developer.apple.com/documentation/FoundationModels) for short/medium locally processed chunks, guided structured output, cleanup and small summaries. Apple's on-device `SystemLanguageModel` availability depends on compatible hardware, locale, Apple Intelligence activation and downloaded model readiness ([availability documentation](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)). Do not make Verbatim's basic transcription depend on this API.

**Fallback:** [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) with a separately downloadable, license-vetted local instruction model. Choose specific weights only after testing accuracy, token limits, model download sizes and memory pressure. A model that works on a development Mac may fail on an 8 GB consumer device.

**High-priority safeguard:** make each summary statement carry the IDs of supporting transcript segments. If a model can't cite supporting evidence, exclude or label the statement unverified. Always preserve dates, numbers, names and negation. For long transcripts, build chunk summaries and then a structured synthesis with source IDs; do not simply truncate to the model's context window.

**Privacy UI:** distinguish "On this Mac" processing from any explicitly enabled cloud-provider action. Do not send audio/transcripts to a service without a clear opt-in, visible provider name and understandable data behavior. A fully offline user should still be able to transcribe, edit and export pre-existing local files.

### 8. File input, links and recording

**Files:** MP3, WAV, M4A, FLAC and common video containers should be tested; handle unsupported codecs gracefully. Preserve source file location via security-scoped bookmarks if using Mac sandboxing. Allow dragging folders or importing multiple files only after the single-file pipeline is robust.

**Links:** Keep the link workflow modular. An accessible video page does not always provide a downloadable media stream, and websites frequently change. If using [yt-dlp](https://github.com/yt-dlp/yt-dlp), audit its **specific packaged artifact**, since the project warns that bundled executables can have license obligations different from its core source ([README licensing section](https://github.com/yt-dlp/yt-dlp/blob/master/README.md)). Respect platform terms, copyright, user permissions and content protection; do not bypass DRM or access controls. Consider whether to reuse your Keep downloader through a shared internal component rather than duplicate fragile acquisition code.

**Voice recording:** record microphone input with explicit permission, clear recording status, safe file write/cancel behavior and crash recovery. Use [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) only for an intentionally separate 'system audio / meeting capture' feature, with the required permissions and selection UX. Don't surreptitiously capture other apps' audio; make consent and local recording policy clear.

**Important boundary:** offline speech recognition does **not** make initial video-link acquisition offline. Display "Internet required to fetch this link; transcription runs locally after download".

### 9. Mac UX and information architecture

**Recommended primary layout:** left Library sidebar, center transcript/editor, optional right-side inspector that opens only when needed. Top bar: source title, import/record controls, transcription status, a compact mode selector, search and export. Lower player bar: play/pause, speed, scrubber and current timestamp. Avoid giving the mascot a large section of the working window.

Essential interactions:

- Paste video URL or drop a file and begin immediately with sensible defaults.
- Import/record status is always visible; show model download and first-run initialization separately from transcription progress.
- Click any word/paragraph to jump to source time; highlight current speech during playback.
- Search transcript across one file and the full library; results show surrounding context and timestamp.
- Rename, pin, tag and group sources by projects/clients; don't force a date-first archive.
- Speaker names and glossary terms are editable. A personal/client dictionary should include brand names, product names and recurring people.
- Support speed control, loop around selection, keyboard shortcuts and inline text correction.
- Auto-save edits, retain versions and make exports deterministic.
- Offer a clearly visible offline-ready indicator that reflects **downloaded model availability**, not a generic privacy slogan.

**Visual identity:** Verbie can support onboarding, empty states and pleasant progress moments. The dense transcription screen should prioritize typography, a readable text column, line-spacing and controls. A friendly app doesn't have to feel like a toy.

### 10. Proper nouns and specialist vocabulary

For your own commercial interviews, this is a high-value feature. Technical transcripts frequently mishear company names, people, machines, metal types and industry terms.

Build a **project glossary** where users can add terms such as "DS Fabrication", "DS Stoves", product names and person names before transcription. Use the vocabulary-bias features supplied by an engine when demonstrably supported; otherwise do carefully constrained post-recognition corrections, highlighting proposed changes. **Never globally replace arbitrary homophones without review.** FluidAudio has [custom-vocabulary research and tooling](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md), but engine support and quality must be verified per model.

### 11. Exports and project model

**First-release outputs:**

- TXT: clean or verbatim, with optional speakers and timestamps.
- SRT / VTT: validated cue numbering, time formats, readable cue-length constraints and correct source offsets.
- Markdown: speaker-labeled paragraphs, linked timestamps and a summary.
- JSON: structured transcript, speakers, words, segments, source metadata and revision details for interoperability.

**Future / conditional:** CSV for researchers, Final Cut/Premiere interchange where demand exists, a lightweight interactive HTML transcript, or subtitle styling assistance. Resist building a fully featured subtitle editor before timestamps and text exports are correct.

Canonical stored objects: `Source`, `AudioAsset`, `TranscriptionJob`, `TranscriptSegment`, `WordSpan`, `Speaker`, `TranscriptRevision`, `SummaryClaim`, `Tag/Project`, `ModelInfo`. SQLite/Core Data/SwiftData can back the archive; define stable IDs and a migration strategy before adding multiple AI engines.

### 12. Test strategy and performance gates

Maintain a private benchmark set of **at least 25 audio files**:

- 5 clean single-speaker voice notes
- 5 two- or three-person interviews with known speaker identities
- 5 noisy or distant-microphone meetings
- 5 long videos/podcasts with pauses, music, acronyms and technical nouns
- 5 non-English or accented samples reflecting intended language coverage

Measure:

- **WER** (word error rate) and normalized WER after consistent transcript formatting.
- **Proper noun / number accuracy** separately, since generic WER can hide business-critical errors.
- **DER/JER** or manual speaker-turn review where ground truth exists.
- Word and subtitle timecode drift, especially after long chunks and pauses.
- Real-time factor, peak RAM, first-load time, storage used by installed models, energy/battery behavior and crash recovery.
- Summary factuality: every claim must have valid supporting timestamps; no invented commitments or action items.

Test on at least one less-powerful supported Apple Silicon Mac, not only a high-end development machine. Record the engine version and model checksum for each benchmark run.

### 13. Ranked implementation sequence

**P0 - Trustworthy transcription**

1. Define a canonical segment/word/speaker timeline and immutable original transcript.
2. Implement local file audio conversion and a FluidAudio ASR proof of concept; test Parakeet Ultra, v3 and v2 as relevant.
3. Validate a WhisperKit-based alternative on your benchmark material; keep the winner for each actual use case.
4. Implement offline model downloads, caching, storage visibility and graceful missing-model states.
5. Ship recording, file import, playback-synchronized transcript, basic correction, full-text search and TXT/SRT/VTT export.

**P1 - What makes Verbatim valuable**

6. Add diarization, renaming speakers and manual correction.
7. Build the project glossary and safe proper-name fixes.
8. Implement Cleaned and Summary with traceable source segments; Review with side-by-side diff and audio verification.
9. Persist a searchable, project-based Library and reliable re-import/version handling.

**P2 - Extensions**

10. Improve video-link handling by reusing shared downloader infrastructure with Keep.
11. Add Mac system-audio capture with explicit permissions.
12. Add optional local MLX models, more languages and customizable summary templates, based on real user demand.
13. Consider iPhone intake through Shortcuts/share sheet or another clearly scoped companion mechanism only after Mac reliability is established.

### 14. Commercialization and UX constraints

Your decided business model is a one-time Mac purchase, not a subscription. That argues for predictable ongoing costs: on-device models, no mandatory hosted inference, no unbounded cloud bill, and optional user-configured cloud providers only if you later want them. Model files must be downloadable, relocatable or removable without confusing users. Bundle only what is reasonable for the DMG size and first-launch experience.

Avoid claims such as "perfect transcripts", "works offline with every video link" or "automatic identification of everyone in a meeting". Make capabilities explicit and demonstrable. Provide privacy-first defaults; respect source copyright and recording consent laws.

### 15. Hard acceptance criteria for first release

- A user can record a voice note, end it, and receive a usable local transcript with networking disabled (assuming model already installed).
- A one-hour local meeting transcribes without exhausting memory or losing timestamps.
- The original transcript remains accessible after cleanup or summary generation.
- Every generated action item is traceable to the source recording or labeled as inference.
- A user can correct a speaker, a proper noun or a misheard sentence without re-running ASR.
- SRT and VTT import correctly into at least two common editing/video tools and stay in sync.
- The app gives plain-language failure states for missing/unsupported codecs, model downloads, permissions and link acquisition.
- The UI feels like a professional Mac utility rather than a crowded AI dashboard.

### 16. Primary project risks

- Confusing transcription engines with language models for cleanup.
- Trusting benchmark claims without measuring real meeting audio.
- Incorrect speaker boundaries or identifying speakers without consent.
- AI rewriting names, numbers and negative statements.
- Long-form processing that leaks RAM or shifts timestamps.
- Download or codec dependencies with unexamined redistributable licenses.
- Apple Intelligence not being available on every customer's Mac.
- Building too many modes and animations before the original transcript is dependable.

**My recommendation:** make Verbatim the first GreenLaunch utility you can genuinely rely on during your own client work. When it accurately processes a demanding meeting recording and lets you verify every quote quickly, the visual refinement and companion apps will be worth the investment.

### Primary source links

- FluidAudio official SDK: https://github.com/FluidInference/FluidAudio
- FluidAudio API: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md
- FluidAudio benchmarks: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
- FluidAudio diarization: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md
- Argmax OSS / WhisperKit / SpeakerKit: https://github.com/argmaxinc/argmax-oss-swift
- Argmax 2026 release and migrations: https://github.com/argmaxinc/argmax-oss-swift/discussions/470
- whisper.cpp: https://github.com/ggml-org/whisper.cpp
- Apple Foundation Models: https://developer.apple.com/documentation/FoundationModels
- Apple on-device model availability: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
- MLX Swift LM: https://github.com/ml-explore/mlx-swift-lm
- ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- MacWhisper local privacy: https://docs.macwhisper.com/article/52-keeping-transcriptions-private
- MacWhisper speakers: https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper
- yt-dlp licensing: https://github.com/yt-dlp/yt-dlp/blob/master/README.md
