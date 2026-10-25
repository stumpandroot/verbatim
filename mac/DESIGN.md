# Verbatim design rules

This file is the brand spec for every Verbatim surface: the Mac app, the iPhone app, the keyboard, the dictation bar, the menu bar, widgets and Live Activities, the app icon, and the website. Agents read it before changing any UI. If something you need isn't here, ask; don't invent a color, a typeface, an icon, a material, or a radius.

Sources: the family design system (project doc `01-design-system.md`, v2.1), the brand marks decision (`brand/README.md`, October 18, 2026), the interface icon set (October 18, 2026), Tim's Home review (October 22, 2026), his Home feel choices the same day (sharp corners, stacked tiles, full motion), and the website-style mockup for the Mac app ("The app, in the website's clothes", October 23, 2026; §11). `mac/tools/brand-check.sh` enforces the rules marked **[checked]**.

## 1. Color

The palette lives in `mac/Verbatim/Views/Tokens.swift` (`Ink`). Use tokens only. **[checked]** No hex values outside `Tokens.swift`, and no `Color.red`, `.blue`, `.orange`, `.green`, `.gray`, `.purple`, `.pink`, `.yellow`, or `.accentColor` outside it. Errors and destructive actions use `Ink.danger` (defined in Tokens.swift), with an icon and a word, never persimmon.

| Token | Hex (light) | Means | Use it for |
|---|---|---|---|
| `paper` | `#F5F0E6` | The page | App background |
| `reader` / `card` | `#FFFDF9` | Content you read | Transcript sheet, neutral cards, rows |
| `ink` | `#26352E` | Structure | Text, strokes, primary buttons (`interactive`) |
| `persimmon` | `#FA6B47` | **Record** | Record panel, voice-note chips, recording state, today's bar in This week, the app icon |
| `butter` | `#F4C76B` | **Dictate** | Dictate tile, the Last dictation panel |
| `sage` | `#AFC398` | **Import** (files and links) | Import tile, imported-file and link chips |
| `petal` | `#EFB6C8` | **App audio** | App audio tile, app-audio chips |
| ink outline on `card` | — | **Live captions** | Live captions tile and its chips |

