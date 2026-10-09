## v9 brand messaging and copy update

- The core headline now says **Turn videos into searchable text**, so first-time visitors immediately understand the product.
- The primary action is **Get transcript**, because the app checks existing captions before attempting speech recognition.
- Updated feature cards, sample actions, processing wording, AI refinement, export language, and saved-library text to communicate clear user outcomes instead of vague promotional phrases.
- Kept the original transcript separate from AI edits and made the review warning explicit. No claims of perfect accuracy or universal video availability.
- Added `BRAND_MESSAGING_V1.md`, a working Verbatim-specific positioning and voice guide informed by the supplied marketing frameworks. Audience and promise remain **hypotheses until tested with real users**.
- Preserved the v8 assets, balanced three-tab iPhone nav, and no-scroll initial iPhone home screen. The demo is not a production transcription service.

---

## v7 mobile layout update

- iPhone bottom navigation now uses **three equal-width destinations** (Home, Library, Settings), without a floating center action.
- The iPhone home screen fits the headline, URL input, Paste / Get transcript buttons, platform options, and sample action inside the initial viewport. It intentionally hides secondary marketing content on smaller phones.
- Larger phones display three small shortcuts to sample transcript views. Reading long transcripts still requires scrolling.
- Supports reduced-motion preferences and virtual-keyboard access.
- The standalone interactive preview uses sample content; live transcription requires the backend.

# Verbatim v4 — interactive redesign

Verbatim v4 introduces a responsive, motion-rich design inspired by expressive editorial graphics: animated audio ribbons, warm paper surfaces, indigo/coral/lime accents, live processing feedback, and readable transcript tabs. It keeps the existing **15-platform caption-first transcription backend** from v3.

Open `verbatim-interactive-preview.html` from the download if you want to explore the **sample-only interactive design without installation**. The preview does not retrieve or process real video links.

The local server app in the `link-transcriber` folder retains real-video processing using FastAPI, yt-dlp, Faster Whisper, and optional AI cleanup (Ollama or OpenAI). The home screen also has **Try a sample** for evaluating the new visual design. The example transcript, summary, and review flags are intentionally fictional.

You can save a processed transcript from the results page to the optional **local browser library**. These saved copies remain in the browser’s localStorage until removed, independently of the server’s temporary jobs. Avoid saving sensitive transcripts on a shared device. A saved transcript that was not AI-refined previously cannot request a fresh AI edit unless the source video is reprocessed.

Live processing has not been verified end-to-end against all 15 video services here. Unsupported, login-restricted, or DRM-protected videos can still fail.

---

# Verbatim v3 — multi-platform video transcripts and notes

A local browser app that turns accessible video links from **15 platforms** into text. Supports TikTok, Instagram Reels, YouTube, Vimeo, Facebook videos/Reels, X / Twitter posts, Reddit videos, Twitch VODs/clips, Dailymotion, LinkedIn video posts, Loom, Streamable, Rumble, Pinterest video pins, and Bluesky video posts. Includes **unlisted Vimeo sharing links with the hash** when caption access is available.

1. **Original** — exact available subtitle cues, or local speech recognition when subtitle tracks are unavailable.
2. **Timestamps** — clickable lines that open the source video around that moment.
3. **Cleaned** — optional AI-assisted punctuation, paragraph grouping, and cautious correction of obvious transcription mistakes.
4. **Summary** — optional point-by-point summary with links back to source moments.
5. **Review flags** — ambiguous terms or names suggested for checking against the original; the source transcript never changes.

Copy any active view or export a TXT file. Export **SRT** or **VTT** from the *original* timestamped cues, not from AI-rewritten prose. A source badge identifies creator captions, platform-provided captions of uncertain provenance, automatic captions, or local AI speech recognition.

## Supported links and realistic limitations

| Platform | Example link type | Notes |
|---|---|---|
| YouTube | Watch URLs, Shorts, share links | Published subtitles when available |
| Vimeo | Video/share/player links | Attempts player caption configuration for unlisted hash links |
| TikTok | `tiktok.com/@name/video/<id>`, `vm.tiktok.com`, `vt.tiktok.com` | Can use embedded TikTok captions; often needs audio fallback |
| Instagram | Reel or video post | Login/rate limits can block access; video captions often unavailable |
| Facebook | Video, Reel, `fb.watch` or `watch?v=` | Public videos only if anonymously accessible |
| X / Twitter | Status/post containing video | Text-only posts cannot be transcribed |
| Reddit | Reddit post or `v.redd.it` | Some hosted videos have no audio |
| Twitch | Recorded video or clip | Live streams aren't supported |
| Dailymotion | Single video | Captions vary |
| LinkedIn | Post/update with accessible video | Sign-in restrictions may apply |
| Loom | Shared recording | Recording must be publicly accessible |
| Streamable | Single video | Often requires audio fallback |
| Rumble | Video/watch page | Captions vary |
| Pinterest | Single video pin or `pin.it` link | Image-only pins cannot be transcribed |
| Bluesky | Individual video post | Text/image-only posts cannot be transcribed |

