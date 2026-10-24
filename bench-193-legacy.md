# Verbatim bench: build 193 boost=legacy

- **Status:** done · started 2026-10-24T14:53:19Z · finished 2026-10-24T14:54:56Z
- **App:** Verbatim 0.0.0 (193)
- **Machine:** VirtualMac2,1 · Apple M1 (Virtual) · arm64 · 7.0 GB · Version 26.6.2 (Build 25G83) · virtual machine (speeds aren't representative of a real Mac)
- **Cleanup (Apple Intelligence):** unavailable, so only the literal level ran
- **Clips:** 45 · Dictionary: 12 terms · voices: primary Samantha, secondary Daniel

## Models

| Model | Status | Load s | WER engine | WER boosted | WER pasted | Names engine → pasted | Negation kept | Numbers kept | False activations | Median ms | p90 ms | RTFx |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| Parakeet TDT v3 | ok | 2.3 | 3.0% | 2.5% | 2.0% | 30.8% → 69.2% | 100.0% | 100.0% | 0 / 0 of 1 | 687 | 1207 | 9 |
| Parakeet TDT v2 | ok | 1.5 | 2.7% | 2.0% | 1.4% | 30.8% → 69.2% | 100.0% | 91.7% | 0 / 0 of 1 | 456 | 601 | 17 |

WER is normalized (case, punctuation, number format, and contractions ignored). *Pasted* is the text dictation hands to cleanup: the boosted transcript with Dictionary replacements, after the loudness gate. False activations are engine / pasted text on silence-only clips. Latency is the pasted path (transcription plus Dictionary) per clip, model already loaded.

## Cleanup

| Model | Level | Outcomes | WER vs expected | Checks passed | Negation kept | Numbers kept | Median ms |
|---|---|---|--:|--:|--:|--:|--:|
| Parakeet TDT v3 | none | gated 1, literal 44 | 5.0% | – | 100.0% | 100.0% | 1 |
| Parakeet TDT v2 | none | gated 1, literal 44 | 4.5% | – | 100.0% | 91.7% | 0 |

WER here is against each clip's *expected* text (self-corrections resolved, spoken punctuation applied). Checks are the clip's must-contain and must-not-contain words.

## By category: Parakeet TDT v3

| Category | Clips | WER engine | WER pasted | Names | Median ms |
|---|--:|--:|--:|--:|--:|
| command | 6 | 9.1% | 9.1% | – | 394 |
| email | 5 | 1.0% | 1.0% | – | 605 |
| long | 1 | 0.0% | 0.0% | – | 3266 |
| names | 8 | 10.8% | 3.6% | 81.8% | 725 |
| negation | 5 | 0.0% | 0.0% | – | 1032 |
| noise | 3 | 10.3% | 10.3% | 0.0% | 615 |
| numbers | 6 | 0.0% | 0.0% | – | 929 |
| punctuation | 4 | 6.2% | 6.2% | – | 687 |
| self-correction | 5 | 2.7% | 2.7% | – | 831 |
| silence | 2 | 0.0% | 0.0% | – | 471 |

Hardest clips:

| Clip | WER | Reference | Pasted |
|---|--:|---|---|
| cmd-04 | 100.0% | Thanks! | Thanks, said |
| noise-02 | 30.0% | The Lapp Wagons proofs are ready for review in Lititz. | The lap wagon's proofs are ready for review and litigation. |
| names-02 | 18.2% | Lapp Wagons wants a new catalog shoot before the spring show. | Lapwagons wants a new catalog shoot before the spring show. |
| punct-04 | 16.7% | Great news exclamation point new paragraph The launch is on track period | Great news exclamation point new paragraph The launches on track period. |
| fix-04 | 12.5% | The budget is ten thousand, scratch that, twelve thousand dollars. | The budget is $10,000, scratch that, $12,000. |

## By category: Parakeet TDT v2

| Category | Clips | WER engine | WER pasted | Names | Median ms |
|---|--:|--:|--:|--:|--:|
| command | 6 | 0.0% | 0.0% | – | 413 |
| email | 5 | 0.0% | 0.0% | – | 538 |
| long | 1 | 0.0% | 0.0% | – | 2126 |
| names | 8 | 10.8% | 2.4% | 81.8% | 529 |
| negation | 5 | 0.0% | 0.0% | – | 431 |
| noise | 3 | 10.3% | 10.3% | 0.0% | 410 |
| numbers | 6 | 3.8% | 3.8% | – | 495 |
| punctuation | 4 | 0.0% | 0.0% | – | 388 |
| self-correction | 5 | 2.7% | 2.7% | – | 421 |
| silence | 2 | 0.0% | 0.0% | – | 452 |

Hardest clips:

| Clip | WER | Reference | Pasted |
|---|--:|---|---|
| noise-02 | 30.0% | The Lapp Wagons proofs are ready for review in Lititz. | The lack weapons proofs are ready for review in Lydia. |
| num-02 | 20.0% | Let's meet on March 3rd at 3:30 PM. | Let's meet on March 3 at 3.30 p.m. |
| fix-04 | 12.5% | The budget is ten thousand, scratch that, twelve thousand dollars. | The budget is $10,000, scratch that, $12,000. |
| names-01 | 9.1% | We're driving to Lititz on Saturday for the craft fair. | We're driving to Liditz on Saturday for the craft fair. |
| names-07 | 8.3% | Castwell is shipping the welcome kits for Stump & Root next week. | Castwool is shipping the welcome kits for Stump & Root next week. |