Neutral (`ink` at 6% with `dim` text, plus the item's own diagram or initials): kinds (journal, idea, meeting, note, podcast, video, talk, interview), tags, projects, filters, and counts. They never borrow an action hue.

Speaker pills in a transcript are the one exception: they may use the four panel colors (`panelRecord`, `panelPetal`, `panelSage`, `panelButter`) in a fixed rotation by speaker order (first speaker record, then petal, sage, butter, and around again), with ink text and the speaker's name. The name carries the meaning; the hue only tells speakers apart. Everywhere else, color still means a capture mode.

Reading washes are a separate role and appear only on the transcript and document surfaces, never beside the action tiles: saved = `saved` (butter), playing = `playing` (sage), search match = `match` (persimmon).

Rules:

1. One color, one meaning. Never reuse a hue for a different action on the same screen. Tags, filters, and counts are neutral (filter chips use the `chip` wash, §11). Two exceptions: project cards on color panels (§11), which cycle butter, petal, and sage as decoration (their text and eyebrow say "Project", so the hue never stands alone), and speaker pills in a transcript, which rotate record, petal, sage, and butter (above; the name is always on the pill).
2. About 70% neutral, 20% ink, 10% accent on working screens. Home and onboarding may run richer.
3. One saturated fill per screen: persimmon, for the primary action. The pastel start tiles on Home (butter, sage, petal) are allowed because each one is a different action; everything else is a tint, a color panel (§11), or neutral.
4. Text on paper uses `ink`, `dim`, `mute`, or a text-safe variant (`accentText`, `sageText`), never a bright fill.
5. Text on every fill is ink: petal 7.5:1, butter 8.1:1, sage 6.8:1, persimmon 4.45:1 (so on persimmon, ink text must be 18 pt or larger, or semibold 14 pt or larger). Never put reader white text on persimmon; it measures 2.8:1.
6. Status never depends on color alone; pair it with a word or an icon.
7. Dark mode is a near-black green, never an inversion. Color panels get slightly deeper fills in dark only (`panelRecord` `#E2694B`, `panelButter` `#DDB563`, `panelSage` `#9DB088`, `panelPetal` `#D9A3B5`; light uses the brand values, with `panelRecord` = the Record fill `#FB7350`). Ink text stays on them in both modes.

## 2. Type

| Role | Font | Where |
|---|---|---|
| Display | `Ink.serif` (New York stands in for Instrument Serif) | Greeting, Record, section titles, document titles, big numbers |
| UI and body | SF Pro, Dynamic Type | Everything else: tile names, labels, rows, buttons, transcript text |
| Data | `Ink.mono` | Keyboard shortcuts, timecodes and durations, running recording timers, file paths, tabular indexes ("01"), and in the website style (§11) eyebrows ("◇ This week"), page-title counts ("46 transcripts"), day headers, and a list's status column. Never smaller than 12 pt. |

Rules:

1. Sentence case everywhere. No uppercase tracked labels except `Overline`, at most one per screen.
2. Metadata lines are sans, not mono: "Voice note · 7:50 · Today". Use `.monospacedDigit()` for numbers that change. **[checked]** In files marked `// brand: web style`, mono text is never smaller than 12 pt (`Ink.mono` sizes, `Keycap` sizes, no `Overline`).
3. Shortcuts render as keycaps: mono inside an outlined rectangle with the button radius (4).
4. Never set reading text in the serif.
5. Button names: SF Pro semibold (13.5 pt in a regular pill, 12 pt in a mini). Mac Home's tile names are serif 21 pt with a 12 pt sans detail (§6.5).

## 3. Icons

- **Ours (`BrandArt`) for anything that means something in Verbatim:** record, dictate, import, link, app audio, captions, library, moments, bookmark, play, export, summaries, speakers, language, voice, search inside a transcript, empty states, and all navigation. Fine line: a 24-unit grid with a 1.5 stroke, or a 112-unit box with a 6 stroke. Round caps and joins.
- **Apple's SF Symbols only for standard controls.** **[checked]** Allowed: `xmark`, `xmark.circle.fill`, `plus`, `plus.circle`, `minus.circle`, `chevron.*`, `checkmark`, `checkmark.circle.fill`, `ellipsis`, `ellipsis.circle`, `square.and.arrow.up`, `trash`, `magnifyingglass` (search fields only), `sidebar.left`, `line.3.horizontal` (drag handles), `arrow.right` (text links), `arrow.up.arrow.down`, `chevron.up.chevron.down`, `arrow.uturn.backward`, `arrow.counterclockwise`, and keyboard keys (`return`, `delete.left`, `globe`, `keyboard`, `shift`, `shift.fill`, `capslock.fill`).
- Everything else, such as `sparkles`, `wand.and.stars`, `waveform`, `mic`, `bookmark`, `link`, `play.*`, `note.text`, `doc.on.clipboard`, and `info.circle`, gets a `BrandArt` glyph. If none exists, draw one in the same grammar and add it to `mac/tools/gen_icons.py`.
- **System surfaces** (Control Center controls, Live Activities and the Dynamic Island, widgets, context menus, the menu bar item) can only show SF Symbols or custom symbols from the asset catalog. Export our glyphs as custom symbols (`.symbols` in Assets) and use those; until a glyph is exported, the closest SF Symbol is allowed there, marked on its line with `// brand: system surface`. The menu bar item uses the bars mark.
- Icons sit bare. Home's start tiles and Record panel have no disc behind the icon. Elsewhere an icon may sit in a tinted disc of its own color; never put a white disc on a colored tile.
- **Diagrams:** Capture (rings), Refine (paths into lines), and Understand (overlapping circles). Use them in onboarding, the iPhone's Method cards, empty states, and loading. On Mac color panels they become the panel drawings (§11: rings, lines, circles, strands). Don't use them as wallpaper. Ink strokes on paper or on their own fill.

## 4. Marks and the app icon

- **App icon:** the notation bars (B1), dimensional: white bars with depth and a soft shadow on a persimmon-red field that lightens toward the top left (Tim's render, October 23, 2026). Masters: `brand/verbose-app-icon-render-1254.png` (source), `verbose-app-icon-1024.png` (iPhone, full bleed), `verbose-app-icon-mac-1024.png` (Mac shape). The flat paper-on-persimmon bars stay the mark everywhere else (sidebar, website, favicon).
- **Colophon:** the tangent rings (R3a), for the website, onboarding, About, and print. Never as the app icon.
- Public name: Verbose. Wordmark: lowercase 'verbose.' in the serif, persimmon period. Tagline: 'Go ahead. Be verbose.' 'Verbatim' is the internal codename.
- **In-app wordmark:** the bars plus lowercase "verbose." in the serif, as in the sidebar (`Ink.wordmark`). The period is a mark in the text-safe persimmon (`accentText`, 5.1:1 on paper); the bright `persimmon` measures 2.5:1 on paper, too low for a small mark. The tagline (`Ink.tagline`) sits under it in the serif on About and the first onboarding screen.
- **Retired:** the V wing mark (`BrandArt.mark`). It must not appear anywhere.
- One color per mark: persimmon, ink, or paper.

## 5. Surfaces and glass

1. **[checked]** Never put text on a blur or material (`.ultraThinMaterial`, `.regularMaterial`, `.glassEffect`). Glass belongs to system chrome: toolbars, tab bars, sheets, and transient controls without text. A floating bar with text uses `Ink.bar` or `Ink.card` plus a hairline.
2. Paper, illustrations, and colored tiles stay opaque.
3. Radii (sharp, `Radius` in Tokens.swift): 4 for filter chips, fields, and keycaps; 6 for rows and sheets; 8 for tiles and cards; 10 for the Record panel, color panels, and big strips. Buttons are pills (capsules), and so is the search field (§11). Use the tokens, never a number. Don't round everything the same.
4. Shadows: a hairline, or the website's hard offset shadow (`Ink.hard`, no blur) under an ink-outlined card or highlighted row (§11). No soft shadows everywhere.
5. Color panels (§11) are opaque brand fills with paper grain; grain never goes on paper, cards, or under glass, and it turns off under Increase Contrast and Reduce Transparency.

## 6. Layout (Home and other dashboards)

1. One grid per screen. On Mac Home it's 12 columns, and every band splits at the same 7 / 5 edge.
2. Stats appear in one place only (This week).
3. Rows that sit side by side share a height so they line up.
4. Mac Home, top to bottom: the mono date eyebrow and the big two-line greeting ("Good afternoon, Tim." / italic "What are we keeping?"); the Record panel (7 columns, 196 pt, ink outline and a (6, 7) hard shadow at rest, rings drawing) beside four tiles (5 columns, two by two, 196 pt together); one slim **This week** strip across all 12 columns (eyebrow, words in the serif, seven 8-pt bars with today in the Record color, then recordings, time saved typing, and moments on the right; Settings › General › Show This week on Home); then Recent recordings (two flat rows) beside Last dictation (one card on a butter panel). The Method band is gone from Mac Home; the iPhone keeps its Method carousel until its own pass.
5. Home's start tiles on Mac: the bare 22 pt icon top left, the shortcut keycap top right where one exists, and the name (serif 21) with a one-line 12 pt detail at the foot. Dictate butter, Import sage, App audio petal (color panels with grain), Live captions card white with an ink outline.
6. Whole cards are buttons: This week opens You (iPhone: About me); Last dictation copies its words wherever you click, and its Copy pill turns into "✓ Copied" for 1.6 s. A recent recording with filler words shows "14 filler words" and a mini dark "Clean up" pill, which opens the transcript's Cleaned tab.

## 7. Motion

- Use the `Motion` tokens. Ease-out or critically damped springs; no bounce in productivity controls.
- Never animate keyboard-initiated or high-frequency actions.
- Cards tilt toward the pointer, lift 2 pt, and catch a sheen and an edge light on hover, and press in (0.98) on click or touch (`CardMotion`, `HomeCard`). Keep hit-testing on a flat, untransformed layer: a 3D-rotated view loses clicks on macOS 26. iPhone has no hover, so cards only press.
- The Record meter breathes slowly and evenly at rest: each bar is its resting height × (0.42 + 0.5 × breath), with breath = 0.5 − 0.5 cos(2π t / 5.2 − 0.09 i). Never random. It shows the real mic level while you hover (Mac) or touch (iPhone) the Record panel and while recording. Hover opens the mic, so the system's orange mic indicator shows during it; close the mic within one second of the pointer leaving.
- The Method diagrams loop slowly (iPhone): Capture's rings swell, Refine's strands flow into clean lines, Understand's circles drift together and apart. On Mac the panel drawings loop (§11), at most one per screen.
- Loops (the breath, the diagrams, the panel drawings) use TimelineView with a Canvas, at most 30 frames a second, and pause when they're off screen or the app is inactive (`LoopTimeline`). Never drive a loop with state or a repeatForever animation; on macOS 26 every SwiftUI transaction is expensive.
- Big cards (Record, tiles, color panels, Moments cards, This week, Last dictation) tilt as above and, on Mac, pick up the 1.5 pt ink outline and a hard shadow on hover: (7, 9) under the pointer, (2, 3) while pressed. Flat list rows never tilt; they take the outline and a (4, 5) shadow on hover or selection (§11).
- Screens arrive at once: no entrance stagger on navigation, so a screen never makes you wait for its content.
- Icons arrive fully drawn and draw on again on hover. Icon draw-ons never loop.
- Sidebar rows: on hover a wash fades and scales in (180 ms, ease-out), the label nudges 2 pt right, and the icon redraws. The persimmon selection tick slides to the new row over 300 ms.
- Limit Motion (and the system's Reduce Motion) stills all of it: no tilt, lift, or scale, a still meter, still diagrams, icons fully drawn, and crossfades instead of slides.

## 8. Words

Google developer documentation style: second person, active voice, sentence case, serial commas, and no "simply", "just", "easily", "currently", or "soon". Name buttons with verbs ("Record", "Copy", "Transcribe again in…").

Every user-visible change adds a bullet to the `"next"` entry of `mac/ReleaseNotes/ReleaseNotes.json` in the same commit, in this style, present tense, with no exclamation points or em dashes. CI stamps that entry with the build's run number; after the build ships, a follow-up commit sets its build number (`mac/ReleaseNotes/README.md`). Both apps show the notes in What's new.

## 9. Website

The marketing site and the link transcriber (`link-transcriber/static`) use the same tokens as CSS variables, the same type roles (serif: Newsreader from Google Fonts, SIL OFL, until Instrument Serif is licensed; sans: the system stack; mono: IBM Plex Mono), the colophon rings, and the same icon set. No gradients, no purple, no centered hero with one button over three icon cards.

## 10. QA before you call a screen done

- [ ] Only tokens; no new hex.
- [ ] Every meaningful icon is `BrandArt`.
- [ ] Mono only for shortcuts, timecodes, and indexes.
- [ ] No text on blur.
- [ ] One accent fill per screen, and each color keeps its meaning.
- [ ] Light, dark, Increase Contrast, Reduce Transparency, Limit Motion, and larger text checked.
- [ ] Compared side by side with the website-style mockup (October 23, 2026) for Mac screens, or Home D and the Home feel mockup (October 22, 2026) for iPhone.
- [ ] Mac screens: built from the §11 kit, with the file marked `// brand: web style`.

## 11. Website style (Mac)

The Mac app wears the website's clothes (mockup "The app, in the website's clothes", October 23, 2026, `notes/web-style/playful.src.html`). Home and Library are done; every other Mac screen follows these rules when it's next touched. Build with the kit in `mac/Verbatim/Views/WebStyle.swift` and mark the file `// brand: web style` (brand-check then holds its mono text to 12 pt or larger).

**Titles**

1. The big two-line headline (serif 52, italic second line) is for Home only. Every other screen has a compact title: `PageTitle` (serif 34, a mono 12.5 count beside it such as "128 kept", controls and the search field on the right, an optional 14 pt dim lede under it).
2. Section titles are serif 26 with an italic second part ("Recent *recordings*", "Up *next*"), with an optional "Library →" text link (`SectionTitle`). Day headers are mono 12 with a dashed hairline ("Today · Fri Oct 23", `DayHeader`). Eyebrows are mono 12.5 with an outlined diamond ("◇ This week", `Eyebrow`), at most one per card.

**Lists**

3. List rows are flat (`FlatRowButton`, `flatRow(highlighted:)`): transparent on the paper with a hairline at the bottom and the row radius (6). Under the pointer or selected, a row takes the card fill, a 1.5 pt ink outline, and a (4, 5) hard shadow. **No tilt on rows.** Tilt stays on big cards: Record, tiles, color panels, This week, Last dictation, Moments cards.
4. Library-style rows: the kind dot (`KindDot`: source fill, ink icon for the kind; links an ink ring), a serif 21 title with an italic part where the data allows (after the project's name), a 12.5 pt sentence-case meta line, the status in mono, and the length in mono ("15:39").

**Controls and status**

5. Buttons are pills (`PillButton`, `PillLabel`, `PillButtonStyle`): **dark** (ink fill, paper text), **line** (1.5 pt ink inset outline), regular 36 pt or **mini** 28 pt. On a color panel use the fixed ink pill.
6. Filters are soft chips (`FilterChip`): the 4 pt button radius, the `chip` wash, no border; selected is ink with paper text. Never a capsule. A type chip may carry its source's color as a 9 pt dot (links: an ink ring); kinds, tags, and platforms have no dot.
7. Speaker pills on transcript lines rotate the four panel colors in a fixed order (record, petal, sage, butter; §1) with the name in ink. They're the only colored pills that don't mean a capture mode.
8. Status is plain colored text, never a capsule (`StatusText`): "Cleaned" in `accentText`, "Original" and counts in `dim`, "✓ Video kept" in `keptText`, "Needs retry" in `danger`. A check or an icon may lead it; the word carries the meaning.
9. The search field is a pill with a 1.5 pt ink outline on card white (`WebSearchField`).
10. Mono labels are never smaller than 12 pt. **[checked]** in files marked `// brand: web style`.

**Panels and art**

11. Color panels (Record, butter, sage, petal) are opaque fills with paper grain (`colorPanel`, `GrainOverlay`), ink text, and the panel radius. Dark mode uses the deeper `panel*` fills (§1.7).
12. A color panel may carry one oversized line drawing, clipped by the panel (`PanelArt`): `rings` (concentric circles anchored at the bottom that breathe, 2.6 s, ±7 %), `lines` (horizontal lines that draw in, hold, and draw out, staggered, 7 s), `circles` (three circles that drift apart and back, 7 s), `strands` (two curved strands with flowing dashes into short lines). **At most one drawing moves per screen** (Library: the project card under the pointer, otherwise the first); the rest hold still. All of them stop under Reduce Motion and Limit animation.
13. Empty screens get one horizontal card (`EmptyStateCard`): an 80 pt butter plate with an ink outline and the screen's icon, a serif 26 title, one or two sentences, and one dark pill.

**Windows**

14. Settings is its own window, never a screen inside the main window.

## 12. Dictation surfaces (Mac)

Settings › Dictation › Show dictation in picks one of three styles (mockup "Notch", October 24, 2026, sections 01 and 03). All three read the same `FlowBarModel` phases (idle, listening, working, notice, prompt), so notices and prompts work in each. Each is a non-activating panel at `.statusBar` level, of a fixed size, where only the drawn shape takes clicks: `RibbonControl` or `tapArea`, never SwiftUI Buttons (macOS 26 click safety). Reduce Motion and Limit animation hold them still: spinners stop, and shape changes become a 0.12 s fade.

1. **Ribbon** (`Flow/FlowBarView.swift`): a paper or ink tab flush with the bottom, left, or right edge, with persimmon voice bars. The default. Its settings sit in Dictation when it's chosen (Show the Ribbon when you're not dictating, Style, Voice mark).
2. **Notch** (`Flow/Notch.swift`): Apple's black (`notchBlack`), so it reads as the notch doing something: flush with the top edge, drawn 1 pt larger than the hardware, rounded bottom corners (the notch's 9 pt for one row, up to 20 pt as it grows), and 6 pt concave flares into the menu bar. Widths are fixed per state (the camera plus 2 × 117 pt listening, 2 × 137 pt hovered or for an error, 2 × 160 pt for a prompt, 2 × 77 pt pointed at while idle), so only the contents change. Left of the camera: the app's icon and name; right: nine persimmon voice bars and a mono timer. Text is `onBlack` and `onBlackDim` with `onBlackHair` outlines; errors use `dangerOnBlack` with the attention glyph and a word, never color alone. Kept out of screenshots and screen sharing (`sharingType = .none`). On a display without a notch it's a 250 pt pill hanging 8 pt below the menu bar and gone at rest, or the Ribbon (Settings › Dictation › On displays without a notch).
3. **Floating button** (`Flow/FloatingButton.swift`): four looks (Ink disc, Bars pill, Quiet dot, Labeled pill) at 32, 44, or 56 pt, never a click target under 28 pt. Ink bodies wear a 1.5 pt paper hairline and a hard ink offset shadow so they read on any wallpaper; persimmon marks the live voice. The labeled pill is `butterFixed` (butter means Dictate) with grain and ink marks, never persimmon on butter. Words, Stop and Cancel, notices, and prompts sit beside it, toward the middle of the screen.

The hotkey picker (Settings › Dictation › Hotkey) shows each choice's keys as raised keycaps (`KeyChip`: mono 12.5, ink outline, a 2 pt ink floor).

## 13. Native look

Each device has a second look, Native (mockup "Verbose, in a native look", October 25, 2026), that reads like one of Apple's own apps. `AppLook` (`Views/Look.swift`) holds the choice per device, never synced: the App Group on iPhone (key `appearance.look`, values `verbose` and `native`), so the keyboard follows it with no setting of its own. New installs start in Verbose style; onboarding's Pick a look step and Settings › Appearance change it. A pick shows a small centered card in the new look ("Switching to Native…", its thumbnail, and a spinner) over a scrim of the new look's background; the look is stored once the card is up, everything rebuilds behind it, and the card fades out over the result (`Views/LookSwitch.swift`; under Limit animation the card appears at once and leaves with a fade, with no scaling). Everything in sections 1 to 12 describes Verbose style; Native replaces it as follows.

1. **The only brand element is the persimmon accent**, set as the tint at the root: `Ink.nativeAccent`, #D5431F in light (white on it and it on white both 4.5:1) and #FF6B47 in dark (6.0:1 on #1C1C1E). The record disc keeps the brand persimmon (`persimmonFixed`): it carries no text. Switches stay system green on iPhone.
2. **Stock everything else:** system grouped backgrounds, inset grouped cards, SF Pro (`.monospacedDigit()` for times and counts; no New York serif, no SF Mono), navigation large titles, segmented pickers, capsule chips, standard list rows, `.borderedProminent` and `.bordered` buttons, and SF Symbols. No paper, grain, color panels, line art, ink outlines, or hard shadows.
3. **Branch at the kit, not the screen.** The iPhone kit (`PhoneWebStyle.swift`, `NativeLook.swift`) reads `@Environment(\.look)` and draws either look; `LookStyle` colors (`.lookInk`, `.lookCard`, …) resolve from the environment. Home, Library, the transcript header, Settings, and Appearance have Native layouts of their own. On iPhone, the Home, Library, and Moments tabs are rebuilt in a new look (an identity per look on their navigation stacks, as the Mac's `lookRebuild()` does), so a screen and its navigation bar never switch in place. Only the tab on screen rebuilds when the look changes; a tab you left keeps its look until you open it again. Settings isn't rebuilt, because the look changes from Settings › Appearance. Home's two layouts are separate screens with their own bar setup.
4. **Meaningful color goes.** Verbose style's hues say "this came from Dictate" or "this is Ginna"; in Native every such place keeps a word or a symbol.
5. **Text on glass, Native only.** Native follows Apple and puts text on system glass in standard places: the tab bar, toolbars, the player bar, and the scrubber's time bubble. §5.1 still holds for Verbose style. Keep scroll edge effects on, and check both ends of the glass slider, Reduce Transparency, and Increase Contrast.
6. **The keyboard follows the look** chosen on that iPhone: Apple's gray keyboard in flat colors (an extension can't use the system keyboard's glass), SF Pro, and persimmon only on Tap to talk, the voice bars, and Done. It reads the look once per appearance from the App Group, like the dictate button's settings; without Full Access it keeps Verbose style.
7. **What doesn't switch:** the app icon, the menu bar mark, the notch and Dynamic Island, widgets, and Live Activities.
8. **[checked]** Brand-check skips Native look code for SF Symbols, system color names, glass, and mono sizes. Mark a whole file `// brand: native file`, a block between `// brand: native begin` and `// brand: native end`, or one line with a trailing `// brand: native`. Hex colors still live in Tokens.swift, and the retired mark stays retired.

### Premium Native on iPhone

Premium Native (mockup "premium", section 01, October 25, 2026) replaced the first Native look on iPhone. Same tabs and features; the feel changes (`PremiumKit.swift`, `PremiumHome.swift`, `PremiumYou.swift`, `PremiumRecord.swift`, and the pure rules in `PremiumRules.swift`, which `mac/tools/test-premium.sh` checks).

1. **Page:** warm off-white #F6F3F1 (#0B0B0C in dark) with a soft persimmon glow at the top (`PremiumInk.paper`, `PremiumStyle.glow`), drawn once behind each screen by `phonePage()`.
2. **[checked]** **Gradient cards** use the four warm brand colors only, never purple: persimmon (This week, the year, the Summary), ink green (You's week), sage and rose (You's stat cards). The stops live in Tokens.swift (`PremiumInk`). White text measures 4.5:1 or better from a third of the way down; only big numbers (3:1) sit in the top third, under a 10% highlight that's gone by a third of the way. The Summary uses the persimmon's deeper half, so its small header keeps 4.5:1. Text on a gradient is solid white, never faded.
3. **Type:** SF Pro, with SF Pro Rounded heavy for big numbers (`PremiumStyle.number`). Titles stay SF Pro; no serif.
4. **Accent:** `Ink.nativeAccent`. Text on it is white in light and black in dark (`PremiumInk.onAccent`, 7.2:1).
5. **Recording items** (`PremiumRecordingItem`, Home and Library): a date line, a bold two-line title, a two-line preview of the first cleaned lines (the kind and state while there's no text), a play pill with the length, the state, and ⋯ (Add to project, Copy text, Share, Delete). Plain day headers, no grouped boxes.
6. **The record button** floats just above the tab bar's trailing end on Home and Library: an overlay, because a stock tab can't take a long press. A tap starts a voice note; a long press offers Dictate, Live captions, and Import. It hides while a recording runs. Home's Record card is off unless Settings › Appearance › Show the Record card is on.
7. **Record flow:** a full-screen recorder (an 88 pt rounded clock, a live waveform with the playhead in the middle, Mark moment, Stop, and Pause; moments save as bookmarks), then the Saved sheet (progress, kind, project, Open transcript, Record another). Adding to an existing transcript skips the sheet, so its recorder keeps Discard.
8. **You** follows Journal's Insights: the week (days used in the last seven, with no streak to keep), the year with month bars, two stat cards, and a month calendar with a dot on each day something was recorded or dictated.
9. **Performance:** colors and gradients are built once (static), lists stay lazy, nothing enters with an animation, and navigation never rebuilds a screen with `.id`.

### 13.1 Native on the Mac

The Mac's look is its own (`appearance.look` in the Mac's defaults); Settings › General › Look (two live thumbnails above the light or dark pop-up) and the welcome tour's Pick a look step change it. New installs start in Verbose style.

1. **Tokens and type switch without screen edits.** Under Native, `Ink.dyn` and `Ink.dynC` ask `NativeSwap` (`Views/NativeLook.swift`) for a system color by the token's light value (`NativeRoles`, `Views/LookRules.swift`): paper becomes the window background, card and reader `controlBackgroundColor`, ink, dim, mute, and faint the label colors, and accent text `Ink.nativeAccent`. Brand fills keep their color. `Ink.serif` and `Ink.mono` become SF Pro (mono keeps `.monospacedDigit()`). `lookRebuild()` redraws a window's content when the look changes, behind the switching card, with no animation of its own; sheets stay open.
2. **The kit draws Native** (`WebStyle.swift`, `SettingsKit.swift`): color panels become group boxes, `PageTitle` and `SectionTitle` plain bold titles and headers, pills title-case `.borderedProminent` and `.bordered` faces, chips capsules, kind dots tinted SF Symbols, the empty state `ContentUnavailableView`, and Settings cards grouped form sections. Text on a panel uses `Ink.panelInk`.
3. **Native layouts:** a `NavigationSplitView` with the standard sidebar (SF Symbols in persimmon, count badges, projects; Settings moves to the app menu, ⌘,), Home in group boxes, the Library as a `Table`, the transcript with its modes in the toolbar, an inspector, and an opaque player bar, and the Settings window as System Settings' sidebar and grouped form. Switches take the accent (persimmon on the Mac).
4. **What doesn't switch on the Mac:** the Ribbon, the notch, the floating button (their fonts are pinned with `SurfaceFont`), the menu bar icon, and the app icon.
