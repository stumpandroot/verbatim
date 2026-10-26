# Specialty fields: word patch research

221 candidates, five proposed categories: 2 high, 33 medium, 186 low confidence. Public evidence names hard terms but rarely quotes the engine's actual output.

## Proposed categories and defaults

| Category | Count | Default | Reason |
|---|---|---|---|
| Medical | 47 | Off | Drug-name fixes are a safety issue. |
| Legal | 38 | Off | Context gates around ordinary words (lean, tortuous). |
| Bible and faith | 41 | Off; offer at onboarding | Spelling traditions differ; gates touch "Philippines" and "revelations." |
| Film production | 48 | On | Non-English codec and brand forms; gates need model names. |
| Business and marketing | 47 | On | Spaced acronyms and split brands; word-like acronyms (ARR, SOW, SKU) get `boost: false`. |

## Best sources

- [AssemblyAI on drug-name accuracy](https://assemblyai.com/blog/ai-transcription-accuracy-pharmaceutical-drug-names): quotes real outputs ("metforman," "a dalimumab," "bactarvy," "rezenquizumab"). It also explains why substitutions with another real drug, such as Humira to Humalog or Zantac to Xanax, can't be fixed by a word patch.
- [Quso on sermon captions](https://quso.ai/blog/sermon-captions-and-bible-reference-accuracy): Philippians to "Philippines," Titus to "tightest," Hosea to "hosier," and Jude to "you'd." It also names Habakkuk, Nebuchadnezzar, and Melchizedek as names that rarely survive transcription.
- [GMR Transcription on legal terms](https://www.gmrtranscription.com/blog/difficult-words-and-terms-in-legal-transcription) and [GoTranscript's legal glossary guide](https://gotranscript.com/en/blog/improve-dictation-accuracy-legal-terms-glossary-template): "have this corpus," "pro bonus," "affidate," and "12 B 6" for 12(b)(6).
- Clinician anecdotes ([SHM](https://blog.hospitalmedicine.org/hilarious-medical-transcription-snafus-my-faves-and-yours/), [MDedge](https://mdedge.com/content/dragons-funniest-progress-notes), [AAFP](https://aafp.org/news/blogs/freshperspectives/entry/20200113fp-ehrnotes.html)): forum-grade, and mostly real-English outputs.

## Patterns worth knowing

- **The safe fixes are non-words.** Engines usually swap a hard term for a real word ("an extremist" for in extremis, "minor cycling" for minocycline, "Philippines"). A word patch can't touch those without breaking ordinary sentences. What it can fix: casing (brand drugs, Bible books, ARRI, TASCAM), split coinages ("zep bound," "sky rizi"), spaced letters, and well-known misspellings (prima fascia, HIPPA, spoilation, galations).
- **Context gates need adjacent words:** "writ of have this corpus" won't match "writ."
- **Spaced-letter acronyms** follow the existing "k p i" pattern; they also fire when someone spells aloud.

## Where to look each month

- Medical-mode ASR vendor blogs and benchmarks (AssemblyAI, Deepgram, Appen MedTerm-90).
- FDA brand approvals and the [ISMP confused drug names list](https://online.ecri.org/hubfs/ISMP/Resources/ISMP_ConfusedDrugNames.pdf); GLP-1 names are the model case.
- Sermon-captioning vendors (Quso, Pulpit AI) and Logos forums.
- Court-reporter study guides (RPR homophones) and eggcorn databases for legal word pairs.
- Camera and codec launches (RED, ARRI, Sony FX, Blackmagic) and Shopify or Webflow app-store leaders.

## Deliberately left out

- **Real-word errors:** Jude/"you'd," Job, "an extremist," "Homo Two" (home O2), "five a few" (5-FU), "pregnancy done," "minor cycling," "a picture" (Aputure), "gorgeous" without context, and "Celtics" (Celtx).
- **Drug-to-drug substitutions:** these need human review, not a patch.
- **Title VII:** "Title 7" is also the real U.S. Code agriculture title.
- **V-Log:** collides with "vlog."
- **VND:** collides with the Vietnamese dong currency code.
- **COGS, TAM, MoM, and lowercase "arr":** all ordinary words.
- **Bare "c stand":** collides with "what does C stand for." It's context-gated instead.
- **Valid variant spellings:** subpena, lavaliere, Shechinah, Melchisedech, pedobaptism, and "in banc."
- **Court names and "log footage":** engines already get them right.

## Merge notes

- HIPAA, COVID-19, per se, and bona fide are safe enough for a default-on general category.
- ProRes gets one extra heard form ("pro rez"), marked `existing: true`.
- "Blackmagic RAW" overlaps the existing Blackmagic context rule. Make sure the longer match wins.
- red.com could not be fetched directly. The KOMODO and V-RAPTOR casing comes from red.com URLs in search results.
