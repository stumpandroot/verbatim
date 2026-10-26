# Word patches

Verbose spells modern words right without any setup. Two files ship in both apps:

- `Verbatim/Resources/ModernVocabulary.json`: the built-in vocabulary (`Model/BuiltInVocabulary.swift`). Each term
  lists the ways speech engines write it. It runs after your Dictionary on every transcript and dictation.
- `Verbatim/Resources/EverydayFixes.json`: everyday mix-ups such as "could of been" (`Flow/EverydayFixes.swift`).
  They run on dictation only, right before Harper's grammar pass.

Settings › Built-in vocabulary turns both off. A word patch is a change to either file that ships in a normal
build: the gate and the self-test check it, and the version notes list it.

## Rules for what goes in

1. False positives cost more than misses. Never put an ordinary English word or phrase in `heard`. When the misheard
   form is also English, use `context` with context words in `after`, or leave the term out.
2. Every form passes the gate (below).
3. Use the official spelling from the brand's own site. Don't copy spellings from engine docs.
4. Medical, legal, and Bible and faith terms wait for their per-field switches in Settings (patch 2).
5. Fix an everyday mix-up only with a rule that's always right where it fires. Anything that depends on a comma the
   speaker didn't dictate stays out.
6. Don't auto-fix names with several spellings (Sean, Shawn; Caitlin, Kaitlyn).
7. Include a low-confidence term only when every `heard` form is clearly not English. Low-confidence terms get no
   `context` forms.

## The term schema

```json
{
  "term": "ChatGPT",
  "category": "AI",
  "heard": ["chat gpt"],
  "exact": ["Linked In"],
  "context": ["zoom"],
  "after": ["call", "meeting"],
  "boost": false
}
```

- `term`: the exact spelling to write. It's also the term's ID in Settings, so renaming a term turns it back on for
  anyone who turned it off.
- `category`: one of the categories in `CATEGORIES` in `mac/tools/vocab_check.py`. Settings shows it next to each
  term, so a new category must read well there.
- `heard`: replaced anywhere, in any case. Only forms that are never ordinary English.
- `exact`: replaced only when written with exactly this casing.
- `context`: ordinary English too, so replaced only next to a context word (the shared ones in
  `BuiltInVocabulary.beforeWords` and `.afterWords`, plus `after`) or when the engine capitalized it mid-sentence.
  List a form with a capital ("Kiev", "Disney plus", "I phone") when it starts with a name or a word that's always
  capitalized: then only a context word counts, because the capital says nothing.
- `after`: single words that mark the term when they come right after a `context` form.
- `boost`: `false` keeps the term out of recognition boosting.

Longer forms run first, so "iphone air" becomes "iPhone Air" before "iphone" is considered.

## Run the gate

```bash
bash mac/tools/test-vocabulary.sh
```

CI runs it with the other `mac/tools/test-*.sh` scripts on every push. It runs `mac/tools/vocab_check.py`, then
compiles the app's own `BuiltInVocabulary.swift` and `EverydayFixes.swift` and checks that they give the same
results as the gate on every case. The gate checks:

- **Schema:** the keys, the categories, and no research fields (`confidence`, `why`, `sources`, `risk`, `existing`).
- **Duplicates:** one entry per term, and no form under two terms.
- **Frequency:** no single-word `heard` or `exact` form is a common English word
  (`mac/tools/vocab-fixtures/common-words.txt`). The deliberate exceptions are in
  `mac/tools/vocab-fixtures/allowlist.txt`, each with its reason.
- **Context capitals:** a `context` form that starts with a name is listed with a capital.
- **Order:** every form fixes to exactly its own term, and no term's spelling changes. A shorter form inside a longer
  one for another term fails unless the longest-first order handles it.
- **Corpus:** nothing changes a line of `mac/tools/vocab-fixtures/negatives.txt`, a file of ordinary sentences,
  lists, and look-alike names.
- **Everyday fixes:** every pattern compiles, every `examples` pair becomes its fix, and every `keep` sentence stays.

Other options:

- `python3 mac/tools/vocab_check.py --fix "some text"` shows what the app makes of a sentence and which rule fired.
- `python3 mac/tools/vocab_check.py --phrases` lists `heard` phrases made only of common words, for a review by hand.
- `python3 mac/tools/vocab_check.py --corpus book1.txt book2.txt` reports every change on prose that uses the right
  words. Project Gutenberg books work well. Don't commit the corpus.
- `python3 mac/tools/vocab_check.py --build-common-words` rebuilds the common-words list. It needs
  `pip install wordfreq` and the en_US Hunspell dictionary (`HUNSPELL_DIC` sets its path).

## The monthly routine

1. Research new words, starting with the sources below. Write candidates with sources and a confidence rating to
   `mac/Vocabulary/research/YYYY-MM/`, in the format of `research/2026-10/`.
2. Merge the candidates that follow the rules into the two files, without the research fields, and raise `version`.
3. Run the gate and a corpus run. Add self-test checks for a sample of the new words to
   `Verbatim/Model/VocabularySelfTest.swift`, which the Mac and iPhone UI self-tests run in the full build.
4. Add a version note to the `next` entry in `mac/ReleaseNotes/ReleaseNotes.json`.
5. Open a branch for Tim to approve. Nothing ships without his approval.

Where to look each month:

- **AI and apps:** release timelines (OpenAI, Google, Anthropic, and Meta), Apple newsroom feature names after each
  event, and misspelling roundups built on search data (Ahrefs, Search Console).
- **Dictation tools:** Wispr Flow, Superwhisper, MacWhisper, and FluidAudio docs and changelogs, and whisper.cpp and
  openai/whisper issues.
- **Words and usage:** Cambridge Dictionary and Merriam-Webster new-word announcements, Harper's `weir_rules/` and
  `phrase_set_corrections` for new mix-up rules, and confusion-pair reports on Hugging Face (search
  "CONFUSION PAIRS").
- **Specialty fields:** FDA brand approvals and the ISMP confused-drug-names list, medical ASR vendor benchmarks
  (AssemblyAI, Deepgram), sermon-captioning vendors and Logos forums, court-reporter study guides, and camera and
  codec launches.
- **Names and places:** new public figures in the news, AP Stylebook updates, and Google Trends spelling stories.

## Patch history

| Patch | Vocabulary | Contents |
|---|---|---|
| 1 (October 2026) | Version 2, 824 terms | New names, names and places, film and video, business, four general terms (HIPAA, COVID-19, per se, bona fide), and 72 everyday fixes. The research is in `research/2026-10/`. |
