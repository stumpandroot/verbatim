# Verbatim design rules

This file is the brand spec for every Verbatim surface: the Mac app, the iPhone app, the keyboard, the dictation bar, the menu bar, widgets and Live Activities, the app icon, and the website. Agents read it before changing any UI. If something you need isn't here, ask; don't invent a color, a typeface, an icon, a material, or a radius.

Sources: the family design system (project doc `01-design-system.md`, v2.1), the brand marks decision (`brand/README.md`, October 18, 2026), the interface icon set (October 18, 2026), and Tim's Home review (October 22, 2026). `mac/tools/brand-check.sh` enforces the rules marked **[checked]**.

## 1. Color

The palette lives in `mac/Verbatim/Views/Tokens.swift` (`Ink`). Use tokens only. **[checked]** No hex values outside `Tokens.swift`, and no `Color.red`, `.blue`, `.orange`, `.green`, `.gray`, `.purple`, `.pink`, `.yellow`, or `.accentColor` outside it. Errors and destructive actions use `Ink.danger` (defined in Tokens.swift), with an icon and a word, never persimmon.

| Token | Hex (light) | Means | Use it for |
|---|---|---|---|
| `paper` | `#F5F0E6` | The page | App background |
| `reader` / `card` | `#FFFDF9` | Content you read | Transcript sheet, neutral cards, rows |
| `ink` | `#26352E` | Structure | Text, strokes, primary buttons (`interactive`) |
| `persimmon` | `#FA6B47` | **Record** | Record panel, voice-note chips, recording state, the app icon |
| `butter` | `#F4C76B` | **Dictate** | Dictate tile, dictations panel, today's bar in This week (it counts dictated words) |
| `sage` | `#AFC398` | **Import** (files and links) | Import tile, imported-file and link chips |
| `petal` | `#EFB6C8` | **App audio** | App audio tile, app-audio chips |
| ink outline on `card` | — | **Live captions** | Live captions tile and its chips |

