# Names and places

## What the evidence shows

- Names are the hardest thing for speech engines to get right. On the Earnings-21 benchmark, person names had 42–52% word error rate on every commercial engine, against 11–18% overall. Organization names ran 31–44% ([Earnings-21](https://arxiv.org/abs/2104.11348)). The authors blame lexical diversity and language-model sparsity.
- Whisper misspells names even with a full list in the prompt; OpenAI recommends post-processing ([OpenAI cookbook](https://developers.openai.com/cookbook/examples/whisper_correct_misspelling)).
- Apple dictation favors Contacts names, and that cuts both ways. It mangles names that aren't in Contacts ("Teagle Hall" became "Thiago"), but a contact surname can also take over a common word ("ride" became "Ryd") ([TidBITS](https://tidbits.com/2026/05/15/tipbits-how-fake-contacts-can-fix-dictations-proper-noun-problems/)). Siri turned "Bothell" into "Bath Cell" and "Bodwell" ([iMore forum anecdote](https://forums.imore.com/threads/how-can-i-get-siri-to-understand-the-name-of-my-home-town.319326/)).
- No published list of specific misheard names exists, so most candidates rest on a non-phonetic spelling plus documented human misspelling, which Whisper absorbs from web text. Only 2 of 119 are rated high.

## Names with several spellings: don't auto-fix

Examples: Caitlin, Kaitlyn, Katelyn, Caitlyn; Jon, John; Sean, Shawn, Shaun; Steven, Stephen; Sara, Sarah; Megan, Meghan; Kristen, Kristin, Kirsten; Aidan, Aiden; Geoffrey, Jeffrey; Brian, Bryan; Allison, Alison, Allyson; Madeline, Madeleine, Madelyn; Zoe, Zoey, Zoë; Katherine, Catherine, Kathryn; Rachel, Rachael; Mackenzie, McKenzie; Erin, Aaron.

Recommendations:

1. Ship a variant-group table, but use it only to match names. It never replaces anything on its own.
2. Contacts: when the engine outputs a member of a group, such as "Shawn", and the user has exactly one contact in that group ("Sean"), use the contact's spelling. If both a Jon and a John are in Contacts, leave the output alone.
3. Apply a contact spelling only to a token that is already a name variant. Never apply it to an ordinary word, which avoids Apple's "ride" → "Ryd" failure.
4. Edits: after the same correction twice, offer to save it to the Dictionary. Wispr Flow skips very common names when it auto-learns ([Wispr docs](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary)); Verbose can learn them, scoped to the group.
5. When context is ambiguous, show a quiet suggestion such as "Sean?" instead of replacing the word.

## Patterns and decisions for the merger

- Context words keep real look-alikes safe: Pittsburg (Kansas), Strasbourg, Mannheim, chicken Kiev, Roy Lichtenstein, Columbia University, and "a bird in hand".
- NVIDIA: NVIDIA's brand guidelines say "Always write NVIDIA in all caps" ([NVIDIA guidelines](https://www.nvidia.com/content/dam/en-zz/Solutions/about-us/NVIDIA-Partner-Network-Brand-Guidelines-May-2020.pdf)). The existing term outputs AP-style "Nvidia", so you need to choose between the two. The existing heard form "envidia" is the Spanish word for "envy", so remove it.
- Accented outputs (Reykjavík, Côte d'Ivoire, Häagen-Dazs) fix only misspellings; plain "Reykjavik" is left alone.
- Style choices are flagged (Kyiv, Kharkiv, Lviv, Zelenskyy). Old spellings are context-only.
- FluidAudio's docs misspell the canonical as "Hagen-Dazs"; don't copy spellings from engine docs.

## Where to look each month

- New executives and places in the news; AP Stylebook updates.
- Wispr Flow, Superwhisper, and FluidAudio docs, plus the OpenAI forum and whisper.cpp issues.
- Google Trends "how to spell" stories, for example Chihuahua topping three states ([Mental Floss](https://www.mentalfloss.com/language/spelling/most-misspelled-word-every-state)).

## Deliberately left out

- Wooster, Milwaukie, Lewisville, Edinboro, Edinburg, Andora (Italy), and Ephratah: all real places.
- Leicester ("Lester") and Cheyenne ("Cheyanne"): their misspellings are ordinary names.
- Türkiye, Czechia, Bengaluru, São Paulo, and Marrakech: both spellings are acceptable or it's a style debate.
- "lit its", "show me", "hugging phase", and "school kill" as heard forms: all ordinary English. "school kill" is context-only.
- Split pinyin such as "Hua Wei", "Xiao Mi", and "Shen Zhen", which can be personal names.
- Chipotle: "chipolte" covers both pepper and brand, so there's no safe output casing.