**Supported links are not a guarantee of successful transcription.** Verbatim accepts direct single-video/post URLs from these hostnames and then relies on `yt-dlp` to retrieve metadata/captions or an accessible audio stream. Platform anti-bot measures, geographical rules, creator privacy choices, age restrictions, DRM, removed videos, and authentication can prevent access. The video owner does not need to be you, but you must have the appropriate rights or permission to process the material. Private or login-only content is **not bypassed**. Check [yt-dlp's live list of supported extractors](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md) for platform-specific changes.

## Quick start

Requirements: Python 3.10–3.12 (3.11 recommended), internet access, and FFmpeg. For audio fallback, install FFmpeg:

- macOS: `brew install ffmpeg`
- Windows: `winget install Gyan.FFmpeg`
- Ubuntu/Debian: `sudo apt install ffmpeg`

**macOS / Linux**

```bash
cd link-transcriber
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8000
```

**Windows PowerShell**

```powershell
cd link-transcriber
py -3.11 -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8000
```

Visit **http://127.0.0.1:8000**.

### How caption retrieval works

Verbatim checks for existing text tracks first:

1. For simple and unlisted Vimeo URLs, it tries the public player configuration with the video's sharing hash (`h=`), retrieving a published caption WebVTT track when accessible.
2. It checks `yt-dlp`'s available subtitle/caption tracks, including TikTok captions supplied directly in video metadata as SRT/JSON, preferring manual captions when provenance is available.
3. Only when those routes fail does it attempt to download the audio and transcribe it locally with **Faster Whisper**.

Existing captions are *not* independent proof of accuracy. They may also contain spelling and recognition errors. The first AI speech-transcription run downloads the default `base` Whisper model, then runs locally. Metadata, public captions, and downloaded audio can be inaccessible for private, DRM-protected, or restricted links. **A link that works in the Vimeo player or another caption service is not guaranteed to work here**; platform policies and response formats change.

### Optional AI editor (no paid API required)

You can view/download the **original** without any additional service. To enable the *Refine with AI* button locally:

1. Install [Ollama](https://ollama.com/) (a separate application).
2. Run `ollama pull qwen2.5:7b` to download the language model.
3. Start Ollama (`ollama serve` if not already running), then run Verbatim as above.
4. Transcribe a video and click **Clean & summarize**. This uses Ollama on your computer. The first refinement may be slow on systems with limited RAM.

The default is `AI_PROVIDER=ollama` and `OLLAMA_MODEL=qwen2.5:7b`. If you prefer a hosted service instead, set `AI_PROVIDER=openai` and `OPENAI_API_KEY=<your key>` (optionally `OPENAI_MODEL=gpt-4o-mini`) before running the server. **Using OpenAI sends the source transcript to OpenAI and may incur API charges.** Ollama does not require an external AI API key; initial model installation downloads model weights. The transcript does not leave your computer *for AI processing* when using local Ollama.

AI cleanup is a *separate, editable interpretation*, not an authenticated correction of what the speaker actually said. It may still incorrectly change words or fail to flag an ambiguity. Always verify essential quotes, names, numbers, and technical claims against the original recording. AI-generated time references are approximate and may be absent when not justified by the source.

## Other settings

| Variable | Default | Notes |
|---|---|---|
| `WHISPER_MODEL` | `base` | `small` or `medium` for more accurate but slower audio recognition. |
| `AI_PROVIDER` | `ollama` | `ollama`, `openai`, or `none` to disable refinement. |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Pull the same model in Ollama first. |
| `OPENAI_MODEL` | `gpt-4o-mini` | Used only with `AI_PROVIDER=openai`. |
| `MAX_VIDEO_SECONDS` | `7200` | Maximum video length in seconds. |
| `MAX_DOWNLOAD_MB` | `500` | Maximum audio download size. |

## Mac app (no Terminal after the first build)

`macapp/build_mac.sh` packages the server, the interface, FFmpeg, and the speech engine into a double-click `Verbatim.app`. Build it once on the Mac that will run it:

```bash
brew install python@3.11
cd link-transcriber
bash macapp/build_mac.sh
```

The script downloads static FFmpeg for your Mac's chip, makes the app icon, bundles everything with PyInstaller, and signs the result for this Mac. Output: `dist/Verbatim.app` (roughly 500–800 MB). Drag it to Applications. On the first launch, right-click the app and choose Open.

What the app does on launch:

- Starts the Verbatim server on a free local port and opens it in a native window.
- Uses the bundled FFmpeg, so nothing else needs installing.
- Downloads the Whisper `base` model (about 150 MB) into `~/Library/Application Support/Verbatim/models` the first time you transcribe audio.
- Turns on AI notes only when Ollama is running on this Mac. Install Ollama and run `ollama pull qwen2.5:7b` if you want them.

Sharing the app with other Macs needs Apple notarization (a paid developer account); without it, their Mac warns about an unidentified developer.

## Docker

```bash
docker build -t verbatim .
docker run --rm -p 127.0.0.1:8000:8000 verbatim
```

Docker includes FFmpeg and Whisper. For **local AI refinement** in Docker, Ollama is not included; connect the container to your running Ollama instance or use the OpenAI provider. The default local Ollama endpoint in this example is not automatically accessible from inside a Docker container, so follow your platform's host-networking configuration to run it there. If you do not need refinement, `AI_PROVIDER=none` is sufficient.

## Transcribe your own files

Tap **Or transcribe a recording or video file** on the home screen, or `POST /api/jobs/upload` with a multipart `file` field and an optional `language`. Accepted: MP3, M4A, WAV, AAC, FLAC, OGG, Opus, AIFF, CAF, MP4, MOV, M4V, WebM, MKV. Video containers need FFmpeg. The file is written to a temporary directory on the server, transcribed with Faster Whisper, and deleted when the job finishes. Nothing is fetched from the internet for an uploaded file. Size and duration follow `MAX_DOWNLOAD_MB` and `MAX_VIDEO_SECONDS`.

## API

- `POST /api/jobs/upload` multipart with `file` and optional `language`; transcribes a local recording.
- `GET /api/capabilities` reports the AI provider, whether FFmpeg is present, the Whisper model, and upload limits.
- `POST /api/jobs` with `{"url":"https://www.tiktok.com/@creator/video/<id>","language":"auto"}` or another supported single-video HTTPS URL.
- `GET /api/jobs/{job_id}` returns current progress, transcript segments, source provenance, and optional AI output.
- `POST /api/jobs/{job_id}/refine` begins optional AI editing after transcript completion.
- `GET /api/health` returns `{"ok":true}`.

Jobs and results are held in server memory up to two hours; audio is deleted from temporary storage after processing; no accounts or databases. The single local worker keeps CPU/RAM use manageable.

## Important limitations

- A video may have captions enabled in the browser while anonymous programmatic access is restricted. Videos requiring cookies, passwords, logins, or DRM cannot be guaranteed.
- Some captions have incorrect or missing timestamps, odd overlaps, auto-caption noise, or imperfect language identification. Titles are derived from platform metadata when available. Deep links to a specific timestamp are only offered for YouTube and Vimeo; other platforms show the timestamp as a reference and have a separate **Open original video** link.
- Unit tests cover URL validation and denial of other hosts/profiles, TikTok SRT/JSON captions supplied inline, approved subtitle hosts, mocked multi-platform audio fallback, Vimeo unlisted-hash handling, caption selection, and mocked AI refinement. **End-to-end live fetching from these services has not been verified in this restricted environment.**
- Do not expose this single-user local demo to the public Internet without authentication, strict rate limiting, hardened media URL handling, and resource caps. Only process video material you have permission or rights to use, and respect the source platform's terms.

## v5: iPhone-first visual update (October 2026)

The interface includes 14 brand PNG icons in `static/icons/`, a matching `static/app-icon.png`, the `static/v5.css` design system, and a CSS letter-by-letter animated logo with sound-wave pulses. Mobile UI uses labeled navigation, safe-area-aware spacing, a clipboard Paste button (subject to browser permission), clear platform feedback, and reduced-motion support. The transcript and caption-first backend API are unchanged. The demo HTML is a separate, offline, illustrative preview; it does not process live video.

See `UX_RESEARCH_2026.md` for competitor benchmarks, Apple HIG guidance, user frustrations, UX hypotheses, feature roadmap, and a proposed usability-test plan.

On iPhone, opening the web app requires the **backend running on an HTTPS-accessible or local-network-accessible host**. Adding the website to Home Screen does not turn the Python server into native device-side transcription. For production iOS, a hosted API/native shell or Share Extension is recommended.

## Verbatim v6: no emoji-based interface

- All visible UI pictograms are locally bundled SVG/PNG graphics rather than emoji or decorative text glyphs.
- Brand graphics retain the signature violet, coral, and lime waveform shapes, with sequential logo-letter bounce and subtle sound-bar motion.
- Twelve purpose-designed interface controls (arrows, add, check, favorite, review/cleanup, caption cue, and burst) are shipped both as vector SVG and high-resolution PNG in `static/icons/`.
- The responsive app is a web app designed for iPhone browser layouts; it is **not** a native App Store application.
- The separate HTML preview runs its sample flow offline, but it does not connect to the live transcription backend.

### Local platform brand marks (v8)

The app bundles 12 official-style brand SVG marks from Font Awesome Free, displayed offline on the home screen, in the platform chooser, and in saved library items. Credits and the applicable license are in `static/platform-icons/CREDITS.md`. Loom, Streamable, and Rumble use labeled placeholders rather than made-up logos.
