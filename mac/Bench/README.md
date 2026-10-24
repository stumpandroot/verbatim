# Verbatim bench

The bench measures accuracy and latency of the dictation pipeline on a fixed set of clips, so you can compare model, VAD, Dictionary, and cleanup changes from one build to the next. Every CI build runs it and publishes `bench-<run>.json` and `bench-<run>.md` to the `ci-screens` branch, next to `screens-<run>.zip`.

## What runs

Verbatim has a bench mode (`mac/Verbatim/App/Bench.swift`). Launched with `-bench <folder>`, it skips the microphone and the hotkey and sends each WAV in the folder through the same calls dictation makes:

1. **Loudness gate.** A replica of dictation's check: clips under 0.4 s, or whose loudest 10% averages below 0.05 on the Recorder's level scale, never reach the models. The bench still runs the models on them, to measure what they'd invent.
2. **Engine.** `transcribe(url:model:)` on the engine for each model (the plain call, used for files and for dictation without a Dictionary).
3. **Boosted engine.** `FluidEngine.transcribeBoosted(url:model:terms:)` with the whole Dictionary, which is dictation's call when the Dictionary has words and **Boost Dictionary words** is on (the default).
4. **Dictionary.** `DictionaryApplier.apply` on the boosted transcript. Together with the gate, this is the *pasted* text: what dictation hands to cleanup.
5. **Cleanup.** `FlowCleanup.run` at each level: `none` (literal, still converts "new line" and "new paragraph"), `light`, and `medium`. Email clips use the Email category and Formal style; the rest use Other and Casual, which are the FlowSettings defaults. No app context is sent. Without Apple Intelligence (CI runners), `light` and `medium` are recorded as `unavailable`.

Each model loads first (download on first run, Core ML compile, and one throwaway transcription), so per-clip times are warm.

## Launch it

On your Mac, after building Verbatim:

```bash
bash mac/Bench/make-clips.sh /tmp/verbatim-clips
open -W -n --env VERBATIM_UITEST=1 /path/to/Verbatim.app --args \
  -bench /tmp/verbatim-clips -benchOut /tmp/bench.json -benchModels v3,ultra,v2
```

`VERBATIM_UITEST=1` is optional. It keeps the run off iCloud and away from your thought pad and Activity files, and skips the welcome screens; bench mode turns off the UI tour that variable normally starts. Without it, the bench uses your normal profile but never adds transcripts or changes settings.

| Argument | Default | Meaning |
|---|---|---|
| `-bench <folder>` | (required) | Folder of clips. Turns on bench mode. |
| `-benchOut <file.json>` | `<folder>/bench.json` | Report path. The Markdown summary is written next to it with an `.md` extension. |
| `-benchModels a,b` | `v3,ultra,v2` | Model ids from `Engines.options` in `Engine.swift`. `v3` means `fluid/v3`; `whisper/base` also works. Unknown ids are listed as skipped. |
| `-benchCleanup a,b` | `none,light,medium` | Cleanup levels to run. |
| `-benchBoost 0` | on | Skips `transcribeBoosted`; the pasted text then comes from the plain engine call. |
| `-benchDownload 0` | downloads allowed | Runs only Parakeet models already on disk. |
| `-benchMinutes n` | 20 | Overall cap. Near the cap the bench stops starting clips; at the cap it writes what it has with status `timeout` and quits. |
| `-benchClipTimeout s` | 90 | Per transcription. Three failed clips in a row end that model's run. |
| `-benchLoadTimeout s` | 600 | Per model load, including the download. |
| `-benchLabel text` | none | Shown at the top of the report, such as "build 412 (abc1234)". |

The app quits when it finishes. Progress lines start with `BENCH` in `~/Library/Logs/Verbatim/native.log`.

## Add your own clips

Real dictations catch problems that synthetic speech doesn't. Keep them out of the repo.

