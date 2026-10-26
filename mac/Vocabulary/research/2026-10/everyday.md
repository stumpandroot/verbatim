# Everyday mix-ups: findings

`everyday.json` holds 80 items. 74 are safe to auto-fix in a fixed context, and 6 are suggestion-only. 16 are high confidence, 62 medium, and 2 low. Harper already has rules for 58 of them, and the `harper_rule` field names each one.

## Conventions in the JSON

- All patterns are case-insensitive. Each match is exactly the text to replace, with the context in lookarounds. Replace the match with `right` and copy the case of the first letter. Exceptions are noted in `rule` or `risk`: replace only "of", keep a suffix, or delete text.
- Every lookbehind has a bounded length, as ICU requires, and all patterns compile in JavaScript. `build_everyday.py` tests each one against positive and negative sentences. Over 3 MB of Gutenberg prose, the safe patterns produced one hit: Melville's "for awhile".
- High confidence means an ASR confusion table records the pair (to/too/two, an/and, and/in, here/hear, know/no, accept/except, a/the), or a vendor write-up names it (their/there/they're). Medium means a phonetic cause plus a documented usage error.

## Best sources

1. A sclite confusion-pair report for LibriSpeech test-other (Hugging Face `.dtl`). The top pairs are a⇄the, in⇄and, and an⇄and. It also records to⇄too⇄two, here⇄hear, accept→except, and know→no.
2. Microsoft's human-parity paper (arXiv 1610.05256), Table 10. On Switchboard, and⇄in, a→the, and was→is top both ASR and human errors.
3. Paul Brians, *Common Errors in English Usage*. Its full-text file covers nearly every homophone and eggcorn here.
4. Harper's `weir_rules/`, `phrase_set_corrections/`, and `default_config.json`, for rule names and default states.

## Notes for the merge

- **Enable existing Harper rules** instead of writing new ones: ModalOf, ThereOwn, TheirToThere, ThenThan, NounVerbConfusion, PiqueInterest, SneakPeekPreview, AllIntentsAndPurposes, OneAndTheSame, CaseInPoint, Everyday, EveryTime, APart, AWhile, WasAloud, PrincipleToPrincipalRoleNoun, and the Weir idiom rules. All are on in Harper's curated config. Auto-apply only where the Verbose pattern also matches; otherwise show them as suggestions.
- **Harper rules that misfire on dictation:**
  - SupposedTo flags "I suppose to some degree."
  - The closed-compound rules `Everyone` and `Everybody` flag "every one of them" and "every body part." Don't auto-apply them.
  - AnA can turn a misheard "an" (meant as "and") into "a." Run `an (for and)` before Harper.
- **Missing commas are the main risk.** Dictation drops them, so phrases like "once more then stop" stay suggestion-only.

## Where to look each month

- Harper's `weir_rules/` and `phrase_set_corrections/mod.rs`, where new eggcorn rules land.
- Hugging Face sclite `.dtl` or `.prf` uploads (search "CONFUSION PAIRS"), and ASR error-analysis papers on arXiv.
- whisper.cpp and openai/whisper issues about numbers, currency, or the normalizer.
- r/MacOS and r/iphone threads on dictation homophones (anecdotal).

## Left out on purpose

- **a/the, in/and, was/is.** These are the most frequent ASR substitutions, but no context makes a fix safe.
- **"could care less," "hone in," "alright," "anymore."** These are contested usage, not errors.
- **"accept for," "in principal," "we where."** Valid readings are common ("accept for review," "$500 in principal").
- **"alot," "noone," "in tact."** Fixed-vocabulary engines rarely output these, and Harper already covers them.
- **Spelled-out numbers, "percent" versus "%," and "3 30 pm."** These are inverse text normalization, which belongs in a formatting setting. Only the ordinal-suffix fix and the redundant "$5 dollars" are included.
- **Rare eggcorns** ("doggy dog world," "taken for granite," "tow the line," and others). They are safe but seldom dictated, so they were cut to stay at 80 items.