Neutral (`ink` at 6% with `dim` text, plus the item's own diagram or initials): kinds (journal, idea, meeting, note), tags, speakers, projects, filters, and counts. They never borrow an action hue.

Reading washes are a separate role and appear only on the transcript and document surfaces, never beside the action tiles: saved = `saved` (butter), playing = `playing` (sage), search match = `match` (persimmon).

Rules:

1. One color, one meaning. Never reuse a hue for a different action on the same screen. Tags, filters, and counts are neutral (`ink` at 6% with `dim` text).
2. About 70% neutral, 20% ink, 10% accent on working screens. Home and onboarding may run richer.
3. One saturated fill per screen: persimmon, for the primary action. The pastel start tiles on Home (butter, sage, petal) are allowed because each one is a different action; everything else is a tint or neutral.
4. Text on paper uses `ink`, `dim`, `mute`, or a text-safe variant (`accentText`, `sageText`), never a bright fill.
5. Text on every fill is ink: petal 7.5:1, butter 8.1:1, sage 6.8:1, persimmon 4.45:1 (so on persimmon, ink text must be 18 pt or larger, or semibold 14 pt or larger). Never put reader white text on persimmon; it measures 2.8:1.
6. Status never depends on color alone; pair it with a word or an icon.
7. Dark mode is a near-black green, never an inversion.

## 2. Type

| Role | Font | Where |
|---|---|---|
| Display | `Ink.serif` (New York stands in for Instrument Serif) | Greeting, Record, section titles, document titles, big numbers |
| UI and body | SF Pro, Dynamic Type | Everything else: tile names, labels, rows, buttons, transcript text |
| Data | `Ink.mono` | **Only** keyboard shortcuts, timecodes inside transcripts and players, running recording timers, file paths, and tabular indexes ("01") |

Rules:

1. Sentence case everywhere. No uppercase tracked labels except `Overline`, at most one per screen.
2. Metadata is sans, not mono: "Voice note · 7:50 · Today". Use `.monospacedDigit()` for numbers that change.
3. Shortcuts render as keycaps: mono inside an outlined capsule.
4. Never set reading text in the serif.
5. Tile and button names: SF Pro semibold, 15 pt on Mac.

## 3. Icons

- **Ours (`BrandArt`) for anything that means something in Verbatim:** record, dictate, import, link, app audio, captions, library, moments, bookmark, play, export, summaries, speakers, language, voice, search inside a transcript, empty states, and all navigation. Fine line: a 24-unit grid with a 1.5 stroke, or a 112-unit box with a 6 stroke. Round caps and joins.
- **Apple's SF Symbols only for standard controls.** **[checked]** Allowed: `xmark`, `xmark.circle.fill`, `plus`, `plus.circle`, `minus.circle`, `chevron.*`, `checkmark`, `checkmark.circle.fill`, `ellipsis`, `ellipsis.circle`, `square.and.arrow.up`, `trash`, `magnifyingglass` (search fields only), `sidebar.left`, `line.3.horizontal` (drag handles), `arrow.right` (text links), `arrow.up.arrow.down`, `chevron.up.chevron.down`, `arrow.uturn.backward`, `arrow.counterclockwise`, and keyboard keys (`return`, `delete.left`, `globe`, `keyboard`, `shift`, `shift.fill`, `capslock.fill`).
- Everything else, such as `sparkles`, `wand.and.stars`, `waveform`, `mic`, `bookmark`, `link`, `play.*`, `note.text`, `doc.on.clipboard`, and `info.circle`, gets a `BrandArt` glyph. If none exists, draw one in the same grammar and add it to `mac/tools/gen_icons.py`.
- **System surfaces** (Control Center controls, Live Activities and the Dynamic Island, widgets, context menus, the menu bar item) can only show SF Symbols or custom symbols from the asset catalog. Export our glyphs as custom symbols (`.symbols` in Assets) and use those; until a glyph is exported, the closest SF Symbol is allowed there, marked on its line with `// brand: system surface`. The menu bar item uses the bars mark.
- Icons sit bare or in a tinted disc of their own color. Don't put a white disc on a colored tile.
- **Diagrams:** Capture (rings), Refine (paths into lines), and Understand (overlapping circles). Use them on Home (the Method band), onboarding, empty states, and loading. Don't use them as wallpaper. Ink strokes on paper or on their own fill.

## 4. Marks and the app icon

- **App icon:** the notation bars (B1). A paper mark on a persimmon field, flat, with glass off on the mark. Ink and reversed alternates. Masters are in `brand/`.
- **Colophon:** the tangent rings (R3a), for the website, onboarding, About, and print. Never as the app icon.
- Public name: Verbose. Wordmark: lowercase 'verbose.' in the serif, persimmon period. Tagline: 'Go ahead. Be verbose.' 'Verbatim' is the internal codename.
- **In-app wordmark:** the bars plus lowercase "verbose." in the serif, as in the sidebar (`Ink.wordmark`). The period is a mark in the text-safe persimmon (`accentText`, 5.1:1 on paper); the bright `persimmon` measures 2.5:1 on paper, too low for a small mark. The tagline (`Ink.tagline`) sits under it in the serif on About and the first onboarding screen.
- **Retired:** the V wing mark (`BrandArt.mark`). It must not appear anywhere.
- One color per mark: persimmon, ink, or paper.

## 5. Surfaces and glass

1. **[checked]** Never put text on a blur or material (`.ultraThinMaterial`, `.regularMaterial`, `.glassEffect`). Glass belongs to system chrome: toolbars, tab bars, sheets, and transient controls without text. A floating bar with text uses `Ink.bar` or `Ink.card` plus a hairline.
2. Paper, illustrations, and colored tiles stay opaque.
3. Radii: 9 for buttons and fields, 12–14 for rows and sheets, 16–18 for tiles and panels, 22 for the Record panel. Don't round everything the same.
4. Shadows: `shadow.low` only, or a hairline. No soft shadows everywhere.

## 6. Layout (Home and other dashboards)

1. One grid per screen. On Mac Home it's 12 columns, and every band splits at the same 7 / 5 edge.
2. Stats appear in one place only (This week).
3. Rows that sit side by side share a height so they line up.
4. Explain the app (the Method band) with the diagrams, not with a second set of colored cards.

## 7. Motion

- Use the `Motion` tokens. Ease-out or critically damped springs; no bounce in productivity controls.
- Never animate keyboard-initiated or high-frequency actions.
- Movement means something. The Record meter shows the real mic level: live while recording, live while you hover (Mac) or touch (iPhone) the Record panel, and still otherwise. Hover opens the mic, so the system's orange mic indicator shows during it; close the mic within one second of the pointer leaving. Don't animate the meter randomly, and don't loop icon animations.
- Icons draw on once when they appear and again on hover. Limit Motion turns this off.

## 8. Words

Google developer documentation style: second person, active voice, sentence case, serial commas, and no "simply", "just", "easily", "currently", or "soon". Name buttons with verbs ("Record", "Copy", "Transcribe again in…").

## 9. Website

The marketing site and the link transcriber (`link-transcriber/static`) use the same tokens as CSS variables, the same type roles (serif: Newsreader from Google Fonts, SIL OFL, until Instrument Serif is licensed; sans: the system stack; mono: IBM Plex Mono), the colophon rings, and the same icon set. No gradients, no purple, no centered hero with one button over three icon cards.

## 10. QA before you call a screen done

- [ ] Only tokens; no new hex.
- [ ] Every meaningful icon is `BrandArt`.
- [ ] Mono only for shortcuts, timecodes, and indexes.
- [ ] No text on blur.
- [ ] One accent fill per screen, and each color keeps its meaning.
- [ ] Light, dark, Increase Contrast, Reduce Transparency, Limit Motion, and larger text checked.
- [ ] Compared side by side with Home D (board "Verbatim new screens").