1. Make a folder anywhere on your Mac, for example `~/VerbatimBench`.
2. For each clip, add `<id>.wav` and `<id>.txt`. The `.txt` holds exactly what you said, in normal writing (numbers, punctuation, and casing as you'd type them). Any sample rate works; Verbatim converts it.
3. Optional: add `<id>.terms` with one Dictionary word per line that the clip contains, to measure name recall.
4. Optional: add `dictionary.txt` with one entry per line, `Preferred` or `Preferred | heard as, another heard as`. Every term from `.terms` files is added automatically.
5. Run the bench with `-bench ~/VerbatimBench`.

Clips without a `clips.json` entry get the category `private`. To set categories, expected cleanup output, and checks, copy `mac/Bench/clips.json` into the folder and list your clips there. Mixing your clips with the synthetic set also works: generate the synthetic clips into the same folder, then add yours.

Recordings of other people need their consent. Keep the folder out of iCloud if it holds client audio.

## The synthetic set

`clips.json` defines 45 clips in 10 categories: short commands, emails, names and jargon from a fake Dictionary, numbers, dates, and money, negations, self-corrections, spoken punctuation, a long monologue (about a minute), silence (3 s of silence, and speech after 1 s of silence), and noise (white noise at 10 dB SNR, a second voice at 8 dB, and speech 24 dB quieter). `make-clips.sh` speaks them with macOS `say` (Samantha, plus Daniel or another English voice for some clips) at 16 kHz mono and mixes the silence and noise variants in Python with a fixed seed. No sox or ffmpeg is needed. The same macOS version gives the same audio, so changes in the numbers come from Verbatim, not the clips. A new macOS version or voice can shift them, and the report lists the voices used.

Fields in `clips.json`:

| Field | Meaning |
|---|---|
| `text` | Reference for the transcript: what is spoken, in normal writing. |
| `expected` | The ideal pasted text after cleanup, such as the self-correction resolved or spoken punctuation applied. Defaults to `text`. |
| `terms` | Dictionary words spoken in the clip, for name recall. |
| `cleanupMustContain`, `cleanupMustNotContain` | Words checked in `light` and `medium` cleanup output, such as "wednesday" but not "tuesday". |
| `voice` | `secondary` uses the second voice. |
| `gen` | How to make the audio: `silence`, `lead-silence`, `white-noise` (`snrDb`), `babble` (`snrDb`, `babbleText`), or `quiet` (`gainDb`). |
| `dictionary` (top level) | The Dictionary installed for every clip, including two distractor terms that are never spoken, so false insertions show up. |

## Metrics

All text metrics compare normalized words. The normalizer is modeled on Whisper's English normalizer and the Open ASR Leaderboard normalizer in FluidAudio's CLI (`TextNormalizer.swift`, Apache 2.0), cut down for dictation. It lowercases; removes punctuation (except decimal points) and fillers (um, uh, hmm, mm, mhm, er); expands contractions (`don't` → `do not`) and Mr, Mrs, and Dr; turns number words into digits (`twenty five` → `25`, `third` → `3`, `twelve thousand` → `12000`, `twenty twenty six` → `2026`); turns money into `<amount> dollars` (`$1,250.75` and "one thousand two hundred fifty dollars and seventy five cents" both become `1250.75 dollars`); turns `%` into `percent` and `&` into `and`; and treats `3:00` as `3`, `p.m.` as `pm`, and `ok` as `okay`. It has no British-to-American spelling map and doesn't join spoken digit strings ("seven one seven" stays `7 1 7`). The exact list is in the report under `settings.normalizer`.

| Metric | Meaning |
|---|---|
| WER | (substitutions + deletions + insertions) ÷ reference words, summed over the clips in the group (not an average of per-clip rates). Lower is better. Can exceed 100% when the output adds words. |
| WER engine, boosted, pasted | WER of the plain engine call, of the boosted call, and of the pasted text (boosted plus Dictionary, after the gate), all against `text`. |
| WER vs expected | WER of cleanup output against `expected`. At level `none`, self-corrections and spoken punctuation count against it, by design. |
| Names | Share of the clip's `terms` found in the output, case-insensitive, as whole words. `nameRecallDictationCased` in the JSON requires the exact spelling and casing ("Stump & Root", not "Stump and Root"). |
| Negation kept | Share of clips whose reference has a negation (not, no, never, nobody, nothing, none, neither, nor, nowhere, including `n't`) where the output has at least as many. A drop means the meaning flipped. |
| Numbers kept | Share of clips whose reference has numbers where every number appears in the output. |
| False activations | On silence-only clips (empty `text`): engine / pasted. The engine number shows what the model invents in silence; the pasted number shows whether the gate stops it. |
| Vocabulary false insertions | Dictionary terms in the output that aren't in the reference, such as a distractor brand appearing in ordinary speech. In the JSON per clip and per group. |
| Checks passed | Share of cleaned clips that pass their must-contain and must-not-contain checks. |
| Load s | First transcription after switching models: download (first run only), Core ML compile, and inference. |
| Median ms, p90 ms | Pasted path per clip: transcription plus Dictionary, model warm. Cleanup times are separate. |
| RTFx | Audio seconds ÷ plain-engine seconds. 100 means a 10-second clip takes 0.1 s. |

## Read the report

`bench-<run>.md` opens with the build, the machine (including whether it's a virtual machine), and whether cleanup was available. Then:

- **Models:** one row per model. Compare WER pasted, Names, and Negation kept for accuracy, and Median ms for speed. A row with status `failed` or `skipped` says why.
- **Cleanup:** per model and level, the outcomes (`literal`, `cleaned`, `unchanged`, `fallback` when a guard kept the raw words, `unavailable`, `gated`, `error`), WER against the expected text, and the checks.
- **By category:** where a model struggles, such as names or numbers.
- **Hardest clips:** the five worst clips by pasted WER, with the reference and what was pasted.

`bench-<run>.json` has everything per clip: raw text from each step, the normalized words, edit counts, timings, gate result, and Dictionary fixes. To compare two builds, download both JSON files from `ci-screens` and compare `models[].overall` and `models[].categories`.

Caveats:

- GitHub's macOS runners are virtual machines (the report says so under Machine), and FluidAudio's docs say VMs and CI runners have no Neural Engine. Treat CI latency as a build-to-build comparison on the same runner type, not as real-Mac speed. Run locally for real speed numbers.
- Synthetic voices are clean and evenly paced. Low WER here doesn't mean low WER on your voice, which is why the private-clip folder exists.
- A model that times out while loading may finish loading in the background and interfere with the next model's first clips. If a row looks odd after a load timeout, rerun that model alone.

The bench's other files are in the `bench-diagnostics-<run>` artifact on the workflow run, kept for 7 days, not on `ci-screens`: `bench-clips-<run>.log` (clip generation), `bench-voices-<run>.txt` (installed voices), `bench-native-<run>.log` (the app's log during the bench), `bench-open-<run>.txt`, and `bench-crash-<run>.ips` if the app crashed. A crash also shows as a warning in the job log.
