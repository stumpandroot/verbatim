# New names: research notes

## What you'll find

`new-names.json` holds 147 candidates: 136 new terms plus 11 entries that add heard forms to existing terms (`"existing": true`). By confidence: 1 high, 83 medium, 63 low. Finance is a new category.

- **AI:** Qwen, Nano Banana, Veo 3, Gemini CLI, Codex, gpt-oss, o4-mini, ChatGPT Atlas, Meta AI, Llama 4, HeyGen, Synthesia, Suno, OpenRouter, LangGraph, LlamaIndex, n8n, whisper.cpp, llama.cpp, MLX, Core ML, Copilot+ PC, and Alexa+.
- **Apple:** Genmoji, SpeechAnalyzer, iPhone Air, iPhone 16e, plus developer frameworks (SwiftData, StoreKit, HealthKit, CloudKit, WidgetKit, ARKit, RealityKit) and RevenueCat. Check for overlap with a developer-terms area.
- **Creator tools:** vidIQ, TubeBuddy, OpusClip, Insta360, Sony FX3, Osmo Pocket, Pixelmator, Filmora, Streamlabs, Buzzsprout, and MrBeast.
- **Finance:** Klarna, Afterpay, Coinbase, Kalshi, Polymarket, and USDC.
- **Slang and abbreviations:** POV, IYKYK, TL;DR, ELI5, GRWM, FYP, delulu, skibidi, tradwife, and rizz.

## Evidence

Published misrecognition evidence for individual brand names is thin. Dictation-app docs use placeholder examples. Two sources hold up:

1. [Fello AI's misspelled AI names](https://felloai.com/misspelled-ai-names/) gives Ahrefs search volumes, dated October 2026. For example, "chatgbt" and "chat gbt" each get 1M+ US searches a month, and "gemeni" gets 100K+. These are typing errors, but Whisper learned from web text. Most existing-term additions come from here.
2. The [superwhisper-trainer README](https://github.com/verygoodplugins/superwhisper-trainer) records "cloud code" and "clawed code" for Claude Code. That's the only documented speech-engine error in this set, and the file already has both.

Other ratings rest on the name's structure (camel case, digits, plus signs, Pinyin, a missing letter), checked against the brand's site. Cambridge and Merriam-Webster settle the slang spellings. I checked cited URLs with curl; GitHub, openai.com, and microsoft.com returned 403 to the proxy but exist.

## Patterns for monthly patches

- **Plus-sign and digit names** (Disney+, Alexa+, Copilot+ PC, Insta360, Lemon8, n8n) never come out right from any engine, so they're reliable wins.
- **Camel-case coinages split into two ordinary words.** When the split form is ordinary English (health kit, only fans, robin hood, letterboxed, red note, be real), heard holds the closed-up form only and the spaced form goes in context.
- **Where to look each month:**
  - Ahrefs and Search Console misspelling roundups like Fello's.
  - OpenAI and Google release timelines.
  - Apple newsroom feature names after each event.
  - Cambridge Dictionary and Merriam-Webster "new words" announcements (August and September).
  - Dictation-app changelogs.

## Left out on purpose

- **Ordinary-word brands:** Lovable, Kit (the renamed ConvertKit), Comet, Flux, Ideogram, Skool (speech engines output "school"), Kick, Chime, Wise, Mercury, and Image Playground.
- **Name and word clashes:** Gemma, LoRA ("Laura", LoRa radio), and bare "claud", "grok", "Kofi", "Teemu", and "hey gen" ("hey Gen Z") in heard.
- **Apple TV+:** renamed to Apple TV in October 2025.
- **Slang written in ordinary words:** brain rot, rage bait, aura farming, and 6-7.
- **OpenAI model names after June 2026** (the GPT-5.6 and GPT-6 entries in one timeline): I couldn't verify them.

## Notes for merging

- **Overlap order:** "iphone air" overlaps the existing iPhone rule, and "gen alpha" sits next to Gen Z. Make sure the longest match wins.
- **List risk:** Disney+ and Paramount+ use plain "disney plus" and "paramount plus" in heard. That mis-corrects a list like "Disney plus Universal", so demote them to context if you want zero risk.
- **Crumbl:** context-only, and the risk is real ("apple crumble cookies"). Consider dropping it.
- **Manychat:** casing needs a final check against the brand's site.
